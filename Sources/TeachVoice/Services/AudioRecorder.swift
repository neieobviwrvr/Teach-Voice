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

    func startRecording() async {
        guard await requestPermission() else {
            permissionDenied = true
            return
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
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            lastRecordingURL = url
            isRecording = true
        } catch {
            isRecording = false
        }
    }

    /// Stoppt die Aufnahme und liefert die Datei-URL für die Transkription.
    func stopRecording() -> URL? {
        recorder?.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return lastRecordingURL
    }
}
