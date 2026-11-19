import Foundation

/// Abstraktion über die Datenhaltung von Ordnern/Unterordnern/Karteikarten.
/// Zwei Implementierungen:
/// - `RemoteLibraryRepository`: Supabase (E-Mail-Login, cloudfähig, geräteübergreifend)
/// - `LocalLibraryRepository`: rein on-device (Gastzugang, kein Server-Roundtrip)
///
/// `LibraryStore` (die von den Views genutzte ObservableObject) kennt nur dieses
/// Protokoll – die Views selbst müssen nicht wissen, ob gerade Gast- oder
/// Cloud-Modus aktiv ist.
protocol LibraryRepository: AnyObject {
    /// Eindeutig pro Konto ("cloud:<userId>" bzw. "guest:<id>"). Noch nicht
    /// gespeicherte Bewertungen (`PendingReviewQueue`) werden nur in das Konto
    /// nachgeholt, in dem sie entstanden sind.
    var ownerKey: String { get }

    func fetchFolders() async throws -> [Folder]
    func insertFolder(name: String) async throws -> Folder
    func renameFolder(id: UUID, name: String) async throws -> Folder
    /// Setzt oder löscht (`nil`) den Prüfungstermin eines Ober-Ordners.
    func setFolderExamDate(id: UUID, examAt: Date?) async throws -> Folder
    func deleteFolder(id: UUID) async throws

    func fetchSubfolders(folderId: UUID) async throws -> [Subfolder]
    func insertSubfolder(name: String, folderId: UUID) async throws -> Subfolder
    func renameSubfolder(id: UUID, name: String) async throws -> Subfolder
    func deleteSubfolder(id: UUID) async throws

    func fetchFlashcards(subfolderId: UUID) async throws -> [Flashcard]
    func insertFlashcard(question: String, answer: String, subfolderId: UUID) async throws -> Flashcard
    func updateFlashcard(id: UUID, question: String, answer: String) async throws -> Flashcard
    func deleteFlashcard(id: UUID) async throws

    /// Schreibt den Kernelemente-Cache für die STT-Bewertung fort (Lazy Caching).
    func updateFlashcardGradingCache(id: UUID, kernelemente: [String], sourceHash: String) async throws -> Flashcard

    /// Schreibt den FSRS-Lernzustand fort (Stabilität, Schwierigkeit,
    /// Wiederholungen, Fälligkeit, letzte Wiederholung).
    func updateFlashcardReview(id: UUID, state: FSRSCardState) async throws -> Flashcard

    /// Protokolliert eine einzelne Bewertung (Lernverlauf). Ein zweiter
    /// Versuch mit derselben `log.id` darf keinen doppelten Eintrag erzeugen.
    func insertReviewLog(_ log: NewReviewLog) async throws
    /// Lernverlauf ab `since`, älteste zuerst.
    func fetchReviewLogs(since: Date) async throws -> [ReviewLog]
}
