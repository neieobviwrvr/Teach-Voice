import XCTest
@testable import TeachVoice

final class SpacedRepetitionTests: XCTestCase {

    private func makeCard(id: UUID = UUID(), srsBox: Int = 1, srsDueAt: Date? = nil) -> Flashcard {
        Flashcard(
            id: id, subfolderId: UUID(), userId: UUID(),
            question: "Q", answer: "A", position: 0,
            createdAt: Date(), updatedAt: Date(),
            srsBox: srsBox, srsDueAt: srsDueAt
        )
    }

    // MARK: - nextState

    func testRichtigMovesUpOneBox() {
        let outcome = SpacedRepetition.nextState(currentBox: 2, urteil: .richtig)
        XCTAssertEqual(outcome.newBox, 3)
    }

    func testRichtigAtMaxBoxStaysCapped() {
        let outcome = SpacedRepetition.nextState(currentBox: SpacedRepetition.maxBox, urteil: .richtig)
        XCTAssertEqual(outcome.newBox, SpacedRepetition.maxBox, "Box darf 5 nicht überschreiten.")
    }

    func testTeilweiseKeepsSameBox() {
        let outcome = SpacedRepetition.nextState(currentBox: 3, urteil: .teilweise)
        XCTAssertEqual(outcome.newBox, 3)
    }

    func testFalschResetsToBoxOne() {
        let outcome = SpacedRepetition.nextState(currentBox: 5, urteil: .falsch)
        XCTAssertEqual(outcome.newBox, SpacedRepetition.minBox)
    }

    func testDueDateMatchesIntervalTableForNewBox() {
        let now = Date()
        let outcome = SpacedRepetition.nextState(currentBox: 1, urteil: .richtig, now: now)
        // Box 1 -> richtig -> Box 2 -> intervalDays[1] = 1 Tag.
        let expected = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(outcome.dueAt.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testOutOfRangeCurrentBoxIsClamped() {
        // Defensive: sollte ein ungültiger Box-Wert (0 oder >5) je vorkommen,
        // darf intervalDays[newBox - minBox] nicht out-of-bounds crashen.
        let tooLow = SpacedRepetition.nextState(currentBox: 0, urteil: .teilweise)
        XCTAssertEqual(tooLow.newBox, SpacedRepetition.minBox)
        let tooHigh = SpacedRepetition.nextState(currentBox: 99, urteil: .teilweise)
        XCTAssertEqual(tooHigh.newBox, SpacedRepetition.maxBox)
    }

    // MARK: - ordered

    func testOrderedPutsOverdueCardsFirst() {
        let now = Date()
        let overdue = makeCard(srsDueAt: now.addingTimeInterval(-86_400))
        let notYetDue = makeCard(srsDueAt: now.addingTimeInterval(86_400))
        let neverReviewed = makeCard(srsDueAt: nil)

        let result = SpacedRepetition.ordered([notYetDue, neverReviewed, overdue], now: now)

        XCTAssertEqual(result.map(\.id), [overdue.id, neverReviewed.id, notYetDue.id])
    }

    func testOrderedNeverDropsACard() {
        let now = Date()
        let cards = (0..<6).map { i in
            makeCard(srsDueAt: i.isMultiple(of: 2) ? now.addingTimeInterval(Double(i) * -1000) : nil)
        }
        let result = SpacedRepetition.ordered(cards, now: now)
        XCTAssertEqual(Set(result.map(\.id)), Set(cards.map(\.id)), "ordered() darf niemals Karten ausschließen, nur umsortieren.")
        XCTAssertEqual(result.count, cards.count)
    }

    func testOrderedSortsMultipleOverdueCardsByLongestOverdueFirst() {
        let now = Date()
        let mostOverdue = makeCard(srsDueAt: now.addingTimeInterval(-10_000))
        let leastOverdue = makeCard(srsDueAt: now.addingTimeInterval(-100))

        let result = SpacedRepetition.ordered([leastOverdue, mostOverdue], now: now)

        XCTAssertEqual(result.map(\.id), [mostOverdue.id, leastOverdue.id])
    }
}
