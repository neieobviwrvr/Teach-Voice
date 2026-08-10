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
private struct SRSPatch: Encodable {
    let srsBox: Int
    let srsDueAt: Date
    let srsLastReviewedAt: Date
    enum CodingKeys: String, CodingKey {
        case srsBox = "srs_box"
        case srsDueAt = "srs_due_at"
        case srsLastReviewedAt = "srs_last_reviewed_at"
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

    func updateFlashcardSRS(id: UUID, box: Int, dueAt: Date, lastReviewedAt: Date) async throws -> Flashcard {
        let ctx = try await context()
        return try await SupabaseRestClient.update(
            table: "flashcards",
            id: id,
            body: SRSPatch(srsBox: box, srsDueAt: dueAt, srsLastReviewedAt: lastReviewedAt),
            accessToken: ctx.token
        )
    }
}
