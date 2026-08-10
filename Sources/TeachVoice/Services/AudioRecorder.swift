import AVFoundation

/// Nimmt die gesprochene Antwort des Users als 16kHz-Mono-WAV auf
/// (das Format, das Whisper/WhisperKit erwartet) und legt sie temporär ab.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private(set) var lastRecordingURL: URL?
    /// Manueller Fallback für `recordUntilSilence`, falls die Umgebungslautstärke
    /// die automatische Stille-Erkennung unzuverlässig macht (z.B. schwankender
    /// Lärmpegel) – z.B. per "Lösung abgeben"-Button gesetzt.
    private var manualStopRequested = false

    func requestManualStop() {
        manualStopRequested = true
    }

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
    ///
    /// Die Stille-Schwelle ist bewusst NICHT fest, sondern wird zu Beginn
    /// jeder Aufnahme aus der tatsächlichen Umgebungslautstärke berechnet
    /// (Kalibrierungsfenster + Sicherheitsabstand) – ein fixer Wert würde in
    /// lauten Umgebungen (Café, Bahn, WG-Küche) nie "Stille" erkennen, weil
    /// die Umgebung selbst schon lauter als jeder sinnvolle feste Schwellwert
    /// wäre.
    ///
    /// Wichtig: `silenceTimeout` zählt erst NACH dem ersten tatsächlich
    /// erkannten Sprechen (Pegel über der Schwelle). Eine Denkpause direkt
    /// am Anfang, bevor der User überhaupt zu sprechen beginnt, darf die
    /// Aufnahme nicht vorzeitig beenden – sonst würde ein kurzes
    /// `silenceTimeout` (z.B. 3s) genau die Leute abschneiden, die sich vor
    /// der Antwort noch kurz sammeln. `maxDuration` bleibt als Sicherheitsnetz
    /// für den Fall, dass gar nie gesprochen wird.
    func recordUntilSilence(
        calibrationDuration: TimeInterval = 1.0,
        silenceMargin: Float = 12.0,
        minSilenceThresholdDB: Float = -50.0,
        maxSilenceThresholdDB: Float = -20.0,
        silenceTimeout: TimeInterval = 3.0,
        maxDuration: TimeInterval = 45.0
    ) async -> URL? {
        manualStopRequested = false
        guard await beginRecording() else { return nil }

        let pollInterval: TimeInterval = 0.2
        var silenceElapsed: TimeInterval = 0
        var totalElapsed: TimeInterval = 0
        var ambientSamples: [Float] = []
        var silenceThresholdDB: Float?
        // Wird erst true, sobald der Pegel einmal über der Stille-Schwelle
        // lag – erst dann darf `silenceElapsed` überhaupt zum Timeout führen.
        var hasDetectedSpeech = false

        while isRecording {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            guard let recorder, recorder.isRecording else { break }

            // Wenn der umgebende Task abgebrochen wurde (z.B. weil ein
            // "Beenden"/"Anderen Unterordner wählen"-Button eine noch
            // laufende Sprachschleife explizit gecancelt hat), sofort
            // aufhören statt bis zur natürlichen Stille-/Timeout-Grenze
            // weiterzuhören.
            if Task.isCancelled { break }

            if manualStopRequested {
                manualStopRequested = false
                break
            }

            recorder.updateMeters()
            let level = recorder.averagePower(forChannel: 0)
            totalElapsed += pollInterval

            if totalElapsed <= calibrationDuration {
                // Kalibrierungsfenster: noch keine Stille-Erkennung, nur die
                // Umgebungslautstärke sammeln (Annahme: die ersten ~1s sind
                // noch kein Sprechbeginn, sondern Raumgeräusch).
                ambientSamples.append(level)
                continue
            }

            if silenceThresholdDB == nil {
                let ambientFloor = ambientSamples.isEmpty
                    ? minSilenceThresholdDB
                    : ambientSamples.reduce(0, +) / Float(ambientSamples.count)
                silenceThresholdDB = min(maxSilenceThresholdDB, max(minSilenceThresholdDB, ambientFloor + silenceMargin))
            }

            guard let threshold = silenceThresholdDB else { continue }

            if level >= threshold {
                // User spricht gerade (oder beginnt jetzt zu sprechen).
                hasDetectedSpeech = true
                silenceElapsed = 0
            } else if hasDetectedSpeech {
                // Stille zählt nur, nachdem der User schon mal wirklich
                // gesprochen hat – eine Denkpause vor dem ersten Wort zählt
                // bewusst nicht mit.
                silenceElapsed += pollInterval
            }

            if (hasDetectedSpeech && silenceElapsed >= silenceTimeout) || totalElapsed >= maxDuration {
                break
            }
        }

        return stopRecording()
    }
}
