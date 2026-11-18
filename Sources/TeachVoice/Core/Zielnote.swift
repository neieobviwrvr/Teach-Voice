import Foundation

/// Strenge der KI-Bewertung im Sprach-Modus, ausgedrückt als Zielnote auf der
/// deutschen Notenskala (Simons Wunsch: "Zielnote z.B. 2,3 oder 1,5" statt
/// Normal/Tryhard). Wird einmal im Profil eingestellt und gilt dann für jede
/// Sprach-Session.
///
/// Die Zielnote ändert NICHT, wie großzügig die KI einzelne Kernthemen
/// erkennt (umgangssprachlich, ohne exaktes Fachwort zählt immer, siehe
/// grade-answer/index.ts). Sie legt nur fest, wie viel Prozent der Kernthemen
/// für "richtig" bzw. "teilweise richtig" nötig sind – linear, 15
/// Prozentpunkte pro ganzer Notenstufe:
///
///     1,0 -> 95 %   2,0 -> 80 %   3,0 -> 65 %   4,0 -> 50 %
///
/// "Teilweise" beginnt jeweils 20 Punkte unter "richtig". Zum Vergleich: das
/// frühere "Normal" (65 %) entspricht 3,0, "Tryhard" (85 %) etwa 1,7.
struct Zielnote: Equatable {
    static let minWert = 1.0
    static let maxWert = 4.0
    static let schrittweite = 0.1
    static let standardWert = 2.3
    /// UserDefaults-Schlüssel (auch für `@AppStorage` im Profil).
    static let speicherSchluessel = "zielnote"
    /// Abstand zwischen "richtig"- und "teilweise"-Schwelle in Prozentpunkten.
    static let teilweiseSpanne = 20.0

    /// Note in Zehnteln (z.B. 23 für 2,3) – als Ganzzahl gespeichert, damit
    /// die Schwellen exakt berechnet werden statt mit Gleitkomma-Rauschen
    /// (2,3 ist als Double nicht exakt darstellbar).
    let zehntel: Int

    init(_ wert: Double) {
        let begrenzt = min(max(wert, Self.minWert), Self.maxWert)
        zehntel = Int((begrenzt * 10).rounded())
    }

    var wert: Double { Double(zehntel) / 10 }

    /// Deutsch formatiert, z.B. "2,3".
    var anzeige: String { "\(zehntel / 10),\(zehntel % 10)" }

    /// Ab diesem Anteil getroffener Kernthemen zählt eine Antwort als richtig.
    var richtigAbProzent: Double { 95 - Double(zehntel - 10) * 1.5 }

    /// Ab diesem Anteil zählt eine Antwort als teilweise richtig.
    var teilweiseAbProzent: Double { richtigAbProzent - Self.teilweiseSpanne }

    func urteil(fromDeckungProzent percent: Double) -> GradingResult.Urteil {
        if percent >= richtigAbProzent { return .richtig }
        if percent >= teilweiseAbProzent { return .teilweise }
        return .falsch
    }

    /// Ein Satz für die Einstellungen, z.B. "Richtig ab 75,5 % der
    /// Kernthemen, teilweise richtig ab 55,5 %."
    var beschreibung: String {
        "Richtig ab \(Self.prozentText(richtigAbProzent)) der Kernthemen, teilweise richtig ab \(Self.prozentText(teilweiseAbProzent))."
    }

    /// Die im Profil eingestellte Zielnote (Standard 2,3, falls nie gesetzt).
    static var gespeichert: Zielnote {
        let wert = UserDefaults.standard.object(forKey: speicherSchluessel) as? Double
        return Zielnote(wert ?? standardWert)
    }

    private static func prozentText(_ prozent: Double) -> String {
        let gerundet = (prozent * 10).rounded() / 10
        if gerundet == gerundet.rounded() {
            return "\(Int(gerundet)) %"
        }
        return String(format: "%.1f %%", gerundet).replacingOccurrences(of: ".", with: ",")
    }
}
