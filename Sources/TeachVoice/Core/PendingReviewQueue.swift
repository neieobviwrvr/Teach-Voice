import Foundation

/// Eine Bewertung, die noch (ganz oder teilweise) gespeichert werden muss.
/// Jede Bewertung geht zuerst hierher und wird dann nachgeholt -- so geht
/// nichts verloren, wenn das Netz kurz weg ist (Simons Wunsch: "absichern").
struct PendingReview: Codable, Identifiable, Equatable {
    let id: UUID
    /// Wem die Bewertung gehört (`LibraryRepository.ownerKey`). Wird nur in
    /// genau dieses Konto nachgeholt, nie in ein anderes.
    let ownerKey: String
    let flashcardId: UUID
    let subfolderId: UUID
    /// Neuer FSRS-Stand der Karte. `nil`, sobald gespeichert ODER von einer
    /// neueren Bewertung derselben Karte ersetzt (der Stand ist absolut,
    /// es zählt nur der neueste).
    var state: FSRSCardState?
    /// Eintrag für den Lernverlauf. `nil`, sobald gespeichert. Wird nie
    /// ersetzt -- jede einzelne Bewertung gehört in den Verlauf.
    var log: NewReviewLog?
    let createdAt: Date

    var isDone: Bool { state == nil && log == nil }
}

/// Warteschlange der noch nicht gespeicherten Bewertungen (reine Logik,
/// gespeichert als JSON auf dem Gerät, siehe `load`/`save`).
struct PendingReviewQueue: Codable, Equatable {
    /// Älter als das wird verworfen, damit ein dauerhaft unspeicherbarer
    /// Eintrag die Schlange nie für immer blockiert.
    static let maxAge: TimeInterval = 30 * 24 * 3600

    private(set) var items: [PendingReview] = []

    /// Hängt eine neue Bewertung an. Ältere, noch offene Stände derselben
    /// Karte werden verworfen (sonst könnte ein alter Stand später einen
    /// neueren überschreiben); ihre Lernverlauf-Einträge bleiben.
    mutating func enqueue(_ review: PendingReview) {
        for index in items.indices
        where items[index].ownerKey == review.ownerKey && items[index].flashcardId == review.flashcardId {
            items[index].state = nil
        }
        items.append(review)
        items.removeAll(where: \.isDone)
    }

    /// Nächster offener Eintrag dieses Besitzers (älteste zuerst).
    func next(for owner: String) -> PendingReview? {
        items.first { $0.ownerKey == owner }
    }

    func count(for owner: String) -> Int {
        items.filter { $0.ownerKey == owner }.count
    }

    /// Der neueste noch nicht gespeicherte Stand einer Karte, falls vorhanden.
    func pendingState(for flashcardId: UUID, owner: String) -> FSRSCardState? {
        items.last { $0.ownerKey == owner && $0.flashcardId == flashcardId && $0.state != nil }?.state
    }

    mutating func markStateDone(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = nil
        items.removeAll(where: \.isDone)
    }

    mutating func markLogDone(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].log = nil
        items.removeAll(where: \.isDone)
    }

    mutating func pruneExpired(now: Date = Date()) {
        items.removeAll { now.timeIntervalSince($0.createdAt) > Self.maxAge }
    }

    // MARK: - Speichern auf dem Gerät

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pending_reviews.json")
    }

    static func load(from url: URL = fileURL) -> PendingReviewQueue {
        guard let data = try? Data(contentsOf: url),
              let queue = try? JSONDecoder().decode(PendingReviewQueue.self, from: data) else {
            return PendingReviewQueue()
        }
        return queue
    }

    func save(to url: URL = Self.fileURL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Was nach einem fehlgeschlagenen Speicherversuch passiert.
enum PendingReviewRetry: Equatable {
    /// Gilt als gespeichert (z.B. schon vorhanden).
    case saved
    /// Vorübergehend (kein Netz, Server schläft, Anmeldung läuft ab) --
    /// behalten und später erneut versuchen.
    case retryLater
    /// Dauerhaft unmöglich (z.B. Karte inzwischen gelöscht) -- verwerfen.
    case discard

    static func classify(_ error: Error) -> PendingReviewRetry {
        if error is URLError { return .retryLater }
        guard let apiError = error as? APIError else { return .retryLater }
        switch apiError {
        case .notAuthenticated, .invalidResponse:
            // Ohne Netz scheitert auch das Erneuern der Anmeldung.
            return .retryLater
        case .decoding:
            // Der Server hat geschrieben, nur die Antwort war unlesbar.
            return .saved
        case .server(let status, _):
            switch status {
            case 409:
                // Lernverlauf-Eintrag schon da (doppelter Versuch) oder die
                // Karte gibt es nicht mehr -- so oder so nichts mehr zu tun.
                return .saved
            case 401, 408, 429, 500...599:
                return .retryLater
            default:
                // z.B. 406: Karte gelöscht (Update traf keine Zeile), 404.
                return .discard
            }
        }
    }
}
