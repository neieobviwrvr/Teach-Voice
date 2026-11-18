import Foundation

/// Warteschlange einer Lern-Session, gemeinsam für den Sprach- und den
/// Tipp-Modus (Anki-Stil). Reine Logik ohne UI, damit sie testbar bleibt.
///
/// - Die erste Karte in `pending` ist die aktuelle.
/// - Nach jeder Bewertung wandert die Karte aus der Schlange. Muss sie laut
///   Spaced Repetition heute nochmal dran (`SpacedRepetition.isDueAgainToday`),
///   wird sie mit ihrem neuen Box-Stand hinten wieder angehängt. Die Session
///   endet also erst, wenn jede Karte mindestens "teilweise" aus Box 2+ bzw.
///   einmal "richtig" war.
/// - Für die Statistik zählt nur der ERSTE Versuch pro Karte ("auf Anhieb"),
///   Wiederholungen werden separat mitgezählt.
struct StudyQueue {
    struct Attempt: Identifiable {
        let id = UUID()
        let card: Flashcard
        let urteil: GradingResult.Urteil
        /// Anteil getroffener Kernthemen laut KI, `nil` im Tipp-Modus oder
        /// wenn die KI-Bewertung nicht verfügbar war.
        let percent: Double?
    }

    private(set) var pending: [Flashcard]
    /// Erster Versuch pro Karte, in Abfrage-Reihenfolge.
    private(set) var firstAttempts: [Attempt] = []
    /// Anzahl Wiederholungen in dieser Session (Versuche ab dem zweiten).
    private(set) var repetitions = 0
    /// Anzahl unterschiedlicher Karten in dieser Session.
    let cardCount: Int

    init(cards: [Flashcard]) {
        pending = cards
        cardCount = Set(cards.map(\.id)).count
    }

    var current: Flashcard? { pending.first }
    var isFinished: Bool { pending.isEmpty }

    /// Ist die aktuelle Karte eine Wiederholung (war in dieser Session schon dran)?
    var currentIsRepetition: Bool {
        guard let current else { return false }
        return firstAttempts.contains { $0.card.id == current.id }
    }

    /// Fortschrittszeile für die Lern-Ansichten.
    var progressText: String {
        if currentIsRepetition {
            return "Wiederholung · noch \(pending.count) offen"
        }
        return "Karte \(min(seenCount + 1, cardCount)) von \(cardCount)"
    }

    /// Wie viele Karten bereits mindestens einmal dran waren.
    var seenCount: Int { firstAttempts.count }

    /// Verbucht das Ergebnis für die aktuelle Karte und gibt das
    /// Spaced-Repetition-Ergebnis zurück (zum Speichern über `LibraryStore`).
    /// Gibt `nil` zurück, wenn die Schlange leer ist.
    @discardableResult
    mutating func record(_ urteil: GradingResult.Urteil, percent: Double? = nil, now: Date = Date()) -> SpacedRepetition.Outcome? {
        guard var card = pending.first else { return nil }
        pending.removeFirst()

        if firstAttempts.contains(where: { $0.card.id == card.id }) {
            repetitions += 1
        } else {
            firstAttempts.append(Attempt(card: card, urteil: urteil, percent: percent))
        }

        let outcome = SpacedRepetition.nextState(currentBox: card.srsBox, urteil: urteil, now: now)
        card.srsBox = outcome.newBox
        card.srsDueAt = outcome.dueAt
        card.srsLastReviewedAt = now
        if SpacedRepetition.isDueAgainToday(outcome) {
            pending.append(card)
        }
        return outcome
    }

    func count(of urteil: GradingResult.Urteil) -> Int {
        firstAttempts.filter { $0.urteil == urteil }.count
    }
}
