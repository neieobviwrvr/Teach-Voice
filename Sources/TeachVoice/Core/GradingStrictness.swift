import Foundation

/// Vom User pro Lernsession frei wählbare Bewertungs-Strenge (bewusst nicht
/// global fix, auf Wunsch von Simon trotz der Konsequenz, dass dieselbe Karte
/// je nach gewähltem Modus in unterschiedliche Spaced-Repetition-Boxen
/// einsortiert werden kann). Steuert einheitlich ALLES, was auf
/// `deckung_prozent` basiert: die Selbsteinschätzungs-Vorbelegung im
/// Detail-Modus, den Erfolgs-/Fehler-Ton im Hands-free-Modus, und das
/// Spaced-Repetition-Signal in beiden Modi – eine einzige Stellschraube statt
/// mehrerer verstreuter, uneinheitlicher Zahlen.
enum GradingStrictness: String, CaseIterable, Identifiable, Hashable {
    case normal
    case tryhard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .tryhard: return "Tryhard"
        }
    }

    var description: String {
        switch self {
        case .normal: return "65% Deckung = richtig, 45% = teilweise richtig"
        case .tryhard: return "85% Deckung = richtig, 65% = teilweise richtig – nur präzise, vollständige Antworten zählen"
        }
    }

    private var richtigThreshold: Double {
        switch self {
        case .normal: return 65
        case .tryhard: return 85
        }
    }

    private var teilweiseThreshold: Double {
        switch self {
        case .normal: return 45
        case .tryhard: return 65
        }
    }

    func urteil(fromDeckungProzent percent: Double) -> GradingResult.Urteil {
        if percent >= richtigThreshold { return .richtig }
        if percent >= teilweiseThreshold { return .teilweise }
        return .falsch
    }
}
