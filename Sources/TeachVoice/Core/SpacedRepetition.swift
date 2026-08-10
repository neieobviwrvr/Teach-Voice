import Foundation

/// Einfaches 5-Stufen-Box-System für die Wiederholungsplanung im
/// Hands-free-Modus. Bewusst simpel (kein SM-2/Ease-Factor) für kurzfristiges
/// Klausurenlernen statt langfristiger Jahres-Retention.
///
/// Signalquelle je Review (mit Simon abgestimmt):
/// - Detail-Modus: die Selbsteinschätzung des Users ist immer maßgeblich
///   (Tap auf einen der drei Buttons ist zugleich die SRS-Eingabe).
/// - Hands-free-Modus (keine Selbsteinschätzung möglich): GPTs `deckung_prozent`
///   wird über `urteil(fromDeckungProzent:)` auf dasselbe 3-Stufen-Schema
///   abgebildet wie die Selbsteinschätzungs-Buttons.
enum SpacedRepetition {
    static let minBox = 1
    static let maxBox = 5
    /// Tage bis zur nächsten Fälligkeit, indiziert nach Box (Box 1 = Index 0).
    static let intervalDays: [Int] = [0, 1, 3, 7, 14]

    struct Outcome {
        let newBox: Int
        let dueAt: Date
    }

    /// Richtig -> eine Stufe hoch (max. 5). Teilweise -> Stufe bleibt gleich.
    /// Falsch -> zurück auf Stufe 1.
    static func nextState(currentBox: Int, urteil: GradingResult.Urteil, now: Date = Date()) -> Outcome {
        let clampedCurrent = min(max(currentBox, minBox), maxBox)
        let newBox: Int
        switch urteil {
        case .richtig:
            newBox = min(clampedCurrent + 1, maxBox)
        case .teilweise:
            newBox = clampedCurrent
        case .falsch:
            newBox = minBox
        }
        let days = intervalDays[newBox - minBox]
        let dueAt = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        return Outcome(newBox: newBox, dueAt: dueAt)
    }

    /// Bildet eine GPT-Deckung (0-100) auf dasselbe 3-stufige Schema ab wie
    /// die Selbsteinschätzungs-Buttons – für Karten ohne Eigeneinschätzung.
    /// Bewusst dieselben Schwellen wie der Detail-Modus-Urteil-Fallback
    /// (65%/45%), NICHT die 50%-Schwelle des Hands-free-Tons – der Ton ist
    /// nur unmittelbares Feedback, dieses Mapping steuert die Wiederholungsplanung.
    static func urteil(fromDeckungProzent percent: Double) -> GradingResult.Urteil {
        if percent >= 65 { return .richtig }
        if percent >= 45 { return .teilweise }
        return .falsch
    }

    /// Sortiert Karten für den Hands-free-Modus: fällige/überfällige Karten
    /// zuerst (am längsten überfällig zuerst), danach noch nie bewertete
    /// Karten, danach noch nicht fällige Karten (am nächsten fällige zuerst).
    /// Nichts wird ausgeschlossen – "vorrangig" heißt Reihenfolge, nicht Filter.
    static func ordered(_ cards: [Flashcard], now: Date = Date()) -> [Flashcard] {
        let due = cards.filter { ($0.srsDueAt ?? .distantPast) <= now && $0.srsDueAt != nil }
            .sorted { $0.srsDueAt! < $1.srsDueAt! }
        let neverReviewed = cards.filter { $0.srsDueAt == nil }
        let notYetDue = cards.filter { ($0.srsDueAt ?? .distantPast) > now }
            .sorted { $0.srsDueAt! < $1.srsDueAt! }
        return due + neverReviewed + notYetDue
    }
}
