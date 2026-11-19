import XCTest
@testable import TeachVoice

/// Bewertungen dürfen ohne Netz nicht verloren gehen -- und ein alter,
/// nachgeholter Stand darf nie einen neueren überschreiben.
final class PendingReviewQueueTests: XCTestCase {

    private let owner = "cloud:A"
    private let card = UUID()

    private func state(_ stability: Double) -> FSRSCardState {
        FSRSCardState(stability: stability, difficulty: 5, lastReview: Date(), due: Date(), reps: 1)
    }

    private func log(for flashcardId: UUID) -> NewReviewLog {
        NewReviewLog(id: UUID(), flashcardId: flashcardId, rating: .good, reviewedAt: Date(), mode: .tippen,
                     elapsedDays: nil, intervalDays: 2, stability: 2.3, difficulty: 2.1, deckungProzent: nil)
    }

    private func review(_ stability: Double, card: UUID? = nil, owner: String? = nil, createdAt: Date = Date()) -> PendingReview {
        let id = card ?? self.card
        return PendingReview(id: UUID(), ownerKey: owner ?? self.owner, flashcardId: id, subfolderId: UUID(),
                             state: state(stability), log: log(for: id), createdAt: createdAt)
    }

    func testNewerReviewReplacesOlderStateButKeepsBothLogs() {
        var queue = PendingReviewQueue()
        let first = review(1)
        let second = review(2)
        queue.enqueue(first)
        queue.enqueue(second)

        XCTAssertEqual(queue.items.count, 2)
        XCTAssertNil(queue.items[0].state, "Alter Stand darf den neuen später nicht überschreiben")
        XCTAssertNotNil(queue.items[0].log, "Jede Bewertung gehört in den Lernverlauf")
        XCTAssertEqual(queue.pendingState(for: card, owner: owner)?.stability, 2)
    }

    func testItemDisappearsWhenStateAndLogAreSaved() {
        var queue = PendingReviewQueue()
        let item = review(1)
        queue.enqueue(item)

        queue.markStateDone(item.id)
        XCTAssertEqual(queue.count(for: owner), 1, "Lernverlauf fehlt noch")
        XCTAssertNil(queue.pendingState(for: card, owner: owner))

        queue.markLogDone(item.id)
        XCTAssertEqual(queue.count(for: owner), 0)
        XCTAssertNil(queue.next(for: owner))
    }

    func testOwnersAreKeptApart() {
        var queue = PendingReviewQueue()
        queue.enqueue(review(1, owner: "cloud:A"))
        queue.enqueue(review(2, owner: "cloud:B"))

        XCTAssertEqual(queue.count(for: "cloud:A"), 1)
        XCTAssertEqual(queue.next(for: "cloud:B")?.state?.stability, 2)
        XCTAssertEqual(queue.pendingState(for: card, owner: "cloud:A")?.stability, 1,
                       "Eine Bewertung in Konto B ersetzt nichts in Konto A")
    }

    func testOldestFirst() {
        var queue = PendingReviewQueue()
        let other = UUID()
        queue.enqueue(review(1))
        queue.enqueue(review(5, card: other))
        XCTAssertEqual(queue.next(for: owner)?.flashcardId, card)
    }

    func testExpiredItemsArePruned() {
        var queue = PendingReviewQueue()
        queue.enqueue(review(1, createdAt: Date().addingTimeInterval(-PendingReviewQueue.maxAge - 60)))
        queue.enqueue(review(2, card: UUID()))
        queue.pruneExpired()
        XCTAssertEqual(queue.count(for: owner), 1)
    }

    func testSurvivesSavingAndLoading() throws {
        var queue = PendingReviewQueue()
        queue.enqueue(review(3))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        queue.save(to: url)
        let loaded = PendingReviewQueue.load(from: url)
        // Felder einzeln statt `==`: Datumswerte können beim JSON-Umweg im
        // Sub-Mikrosekundenbereich abweichen.
        XCTAssertEqual(loaded.items.map(\.id), queue.items.map(\.id))
        XCTAssertEqual(loaded.items.first?.state?.stability, 3)
        XCTAssertEqual(loaded.items.first?.log?.id, queue.items.first?.log?.id)
        XCTAssertEqual(loaded.items.first?.log?.mode, .tippen)
        XCTAssertEqual(loaded.pendingState(for: card, owner: owner)?.stability, 3)
    }

    func testRetryClassification() {
        XCTAssertEqual(PendingReviewRetry.classify(URLError(.notConnectedToInternet)), .retryLater)
        XCTAssertEqual(PendingReviewRetry.classify(URLError(.timedOut)), .retryLater)
        XCTAssertEqual(PendingReviewRetry.classify(APIError.notAuthenticated), .retryLater)
        XCTAssertEqual(PendingReviewRetry.classify(APIError.server(status: 503, message: "")), .retryLater)
        XCTAssertEqual(PendingReviewRetry.classify(APIError.server(status: 401, message: "")), .retryLater)
        XCTAssertEqual(PendingReviewRetry.classify(APIError.server(status: 409, message: "")), .saved,
                       "Doppelter Lernverlauf-Eintrag = schon gespeichert")
        XCTAssertEqual(PendingReviewRetry.classify(APIError.server(status: 406, message: "")), .discard,
                       "Karte gelöscht -> nicht ewig erneut versuchen")
    }
}
