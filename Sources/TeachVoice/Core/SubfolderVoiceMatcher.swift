import Foundation

/// Rein lokaler Abgleich für die sprachgesteuerte Unterordner-Auswahl im
/// Hands-free-Menü (keine GPT-Kosten/Latenz nötig). Unterordner sind seit
/// 0007_unlimited_subfolders.sql nicht mehr auf 2 begrenzt – die Zahlwort-
/// Tabelle unten deckt deshalb 1-20 ab statt nur 1-5. Bei SEHR vielen
/// Unterordnern (zweistellig+) wird das Sprachmenü selbst unhandlich (jeden
/// einzeln vorlesen, dann eine Nummer erraten) – das ist ein UX-Punkt, kein
/// Bug in diesem Matcher, und noch nicht mit Simon abschließend geklärt.
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
        "5": 5, "fünf": 5, "fünfte": 5, "fünfter": 5, "fünftes": 5,
        "6": 6, "sechs": 6, "sechste": 6, "sechster": 6, "sechstes": 6,
        "7": 7, "sieben": 7, "siebte": 7, "siebter": 7, "siebtes": 7,
        "8": 8, "acht": 8, "achte": 8, "achter": 8, "achtes": 8,
        "9": 9, "neun": 9, "neunte": 9, "neunter": 9, "neuntes": 9,
        "10": 10, "zehn": 10, "zehnte": 10, "zehnter": 10, "zehntes": 10,
        "11": 11, "elf": 11, "elfte": 11,
        "12": 12, "zwölf": 12, "zwölfte": 12,
        "13": 13, "dreizehn": 13, "dreizehnte": 13,
        "14": 14, "vierzehn": 14, "vierzehnte": 14,
        "15": 15, "fünfzehn": 15, "fünfzehnte": 15,
        "16": 16, "sechzehn": 16, "sechzehnte": 16,
        "17": 17, "siebzehn": 17, "siebzehnte": 17,
        "18": 18, "achtzehn": 18, "achtzehnte": 18,
        "19": 19, "neunzehn": 19, "neunzehnte": 19,
        "20": 20, "zwanzig": 20, "zwanzigste": 20
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
