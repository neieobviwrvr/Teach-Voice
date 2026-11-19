import Foundation

/// Auswahl und Reihenfolge der Karten für eine Lernrunde. Die eigentliche
/// Wiederholungsplanung (wann ist eine Karte wieder dran?) macht FSRS, siehe
/// `FSRS` und `FSRSScheduler` -- es setzt `srsDueAt`.
///
/// Signalquelle ist in beiden Lernmodi (Sprechen und Tippen) immer die
/// Selbsteinschätzung des Users – im Sprach-Modus schlägt die KI sie anhand
/// der Zielnote nur vor (siehe `Zielnote`).
enum SpacedRepetition {
    /// Die Karten für eine normale Lernrunde: fällige/überfällige (am
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
