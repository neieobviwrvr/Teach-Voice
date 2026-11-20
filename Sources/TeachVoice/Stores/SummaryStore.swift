import Foundation

/// Hält die importierten Zusammenfassungen: Dateien + `summaries.json` in
/// Application Support/Summaries. Wie die Podcasts nie in Supabase und nicht
/// im `LibraryRepository`, gleich im Cloud- und Gast-Modus.
///
/// Anders als die Podcasts BLEIBEN Zusammenfassungen im iCloud-Backup: sie
/// sind klein und oft Simons eigene Arbeit -- ein verlorenes Original wäre
/// hier schlimmer als ein paar MB im Backup.
@MainActor
final class SummaryStore: ObservableObject {
    @Published private(set) var index: SummaryIndex

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("summaries.json") }

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Summaries", isDirectory: true)
    }

    init(directory: URL = SummaryStore.defaultDirectory) {
        self.directory = directory
        FileImport.prepareDirectory(directory, excludeFromBackup: false)
        let loaded = SummaryIndex.loadValidated(from: directory.appendingPathComponent("summaries.json"))
        index = loaded ?? SummaryIndex()
        if let loaded {
            FileImport.removeOrphans(in: directory, keeping: Set(loaded.summaries.map(\.fileName) + ["summaries.json"]))
        }
    }

    var summaries: [Summary] { index.sorted }
    var totalBytes: Int64 { index.totalBytes }

    func fileURL(for summary: Summary) -> URL {
        directory.appendingPathComponent(summary.fileName)
    }

    /// Kopiert die gewählte Datei in den Ordner und nimmt sie in die Liste auf.
    func importFile(from source: URL) async throws {
        let summary = try await Self.copyIntoLibrary(from: source, directory: directory)
        index.add(summary)
        save()
    }

    func delete(_ id: UUID) {
        guard let removed = index.remove(id) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(removed.fileName))
        save()
    }

    func rename(_ id: UUID, to title: String) {
        index.rename(id, to: title)
        save()
    }

    func setFolder(_ id: UUID, folderId: UUID?) {
        index.setFolder(id, folderId: folderId)
        save()
    }

    private func save() {
        index.save(to: indexURL)
    }

    /// Läuft außerhalb des Main Threads: die Kopie kann eine iCloud-Datei
    /// erst herunterladen.
    private nonisolated static func copyIntoLibrary(from source: URL, directory: URL) async throws -> Summary {
        let id = UUID()
        let originalName = source.lastPathComponent
        let ext = FileImport.fileExtension(forFileName: originalName, fallback: "pdf")
        let target = directory.appendingPathComponent("\(id.uuidString).\(ext)")
        try FileImport.copyPickedFile(from: source, to: target)
        return Summary(
            id: id,
            title: FileImport.defaultTitle(forFileName: originalName, fallback: "Zusammenfassung"),
            fileName: target.lastPathComponent,
            originalFileName: originalName,
            byteSize: FileImport.fileSize(target),
            importedAt: Date(),
            folderId: nil
        )
    }
}
