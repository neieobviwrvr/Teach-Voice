import XCTest
@testable import TeachVoice

/// Prüft die FSRS-6-Umsetzung gegen Werte aus einer unabhängigen
/// Nachrechnung der offiziellen Referenzimplementierung (py-fsrs,
/// `fsrs/scheduler.py`, Standardparameter, Zielwahrscheinlichkeit 0,9).
/// Weicht hier etwas ab, plant die App falsch -- dann NICHT die Erwartung
/// anpassen, sondern den Fehler im Code suchen.
final class FSRSTests: XCTestCase {

    private let fsrs = FSRS()
    private let accuracy = 1e-9

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 12:00 UTC am Tag `day` (weit weg von der 4-Uhr-Tagesgrenze).
    private func noon(_ day: Int, minutes: Int = 0) -> Date {
        let start = utc.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12, minute: minutes))!
        return utc.date(byAdding: .day, value: day, to: start)!
    }

    // MARK: - Modell

    func testForgettingCurveHitsDesiredRetentionAtStability() {
        XCTAssertEqual(fsrs.factor, 0.9803464944134797, accuracy: accuracy)
        XCTAssertEqual(fsrs.retrievability(elapsedDays: 5, stability: 5), 0.9, accuracy: accuracy)
        XCTAssertEqual(fsrs.retrievability(elapsedDays: 0, stability: 5), 1.0, accuracy: accuracy)
    }

    func testIntervalEqualsStabilityAtNinetyPercent() {
        for stability in [2.3065, 10.4, 46.28] {
            XCTAssertEqual(fsrs.nextInterval(stability: stability), Int(stability.rounded(.toNearestOrEven)))
        }
    }

    func testNewCardStartValues() {
        XCTAssertEqual(fsrs.initialStability(.again), 0.212, accuracy: accuracy)
        XCTAssertEqual(fsrs.initialStability(.good), 2.3065, accuracy: accuracy)
        XCTAssertEqual(fsrs.initialDifficulty(.again), 6.4133, accuracy: accuracy)
        XCTAssertEqual(fsrs.initialDifficulty(.hard), 5.112170705601056, accuracy: accuracy)
        XCTAssertEqual(fsrs.initialDifficulty(.good), 2.118103970459016, accuracy: accuracy)
        XCTAssertEqual(fsrs.initialDifficulty(.easy), 1.0, accuracy: accuracy)
        // Erste Intervalle laut Referenz: Again 1, Hard 1, Good 2, Easy 8 Tage.
        XCTAssertEqual(fsrs.nextInterval(stability: fsrs.initialStability(.hard)), 1)
        XCTAssertEqual(fsrs.nextInterval(stability: fsrs.initialStability(.good)), 2)
        XCTAssertEqual(fsrs.nextInterval(stability: fsrs.initialStability(.easy)), 8)
    }

    // MARK: - Ablauf einer Karte (Referenzszenario)

    func testReferenceScenario() {
        var card = FSRSCardState()

        // Tag 0: neu, Richtig
        var outcome = FSRSScheduler.review(card, rating: .good, now: noon(0), calendar: utc)
        XCTAssertEqual(outcome.state.stability!, 2.3065, accuracy: accuracy)
        XCTAssertEqual(outcome.state.difficulty!, 2.118103970459016, accuracy: accuracy)
        XCTAssertEqual(outcome.intervalDays, 2)
        XCTAssertEqual(outcome.state.due, utc.date(byAdding: .hour, value: -8, to: noon(2)), "Fällig ab 4 Uhr des Zieltags")
        card = outcome.state

        // Tag 2: Richtig
        outcome = FSRSScheduler.review(card, rating: .good, now: noon(2), calendar: utc)
        XCTAssertEqual(outcome.state.stability!, 10.964332335820698, accuracy: accuracy)
        XCTAssertEqual(outcome.state.difficulty!, 2.111214235785395, accuracy: accuracy)
        XCTAssertEqual(outcome.intervalDays, 11)
        card = outcome.state

        // Tag 13: Richtig
        outcome = FSRSScheduler.review(card, rating: .good, now: noon(13), calendar: utc)
        XCTAssertEqual(outcome.state.stability!, 46.28021728755693, accuracy: accuracy)
        XCTAssertEqual(outcome.state.difficulty!, 2.1043313908464483, accuracy: accuracy)
        XCTAssertEqual(outcome.intervalDays, 46)
        card = outcome.state

        // Tag 59: vergessen -> Falsch, in 10 Minuten wieder fällig
        outcome = FSRSScheduler.review(card, rating: .again, now: noon(59), calendar: utc)
        XCTAssertEqual(outcome.state.stability!, 2.9325804541638116, accuracy: accuracy)
        XCTAssertEqual(outcome.state.difficulty!, 7.389975788014609, accuracy: accuracy)
        XCTAssertNil(outcome.intervalDays)
        XCTAssertTrue(outcome.isDueAgainToday)
        XCTAssertEqual(outcome.state.due, noon(59, minutes: 10))
        XCTAssertEqual(outcome.state.lapses, 1)
        card = outcome.state

        // Gleicher Tag, 10 Minuten später: Richtig (Kurzzeit-Stabilität)
        outcome = FSRSScheduler.review(card, rating: .good, now: noon(59, minutes: 10), calendar: utc)
        XCTAssertEqual(outcome.state.stability!, 2.9325804541638116, accuracy: accuracy)
        XCTAssertEqual(outcome.state.difficulty!, 7.377814181523433, accuracy: accuracy)
        XCTAssertEqual(outcome.intervalDays, 3)
        card = outcome.state

        // Tag 60 (vorzeitig): Teilweise = Hard
        outcome = FSRSScheduler.review(card, rating: .hard, now: noon(60), calendar: utc)
        XCTAssertEqual(outcome.state.stability!, 4.155907415522263, accuracy: accuracy)
        XCTAssertEqual(outcome.state.difficulty!, 8.244499229132952, accuracy: accuracy)
        XCTAssertEqual(outcome.intervalDays, 4)
        card = outcome.state

        // Tag 64: Easy
        outcome = FSRSScheduler.review(card, rating: .easy, now: noon(64), calendar: utc)
        XCTAssertEqual(outcome.state.stability!, 13.023160711921603, accuracy: accuracy)
        XCTAssertEqual(outcome.state.difficulty!, 7.643121047141945, accuracy: accuracy)
        XCTAssertEqual(outcome.intervalDays, 13)
        XCTAssertEqual(outcome.state.reps, 7)
        XCTAssertEqual(outcome.state.lapses, 1)
    }

    // MARK: - Lerntage (Tagesgrenze 4 Uhr)

    func testEveningAndNextMorningAreDifferentLearningDays() {
        let evening = utc.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 22))!
        let nextMorning = utc.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 9))!
        let afterMidnight = utc.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 2))!
        let eveningDay = FSRSScheduler.learningDay(evening, calendar: utc)
        XCTAssertEqual(FSRSScheduler.learningDay(nextMorning, calendar: utc) - eveningDay, 1)
        XCTAssertEqual(FSRSScheduler.learningDay(afterMidnight, calendar: utc), eveningDay, "Vor 4 Uhr zählt noch zum Vortag")
    }

    // MARK: - Prüfungstermin

    func testExamDatePullsReviewBeforeTheExam() {
        // Ohne Prüfung: 46 Tage. Prüfung in 20 Tagen -> Hälfte = 10 Tage.
        let card = FSRSCardState(stability: 10.964332335820698, difficulty: 2.111214235785395, lastReview: noon(2), reps: 2)
        let without = FSRSScheduler.review(card, rating: .good, now: noon(13), calendar: utc)
        XCTAssertEqual(without.intervalDays, 46)
        let withExam = FSRSScheduler.review(card, rating: .good, now: noon(13), examDate: noon(33), calendar: utc)
        XCTAssertEqual(withExam.intervalDays, 10)
        // Das Gedächtnismodell selbst bleibt unverändert, nur der Termin rückt vor.
        XCTAssertEqual(withExam.state.stability!, without.state.stability!, accuracy: accuracy)
    }

    func testExamDateDoesNothingWhenIntervalEndsBeforeExamOrExamIsOver() {
        let card = FSRSCardState()
        XCTAssertEqual(FSRSScheduler.review(card, rating: .good, now: noon(0), examDate: noon(30), calendar: utc).intervalDays, 2)
        XCTAssertEqual(FSRSScheduler.review(card, rating: .easy, now: noon(10), examDate: noon(5), calendar: utc).intervalDays, 8)
    }

    func testExamTomorrowStillSchedulesAtLeastOneDay() {
        let card = FSRSCardState()
        XCTAssertEqual(FSRSScheduler.review(card, rating: .easy, now: noon(0), examDate: noon(1), calendar: utc).intervalDays, 1)
    }

    // MARK: - Beschriftung

    func testIntervalLabels() {
        XCTAssertEqual(FSRSScheduler.intervalLabel(nil), "10 Min")
        XCTAssertEqual(FSRSScheduler.intervalLabel(1), "1 T")
        XCTAssertEqual(FSRSScheduler.intervalLabel(21), "3 Wo")
        XCTAssertEqual(FSRSScheduler.intervalLabel(90), "3 Mon")
        XCTAssertEqual(FSRSScheduler.intervalLabel(730), "2,0 J")
    }

    func testRatingMappingFromSelfAssessment() {
        XCTAssertEqual(FSRSRating(.falsch), .again)
        XCTAssertEqual(FSRSRating(.teilweise), .hard)
        XCTAssertEqual(FSRSRating(.richtig), .good)
    }
}
