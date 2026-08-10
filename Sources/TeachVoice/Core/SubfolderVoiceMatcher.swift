import Foundation

/// Rein lokaler Abgleich für die sprachgesteuerte Unterordner-Auswahl im
/// Hands-free-Menü (keine GPT-Kosten/Latenz nötig bei max. 2 Unterordnern).
///
/// WICHTIG (explizite Vorgabe von Simon, siehe Memory
/// `handsfree-voice-menu-folder-matching`): falls sich dieser lokale Abgleich
/// in der Praxis als unzuverlässig erweist, auf eine GPT-4o-mini-Interpretation
/// umsteigen statt hier immer weiter nachzujustieren.
enum SubfolderVoiceMatcher {
    private static let numberWords: [String: Int] = [
        "1": 1, "eins": 1, "erste": 1, "erster": 1, "erstes": 1, "eine": 1,
        "2": 2, "zwei": 2, "zweite": 2, "zweiter": 2, "zweites": 2,
        "3": 3, "drei": 3, "dritte": 3, "dritter": 3, "drittes": 3,
        "4": 4, "vier": 4, "vierte": 4, "vierter": 4, "viertes": 4,
        "5": 5, "fünf": 5, "fünfte": 5, "fünfter": 5, "fünftes": 5
    ]

    private static let yesWords = ["ja", "jep", "jo", "gerne", "klar", "genau", "yes", "jup"]
    private static let noWords = ["nein", "ne", "nö", "nope", "no"]

    /// Ordnet einen STT-Transkript-Text einem der übergebenen Unterordner zu –
    /// per Zahl ("eins"/"1"/"die erste") oder per (teilweisem) Namensabgleich.
    static func match(transcript: String, options: [Subfolder]) -> Subfolder? {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return nil }
        let words = normalized.split(separator: " ").map(String.init)

        // 1) Zahlwort/Ziffer im Text -> direkt per Position.
        for word in words {
            if let number = numberWords[word], options.indices.contains(number - 1) {
                return options[number - 1]
            }
        }

        // 2) Name kommt (ganz oder in Teilen) im Transkript vor.
        for option in options {
            let optionName = normalize(option.name)
            if normalized.contains(optionName) || optionName.contains(normalized) {
                return option
            }
        }

        // 3) Grobe Wortüberlappung als letzter lokaler Versuch.
        let transcriptWords = Set(words)
        for option in options {
            let optionWords = Set(normalize(option.name).split(separator: " ").map(String.init))
            if !optionWords.isDisjoint(with: transcriptWords) {
                return option
            }
        }

        return nil
    }

    /// `true` = ja, `false` = nein, `nil` = nicht eindeutig erkannt.
    static func matchYesNo(transcript: String) -> Bool? {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return nil }
        if yesWords.contains(where: { normalized.contains($0) }) { return true }
        if noWords.contains(where: { normalized.contains($0) }) { return false }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
    }
}
