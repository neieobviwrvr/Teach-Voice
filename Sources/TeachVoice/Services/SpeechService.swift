import AVFoundation

/// Liest Karteikarten-Text vor -- bevorzugt über Cloud-TTS (Google Cloud
/// WaveNet, siehe `CloudSpeechService`/`text-to-speech`-Edge-Function), mit
/// automatischem Fallback auf die native, kostenlose On-Device-TTS
/// (`AVSpeechSynthesizer`), falls kein Netz da ist oder der Cloud-Call
/// fehlschlägt.
///
/// Grund für den Wechsel weg von reinem on-device TTS: empirisch bestätigt
/// (siehe Chat-Historie), dass viele User real nur Apples Standard-
/// Kompaktstimme zur Verfügung haben -- Enhanced/Premium-Stimmen erfordern
/// manuellen Download in den Systemeinstellungen (oft hunderte MB, macht
/// niemand im Prüfungsstress), Siri-Stimmen sind für Drittanbieter-Apps
/// grundsätzlich gesperrt. Der lokale Fallback bleibt trotzdem bestehen --
/// die App soll auch ganz ohne Internet nutzbar sein, nur eben mit
/// schlechterer Stimmqualität.
///
/// Cloud-Antworten werden lokal gecacht (`AudioFileCache`, Hash aus
/// Text+Stimme) -- dieselbe Frage wird bei Spaced Repetition oft wiederholt
/// vorgelesen, aber nur beim ersten Mal tatsächlich synthetisiert.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    /// Der Hintergrund-Task, der den Cloud-Fetch (+ ggf. lokalen Fallback)
    /// einer einzelnen `speak()`-Anfrage antreibt. `stop()` bricht ihn immer
    /// zuerst ab -- sonst könnte eine gerade noch ladende alte Anfrage nach
    /// einem neuen `speak()`-Aufruf verspätet doch noch losplärren.
    private var cloudTask: Task<Void, Never>?
    /// Für `speakAndWait`: löst auf, sobald die aktuelle Ansage fertig ist --
    /// ob per lokalem Synthesizer (Delegate) oder per Cloud-Wiedergabe
    /// (AVAudioPlayer-Delegate), beide lösen dieselbe Continuation auf.
    private var pendingContinuation: CheckedContinuation<Void, Never>?

    private let auth: AuthManager

    init(auth: AuthManager) {
        self.auth = auth
        super.init()
        synthesizer.delegate = self
        // Kategorie wird NICHT hier fest gesetzt, sondern einheitlich über
        // AudioSessionCoordinator -- siehe dortige Doku, Grund ist Barge-in
        // (Mikrofon hört schon während einer laufenden Ansage mit).
    }

    /// `voice` überschreibt die normale Cloud-/Auto-Ermittlung komplett und
    /// erzwingt lokale Apple-Synthese -- nur für `VoicePickerView`s
    /// "Anhören"-Button gedacht, der GENAU DIESE eine on-device Stimme
    /// vorspielen will. Normale Aufrufstellen lassen den Parameter weg und
    /// bekommen den Cloud-Pfad (mit lokalem Fallback bei Fehler).
    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil, languageHint: String? = nil) {
        guard !text.isEmpty else { return }
        stop()
        AudioSessionCoordinator.activate()

        if let voice {
            speakLocally(text, voice: voice, languageHint: languageHint)
            return
        }

        // Optimistisch schon hier gesetzt (nicht erst wenn die Cloud-Antwort
        // tatsächlich eintrifft) -- sonst würde z.B. der "Spielt ab…"-Button
        // in StudyView während des kurzen Netzwerk-Ladens fälschlich noch
        // "Frage nochmal vorlesen" anzeigen.
        isSpeaking = true
        cloudTask = Task { [weak self] in
            await self?.speakPreferCloud(text, languageHint: languageHint)
        }
    }

    /// Für den Hands-free-Modus: wartet, bis die Ansage fertig ist (Cloud
    /// ODER lokaler Fallback), bevor der nächste Schritt losläuft.
    func speakAndWait(_ text: String, languageHint: String? = nil) async {
        guard !text.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Reihenfolge wichtig: speak() ruft intern stop() auf, das eine
            // ggf. noch offene Continuation sofort auflöst. Würde man die neue
            // Continuation VOR speak() setzen, würde genau dieser stop()-
            // Aufruf sie sofort wieder auflösen, bevor die Ansage überhaupt
            // begonnen hat.
            speak(text, languageHint: languageHint)
            pendingContinuation = continuation
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        cloudTask?.cancel()
        cloudTask = nil
        isSpeaking = false
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    // MARK: - Cloud-Pfad

    private func speakPreferCloud(_ text: String, languageHint: String?) async {
        let voiceKey = CloudSpeechConfig.voiceIdentifier

        if let cached = AudioFileCache.cachedFileURL(text: text, voice: voiceKey) {
            playCloudAudio(fileURL: cached)
            return
        }

        do {
            let token = await auth.validAccessToken()
            let data = try await CloudSpeechService.synthesize(text: text, accessToken: token)
            if Task.isCancelled { return }
            let cachedURL = AudioFileCache.store(data, text: text, voice: voiceKey)
            if let cachedURL {
                playCloudAudio(fileURL: cachedURL)
            } else {
                // Schreiben in den Cache fehlgeschlagen (z.B. Speicher voll) --
                // trotzdem direkt aus den Bytes abspielen, kein Grund die
                // Ansage deswegen ausfallen zu lassen.
                playCloudAudio(data: data)
            }
        } catch {
            if Task.isCancelled { return }
            // Kein Netz / Edge Function nicht erreichbar / Rate-Limit erreicht
            // -- App bleibt trotzdem benutzbar, nur mit schlechterer Stimme.
            speakLocally(text, voice: nil, languageHint: languageHint)
        }
    }

    private func playCloudAudio(fileURL: URL) {
        playCloudAudio(player: try? AVAudioPlayer(contentsOf: fileURL))
    }

    private func playCloudAudio(data: Data) {
        playCloudAudio(player: try? AVAudioPlayer(data: data))
    }

    private func playCloudAudio(player: AVAudioPlayer?) {
        guard let player else {
            // Kaputte/nicht abspielbare Audiodaten -- kein Crash, einfach
            // stumm bleiben. Sollte praktisch nie passieren (Google TTS
            // liefert immer valides MP3), aber besser als ein Force-Unwrap.
            return
        }
        player.delegate = self
        audioPlayer = player
        isSpeaking = true
        player.play()
    }

    // MARK: - Lokaler Fallback (Apple TTS)

    private func speakLocally(_ text: String, voice: AVSpeechSynthesisVoice?, languageHint: String?) {
        synthesizer.speak(makeUtterance(text, voice: voice, languageHint: languageHint))
    }

    private func makeUtterance(_ text: String, voice: AVSpeechSynthesisVoice? = nil, languageHint: String? = nil) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? Self.preferredVoice(languageCode: languageHint ?? detectedLanguage(for: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return utterance
    }

    /// Sehr einfache Heuristik: deutsches Gerätegebietsschema als Default,
    /// da die App primär für deutschsprachige Studierende gedacht ist.
    private func detectedLanguage(for text: String) -> String {
        Locale.preferredLanguages.first ?? "de-DE"
    }

    /// Wählt die lokale Fallback-Stimme für die gegebene Sprache:
    /// 0. Hat der User in `VoicePickerView` manuell eine Stimme gewählt
    ///    (`VoicePreference.selectedIdentifier`), hat die immer Vorrang --
    ///    ein ungültig gewordener Identifier liefert `nil` und fällt
    ///    automatisch auf `automaticVoice` zurück.
    static func preferredVoice(languageCode: String) -> AVSpeechSynthesisVoice? {
        if let identifier = VoicePreference.selectedIdentifier,
           let manual = AVSpeechSynthesisVoice(identifier: identifier) {
            return manual
        }
        return automaticVoice(languageCode: languageCode)
    }

    /// Die "Automatisch"-Kaskade OHNE die manuelle Auswahl aus
    /// `VoicePreference` -- eigenständig aufrufbar, damit `VoicePickerView`
    /// neben "Automatisch (empfohlen)" anzeigen kann, welche Stimme das
    /// GERADE konkret bedeutet.
    ///
    /// 1. Die beste heruntergeladene Enhanced/Premium-Stimme, falls
    ///    `AVSpeechSynthesisVoice.speechVoices()` der App überhaupt eine
    ///    solche meldet.
    /// 2. Sonst Apples Standard-Kompaktstimme (immer verfügbar, auch ganz
    ///    ohne jeden manuellen Download) als letzter Fallback.
    ///
    /// KEINE Siri-Stimmen-Sonderbehandlung (gab es hier früher) -- empirisch
    /// bei Simon bestätigt: Apple gibt Drittanbieter-Apps über diese API
    /// keinen Zugriff auf die als "Siri-Stimme 1-4" gebrandeten Personas.
    static func automaticVoice(languageCode: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }

        if let premium = candidates.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = candidates.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: languageCode)
    }

    fileprivate func finishSpeaking() {
        isSpeaking = false
        pendingContinuation?.resume()
        pendingContinuation = nil
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }
}

extension SpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finishSpeaking() }
    }
}
