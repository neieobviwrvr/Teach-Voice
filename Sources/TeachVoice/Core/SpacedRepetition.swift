import Foundation

/// Einfaches 5-Stufen-Box-System für die Wiederholungsplanung. Bewusst simpel
/// (kein SM-2/Ease-Factor) für kurzfristiges Klausurenlernen statt
/// langfristiger Jahres-Retention.
///
/// Signalquelle ist in beiden Lernmodi (Sprechen und Tippen) immer die
/// Selbsteinschätzung des Users – im Sprach-Modus schlägt die KI sie anhand
/// der Zielnote nur vor (siehe `Zielnote`).
///
/// Ablauf einer Session (siehe `StudyQueue`): abgefragt werden nur fällige und
/// neue Karten (`sessionCards`). Landet eine Karte nach der Bewertung in einer
/// Box mit 0 Tagen Intervall (`isDueAgainToday`), kommt sie in derselben
/// Session nochmal dran – so lange, bis sie sitzt.
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

    /// Muss die Karte nach diesem Ergebnis noch HEUTE wiederholt werden? Das
    /// ist genau dann der Fall, wenn ihre neue Box ein Intervall von 0 Tagen
    /// hat (aktuell nur Box 1: nach "falsch", oder "teilweise" in Box 1).
    static func isDueAgainToday(_ outcome: Outcome) -> Bool {
        intervalDays[outcome.newBox - minBox] == 0
    }

    /// Die Karten für eine normale Lern-Session: fällige/überfällige (am
    /// längsten überfällig zuerst) und noch nie bewertete Karten. Noch nicht
    /// fällige Karten bleiben draußen. Ist das Ergebnis leer, kann der
    /// Aufrufer stattdessen alle Karten über `ordered` anbieten.
    static func sessionCards(_ cards: [Flashcard], now: Date = Date()) -> [Flashcard] {
        ordered(cards, now: now).filter { card in
            guard let dueAt = card.srsDueAt else { return true }
            return dueAt <= now
        }
    }

    /// Sortiert Karten: fällige/überfällige Karten zuerst (am längsten
    /// überfällig zuerst), danach noch nie bewertete Karten, danach noch nicht
    /// fällige Karten (am nächsten fällige zuerst). Nichts wird
    /// ausgeschlossen – das ist die Reihenfolge fürs "alle Karten üben".
    static func ordered(_ cards: [Flashcard], now: Date = Date()) -> [Flashcard] {
        let due = cards.filter { ($0.srsDueAt ?? .distantPast) <= now && $0.srsDueAt != nil }
            .sorted { $0.srsDueAt! < $1.srsDueAt! }
        let neverReviewed = cards.filter { $0.srsDueAt == nil }
        let notYetDue = cards.filter { ($0.srsDueAt ?? .distantPast) > now }
            .sorted { $0.srsDueAt! < $1.srsDueAt! }
        return due + neverReviewed + notYetDue
    }
}
