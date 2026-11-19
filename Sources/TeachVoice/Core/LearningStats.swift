import Foundation

/// Kennzahlen für die Statistik-Seite eines Ordners oder Unterordners,
/// berechnet aus dem FSRS-Stand der Karten (keine eigene Speicherung nötig).
struct LearningStats: Equatable {
    let total: Int
    /// Mindestens einmal mit FSRS bewertet.
    let learned: Int
    var new: Int { total - learned }

    /// Geschätzte Abrufwahrscheinlichkeit JETZT, gemittelt über ALLE Karten
    /// (neue Karten zählen als 0 % -- "wie viel von diesem Ordner weißt du").
    let knownNow: Double
    /// Dasselbe nur über die gelernten Karten (`nil`, wenn noch keine).
    let knownNowLearned: Double?

    /// Heute fällig (inkl. überfällig), ohne neue Karten.
    let dueToday: Int
    /// In den nächsten 7 Lerntagen fällig (ohne heute).
    let dueNext7Days: Int

    /// Prognose für den Prüfungstag (nur mit Prüfungstermin in der Zukunft).
    let exam: ExamForecast?

    struct ExamForecast: Equatable {
        let examDate: Date
        let daysLeft: Int
        /// Wenn jede Karte bis zur Prüfung bei Fälligkeit wiederholt (und
        /// dann gewusst) wird; neue Karten werden dafür ab heute gelernt.
        let withPlan: Double
        /// Wenn ab jetzt gar nicht mehr wiederholt wird (neue Karten = 0 %).
        let withoutReview: Double
    }

    static func compute(
        cards: [Flashcard],
        examDate: Date?,
        now: Date = Date(),
        fsrs: FSRS = FSRS(),
        calendar: Calendar = .current
    ) -> LearningStats {
        let today = FSRSScheduler.learningDay(now, calendar: calendar)
        var learned = 0
        var knownSum = 0.0
        var dueToday = 0
        var dueNext7 = 0

        for card in cards {
            let state = card.fsrsState
            guard !state.isNew, let stability = state.stability, let lastReview = state.lastReview else { continue }
            learned += 1
            knownSum += retrievability(stability: stability, lastReview: lastReview, at: now, fsrs: fsrs, calendar: calendar)
            if let due = state.due {
                let dueDay = FSRSScheduler.learningDay(due, calendar: calendar)
                if due <= now || dueDay <= today {
                    dueToday += 1
                } else if dueDay <= today + 7 {
                    dueNext7 += 1
                }
            }
        }

        let exam = examDate.flatMap { date -> ExamForecast? in
            let daysLeft = FSRSScheduler.learningDay(date, calendar: calendar) - today
            guard daysLeft >= 1, !cards.isEmpty else { return nil }
            let withPlan = cards.map { forecastWithPlan($0, exam: date, now: now, fsrs: fsrs, calendar: calendar) }
            let withoutReview = cards.map { card -> Double in
                let state = card.fsrsState
                guard !state.isNew, let stability = state.stability, let lastReview = state.lastReview else { return 0 }
                return retrievability(stability: stability, lastReview: lastReview, at: date, fsrs: fsrs, calendar: calendar)
            }
            return ExamForecast(
                examDate: date,
                daysLeft: daysLeft,
                withPlan: withPlan.reduce(0, +) / Double(cards.count),
                withoutReview: withoutReview.reduce(0, +) / Double(cards.count)
            )
        }

        return LearningStats(
            total: cards.count,
            learned: learned,
            knownNow: cards.isEmpty ? 0 : knownSum / Double(cards.count),
            knownNowLearned: learned == 0 ? nil : knownSum / Double(learned),
            dueToday: dueToday,
            dueNext7Days: dueNext7,
            exam: exam
        )
    }

    /// Abrufwahrscheinlichkeit zu einem Zeitpunkt, mit Lerntagen gerechnet
    /// wie die Planung selbst (`FSRSScheduler`).
    static func retrievability(stability: Double, lastReview: Date, at date: Date, fsrs: FSRS, calendar: Calendar) -> Double {
        let elapsed = FSRSScheduler.learningDay(date, calendar: calendar) - FSRSScheduler.learningDay(lastReview, calendar: calendar)
        return fsrs.retrievability(elapsedDays: Double(max(0, elapsed)), stability: stability)
    }

    /// Spielt den Plan bis zur Prüfung durch: Jede Wiederholung findet am
    /// Fälligkeitstag statt und wird mit "Gut" bewertet (Prüfungstermin wie in
    /// der echten Planung berücksichtigt). Neue und schon fällige Karten werden
    /// heute wiederholt. Ergebnis: Abrufwahrscheinlichkeit am Prüfungstag.
    static func forecastWithPlan(_ card: Flashcard, exam: Date, now: Date, fsrs: FSRS, calendar: Calendar) -> Double {
        let examDay = FSRSScheduler.learningDay(exam, calendar: calendar)
        var state = card.fsrsState
        var reviewDate = now
        if !state.isNew, let due = state.due, due > now {
            reviewDate = due
        }

        // Höchstens so viele Schritte, wie es Tage bis zur Prüfung gibt (+ Puffer).
        var steps = 0
        while FSRSScheduler.learningDay(reviewDate, calendar: calendar) < examDay, steps < 400 {
            let outcome = FSRSScheduler.review(state, rating: .good, now: reviewDate, examDate: exam, fsrs: fsrs, calendar: calendar)
            state = outcome.state
            guard let due = state.due else { break }
            reviewDate = due
            steps += 1
        }

        guard let stability = state.stability, let lastReview = state.lastReview else { return 0 }
        return retrievability(stability: stability, lastReview: lastReview, at: exam, fsrs: fsrs, calendar: calendar)
    }
}

/// Lernverlauf aus `review_logs`: Lerntage, Serie, Karten pro Tag.
struct LearningHistory: Equatable {
    struct Day: Equatable, Identifiable {
        let date: Date
        let reviews: Int
        var id: Date { date }
    }

    /// Lerntage mit mindestens einer Bewertung in den letzten `windowDays`.
    let activeDays: Int
    let windowDays: Int
    /// Aufeinanderfolgende Lerntage bis heute (bzw. bis gestern, wenn heute
    /// noch nichts gelernt wurde -- die Serie ist dann noch nicht gerissen).
    let streak: Int
    let reviewsToday: Int
    /// Bewertungen pro Lerntag, die letzten `chartDays` Tage, älteste zuerst.
    let perDay: [Day]

    static func compute(
        logs: [ReviewLog],
        now: Date = Date(),
        windowDays: Int = 30,
        chartDays: Int = 14,
        calendar: Calendar = .current
    ) -> LearningHistory {
        let today = FSRSScheduler.learningDay(now, calendar: calendar)
        var counts: [Int: Int] = [:]
        for log in logs {
            counts[FSRSScheduler.learningDay(log.reviewedAt, calendar: calendar), default: 0] += 1
        }

        let activeDays = (0..<windowDays).filter { counts[today - $0, default: 0] > 0 }.count

        var streak = 0
        var day = counts[today, default: 0] > 0 ? today : today - 1
        while counts[day, default: 0] > 0 {
            streak += 1
            day -= 1
        }

        let perDay = (0..<chartDays).reversed().map { offset -> Day in
            let learningDay = today - offset
            return Day(date: FSRSScheduler.startOfLearningDay(learningDay, calendar: calendar), reviews: counts[learningDay, default: 0])
        }

        return LearningHistory(
            activeDays: activeDays,
            windowDays: windowDays,
            streak: streak,
            reviewsToday: counts[today, default: 0],
            perDay: perDay
        )
    }
}
