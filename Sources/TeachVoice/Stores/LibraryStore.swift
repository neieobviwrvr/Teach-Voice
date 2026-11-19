import Foundation
import Network

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
    /// Bewertungen des aktuellen Kontos, die noch nicht gespeichert werden
    /// konnten (z.B. kein Netz) und nachgeholt werden -- für den Hinweis
    /// `PendingReviewsBanner`.
    @Published private(set) var pendingReviewCount = 0

    private var repository: LibraryRepository

    /// Jede Bewertung geht zuerst in diese Schlange (auf dem Gerät
    /// gespeichert) und wird von dort gespeichert bzw. nachgeholt.
    private var pendingReviews = PendingReviewQueue.load() {
        didSet {
            pendingReviews.save()
            pendingReviewCount = pendingReviews.count(for: repository.ownerKey)
        }
    }
    private var isFlushingPendingReviews = false
    /// Holt offene Bewertungen nach, sobald das Netz zurück ist.
    private let pathMonitor = NWPathMonitor()

    init(repository: LibraryRepository) {
        self.repository = repository
        pendingReviewCount = pendingReviews.count(for: repository.ownerKey)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flushPendingReviews() }
        }
        // Läuft so lange wie die App (der Store lebt app-weit).
        pathMonitor.start(queue: DispatchQueue(label: "teachvoice.network-monitor"))
    }

    /// Wechselt die Datenquelle (z.B. Gast -> eingeloggt) und leert den lokalen
    /// Cache, damit keine Daten aus dem vorherigen Modus sichtbar bleiben.
    func useRepository(_ repository: LibraryRepository) {
        self.repository = repository
        folders = []
        subfolders = [:]
        flashcards = [:]
        errorMessage = nil
        pendingReviewCount = pendingReviews.count(for: repository.ownerKey)
        Task { await flushPendingReviews() }
    }

    func subfolders(in folder: Folder) -> [Subfolder] { subfolders[folder.id] ?? [] }
    func flashcards(in subfolder: Subfolder) -> [Flashcard] { flashcards[subfolder.id] ?? [] }

    /// Der aktuelle Stand einer Karte (z.B. mit dem in dieser Session
    /// gespeicherten Spaced-Repetition-Zustand), falls sie noch geladen ist.
    /// Gelöschte Karten liefern `nil`.
    func currentVersion(of card: Flashcard) -> Flashcard? {
        guard let list = flashcards[card.subfolderId] else { return card }
        return list.first { $0.id == card.id }
    }

    /// Summe der Karten über ALLE Unterordner eines Ordners. Nur so genau wie
    /// die bereits geladenen Karten (siehe `loadAllFlashcards`).
    func totalFlashcardCount(in folder: Folder) -> Int {
        subfolders(in: folder).reduce(0) { $0 + flashcards(in: $1).count }
    }

    /// Lädt Karten für JEDEN Unterordner eines Ordners nach, nicht nur den
    /// zuletzt besuchten – nötig, um einen ganzen Ordner (alle Unterordner)
    /// abzufragen oder seine Gesamt-Kartenzahl anzuzeigen. `force` lädt auch
    /// bereits geladene Unterordner neu (z.B. vor einer Lern-Session, damit
    /// gerade über Claude angelegte Karten mit dabei sind).
    func loadAllFlashcards(for folder: Folder, force: Bool = false) async {
        if force || subfolders(in: folder).isEmpty {
            await loadSubfolders(for: folder)
        }
        for subfolder in subfolders(in: folder) where force || flashcards[subfolder.id] == nil {
            await loadFlashcards(for: subfolder)
        }
    }

    /// Alle Karten eines Ordners über alle Unterordner, in Unterordner-Reihenfolge.
    func allFlashcards(in folder: Folder) -> [Flashcard] {
        subfolders(in: folder).flatMap { flashcards(in: $0) }
    }

    // MARK: - Folders

    func loadFolders() async {
        isLoading = true
        defer { isLoading = false }
        do {
            folders = try await repository.fetchFolders()
            // Server erreichbar -> gute Gelegenheit, Offenes nachzuholen.
            if pendingReviewCount > 0 { Task { await flushPendingReviews() } }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Legt einen Ober-Ordner an. Gibt `false` zurück, wenn das Anlegen
    /// fehlschlägt (Fehlertext landet in `errorMessage`).
    @discardableResult
    func addFolder(name: String) async -> Bool {
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

    /// Unterordner sind bewusst unbegrenzt – gibt den neu angelegten
    /// Unterordner zurück (statt nur `Bool`), weil der PDF-Import
    /// (`PDFImportView`) sofort danach Karten in genau diesen neuen
    /// Unterordner schreiben muss.
    @discardableResult
    func addSubfolder(name: String, to folder: Folder) async -> Subfolder? {
        do {
            let created = try await repository.insertSubfolder(name: name, folderId: folder.id)
            subfolders[folder.id, default: []].append(created)
            return created
        } catch {
            errorMessage = error.localizedDescription
            return nil
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
            let loaded = try await repository.fetchFlashcards(subfolderId: subfolder.id)
            // Noch nicht gespeicherte Bewertungen sind neuer als der Server-
            // Stand -- sonst würde ein Neuladen sie in der App "zurückdrehen".
            flashcards[subfolder.id] = loaded.map(applyingPendingState)
            if pendingReviewCount > 0 { Task { await flushPendingReviews() } }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Legt eine Karteikarte an. Gibt `false` zurück, wenn das Anlegen
    /// fehlschlägt (Fehlertext landet in `errorMessage`).
    @discardableResult
    func addFlashcard(question: String, answer: String, to subfolder: Subfolder) async -> Bool {
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

    /// Der Prüfungstermin des Ober-Ordners, zu dem diese Karte gehört (nur
    /// bekannt, wenn der Unterordner geladen ist -- das ist beim Lernen immer so).
    func examDate(for flashcard: Flashcard) -> Date? {
        examDate(forSubfolderId: flashcard.subfolderId)
    }

    func examDate(forSubfolderId subfolderId: UUID) -> Date? {
        for (folderId, list) in subfolders where list.contains(where: { $0.id == subfolderId }) {
            return folders.first { $0.id == folderId }?.examAt
        }
        return nil
    }

    /// Lernverlauf ab `since` (für die Statistik). Fehler -> leere Liste,
    /// die Statistik zeigt dann nur den Kartenstand.
    func reviewLogs(since: Date) async -> [ReviewLog] {
        (try? await repository.fetchReviewLogs(since: since)) ?? []
    }

    /// Kurztext, wann FSRS die Karte bei dieser Bewertung wieder zeigt
    /// ("10 Min", "3 T", "2 Wo" ...) -- für die Bewertungs-Buttons.
    func nextReviewLabel(for flashcard: Flashcard, urteil: GradingResult.Urteil) -> String {
        nextReviewLabel(for: flashcard, rating: FSRSRating(urteil))
    }

    func nextReviewLabel(for flashcard: Flashcard, rating: FSRSRating) -> String {
        let outcome = FSRSScheduler.review(flashcard.fsrsState, rating: rating, examDate: examDate(for: flashcard))
        return FSRSScheduler.intervalLabel(outcome.intervalDays)
    }

    func setExamDate(_ date: Date?, for folder: Folder) async {
        do {
            let updated = try await repository.setFolderExamDate(id: folder.id, examAt: date)
            if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                folders[idx] = updated
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Verbucht ein Lernergebnis mit FSRS und speichert den neuen Lernzustand
    /// (Stabilität, Schwierigkeit, Fälligkeit). `urteil` ist die
    /// Selbsteinschätzung des Users (in beiden Lernmodi). Rechnet mit exakt
    /// demselben Kartenstand wie die Lernrunde (`StudyQueue.record`), damit
    /// gespeicherter Zustand und Runde übereinstimmen.
    @discardableResult
    func recordSpacedRepetitionOutcome(
        for flashcard: Flashcard,
        urteil: GradingResult.Urteil,
        mode: StudyMode,
        percent: Double? = nil,
        now: Date = Date()
    ) async -> Flashcard? {
        await recordSpacedRepetitionOutcome(for: flashcard, rating: FSRSRating(urteil), mode: mode, percent: percent, now: now)
    }

    /// Wie oben, mit einer der vier FSRS-Bewertungen (Tipp-Modus). Schreibt
    /// zusätzlich einen Eintrag in den Lernverlauf (`review_logs`).
    ///
    /// Speichern ohne Datenverlust: Die Bewertung landet zuerst in der
    /// Warteschlange auf dem Gerät (`PendingReviewQueue`), die App zeigt den
    /// neuen Stand sofort, und gespeichert wird im Hintergrund. Klappt das
    /// nicht (kein Netz), wird es nachgeholt -- beim nächsten Netz-Wechsel,
    /// Laden oder Bewerten. Das Lernen wartet nie auf den Server.
    @discardableResult
    func recordSpacedRepetitionOutcome(
        for flashcard: Flashcard,
        rating: FSRSRating,
        mode: StudyMode,
        percent: Double? = nil,
        now: Date = Date()
    ) async -> Flashcard? {
        let before = flashcard.fsrsState
        let outcome = FSRSScheduler.review(before, rating: rating, now: now, examDate: examDate(for: flashcard))

        let elapsed = before.lastReview.map {
            FSRSScheduler.learningDay(now, calendar: .current) - FSRSScheduler.learningDay($0, calendar: .current)
        }
        let log = NewReviewLog(
            id: UUID(), flashcardId: flashcard.id, rating: rating, reviewedAt: now, mode: mode,
            elapsedDays: before.isNew ? nil : elapsed, intervalDays: outcome.intervalDays,
            stability: outcome.state.stability ?? 0, difficulty: outcome.state.difficulty ?? 0,
            deckungProzent: percent
        )

        pendingReviews.enqueue(PendingReview(
            id: UUID(), ownerKey: repository.ownerKey, flashcardId: flashcard.id,
            subfolderId: flashcard.subfolderId, state: outcome.state, log: log, createdAt: now
        ))

        var updated = flashcard
        updated.apply(outcome.state)
        replaceInCache(updated)

        Task { await flushPendingReviews() }
        return updated
    }

    // MARK: - Offene Bewertungen nachholen

    /// Speichert alle offenen Bewertungen des aktuellen Kontos, älteste
    /// zuerst. Bricht beim ersten vorübergehenden Fehler ab (kein Netz ->
    /// alle weiteren würden genauso scheitern) und versucht es beim nächsten
    /// Anlass erneut.
    func flushPendingReviews() async {
        guard !isFlushingPendingReviews else { return }
        isFlushingPendingReviews = true
        defer { isFlushingPendingReviews = false }

        let repo = repository
        let owner = repo.ownerKey
        pendingReviews.pruneExpired()

        // Liest die Schlange in jeder Runde neu, damit auch Bewertungen
        // drankommen, die während des Speicherns dazukommen. Die Obergrenze
        // ist nur ein Sicherheitsnetz gegen eine Endlosschleife.
        for _ in 0..<500 {
            // Konto gewechselt -> nichts mehr in dieses Repository schreiben.
            guard repo === repository, let item = pendingReviews.next(for: owner) else { return }

            if let state = item.state {
                do {
                    let saved = try await repo.updateFlashcardReview(id: item.flashcardId, state: state)
                    pendingReviews.markStateDone(item.id)
                    // Nur übernehmen, wenn inzwischen keine neuere Bewertung
                    // dieser Karte wartet.
                    if repo === repository, pendingReviews.pendingState(for: item.flashcardId, owner: owner) == nil {
                        replaceInCache(saved)
                    }
                } catch {
                    if PendingReviewRetry.classify(error) == .retryLater { return }
                    pendingReviews.markStateDone(item.id)
                }
            }

            if let log = item.log {
                do {
                    try await repo.insertReviewLog(log)
                    pendingReviews.markLogDone(item.id)
                } catch {
                    if PendingReviewRetry.classify(error) == .retryLater { return }
                    pendingReviews.markLogDone(item.id)
                }
            }
        }
    }

    /// Karte vom Server mit einem noch nicht gespeicherten, neueren
    /// FSRS-Stand überlagern.
    private func applyingPendingState(_ card: Flashcard) -> Flashcard {
        guard let state = pendingReviews.pendingState(for: card.id, owner: repository.ownerKey) else { return card }
        var updated = card
        updated.apply(state)
        return updated
    }

    private func replaceInCache(_ card: Flashcard) {
        guard var list = flashcards[card.subfolderId], let idx = list.firstIndex(where: { $0.id == card.id }) else { return }
        list[idx] = card
        flashcards[card.subfolderId] = list
    }
}
