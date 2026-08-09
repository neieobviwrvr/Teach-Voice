import Foundation

struct Folder: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var name: String
    var position: Int
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, position
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct Subfolder: Codable, Identifiable, Hashable {
    let id: UUID
    let folderId: UUID
    let userId: UUID
    var name: String
    var position: Int
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, position
        case folderId = "folder_id"
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct Flashcard: Codable, Identifiable, Hashable {
    let id: UUID
    let subfolderId: UUID
    let userId: UUID
    var question: String
    var answer: String
    var position: Int
    let createdAt: Date
    var updatedAt: Date

    /// Lazy-Cache für die STT-Bewertung: in Kernelemente zerlegte Musterantwort
    /// + SHA-256 der Musterantwort, für die diese Kernelemente zuletzt extrahiert
    /// wurden. `nil`, solange die Karte noch nie im Lernmodus bewertet wurde.
    /// Explizite `= nil`-Defaults, damit der memberwise Initializer (genutzt in
    /// `LocalLibraryRepository.insertFlashcard`) diese Felder optional lässt.
    var kernelemente: [String]? = nil
    var kernelementeSourceHash: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, question, answer, position, kernelemente
        case subfolderId = "subfolder_id"
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case kernelementeSourceHash = "kernelemente_source_hash"
    }
}

// Harte Limits für die Startphase (siehe DB-Trigger enforce_folder_limit /
// enforce_subfolder_limit / enforce_flashcard_limit in
// supabase/migrations/0003_tighter_limits.sql) – bewusst als benannte
// Konstanten statt verstreuter Zahlen, da Simon das ausdrücklich als
// vorläufigen Startwert bezeichnet hat, nicht als endgültige Grenze.

/// Maximale Anzahl Ober-Ordner pro Nutzer.
let maxFoldersPerUser = 1

/// Maximale Anzahl Unterordner pro Ober-Ordner.
let maxSubfoldersPerFolder = 2

/// Maximale Anzahl Karteikarten pro Unterordner.
let maxFlashcardsPerSubfolder = 10
