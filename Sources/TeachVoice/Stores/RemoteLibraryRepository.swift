import Foundation

private struct NewFolder: Encodable {
    let userId: UUID
    let name: String
    enum CodingKeys: String, CodingKey { case userId = "user_id", name }
}

private struct NewSubfolder: Encodable {
    let folderId: UUID
    let userId: UUID
    let name: String
    enum CodingKeys: String, CodingKey { case folderId = "folder_id", userId = "user_id", name }
}

private struct NewFlashcard: Encodable {
    let subfolderId: UUID
    let userId: UUID
    let question: String
    let answer: String
    enum CodingKeys: String, CodingKey { case subfolderId = "subfolder_id", userId = "user_id", question, answer }
}

private struct RenamePatch: Encodable { let name: String }
private struct FlashcardPatch: Encodable { let question: String; let answer: String }
private struct GradingCachePatch: Encodable {
    let kernelemente: [String]
    let kernelementeSourceHash: String
    enum CodingKeys: String, CodingKey {
        case kernelemente
        case kernelementeSourceHash = "kernelemente_source_hash"
    }
}
private struct ReviewPatch: Encodable {
    let state: FSRSCardState
    enum CodingKeys: String, CodingKey {
        case stability = "fsrs_stability"
        case difficulty = "fsrs_difficulty"
        case reps = "fsrs_reps"
        case lapses = "fsrs_lapses"
        case dueAt = "srs_due_at"
        case lastReviewedAt = "srs_last_reviewed_at"
    }

    // Explizit kodiert, damit auch `nil` als JSON-null geschrieben wird.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state.stability, forKey: .stability)
        try container.encode(state.difficulty, forKey: .difficulty)
        try container.encode(state.reps, forKey: .reps)
        try container.encode(state.lapses, forKey: .lapses)
        try container.encode(state.due, forKey: .dueAt)
        try container.encode(state.lastReview, forKey: .lastReviewedAt)
    }
}

private struct ReviewLogBody: Encodable {
    let userId: UUID
    let log: NewReviewLog
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case flashcardId = "flashcard_id"
        case rating
        case reviewedAt = "reviewed_at"
        case mode
        case elapsedDays = "elapsed_days"
        case intervalDays = "interval_days"
        case stability, difficulty
        case deckungProzent = "deckung_prozent"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(userId, forKey: .userId)
        try container.encode(log.flashcardId, forKey: .flashcardId)
        try container.encode(log.rating.rawValue, forKey: .rating)
        try container.encode(log.reviewedAt, forKey: .reviewedAt)
        try container.encode(log.mode.logValue, forKey: .mode)
        try container.encode(log.elapsedDays, forKey: .elapsedDays)
        try container.encode(log.intervalDays, forKey: .intervalDays)
        try container.encode(log.stability, forKey: .stability)
        try container.encode(log.difficulty, forKey: .difficulty)
        try container.encode(log.deckungProzent, forKey: .deckungProzent)
    }
}

private struct ExamDatePatch: Encodable {
    let examAt: Date?
    enum CodingKeys: String, CodingKey { case examAt = "exam_at" }

    // Explizit, damit "Termin löschen" wirklich null schreibt (die
    // synthetisierte Kodierung würde nil einfach weglassen).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(examAt, forKey: .examAt)
    }
}

/// Speichert Ordner/Unterordner/Karteikarten in Supabase (Postgres via PostgREST),
/// RLS-geschützt pro eingeloggtem User. Genutzt für den E-Mail/Passwort-Login.
final class RemoteLibraryRepository: LibraryRepository {
    private let auth: AuthManager

    init(auth: AuthManager) {
        self.auth = auth
    }

    private func context() async throws -> (token: String, userId: UUID) {
        guard let token = await auth.validAccessToken(), let userId = await auth.session?.userId else {
            throw APIError.notAuthenticated
        }
        return (token, userId)
    }

