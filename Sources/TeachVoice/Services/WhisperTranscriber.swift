import Foundation
import WhisperKit

/// Lädt das OpenAI "Whisper-base"-Modell einmalig lokal auf das Gerät (CoreML,
/// über WhisperKit) und transkribiert damit anschließend komplett offline –
/// es geht keine Sprachaufnahme an einen Server.
@MainActor
final class WhisperTranscriber: ObservableObject {
    enum State: Equatable {
        case notLoaded
        case downloading(progress: Double)
        case ready
        case transcribing
        case failed(String)
    }

    @Published private(set) var state: State = .notLoaded

    private var whisperKit: WhisperKit?
    /// Läuft gerade ein Ladevorgang? Verhindert, dass zwei überlappende
    /// `prepareIfNeeded()`-Aufrufe (z.B. einer aus `StudyView.task` beim
    /// Öffnen, einer aus dem ersten `transcribe()`, falls der User schneller
    /// ist als der Modell-Download) jeweils ihr eigenes WhisperKit laden.
    private var loadingTask: Task<Void, Never>?

    /// Lädt/initialisiert das Whisper-base-Modell. Idempotent und gegen
    /// überlappende Aufrufe abgesichert – kann sicher mehrfach/parallel
    /// aufgerufen werden.
    func prepareIfNeeded() async {
        guard whisperKit == nil else { return }
        if let loadingTask {
            await loadingTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            self.state = .downloading(progress: 0)
            do {
                let config = WhisperKitConfig(model: "base")
                self.whisperKit = try await WhisperKit(config)
                self.state = .ready
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
        loadingTask = task
        await task.value
        loadingTask = nil
    }

    /// Transkribiert eine zuvor aufgenommene WAV-Datei und gibt den erkannten Text zurück.
    func transcribe(audioURL: URL) async -> String? {
        await prepareIfNeeded()
        guard let whisperKit else { return nil }
        state = .transcribing
        defer { state = .ready }
        do {
            // Sprache und Task explizit erzwingen: ohne diese Vorgabe
            // entscheidet WhisperKit selbst per Auto-Erkennung/Task, was dazu
            // führen kann, dass eine deutsche Antwort ins Englische übersetzt
            // statt wortgetreu transkribiert wird. Die App ist für deutsch-
            // sprachige Studierende gedacht, daher hart auf "de" statt auf
            // Geräte-Locale o.ä.
            let options = DecodingOptions(task: .transcribe, language: "de")
            let results = try await whisperKit.transcribe(audioPath: audioURL.path, decodeOptions: options)
            let text = results.map { $0.text }.joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }
}
