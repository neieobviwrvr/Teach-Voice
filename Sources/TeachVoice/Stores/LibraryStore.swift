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

/// Hält Ordner/Unterordner/Karteikarten lokal vor und synchronisiert sie mit Supabase.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var subfolders: [UUID: [Subfolder]] = [:]
    @Published private(set) var flashcards: [UUID: [Flashcard]] = [:]
    @Published var errorMessage: String?
    @Published var isLoading = false

    private let auth: AuthManager

    init(auth: AuthManager) {
        self.auth = auth
    }

    func subfolders(in folder: Folder) -> [Subfolder] { subfolders[folder.id] ?? [] }
    func flashcards(in subfolder: Subfolder) -> [Flashcard] { flashcards[subfolder.id] ?? [] }

    // MARK: - Folders

    func loadFolders() async {
        guard let token = await auth.validAccessToken(), let userId = auth.session?.userId else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await SupabaseRestClient.select(
                table: "folders",
                query: [
                    URLQueryItem(name: "user_id", value: "eq.\(userId.uuidString)"),
                    URLQueryItem(name: "order", value: "position.asc,created_at.asc")
                ],
                accessToken: token
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addFolder(name: String) async {
        guard let token = await auth.validAccessToken(), let userId = auth.session?.userId else { return }
        do {
            let created: Folder = try await SupabaseRestClient.insert(
                table: "folders",
                body: NewFolder(userId: userId, name: name),
                accessToken: token
            )
            folders.append(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: Folder) async {
        guard let token = await auth.validAccessToken() else { return }
        do {
            try await SupabaseRestClient.delete(table: "folders", id: folder.id, accessToken: token)
            folders.removeAll { $0.id == folder.id }
            subfolders[folder.id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Subfolders

    func loadSubfolders(for folder: Folder) async {
        guard let token = await auth.validAccessToken() else { return }
        do {
            let items: [Subfolder] = try await SupabaseRestClient.select(
                table: "subfolders",
                query: [
                    URLQueryItem(name: "folder_id", value: "eq.\(folder.id.uuidString)"),
                    URLQueryItem(name: "order", value: "position.asc,created_at.asc")
                ],
                accessToken: token
            )
            subfolders[folder.id] = items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addSubfolder(name: String, to folder: Folder) async {
        guard let token = await auth.validAccessToken(), let userId = auth.session?.userId else { return }
        do {
            let created: Subfolder = try await SupabaseRestClient.insert(
                table: "subfolders",
                body: NewSubfolder(folderId: folder.id, userId: userId, name: name),
                accessToken: token
            )
            subfolders[folder.id, default: []].append(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSubfolder(_ subfolder: Subfolder, to newName: String) async {
        guard let token = await auth.validAccessToken() else { return }
        do {
            let updated: Subfolder = try await SupabaseRestClient.update(
                table: "subfolders",
                id: subfolder.id,
                body: RenamePatch(name: newName),
                accessToken: token
            )
            if var list = subfolders[subfolder.folderId], let idx = list.firstIndex(where: { $0.id == subfolder.id }) {
                list[idx] = updated
                subfolders[subfolder.folderId] = list
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSubfolder(_ subfolder: Subfolder) async {
        guard let token = await auth.validAccessToken() else { return }
        do {
            try await SupabaseRestClient.delete(table: "subfolders", id: subfolder.id, accessToken: token)
            subfolders[subfolder.folderId]?.removeAll { $0.id == subfolder.id }
            flashcards[subfolder.id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Flashcards

    func loadFlashcards(for subfolder: Subfolder) async {
        guard let token = await auth.validAccessToken() else { return }
        do {
            let items: [Flashcard] = try await SupabaseRestClient.select(
                table: "flashcards",
                query: [
                    URLQueryItem(name: "subfolder_id", value: "eq.\(subfolder.id.uuidString)"),
                    URLQueryItem(name: "order", value: "position.asc,created_at.asc")
                ],
                accessToken: token
            )
            flashcards[subfolder.id] = items
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Legt eine Karteikarte an. Gibt `false` zurück, wenn das 20er-Limit
    /// (clientseitige Vorabprüfung, hart durchgesetzt per DB-Trigger) erreicht ist.
    @discardableResult
    func addFlashcard(question: String, answer: String, to subfolder: Subfolder) async -> Bool {
        guard flashcards(in: subfolder).count < maxFlashcardsPerSubfolder else {
            errorMessage = "Maximal \(maxFlashcardsPerSubfolder) Karteikarten pro Unterordner."
            return false
        }
        guard let token = await auth.validAccessToken(), let userId = auth.session?.userId else { return false }
        do {
            let created: Flashcard = try await SupabaseRestClient.insert(
                table: "flashcards",
                body: NewFlashcard(subfolderId: subfolder.id, userId: userId, question: question, answer: answer),
                accessToken: token
            )
            flashcards[subfolder.id, default: []].append(created)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateFlashcard(_ flashcard: Flashcard, question: String, answer: String) async {
        guard let token = await auth.validAccessToken() else { return }
        do {
            let updated: Flashcard = try await SupabaseRestClient.update(
                table: "flashcards",
                id: flashcard.id,
                body: FlashcardPatch(question: question, answer: answer),
                accessToken: token
            )
            if var list = flashcards[flashcard.subfolderId], let idx = list.firstIndex(where: { $0.id == flashcard.id }) {
                list[idx] = updated
                flashcards[flashcard.subfolderId] = list
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFlashcard(_ flashcard: Flashcard) async {
        guard let token = await auth.validAccessToken() else { return }
        do {
            try await SupabaseRestClient.delete(table: "flashcards", id: flashcard.id, accessToken: token)
            flashcards[flashcard.subfolderId]?.removeAll { $0.id == flashcard.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
