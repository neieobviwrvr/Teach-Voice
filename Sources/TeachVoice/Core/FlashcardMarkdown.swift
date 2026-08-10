import SwiftUI

/// Der bewusst einfache Markdown-Dialekt, den `RichAnswerEditor` erzeugt und
/// den `Flashcard.question`/`.answer` jetzt enthalten dürfen: "**Text**" für
/// Fett, "- " am Zeilenanfang für Aufzählungspunkte. Bewusst KEIN
/// vollständiger Markdown-Parser, sondern deckt exakt das ab, was der Editor
/// schreiben kann – dafür lässt sich alles ohne Datenmodell-/DB-Änderung im
/// bestehenden `answer`/`question`-String unterbringen (Gastmodus bekommt die
/// Formatierung damit automatisch kostenlos mit, siehe CLAUDE.md-Prinzip
/// "Gastmodus bleibt in Parität zu Cloud").
enum FlashcardMarkdown {
    /// Für die Anzeige: Fett + Aufzählungspunkte werden tatsächlich gerendert.
    static func attributedString(from raw: String) -> AttributedString {
        var result = AttributedString()
        let lines = raw.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result.append(AttributedString("\n"))
            }
            if line.hasPrefix("- ") {
                var bullet = AttributedString("•  ")
                bullet.foregroundColor = .secondary
                result.append(bullet)
                result.append(inlineBold(String(line.dropFirst(2))))
            } else {
                result.append(inlineBold(line))
            }
        }
        return result
    }

    /// Für TTS (die Frage wird vorgelesen, siehe SpeechService-Aufrufe) und für
    /// alles, was NICHT von der Formatierung beeinflusst werden soll – Simons
    /// ausdrückliche Vorgabe: Fett bei der Frage ist rein fürs Lernen, "soll
    /// keine Auswirkung auf GPT haben". Entfernt "**" und führende "- "
    /// wieder, reiner Text bleibt übrig.
    static func plainText(from raw: String) -> String {
        raw.components(separatedBy: "\n")
            .map { line -> String in
                let stripped = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                return stripped.replacingOccurrences(of: "**", with: "")
            }
            .joined(separator: "\n")
    }

    /// Parst "**fett**"-Abschnitte innerhalb einer einzelnen Zeile.
    private static func inlineBold(_ line: String) -> AttributedString {
        var result = AttributedString()
        let segments = line.components(separatedBy: "**")
        for (index, segment) in segments.enumerated() {
            var piece = AttributedString(segment)
            // Ungerade Indizes liegen zwischen einem öffnenden und
            // schließenden "**"-Paar -> fett.
            if index % 2 == 1 {
                piece.inlinePresentationIntent = .stronglyEmphasized
            }
            result.append(piece)
        }
        return result
    }
}

extension Text {
    /// Baut einen `Text` aus dem Flashcard-Markdown-Dialekt (Fett +
    /// Aufzählungspunkte) – überall verwenden, wo `Flashcard.question`/
    /// `.answer` angezeigt wird, damit die im Editor gesetzte Formatierung
    /// konsistent sichtbar ist statt roher "**Sternchen**"/"- ".
    init(flashcardMarkdown raw: String) {
        self.init(FlashcardMarkdown.attributedString(from: raw))
    }
}
