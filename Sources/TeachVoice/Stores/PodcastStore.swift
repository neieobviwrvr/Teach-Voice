import Foundation

/// Hält die importierten Podcasts: Audiodateien + `podcasts.json` in
/// Application Support/Podcasts. Bewusst NICHT im `LibraryRepository`:
/// Podcasts gehen nie an Supabase, sind unabhängig vom Konto und gleich im
/// Cloud- und Gast-Modus.
///
/// Der Ordner ist vom iCloud-Backup ausgeschlossen (das Original liegt bei
/// NotebookLM, ein Backup würde nur den iCloud-Speicher füllen) -- nach
/// einem neuen iPhone müssen Podcasts neu importiert werden. Bewusst nicht
/// im Caches-Ordner: den dürfte iOS bei knappem Speicher ungefragt leeren.
@MainActor
final class PodcastStore: ObservableObject {
    @Published private(set) var index: PodcastIndex

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("podcasts.json") }

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Podcasts", isDirectory: true)
    }

    init(directory: URL = PodcastStore.defaultDirectory) {
        self.directory = directory
        Self.prepareDirectory(directory)
        let loaded = PodcastIndex.loadValidated(from: directory.appendingPathComponent("podcasts.json"))
        index = loaded ?? PodcastIndex()
        if loaded != nil { removeOrphans() }
    }

    var podcasts: [Podcast] { index.sorted }
    var totalBytes: Int64 { index.totalBytes }

    func podcast(_ id: UUID) -> Podcast? { index.podcast(id) }

    func fileURL(for podcast: Podcast) -> URL {
        directory.appendingPathComponent(podcast.fileName)
    }

    func add(_ podcast: Podcast) {
        index.add(podcast)
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

    func setPosition(_ id: UUID, position: TimeInterval) {
        index.setPosition(id, position: position)
        save()
    }

    func markFinished(_ id: UUID) {
        index.markFinished(id)
        save()
    }

    private func save() {
        index.save(to: indexURL)
    }

    /// Dateien ohne Eintrag (z.B. ein Import, der mittendrin abgebrochen
    /// wurde) belegen sonst unsichtbar Speicher -- beim Start wegräumen.
    private func removeOrphans() {
        let known = Set(index.podcasts.map(\.fileName) + ["podcasts.json"])
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !known.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private static func prepareDirectory(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }
}
