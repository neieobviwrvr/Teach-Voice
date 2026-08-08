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

    /// Lädt/initialisiert das Whisper-base-Modell. Idempotent – kann sicher
    /// mehrfach aufgerufen werden (z.B. beim Öffnen der StudyView).
    func prepareIfNeeded() async {
        guard whisperKit == nil else { return }
        state = .downloading(progress: 0)
        do {
            let config = WhisperKitConfig(model: "base")
            whisperKit = try await WhisperKit(config)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Transkribiert eine zuvor aufgenommene WAV-Datei und gibt den erkannten Text zurück.
    func transcribe(audioURL: URL) async -> String? {
        await prepareIfNeeded()
        guard let whisperKit else { return nil }
        state = .transcribing
        defer { state = .ready }
        do {
            let results = try await whisperKit.transcribe(audioPath: audioURL.path)
            let text = results.map { $0.text }.joined(separator: " ")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            state = .failed(error.localizedDescription)
            return nil
        }
    }
}
