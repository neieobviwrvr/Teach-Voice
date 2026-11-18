import XCTest
@testable import TeachVoice

final class StudyQueueTests: XCTestCase {

    private func makeCard(srsBox: Int = 1, srsDueAt: Date? = nil) -> Flashcard {
        Flashcard(
            id: UUID(), subfolderId: UUID(), userId: UUID(),
            question: "Q", answer: "A", position: 0,
            createdAt: Date(), updatedAt: Date(),
            srsBox: srsBox, srsDueAt: srsDueAt
        )
    }

    func testRichtigRemovesCardFromSession() {
        let card = makeCard()
        var queue = StudyQueue(cards: [card])

        let outcome = queue.record(.richtig)

        XCTAssertEqual(outcome?.newBox, 2)
        XCTAssertTrue(queue.isFinished)
        XCTAssertEqual(queue.count(of: .richtig), 1)
    }

    func testFalschComesBackAtTheEndUntilItSits() {
        let a = makeCard()
        let b = makeCard()
        var queue = StudyQueue(cards: [a, b])

        queue.record(.falsch)                     // a -> hinten wieder dran
        XCTAssertEqual(queue.pending.map(\.id), [b.id, a.id])

        queue.record(.richtig)                    // b sitzt
        XCTAssertEqual(queue.current?.id, a.id)

        queue.record(.richtig)                    // a sitzt jetzt auch
        XCTAssertTrue(queue.isFinished)
        XCTAssertEqual(queue.repetitions, 1)
    }

    func testTeilweiseInBoxOneRepeatsButHigherBoxDoesNot() {
        let neu = makeCard(srsBox: 1)
        let gelernt = makeCard(srsBox: 3)
        var queue = StudyQueue(cards: [neu, gelernt])

        queue.record(.teilweise)                  // Box 1 bleibt Box 1 -> heute nochmal
        queue.record(.teilweise)                  // Box 3 bleibt Box 3 -> in 3 Tagen

        XCTAssertEqual(queue.pending.map(\.id), [neu.id])
    }

    func testRequeuedCardCarriesUpdatedBox() {
        let card = makeCard(srsBox: 4)
        var queue = StudyQueue(cards: [card])

        queue.record(.falsch)

        XCTAssertEqual(queue.current?.srsBox, 1, "Die Wiederholung muss mit der neuen Box weiterrechnen.")
        let next = queue.record(.richtig)
        XCTAssertEqual(next?.newBox, 2)
    }

    func testStatisticsCountOnlyTheFirstAttempt() {
        let card = makeCard()
        var queue = StudyQueue(cards: [card])

        queue.record(.falsch, percent: 20)
        queue.record(.falsch, percent: 40)
        queue.record(.richtig, percent: 90)

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

    // MARK: - SpacedRepetition.sessionCards

    func testSessionCardsContainDueAndNewButNotFutureCards() {
        let now = Date()
        let overdue = makeCard(srsDueAt: now.addingTimeInterval(-3_600))
        let neu = makeCard(srsDueAt: nil)
        let future = makeCard(srsDueAt: now.addingTimeInterval(86_400))

        let result = SpacedRepetition.sessionCards([future, neu, overdue], now: now)

        XCTAssertEqual(result.map(\.id), [overdue.id, neu.id])
    }

    func testIsDueAgainTodayOnlyForBoxOne() {
        XCTAssertTrue(SpacedRepetition.isDueAgainToday(SpacedRepetition.nextState(currentBox: 3, urteil: .falsch)))
        XCTAssertFalse(SpacedRepetition.isDueAgainToday(SpacedRepetition.nextState(currentBox: 1, urteil: .richtig)))
        XCTAssertFalse(SpacedRepetition.isDueAgainToday(SpacedRepetition.nextState(currentBox: 2, urteil: .teilweise)))
    }
}
