import Foundation

/// Hält Ordner/Unterordner/Karteikarten lokal (für die UI) vor und delegiert
/// alle Lese-/Schreibzugriffe an ein `LibraryRepository` – je nach Modus
/// entweder Supabase (E-Mail-Login) oder rein lokale Speicherung (Gastzugang).
/// Views bleiben davon unberührt, sie kennen nur `LibraryStore`.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var subfolders: [UUID: [Subfolder]] = [:]
    @Published private(set) var flashcards: [UUID: [Flashcard]] = [:]
    @Published var errorMessage: String?
    @Published var isLoading = false

    private var repository: LibraryRepository

    init(repository: LibraryRepository) {
        self.repository = repository
    }

    /// Wechselt die Datenquelle (z.B. Gast -> eingeloggt) und leert den lokalen
    /// Cache, damit keine Daten aus dem vorherigen Modus sichtbar bleiben.
    func useRepository(_ repository: LibraryRepository) {
        self.repository = repository
        folders = []
        subfolders = [:]
        flashcards = [:]
        errorMessage = nil
    }

    func subfolders(in folder: Folder) -> [Subfolder] { subfolders[folder.id] ?? [] }
    func flashcards(in subfolder: Subfolder) -> [Flashcard] { flashcards[subfolder.id] ?? [] }

    // MARK: - Folders

    func loadFolders() async {
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await repository.fetchFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Legt einen Ober-Ordner an. Gibt `false` zurück, wenn das Limit erreicht ist
    /// (clientseitige Vorabprüfung; im Cloud-Modus zusätzlich hart per DB-Trigger,
    /// im Gastmodus hart im Repository selbst durchgesetzt).
    @discardableResult
    func addFolder(name: String) async -> Bool {
        guard folders.count < maxFoldersPerUser else {
            errorMessage = "Maximal \(maxFoldersPerUser) Ordner erlaubt."
            return false
        }
        do {
            let created = try await repository.insertFolder(name: name)
            folders.append(created)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameFolder(_ folder: Folder, to newName: String) async {
        do {
            let updated = try await repository.renameFolder(id: folder.id, name: newName)
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: Folder) async {
        do {
            try await repository.deleteFolder(id: folder.id)
            folders.removeAll { $0.id == folder.id }
            subfolders[folder.id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Subfolders

    func loadSubfolders(for folder: Folder) async {
        do {
            subfolders[folder.id] = try await repository.fetchSubfolders(folderId: folder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addSubfolder(name: String, to folder: Folder) async -> Bool {
        guard subfolders(in: folder).count < maxSubfoldersPerFolder else {
            errorMessage = "Maximal \(maxSubfoldersPerFolder) Unterordner pro Ordner erlaubt."
            return false
        }
        do {
            let created = try await repository.insertSubfolder(name: name, folderId: folder.id)
            subfolders[folder.id, default: []].append(created)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameSubfolder(_ subfolder: Subfolder, to newName: String) async {
        do {
            let updated = try await repository.renameSubfolder(id: subfolder.id, name: newName)
            if var list = subfolders[subfolder.folderId], let idx = list.firstIndex(where: { $0.id == subfolder.id }) {
                list[idx] = updated
                subfolders[subfolder.folderId] = list
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSubfolder(_ subfolder: Subfolder) async {
        do {
            try await repository.deleteSubfolder(id: subfolder.id)
            subfolders[subfolder.folderId]?.removeAll { $0.id == subfolder.id }
            flashcards[subfolder.id] = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Flashcards

    func loadFlashcards(for subfolder: Subfolder) async {
        do {
            flashcards[subfolder.id] = try await repository.fetchFlashcards(subfolderId: subfolder.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Legt eine Karteikarte an. Gibt `false` zurück, wenn `maxFlashcardsPerSubfolder`
    /// erreicht ist (clientseitige Vorabprüfung für sofortiges UI-Feedback; im Cloud-Modus
    /// zusätzlich hart per DB-Trigger, im Gastmodus hart im Repository selbst durchgesetzt).
    @discardableResult
    func addFlashcard(question: String, answer: String, to subfolder: Subfolder) async -> Bool {
        guard flashcards(in: subfolder).count < maxFlashcardsPerSubfolder else {
            errorMessage = "Maximal \(maxFlashcardsPerSubfolder) Karteikarten pro Unterordner."
            return false
        }
        do {
            let created = try await repository.insertFlashcard(question: question, answer: answer, subfolderId: subfolder.id)
            flashcards[subfolder.id, default: []].append(created)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateFlashcard(_ flashcard: Flashcard, question: String, answer: String) async -> Bool {
        do {
            let updated = try await repository.updateFlashcard(id: flashcard.id, question: question, answer: answer)
            if var list = flashcards[flashcard.subfolderId], let idx = list.firstIndex(where: { $0.id == flashcard.id }) {
                list[idx] = updated
                flashcards[flashcard.subfolderId] = list
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteFlashcard(_ flashcard: Flashcard) async {
        do {
            try await repository.deleteFlashcard(id: flashcard.id)
            flashcards[flashcard.subfolderId]?.removeAll { $0.id == flashcard.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Persistiert den Kernelemente-Cache nach einem Grading-Call (idempotent,
    /// still im Hintergrund – Fehler hier sollen dem User keinen Bewertungs-
    /// Fehler vortäuschen, deshalb kein `errorMessage`-Update).
    func cacheKernelemente(_ kernelemente: [String], for flashcard: Flashcard, sourceHash: String) async {
        do {
            let updated = try await repository.updateFlashcardGradingCache(
                id: flashcard.id, kernelemente: kernelemente, sourceHash: sourceHash
            )
            if var list = flashcards[flashcard.subfolderId], let idx = list.firstIndex(where: { $0.id == flashcard.id }) {
                list[idx] = updated
                flashcards[flashcard.subfolderId] = list
            }
        } catch {
            print("Kernelemente-Cache konnte nicht gespeichert werden: \(error.localizedDescription)")
        }
    }

    /// Verbucht ein Lernergebnis im Spaced-Repetition-Box-System und
    /// persistiert die neue Stufe + Fälligkeit. `urteil` ist bereits die
    /// aufgelöste Signalquelle (Selbsteinschätzung im Detail-Modus, GPT-Mapping
    /// im Hands-free-Modus) – die Priorisierung passiert beim Aufrufer.
    @discardableResult
    func recordSpacedRepetitionOutcome(for flashcard: Flashcard, urteil: GradingResult.Urteil) async -> Flashcard? {
        let outcome = SpacedRepetition.nextState(currentBox: flashcard.srsBox, urteil: urteil)
        do {
            let updated = try await repository.updateFlashcardSRS(
                id: flashcard.id, box: outcome.newBox, dueAt: outcome.dueAt, lastReviewedAt: Date()
            )
            if var list = flashcards[flashcard.subfolderId], let idx = list.firstIndex(where: { $0.id == flashcard.id }) {
                list[idx] = updated
                flashcards[flashcard.subfolderId] = list
            }
            return updated
        } catch {
            print("Spaced-Repetition-Update fehlgeschlagen: \(error.localizedDescription)")
            return nil
        }
    }
}