    func fetchFolders() async throws -> [Folder] {
        let ctx = try await context()
        return try await SupabaseRestClient.select(
            table: "folders",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(ctx.userId.uuidString)"),
                URLQueryItem(name: "order", value: "position.asc,created_at.asc")
            ],
            accessToken: ctx.token
        )
    }

    func insertFolder(name: String) async throws -> Folder {
        let ctx = try await context()
        return try await SupabaseRestClient.insert(
            table: "folders",
            body: NewFolder(userId: ctx.userId, name: name),
            accessToken: ctx.token
        )
    }

    func renameFolder(id: UUID, name: String) async throws -> Folder {
        let ctx = try await context()
        return try await SupabaseRestClient.update(
            table: "folders",
            id: id,
            body: RenamePatch(name: name),
            accessToken: ctx.token
        )
    }

    func setFolderExamDate(id: UUID, examAt: Date?) async throws -> Folder {
        let ctx = try await context()
        return try await SupabaseRestClient.update(
            table: "folders",
            id: id,
            body: ExamDatePatch(examAt: examAt),
            accessToken: ctx.token
        )
    }

    func deleteFolder(id: UUID) async throws {
        let ctx = try await context()
        try await SupabaseRestClient.delete(table: "folders", id: id, accessToken: ctx.token)
    }

    func fetchSubfolders(folderId: UUID) async throws -> [Subfolder] {
        let ctx = try await context()
        return try await SupabaseRestClient.select(
            table: "subfolders",
            query: [
                URLQueryItem(name: "folder_id", value: "eq.\(folderId.uuidString)"),
                URLQueryItem(name: "order", value: "position.asc,created_at.asc")
            ],
            accessToken: ctx.token
        )
    }

    func insertSubfolder(name: String, folderId: UUID) async throws -> Subfolder {
        let ctx = try await context()
        return try await SupabaseRestClient.insert(
            table: "subfolders",
            body: NewSubfolder(folderId: folderId, userId: ctx.userId, name: name),
            accessToken: ctx.token
        )
    }

    func renameSubfolder(id: UUID, name: String) async throws -> Subfolder {
        let ctx = try await context()
        return try await SupabaseRestClient.update(
            table: "subfolders",
            id: id,
            body: RenamePatch(name: name),
            accessToken: ctx.token
        )
    }

    func deleteSubfolder(id: UUID) async throws {
        let ctx = try await context()
        try await SupabaseRestClient.delete(table: "subfolders", id: id, accessToken: ctx.token)
    }

    func fetchFlashcards(subfolderId: UUID) async throws -> [Flashcard] {
        let ctx = try await context()
        return try await SupabaseRestClient.select(
            table: "flashcards",
            query: [
                URLQueryItem(name: "subfolder_id", value: "eq.\(subfolderId.uuidString)"),
                URLQueryItem(name: "order", value: "position.asc,created_at.asc")
            ],
            accessToken: ctx.token
        )
    }

    func insertFlashcard(question: String, answer: String, subfolderId: UUID) async throws -> Flashcard {
        let ctx = try await context()
        return try await SupabaseRestClient.insert(
            table: "flashcards",
            body: NewFlashcard(subfolderId: subfolderId, userId: ctx.userId, question: question, answer: answer),
            accessToken: ctx.token
        )
    }

    func updateFlashcard(id: UUID, question: String, answer: String) async throws -> Flashcard {
        let ctx = try await context()
        return try await SupabaseRestClient.update(
            table: "flashcards",
            id: id,
            body: FlashcardPatch(question: question, answer: answer),
            accessToken: ctx.token
        )
    }

    func deleteFlashcard(id: UUID) async throws {
        let ctx = try await context()
        try await SupabaseRestClient.delete(table: "flashcards", id: id, accessToken: ctx.token)
    }

    func updateFlashcardGradingCache(id: UUID, kernelemente: [String], sourceHash: String) async throws -> Flashcard {
        let ctx = try await context()
        return try await SupabaseRestClient.update(
            table: "flashcards",
            id: id,
            body: GradingCachePatch(kernelemente: kernelemente, kernelementeSourceHash: sourceHash),
            accessToken: ctx.token
        )
    }

    func insertReviewLog(_ log: NewReviewLog) async throws {
        let ctx = try await context()
        let _: ReviewLog = try await SupabaseRestClient.insert(
            table: "review_logs",
            body: ReviewLogBody(userId: ctx.userId, log: log),
            accessToken: ctx.token
        )
    }

    func fetchReviewLogs(since: Date) async throws -> [ReviewLog] {
        let ctx = try await context()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return try await SupabaseRestClient.select(
            table: "review_logs",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(ctx.userId.uuidString)"),
                URLQueryItem(name: "reviewed_at", value: "gte.\(formatter.string(from: since))"),
                URLQueryItem(name: "order", value: "reviewed_at.asc"),
            ],
            accessToken: ctx.token
        )
    }

    func updateFlashcardReview(id: UUID, state: FSRSCardState) async throws -> Flashcard {
        let ctx = try await context()
        return try await SupabaseRestClient.update(
            table: "flashcards",
            id: id,
            body: ReviewPatch(state: state),
            accessToken: ctx.token
        )
    }
}
