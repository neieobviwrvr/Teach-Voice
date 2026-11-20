import AVFoundation
import MediaPlayer
import UIKit

/// Spielt einen importierten Podcast ab -- auch bei gesperrtem Bildschirm
/// (`UIBackgroundModes: audio` in project.yml), mit Steuerung auf dem
/// Sperrbildschirm / im Kontrollzentrum. Merkt sich die Hörstelle pro
/// Podcast im `PodcastStore`.
///
/// Nie gleichzeitig mit Lern-Audio: sobald Vorlesen, Signalton oder Aufnahme
/// die Audio-Session übernehmen (`AudioSessionCoordinator.activate`), pausiert
/// der Podcast.
@MainActor
final class PodcastPlayer: ObservableObject {
    static let rates: [Float] = [1.0, 1.25, 1.5, 1.75, 2.0]
    static let skipBackSeconds: TimeInterval = 15
    static let skipForwardSeconds: TimeInterval = 30
    private static let rateKey = "podcastPlaybackRate"
    static let autoDeleteKey = "podcastAutoDeleteFinished"

    @Published private(set) var currentId: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Float {
        didSet {
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
            if isPlaying { player?.rate = rate }
            updateNowPlaying()
        }
    }

    private let store: PodcastStore
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var studyAudioObserver: NSObjectProtocol?
    private var lastSavedPosition: TimeInterval = 0

    init(store: PodcastStore) {
        self.store = store
        let savedRate = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = Self.rates.contains(savedRate) ? savedRate : 1.0
        configureRemoteCommands()
        // `queue: nil`: läuft sofort im Thread von `activate()` -- der Podcast
        // ist pausiert, bevor das Lern-Audio startet.
        studyAudioObserver = NotificationCenter.default.addObserver(
            forName: AudioSessionCoordinator.willActivateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.pause() }
            } else {
                Task { @MainActor in self?.pause() }
            }
        }
    }

    var currentPodcast: Podcast? { currentId.flatMap { store.podcast($0) } }

    // MARK: - Steuerung

    /// Startet `podcast` an der gemerkten Stelle bzw. setzt ihn fort.
    func play(_ podcast: Podcast) {
        if currentId == podcast.id, player != nil {
            resume()
            return
        }
        unload()
        let url = store.fileURL(for: podcast)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentId = podcast.id
        duration = podcast.duration
        let start = PodcastProgress.resumePosition(
            position: podcast.position, duration: podcast.duration, finished: podcast.finishedAt != nil
        )
        currentTime = start
        lastSavedPosition = start
        if start > 0 {
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        observe(player: player, item: item)
        resume()
    }

    func resume() {
        guard let player else { return }
        // Zu Ende gehört und erneut Play: von vorn.
        if PodcastProgress.isAtEnd(position: currentTime, duration: duration) {
            seek(to: 0)
        }
        activatePlaybackSession()
        player.playImmediately(atRate: rate)
        setPlaying(true)
    }

    func pause() {
        guard let player, isPlaying || player.rate != 0 else { return }
        player.pause()
        setPlaying(false)
        savePosition(force: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = max(0, min(seconds, duration))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        savePosition(force: true)
        updateNowPlaying()
    }

    /// Vor dem Löschen eines Podcasts: Wiedergabe beenden, falls er läuft.
    func stopIfPlaying(_ id: UUID) {
        guard currentId == id else { return }
        unload()
    }

    // MARK: - Intern

    private func setPlaying(_ playing: Bool) {
        isPlaying = playing
        AudioSessionCoordinator.isPodcastPlaying = playing
        updateNowPlaying()
    }

    private func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        // Pausen von außen (Anruf, Kopfhörer abgezogen, Sperrbildschirm)
        // im Zustand nachziehen.
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.syncPlayingState() }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
    }

    private func syncPlayingState() {
        guard let player else { return }
        let playing = player.timeControlStatus != .paused
        guard playing != isPlaying else { return }
        setPlaying(playing)
        if !playing { savePosition(force: true) }
    }

    private func tick(_ seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        savePosition(force: false)
    }

    /// Alle 10 s (und bei Pause/Sprung/Ende) die Hörstelle sichern -- nicht
    /// jede Sekunde in die Datei schreiben.
    private func savePosition(force: Bool) {
        guard let id = currentId else { return }
        guard force || abs(currentTime - lastSavedPosition) >= 10 else { return }
        lastSavedPosition = currentTime
        store.setPosition(id, position: currentTime)
    }

    private func didFinish() {
        guard let id = currentId else { return }
        store.markFinished(id)
        setPlaying(false)
        currentTime = duration
        if UserDefaults.standard.bool(forKey: Self.autoDeleteKey) {
            unload()
            store.delete(id)
        }
    }

    private func unload() {
        if let player {
            player.pause()
            savePosition(force: true)
            if let timeObserver { player.removeTimeObserver(timeObserver) }
        }
        timeObserver = nil
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player = nil
        currentId = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        AudioSessionCoordinator.isPodcastPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Sperrbildschirm

    private func updateNowPlaying() {
        guard let podcast = currentPodcast else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: podcast.title,
            MPMediaItemPropertyArtist: "Teach (Voice)",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.handleRemote { $0.resume() } ?? .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handleRemote { $0.pause() } ?? .commandFailed
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleRemote { $0.togglePlayPause() } ?? .commandFailed
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackSeconds)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.handleRemote { $0.skip(by: -PodcastPlayer.skipBackSeconds) } ?? .commandFailed
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForwardSeconds)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.handleRemote { $0.skip(by: PodcastPlayer.skipForwardSeconds) } ?? .commandFailed
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            return self?.handleRemote { $0.seek(to: target) } ?? .commandFailed
        }
    }

    /// Fernbedienungs-Befehle kommen auf dem Main Thread an.
    private nonisolated func handleRemote(_ action: @escaping @MainActor @Sendable (PodcastPlayer) -> Void) -> MPRemoteCommandHandlerStatus {
        guard Thread.isMainThread else {
            Task { @MainActor in action(self) }
            return .success
        }
        let handled: Bool = MainActor.assumeIsolated {
            guard player != nil else { return false }
            action(self)
            return true
        }
        return handled ? .success : .noActionableNowPlayingItem
    }
}
