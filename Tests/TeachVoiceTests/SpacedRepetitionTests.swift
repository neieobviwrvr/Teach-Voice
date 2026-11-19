import XCTest
@testable import TeachVoice

/// Auswahl und Reihenfolge der Karten in einer Lernrunde. Die Planung selbst
/// (FSRS) testet `FSRSTests`.
final class SpacedRepetitionTests: XCTestCase {

    private func makeCard(srsDueAt: Date? = nil) -> Flashcard {
        Flashcard(
            id: UUID(), subfolderId: UUID(), userId: UUID(),
            question: "Q", answer: "A", position: 0,
            createdAt: Date(), updatedAt: Date(),
            srsDueAt: srsDueAt
        )
    }

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

    func testSessionCardsContainDueAndNewButNotFutureCards() {
        let now = Date()
        let overdue = makeCard(srsDueAt: now.addingTimeInterval(-3_600))
        let neu = makeCard(srsDueAt: nil)
        let future = makeCard(srsDueAt: now.addingTimeInterval(86_400))

        let result = SpacedRepetition.sessionCards([future, neu, overdue], now: now)

        XCTAssertEqual(result.map(\.id), [overdue.id, neu.id])
    }
}
