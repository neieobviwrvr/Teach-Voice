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
    func fetchFolders() async throws -> [Folder]
    func insertFolder(name: String) async throws -> Folder
    func renameFolder(id: UUID, name: String) async throws -> Folder
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

    /// Schreibt den Spaced-Repetition-Zustand fort (Box + nächste Fälligkeit).
    func updateFlashcardSRS(id: UUID, box: Int, dueAt: Date, lastReviewedAt: Date) async throws -> Flashcard
}
