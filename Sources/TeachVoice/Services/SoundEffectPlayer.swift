import AVFoundation

/// Kurze, selbst erzeugte Ton-Signale (kein gesprochener Text) für richtig/
/// falsch im Hands-free-Modus – bewusst nur ein Ton, kein TTS-Kommentar,
/// wie von Simon gewünscht. `ready` signalisiert "jetzt bist du dran" nach
/// einer vollständig durchgelaufenen Ansage (siehe HandsFreeStudyView) --
/// Ersatz für das frühere Barge-in (Sprach-Unterbrechung mitten in der
/// Ansage): technisch nicht robust genug von Umgebungslärm zu unterscheiden
/// (siehe Chat-Historie), ein klares akustisches "los geht's"-Signal danach
/// ist das etablierte, verlässliche Muster (Alexa, Siri, Telefon-Menüs).
@MainActor
final class SoundEffectPlayer: NSObject, ObservableObject {
    enum Effect: String {
        case success, failure, ready
    }

    private var player: AVAudioPlayer?

    /// Spielt den Effekt ab und wartet, bis er fertig ist (damit der
    /// Hands-free-Loop nicht mitten in den Ton hinein die nächste Frage stellt).
    func play(_ effect: Effect) async {
        guard let url = Bundle.main.url(forResource: effect.rawValue, withExtension: "wav") else { return }
        // Einheitlich über AudioSessionCoordinator statt einer eigenen
        // .playback-Kategorie -- sonst würde die Session direkt vor dem
        // nächsten Zuhören/Sprechen kurz auf .playback zurückspringen und
        // wieder umgeschaltet werden müssen (Klick-Risiko, siehe dortige Doku).
        AudioSessionCoordinator.activate()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                self.player = player
                self.pendingContinuation = continuation
                player.delegate = self
                player.play()
            } catch {
                continuation.resume()
            }
        }
    }

    private var pendingContinuation: CheckedContinuation<Void, Never>?
}

extension SoundEffectPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            pendingContinuation?.resume()
            pendingContinuation = nil
        }
    }
}
