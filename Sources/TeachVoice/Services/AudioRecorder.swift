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
    /// Ergebnis der LETZTEN `recordUntilSilence`-Aufnahme: wurde überhaupt
    /// einmal ein Pegel über der Stille-Schwelle gemessen? Erlaubt Aufrufern
    /// (siehe `HandsFreeStudyView.listenWhileSpeakingAndArbitrate`), eine
    /// teure Transkription zu überspringen, wenn der User erkennbar gar
    /// nichts gesagt hat (z.B. weil er nur einen Button getippt hat) --
    /// spart in genau diesem Fall die Whisper-Latenz.
    private(set) var lastRecordingDetectedSpeech = false

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

        // Einheitlich über AudioSessionCoordinator statt einer eigenen,
        // abweichenden Kategorie/Modus -- sonst würde eine gleichzeitig
        // laufende TTS-Ansage (Barge-in, siehe HandsFreeStudyView) durch das
        // Umschalten hier unterbrochen bzw. falsch geroutet.
        AudioSessionCoordinator.activate()

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
    ///
    /// Deaktiviert die AVAudioSession bewusst NICHT mehr hier (anders als
    /// früher) -- seit Barge-in (gleichzeitiges TTS+STT, siehe
    /// AudioSessionCoordinator) könnte eine parallel noch laufende Ansage
    /// genau dadurch abgewürgt werden, und häufiges Aktivieren/Deaktivieren
    /// zwischen einzelnen Aufnahmen kann hörbare Klicks verursachen. Die
    /// Session wird stattdessen erst beim echten Verlassen einer Lern-/
    /// Hands-free-Sitzung freigegeben (`AudioSessionCoordinator.deactivate()`
    /// in den jeweiligen `stopEverything()`).
    func stopRecording() -> URL? {
        recorder?.stop()
        isRecording = false
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
    /// `onSpeechDetected` feuert GENAU EINMAL, im Moment des allerersten
    /// Pegels über der Stille-Schwelle -- also sobald der User erkennbar zu
    /// sprechen beginnt, nicht erst wenn die ganze Aufnahme fertig ist.
    /// Gedacht für Barge-in (siehe `HandsFreeStudyView`): ohne dieses Signal
    /// würde eine parallel noch laufende TTS-Ansage erst nach dem KOMPLETTEN
    /// Aufnahmevorgang gestoppt (also unter Umständen über die ganze
    /// gesprochene Antwort hinweg weiterlaufen), statt sofort zu verstummen,
    /// wenn der User anfängt zu reden.
    ///
    /// `isPlaybackActive` (optional, für Barge-in): meldet, ob GERADE eine
    /// TTS-Ansage läuft. Ohne echte Echo-Unterdrückung (siehe
    /// `AudioSessionCoordinator` -- bewusst deaktiviert, sonst brach die
    /// Stille-Erkennung komplett) hört das Mikrofon die eigene Ansage
    /// zwangsläufig mit. Deshalb: solange `isPlaybackActive` true meldet,
    /// darf die kalibrierte Schwelle deutlich höher liegen als sonst
    /// (`maxSilenceThresholdDBWhilePlaying` statt `maxSilenceThresholdDB`) --
    /// filtert die normale Lautstärke der eigenen Ansage heraus, während ein
    /// User, der WIRKLICH dazwischenredet (spürbar lauter als die Ansage
    /// selbst), trotzdem erkannt wird -- echte Unterbrechung bleibt also
    /// möglich, nur eben nicht bei jedem kleinsten Mitschnitt der eigenen
    /// Stimme. Endet die Ansage von selbst (ohne dass unterbrochen wurde),
    /// wird automatisch NEU kalibriert -- sonst wäre die (an die Ansagen-
    /// Lautstärke angepasste, oft recht hohe) Schwelle für die tatsächliche,
    /// leisere Antwort in der jetzt wieder ruhigeren Umgebung zu hoch.
    func recordUntilSilence(
        calibrationDuration: TimeInterval = 1.0,
        silenceMargin: Float = 12.0,
        minSilenceThresholdDB: Float = -50.0,
        maxSilenceThresholdDB: Float = -20.0,
        maxSilenceThresholdDBWhilePlaying: Float = 0.0,
        silenceTimeout: TimeInterval = 3.0,
        maxDuration: TimeInterval = 45.0,
        onSpeechDetected: (() -> Void)? = nil,
        isPlaybackActive: (() -> Bool)? = nil
    ) async -> URL? {
        manualStopRequested = false
        lastRecordingDetectedSpeech = false
        guard await beginRecording() else { return nil }

        let pollInterval: TimeInterval = 0.2
        var silenceElapsed: TimeInterval = 0
        var totalElapsed: TimeInterval = 0
        var calibrationStartElapsed: TimeInterval = 0
        var ambientSamples: [Float] = []
        var silenceThresholdDB: Float?
        var wasPlaybackActiveLastPoll = isPlaybackActive?() ?? false
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
            let playbackActiveNow = isPlaybackActive?() ?? false

            // Ansage ist GERADE (ohne Unterbrechung durch den User) zu Ende
            // gegangen -- neu kalibrieren, siehe Doku oben.
            if wasPlaybackActiveLastPoll && !playbackActiveNow && !hasDetectedSpeech {
                silenceThresholdDB = nil
                ambientSamples = []
                calibrationStartElapsed = totalElapsed
            }
            wasPlaybackActiveLastPoll = playbackActiveNow

            if totalElapsed - calibrationStartElapsed <= calibrationDuration {
                // Kalibrierungsfenster: noch keine Stille-Erkennung, nur die
                // Umgebungslautstärke (bzw. bei laufender Ansage: deren
                // eigene Lautstärke) sammeln.
                ambientSamples.append(level)
                continue
            }

            if silenceThresholdDB == nil {
                let ambientFloor = ambientSamples.isEmpty
                    ? minSilenceThresholdDB
                    : ambientSamples.reduce(0, +) / Float(ambientSamples.count)
                let ceiling = playbackActiveNow ? maxSilenceThresholdDBWhilePlaying : maxSilenceThresholdDB
                silenceThresholdDB = min(ceiling, max(minSilenceThresholdDB, ambientFloor + silenceMargin))
            }

            guard let threshold = silenceThresholdDB else { continue }

            if level >= threshold {
                // User spricht gerade (oder beginnt jetzt zu sprechen) --
                // bzw. bei laufender Ansage: redet spürbar lauter dazwischen.
                if !hasDetectedSpeech {
                    onSpeechDetected?()
                }
                hasDetectedSpeech = true
                lastRecordingDetectedSpeech = true
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
