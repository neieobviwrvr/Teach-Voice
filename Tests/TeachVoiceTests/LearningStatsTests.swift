import XCTest
@testable import TeachVoice

final class LearningStatsTests: XCTestCase {

    private let fsrs = FSRS()

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func noon(_ day: Int) -> Date {
        let start = utc.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        return utc.date(byAdding: .day, value: day, to: start)!
    }

    private func newCard() -> Flashcard {
        Flashcard(id: UUID(), subfolderId: UUID(), userId: UUID(), question: "Q", answer: "A",
                  position: 0, createdAt: Date(), updatedAt: Date())
    }

    private func learnedCard(stability: Double, lastReview: Date, due: Date) -> Flashcard {
        var card = newCard()
        card.apply(FSRSCardState(stability: stability, difficulty: 5, lastReview: lastReview, due: due, reps: 1))
        return card
    }

    // MARK: - Kartenstand

    func testProgressAndKnownNow() {
        let learned = learnedCard(stability: 10, lastReview: noon(-2), due: noon(8))
        let stats = LearningStats.compute(cards: [newCard(), newCard(), learned], examDate: nil, now: noon(0), calendar: utc)

        let expected = fsrs.retrievability(elapsedDays: 2, stability: 10)
        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.learned, 1)
        XCTAssertEqual(stats.new, 2)
        XCTAssertEqual(stats.knownNowLearned!, expected, accuracy: 1e-12)
        XCTAssertEqual(stats.knownNow, expected / 3, accuracy: 1e-12, "Neue Karten zählen als 0 %")
        XCTAssertNil(stats.exam)
    }

    func testDueCounts() {
        let overdue = learnedCard(stability: 3, lastReview: noon(-5), due: noon(-2))
        let dueToday = learnedCard(stability: 3, lastReview: noon(-3), due: utc.date(byAdding: .hour, value: -8, to: noon(0))!)
        let inThreeDays = learnedCard(stability: 5, lastReview: noon(-2), due: noon(3))
        let inTwoWeeks = learnedCard(stability: 20, lastReview: noon(-1), due: noon(14))
        let stats = LearningStats.compute(cards: [overdue, dueToday, inThreeDays, inTwoWeeks, newCard()],
                                          examDate: nil, now: noon(0), calendar: utc)
        XCTAssertEqual(stats.dueToday, 2)
        XCTAssertEqual(stats.dueNext7Days, 1)
    }

    func testEmptyFolder() {
        let stats = LearningStats.compute(cards: [], examDate: noon(10), now: noon(0), calendar: utc)
        XCTAssertEqual(stats.total, 0)
        XCTAssertEqual(stats.knownNow, 0)
        XCTAssertNil(stats.knownNowLearned)
        XCTAssertNil(stats.exam)
    }

    // MARK: - Prüfungsprognose

    func testExamForecastWithAndWithoutPlan() {
        let learned = learnedCard(stability: 5, lastReview: noon(-1), due: noon(4))
        let stats = LearningStats.compute(cards: [learned, newCard()], examDate: noon(20), now: noon(0), calendar: utc)
        let exam = try! XCTUnwrap(stats.exam)

        XCTAssertEqual(exam.daysLeft, 20)
        // Ohne Lernen: gelernte Karte verblasst bis Tag 20, neue Karte 0 %.
        let fading = fsrs.retrievability(elapsedDays: 21, stability: 5)
        XCTAssertEqual(exam.withoutReview, fading / 2, accuracy: 1e-12)
        // Nach Plan: beide Karten wurden kurz vor der Prüfung wiederholt -> hoch.
        XCTAssertGreaterThan(exam.withPlan, 0.9)
        XCTAssertGreaterThan(exam.withPlan, exam.withoutReview)
    }

    func testForecastLastReviewBeforeExamComesFromTheExamRule() {
        // Neue Karte, Prüfung in 10 Tagen: der Plan muss vor der Prüfung
        // mehrfach wiederholen und darf nicht über die Prüfung hinaus planen.
        let forecast = LearningStats.forecastWithPlan(newCard(), exam: noon(10), now: noon(0), fsrs: fsrs, calendar: utc)
        XCTAssertGreaterThan(forecast, 0.9)
        XCTAssertLessThanOrEqual(forecast, 1.0)
    }

    func testNoForecastWhenExamIsTodayOrOver() {
        let cards = [newCard()]
        XCTAssertNil(LearningStats.compute(cards: cards, examDate: noon(0), now: noon(0), calendar: utc).exam)
        XCTAssertNil(LearningStats.compute(cards: cards, examDate: noon(-3), now: noon(0), calendar: utc).exam)
    }

    // MARK: - Lernverlauf

    private func log(_ date: Date) -> ReviewLog {
        ReviewLog(id: UUID(), userId: UUID(), flashcardId: UUID(), rating: 3, reviewedAt: date, mode: "tippen",
                  elapsedDays: nil, intervalDays: 2, stability: 2.3, difficulty: 2.1, deckungProzent: nil)
    }

    func testStreakActiveDaysAndPerDay() {
        let logs = [noon(0), noon(0), noon(-1), noon(-2), noon(-4)].map(log)
        let history = LearningHistory.compute(logs: logs, now: noon(0), calendar: utc)

        XCTAssertEqual(history.streak, 3, "Heute, gestern, vorgestern -- Tag -3 fehlt")
        XCTAssertEqual(history.activeDays, 4)
        XCTAssertEqual(history.reviewsToday, 2)
        XCTAssertEqual(history.perDay.count, 14)
        XCTAssertEqual(history.perDay.last?.reviews, 2)
        XCTAssertEqual(history.perDay[history.perDay.count - 4].reviews, 0)
    }

    func testStreakIsNotBrokenBeforeLearningToday() {
        let logs = [noon(-1), noon(-2)].map(log)
        let history = LearningHistory.compute(logs: logs, now: noon(0), calendar: utc)
        XCTAssertEqual(history.streak, 2)
        XCTAssertEqual(history.reviewsToday, 0)
    }
}
