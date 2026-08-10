import Foundation

/// Rein lokale Datenhaltung für den Gastzugang: Ordner/Unterordner/Karteikarten
/// leben ausschließlich als JSON-Datei im App-Sandbox-Verzeichnis dieses Geräts.
/// Es findet kein Netzwerk-Request statt – nichts verlässt das iPhone.
final class LocalLibraryRepository: LibraryRepository {
    private struct Snapshot: Codable {
        var folders: [Folder] = []
        var subfolders: [Subfolder] = []
        var flashcards: [Flashcard] = []
    }

    private let userId = GuestIdentity.id
    private let fileURL: URL
    private var snapshot: Snapshot

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        fileURL = supportDir.appendingPathComponent("guest_library.json")

        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? Self.decoder.decode(Snapshot.self, from: data) {
            snapshot = loaded
        } else {
            snapshot = Snapshot()
        }
    }

    private func persist() {
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Folders

    func fetchFolders() async throws -> [Folder] {
        snapshot.folders.sorted(by: Self.order)
    }

    func insertFolder(name: String) async throws -> Folder {
        guard snapshot.folders.count < maxFoldersPerUser else {
            throw APIError.server(status: 400, message: "Maximal \(maxFoldersPerUser) Ordner erlaubt.")
        }
        let folder = Folder(
            id: UUID(), userId: userId, name: name, position: snapshot.folders.count,
            createdAt: Date(), updatedAt: Date()
        )
        snapshot.folders.append(folder)
        persist()
        return folder
    }

    func renameFolder(id: UUID, name: String) async throws -> Folder {
        guard let idx = snapshot.folders.firstIndex(where: { $0.id == id }) else {
            throw APIError.server(status: 404, message: "Ordner nicht gefunden.")
        }
        snapshot.folders[idx].name = name
        snapshot.folders[idx].updatedAt = Date()
        persist()
        return snapshot.folders[idx]
    }

    func deleteFolder(id: UUID) async throws {
        snapshot.folders.removeAll { $0.id == id }
        let orphanedSubfolderIds = Set(snapshot.subfolders.filter { $0.folderId == id }.map(\.id))
        snapshot.subfolders.removeAll { $0.folderId == id }
        snapshot.flashcards.removeAll { orphanedSubfolderIds.contains($0.subfolderId) }
        persist()
    }

    // MARK: - Subfolders

    func fetchSubfolders(folderId: UUID) async throws -> [Subfolder] {
        snapshot.subfolders.filter { $0.folderId == folderId }.sorted(by: Self.order)
    }

    func insertSubfolder(name: String, folderId: UUID) async throws -> Subfolder {
        let position = snapshot.subfolders.filter { $0.folderId == folderId }.count
        guard position < maxSubfoldersPerFolder else {
            throw APIError.server(status: 400, message: "Maximal \(maxSubfoldersPerFolder) Unterordner pro Ordner erlaubt.")
        }
        let subfolder = Subfolder(
            id: UUID(), folderId: folderId, userId: userId, name: name, position: position,
            createdAt: Date(), updatedAt: Date()
        )
        snapshot.subfolders.append(subfolder)
        persist()
        return subfolder
    }

    func renameSubfolder(id: UUID, name: String) async throws -> Subfolder {
        guard let idx = snapshot.subfolders.firstIndex(where: { $0.id == id }) else {
            throw APIError.server(status: 404, message: "Unterordner nicht gefunden.")
        }
        snapshot.subfolders[idx].name = name
        snapshot.subfolders[idx].updatedAt = Date()
        persist()
        return snapshot.subfolders[idx]
    }

    func deleteSubfolder(id: UUID) async throws {
        snapshot.subfolders.removeAll { $0.id == id }
        snapshot.flashcards.removeAll { $0.subfolderId == id }
        persist()
    }

    // MARK: - Flashcards

    func fetchFlashcards(subfolderId: UUID) async throws -> [Flashcard] {
        snapshot.flashcards.filter { $0.subfolderId == subfolderId }.sorted(by: Self.order)
    }

    func insertFlashcard(question: String, answer: String, subfolderId: UUID) async throws -> Flashcard {
        let count = snapshot.flashcards.filter { $0.subfolderId == subfolderId }.count
        guard count < maxFlashcardsPerSubfolder else {
            throw APIError.server(status: 400, message: "Maximal \(maxFlashcardsPerSubfolder) Karteikarten pro Unterordner.")
        }
        let card = Flashcard(
            id: UUID(), subfolderId: subfolderId, userId: userId, question: question, answer: answer,
            position: count, createdAt: Date(), updatedAt: Date()
        )
        snapshot.flashcards.append(card)
        persist()
        return card
    }

    func updateFlashcard(id: UUID, question: String, answer: String) async throws -> Flashcard {
        guard let idx = snapshot.flashcards.firstIndex(where: { $0.id == id }) else {
            throw APIError.server(status: 404, message: "Karteikarte nicht gefunden.")
        }
        snapshot.flashcards[idx].question = question
        snapshot.flashcards[idx].answer = answer
        snapshot.flashcards[idx].updatedAt = Date()
        persist()
        return snapshot.flashcards[idx]
    }

    func deleteFlashcard(id: UUID) async throws {
        snapshot.flashcards.removeAll { $0.id == id }
        persist()
    }

    func updateFlashcardGradingCache(id: UUID, kernelemente: [String], sourceHash: String) async throws -> Flashcard {
        guard let idx = snapshot.flashcards.firstIndex(where: { $0.id == id }) else {
            throw APIError.server(status: 404, message: "Karteikarte nicht gefunden.")
        }
        snapshot.flashcards[idx].kernelemente = kernelemente
        snapshot.flashcards[idx].kernelementeSourceHash = sourceHash
        persist()
        return snapshot.flashcards[idx]
    }

    func updateFlashcardSRS(id: UUID, box: Int, dueAt: Date, lastReviewedAt: Date) async throws -> Flashcard {
        guard let idx = snapshot.flashcards.firstIndex(where: { $0.id == id }) else {
            throw APIError.server(status: 404, message: "Karteikarte nicht gefunden.")
        }
        snapshot.flashcards[idx].srsBox = box
        snapshot.flashcards[idx].srsDueAt = dueAt
        snapshot.flashcards[idx].srsLastReviewedAt = lastReviewedAt
        persist()
        return snapshot.flashcards[idx]
    }

    private static func order<T>(_ a: T, _ b: T) -> Bool where T: Positioned & Timestamped {
        a.position == b.position ? a.createdAt < b.createdAt : a.position < b.position
    }
}

protocol Positioned { var position: Int { get } }
protocol Timestamped { var createdAt: Date { get } }

extension Folder: Positioned, Timestamped {}
extension Subfolder: Positioned, Timestamped {}
extension Flashcard: Positioned, Timestamped {}
