import Foundation

/// Baut den gesprochenen Rundenabschluss-Satz für beide Hands-free-Modi:
/// nennt nur Kategorien (richtig/teilweise richtig/falsch), die tatsächlich
/// > 0 sind, mit korrekter Einzahl/Mehrzahl ("eine Frage" vs. "X Fragen") –
/// explizite Vorgabe von Simon, damit z.B. "null Fragen falsch" nicht mit
/// vorgelesen wird, wenn gar keine falsch war.
enum StudySessionSummarySpeech {
    /// Liefert `nil`, wenn alle drei Zähler 0 sind (z.B. leerer Unterordner) –
    /// der Aufrufer entscheidet dann, wie er den Satz ohne Statistik-Teil baut.
    static func statsClause(richtig: Int, teilweise: Int, falsch: Int) -> String? {
        let parts = [
            phrase(richtig, "richtig"),
            phrase(teilweise, "teilweise richtig"),
            phrase(falsch, "falsch")
        ].compactMap { $0 }

        guard !parts.isEmpty else { return nil }

        switch parts.count {
        case 1:
            return parts[0]
        case 2:
            return "\(parts[0]) und \(parts[1])"
        default:
            return "\(parts.dropLast().joined(separator: ", ")) und \(parts.last!)"
        }
    }

    private static func phrase(_ count: Int, _ suffix: String) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return "eine Frage \(suffix)"
        }
        return "\(numberWord(count)) Fragen \(suffix)"
    }

    /// Reicht bis 10 – das harte Limit für Karteikarten pro Unterordner
    /// (`maxFlashcardsPerSubfolder`) macht höhere Zähler unmöglich.
    private static func numberWord(_ n: Int) -> String {
        let words = ["null", "eine", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn"]
        guard n >= 0, n < words.count else { return String(n) }
        return words[n]
    }
}
