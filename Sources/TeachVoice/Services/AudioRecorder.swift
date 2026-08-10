import AVFoundation

/// Nimmt die gesprochene Antwort des Users als 16kHz-Mono-WAV auf
/// (das Format, das Whisper/WhisperKit erwartet) und legt sie temporär ab.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private(set) var lastRecordingURL: URL?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func beginRecording() async -> Bool {
        guard await requestPermission() else {
            permissionDenied = true
            return false
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
        try? session.setActive(true)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("answer-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            newRecorder.isMeteringEnabled = true
            recorder = newRecorder
            newRecorder.record()
            lastRecordingURL = url
            isRecording = true
            return true
        } catch {
            isRecording = false
            return false
        }
    }

    func startRecording() async {
        _ = await beginRecording()
    }

    /// Stoppt die Aufnahme und liefert die Datei-URL für die Transkription.
    func stopRecording() -> URL? {
        recorder?.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return lastRecordingURL
    }

    /// Für den Hands-free-Modus: nimmt auf, bis der User `silenceTimeout`
    /// Sekunden am Stück still war (kurze Formulierungspausen darunter zählen
    /// nicht), oder bis `maxDuration` als Sicherheitsnetz erreicht ist (falls
    /// z.B. Hintergrundgeräusche eine echte Stille verhindern).
    func recordUntilSilence(
        silenceTimeout: TimeInterval = 5.0,
        silenceThresholdDB: Float = -35.0,
        maxDuration: TimeInterval = 45.0
    ) async -> URL? {
        guard await beginRecording() else { return nil }

        let pollInterval: TimeInterval = 0.2
        var silenceElapsed: TimeInterval = 0
        var totalElapsed: TimeInterval = 0

        while isRecording {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard let recorder, recorder.isRecording else { break }

            recorder.updateMeters()
            let level = recorder.averagePower(forChannel: 0)

            if level < silenceThresholdDB {
                silenceElapsed += pollInterval
            } else {
                silenceElapsed = 0
            }
            totalElapsed += pollInterval

            if silenceElapsed >= silenceTimeout || totalElapsed >= maxDuration {
                break
            }
        }

        return stopRecording()
    }
}
