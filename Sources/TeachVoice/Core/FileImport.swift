import Foundation

/// Gemeinsame Bausteine für Dateien, die nur auf dem iPhone liegen
/// (Podcasts, Zusammenfassungen).
enum FileImport {
    /// Titel aus dem Dateinamen, ohne Endung; Unterstriche werden Leerzeichen.
    static func defaultTitle(forFileName fileName: String, fallback: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? fallback : base
    }

    /// Endung in Kleinbuchstaben, sonst `fallback`.
    static func fileExtension(forFileName fileName: String, fallback: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? fallback : ext
    }

    static func fileSize(_ url: URL) -> Int64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    /// Kopiert eine vom Nutzer gewählte Datei (Dateien-App, iCloud Drive,
    /// andere Apps) nach `target`. Über NSFileCoordinator, damit eine nur in
    /// iCloud liegende Datei dabei zuerst heruntergeladen wird; mit
    /// security-scoped Zugriff, solange kopiert wird.
    static func copyPickedFile(from source: URL, to target: URL) throws {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinatorError) { readURL in
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: readURL, to: target)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
    }

    /// Verzeichnis anlegen; `excludeFromBackup` für Dateien, deren Original
    /// ohnehin woanders liegt (Podcasts).
    static func prepareDirectory(_ directory: URL, excludeFromBackup: Bool) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard excludeFromBackup else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    /// Dateien ohne Eintrag in der Liste (z.B. abgebrochener Import) belegen
    /// sonst unsichtbar Speicher. Nur aufrufen, wenn die Liste sicher gelesen
    /// wurde -- sonst wären alle Dateien "verwaist".
    static func removeOrphans(in directory: URL, keeping knownFileNames: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where !knownFileNames.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}

/// Ein Abschnitt "Ordnername + Einträge" für Listen, deren Einträge optional
/// einem Lern-Ordner zugeordnet sind.
struct FolderSection<Item: Identifiable>: Identifiable {
    let id: String
    let title: String?
    let items: [Item]
}

enum FolderGrouping {
    /// In der Reihenfolge der Ordner, danach "Ohne Ordner" (auch für Ordner,
    /// die es im aktiven Konto nicht gibt). Ist nichts zugeordnet: ein
    /// Abschnitt ohne Überschrift.
    static func sections<Item: Identifiable>(
        _ items: [Item], folders: [Folder], folderId: (Item) -> UUID?
    ) -> [FolderSection<Item>] {
        let knownIds = Set(folders.map(\.id))
        var result: [FolderSection<Item>] = []
        for folder in folders {
            let inFolder = items.filter { folderId($0) == folder.id }
            if !inFolder.isEmpty {
                result.append(FolderSection(id: folder.id.uuidString, title: folder.name, items: inFolder))
            }
        }
        let unassigned = items.filter { item in
            guard let id = folderId(item) else { return true }
            return !knownIds.contains(id)
        }
        if !unassigned.isEmpty {
            result.append(FolderSection(id: "ohne-ordner", title: result.isEmpty ? nil : "Ohne Ordner", items: unassigned))
        }
        return result
    }
}
