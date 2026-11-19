import XCTest
@testable import TeachVoice

final class StudyQueueTests: XCTestCase {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func noon(_ day: Int, minutes: Int = 0) -> Date {
        let start = utc.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12, minute: minutes))!
        return utc.date(byAdding: .day, value: day, to: start)!
    }

    private func makeCard(srsDueAt: Date? = nil) -> Flashcard {
        Flashcard(
            id: UUID(), subfolderId: UUID(), userId: UUID(),
            question: "Q", answer: "A", position: 0,
            createdAt: Date(), updatedAt: Date(),
            srsDueAt: srsDueAt
        )
    }

    func testRichtigRemovesCardFromSessionAndSchedulesWithFSRS() {
        let card = makeCard()
        var queue = StudyQueue(cards: [card])

        let outcome = queue.record(.richtig, now: noon(0), calendar: utc)

        XCTAssertEqual(outcome?.intervalDays, 2, "Neue Karte, Richtig: laut FSRS-6 in 2 Tagen wieder fällig")
        XCTAssertTrue(queue.isFinished)
        XCTAssertEqual(queue.count(of: .richtig), 1)
    }

    func testFalschComesBackAtTheEndUntilItSits() {
        let a = makeCard()
        let b = makeCard()
        var queue = StudyQueue(cards: [a, b])

        queue.record(.falsch, now: noon(0), calendar: utc)          // a -> hinten wieder dran
        XCTAssertEqual(queue.pending.map(\.id), [b.id, a.id])

        queue.record(.richtig, now: noon(0, minutes: 1), calendar: utc)  // b sitzt
        XCTAssertEqual(queue.current?.id, a.id)

        queue.record(.richtig, now: noon(0, minutes: 2), calendar: utc)  // a sitzt jetzt auch
        XCTAssertTrue(queue.isFinished)
        XCTAssertEqual(queue.repetitions, 1)
    }

    func testTeilweiseCountsAsRecalledAndDoesNotRepeatToday() {
        // FSRS: "Hard" ist ein (knapp) gewusster Abruf -> nicht heute nochmal.
        let neu = makeCard()
        var queue = StudyQueue(cards: [neu])

        let outcome = queue.record(.teilweise, now: noon(0), calendar: utc)

        XCTAssertEqual(outcome?.intervalDays, 1)
        XCTAssertTrue(queue.isFinished)
    }

    func testRequeuedCardCarriesUpdatedFSRSState() {
        let card = makeCard()
        var queue = StudyQueue(cards: [card])

        queue.record(.falsch, now: noon(0), calendar: utc)

        let requeued = queue.current
        XCTAssertNotNil(requeued?.fsrsStability, "Die Wiederholung muss mit dem neuen FSRS-Zustand weiterrechnen.")
        XCTAssertEqual(requeued?.fsrsReps, 1)
        XCTAssertEqual(requeued?.srsDueAt, noon(0, minutes: 10))

        // Gleicher Tag -> Kurzzeit-Stabilität, danach planmäßig in der Zukunft fällig.
        let next = queue.record(.richtig, now: noon(0, minutes: 10), calendar: utc)
        XCTAssertNotNil(next?.intervalDays)
        XCTAssertEqual(next?.state.reps, 2)
    }

    func testExamDateIsPassedThrough() {
        // Ohne Prüfung käme die Karte laut FSRS erst in Wochen wieder dran;
        // Prüfung in 4 Tagen -> die Hälfte, also in 2 Tagen.
        var learned = makeCard()
        learned.apply(FSRSCardState(stability: 8.2956, difficulty: 1.0, lastReview: noon(-8), due: noon(0), reps: 1))
        var queue = StudyQueue(cards: [learned])

        let outcome = queue.record(.richtig, now: noon(0), examDate: noon(4), calendar: utc)

        XCTAssertEqual(outcome?.intervalDays, 2)
    }

    func testStatisticsCountOnlyTheFirstAttempt() {
        let card = makeCard()
        var queue = StudyQueue(cards: [card])

        queue.record(.falsch, percent: 20, now: noon(0), calendar: utc)
        queue.record(.falsch, percent: 40, now: noon(0, minutes: 10), calendar: utc)
        queue.record(.richtig, percent: 90, now: noon(0, minutes: 20), calendar: utc)

        XCTAssertEqual(queue.firstAttempts.count, 1)
        XCTAssertEqual(queue.firstAttempts.first?.urteil, .falsch)
        XCTAssertEqual(queue.firstAttempts.first?.percent, 20)
        XCTAssertEqual(queue.repetitions, 2)
        XCTAssertEqual(queue.cardCount, 1)
    }

    func testUpcomingReturnsCurrentAndNextCardsInOrder() {
        let a = makeCard()
        let b = makeCard()
        let c = makeCard()
        let queue = StudyQueue(cards: [a, b, c])

        XCTAssertEqual(queue.upcoming(2).map(\.id), [a.id, b.id])
        XCTAssertEqual(queue.upcoming(10).map(\.id), [a.id, b.id, c.id], "Mehr als vorhanden darf nicht crashen.")
        XCTAssertTrue(queue.upcoming(0).isEmpty)
        XCTAssertTrue(queue.upcoming(-1).isEmpty)
    }

    func testRecordOnEmptyQueueDoesNothing() {
        var queue = StudyQueue(cards: [])
        XCTAssertNil(queue.record(.richtig))
        XCTAssertTrue(queue.isFinished)
    }
}
