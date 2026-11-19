import Foundation

/// Warteschlange einer Lern-Session, gemeinsam für den Sprach- und den
/// Tipp-Modus (Anki-Stil). Reine Logik ohne UI, damit sie testbar bleibt.
///
/// - Die erste Karte in `pending` ist die aktuelle.
/// - Nach jeder Bewertung wandert die Karte aus der Schlange und bekommt ihren
///   neuen FSRS-Zustand (`FSRSScheduler`). War sie falsch, ist sie laut FSRS
///   in 10 Minuten wieder fällig und wird hinten angehängt -- die Runde endet
///   erst, wenn jede Karte mindestens "teilweise" gewusst wurde. Die
///   Wiederholung am selben Tag rechnet FSRS mit der Kurzzeit-Stabilität.
/// - Für die Statistik zählt nur der ERSTE Versuch pro Karte ("auf Anhieb"),
///   Wiederholungen werden separat mitgezählt.
struct StudyQueue {
    struct Attempt: Identifiable {
        let id = UUID()
        let card: Flashcard
        let rating: FSRSRating
        /// Anteil getroffener Kernthemen laut KI, `nil` im Tipp-Modus oder
        /// wenn die KI-Bewertung nicht verfügbar war.
        let percent: Double?

        /// Für die Statistik: Gut und Einfach zählen als richtig.
        var urteil: GradingResult.Urteil { GradingResult.Urteil(rating) }
    }

    /// Zähler wie in Anki/StudyFlash: neue Karten, Karten, die in dieser
    /// Runde nochmal drankommen, und fällige Wiederholungen.
    struct Counts: Equatable {
        let neu: Int
        let nochmal: Int
        let wiederholen: Int
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

    /// Die aktuelle und die nächsten Karten, insgesamt höchstens `count`
    /// (z.B. um ihre Fragen schon vorab als Audio zu laden).
    func upcoming(_ count: Int) -> [Flashcard] {
        Array(pending.prefix(max(0, count)))
    }

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

    var counts: Counts {
        let seen = Set(firstAttempts.map(\.card.id))
        var neu = 0, nochmal = 0, wiederholen = 0
        for card in pending {
            if seen.contains(card.id) {
                nochmal += 1
            } else if card.fsrsStability == nil {
                neu += 1
            } else {
                wiederholen += 1
            }
        }
        return Counts(neu: neu, nochmal: nochmal, wiederholen: wiederholen)
    }

    /// Verbucht das Ergebnis für die aktuelle Karte und gibt das
    /// FSRS-Ergebnis zurück. Gespeichert wird separat über
    /// `LibraryStore.recordSpacedRepetitionOutcome` mit demselben Kartenstand
    /// und demselben `now`. Gibt `nil` zurück, wenn die Schlange leer ist.
    @discardableResult
    mutating func record(
        _ urteil: GradingResult.Urteil,
        percent: Double? = nil,
        now: Date = Date(),
        examDate: Date? = nil,
        calendar: Calendar = .current
    ) -> FSRSScheduler.Outcome? {
        record(FSRSRating(urteil), percent: percent, now: now, examDate: examDate, calendar: calendar)
    }

    /// Wie oben, mit einer der vier FSRS-Bewertungen (Tipp-Modus).
    @discardableResult
    mutating func record(
        _ rating: FSRSRating,
        percent: Double? = nil,
        now: Date = Date(),
        examDate: Date? = nil,
        calendar: Calendar = .current
    ) -> FSRSScheduler.Outcome? {
        guard var card = pending.first else { return nil }
        pending.removeFirst()

        if firstAttempts.contains(where: { $0.card.id == card.id }) {
            repetitions += 1
        } else {
            firstAttempts.append(Attempt(card: card, rating: rating, percent: percent))
        }

        let outcome = FSRSScheduler.review(
            card.fsrsState, rating: rating, now: now, examDate: examDate, calendar: calendar
        )
        card.apply(outcome.state)
        if outcome.isDueAgainToday {
            pending.append(card)
        }
        return outcome
    }

    func count(of urteil: GradingResult.Urteil) -> Int {
        firstAttempts.filter { $0.urteil == urteil }.count
    }
}
