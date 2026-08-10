import UIKit

/// Haptisches Feedback bei der Bewertung: zwei kurz aufeinanderfolgende
/// Impulse bei richtig, ein einzelner bei teilweise/falsch – nutzbar auch
/// ohne hinzuschauen (v.a. für den Hands-free-Modus gedacht, aber genauso
/// im Detail-Modus aktiv).
@MainActor
enum HapticFeedback {
    static func playCorrect() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            generator.impactOccurred()
        }
    }

    static func playIncorrect() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    static func play(for urteil: GradingResult.Urteil) {
        switch urteil {
        case .richtig: playCorrect()
        case .teilweise, .falsch: playIncorrect()
        }
    }
}
