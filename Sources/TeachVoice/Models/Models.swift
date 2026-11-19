import Foundation

struct Folder: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var name: String
    var position: Int
    let createdAt: Date
    var updatedAt: Date
    /// Optionaler Prüfungstermin (siehe `FSRSScheduler`): Wiederholungen, die
    /// erst danach fällig wären, werden vorgezogen.
    var examAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, position
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case examAt = "exam_at"
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

    /// Lernzustand für FSRS (siehe `FSRS`/`FSRSScheduler`). `srsDueAt == nil`
    /// bedeutet "noch nie bewertet" – solche Karten zählen in einer Lernrunde
    /// als neu und werden nach den fälligen abgefragt.
    /// `srsBox` stammt aus dem früheren Box-System und wird nicht mehr benutzt.
    var srsBox: Int = 1
    var srsDueAt: Date? = nil
    var srsLastReviewedAt: Date? = nil
    var fsrsStability: Double? = nil
    var fsrsDifficulty: Double? = nil
    /// Optional, damit ältere Gastmodus-Daten (ohne diese Felder) lesbar bleiben.
    var fsrsReps: Int? = nil
    var fsrsLapses: Int? = nil

    enum CodingKeys: String, CodingKey {
        case id, question, answer, position, kernelemente
        case subfolderId = "subfolder_id"
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case kernelementeSourceHash = "kernelemente_source_hash"
        case srsBox = "srs_box"
        case srsDueAt = "srs_due_at"
        case srsLastReviewedAt = "srs_last_reviewed_at"
        case fsrsStability = "fsrs_stability"
        case fsrsDifficulty = "fsrs_difficulty"
        case fsrsReps = "fsrs_reps"
        case fsrsLapses = "fsrs_lapses"
    }

    /// Der FSRS-Zustand dieser Karte. Karten aus dem alten Box-System (ohne
    /// Stabilität) gelten als neu.
    var fsrsState: FSRSCardState {
        FSRSCardState(
            stability: fsrsStability,
            difficulty: fsrsDifficulty,
            lastReview: fsrsStability == nil ? nil : srsLastReviewedAt,
            due: srsDueAt,
            reps: fsrsReps ?? 0,
            lapses: fsrsLapses ?? 0
        )
    }

    mutating func apply(_ state: FSRSCardState) {
        fsrsStability = state.stability
        fsrsDifficulty = state.difficulty
        fsrsReps = state.reps
        fsrsLapses = state.lapses
        srsDueAt = state.due
        srsLastReviewedAt = state.lastReview
    }
}

// Keine Mengen-Limits mehr für Ordner, Unterordner oder Karteikarten (Simons
// Entscheidung fürs MVP, das vorerst nur er selbst nutzt). Die früheren
// DB-Trigger entfernt supabase/migrations/0013_remove_limits.sql.
