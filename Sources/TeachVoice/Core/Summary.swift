import Foundation

/// Eine fertige Zusammenfassung als Datei (PDF, Word, PowerPoint, Text,
/// Bild …), nur auf diesem iPhone (Simons Wunsch 2026-11-20). Angezeigt mit
/// QuickLook, also ohne eigenen Viewer.
struct Summary: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    /// Nur der Dateiname im Zusammenfassungs-Ordner, nie ein voller Pfad.
    let fileName: String
    /// Name, unter dem die Datei importiert wurde (z.B. beim Teilen).
    let originalFileName: String
    let byteSize: Int64
    let importedAt: Date
    var folderId: UUID?

    var kind: SummaryKind { SummaryKind(fileExtension: (fileName as NSString).pathExtension) }
}

/// Grobe Dateiart -- nur für Symbol und Beschriftung in der Liste.
enum SummaryKind: Equatable {
    case pdf, document, presentation, spreadsheet, text, image, other

    init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "pdf": self = .pdf
        case "doc", "docx", "pages", "rtf", "odt": self = .document
        case "ppt", "pptx", "key", "odp": self = .presentation
        case "xls", "xlsx", "numbers", "csv", "ods": self = .spreadsheet
        case "txt", "md", "markdown": self = .text
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff": self = .image
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .document: return "Dokument"
        case .presentation: return "Präsentation"
        case .spreadsheet: return "Tabelle"
        case .text: return "Text"
        case .image: return "Bild"
        case .other: return "Datei"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .presentation: return "rectangle.on.rectangle"
        case .spreadsheet: return "tablecells"
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .other: return "doc"
        }
    }
}

/// Die Liste aller Zusammenfassungen als reiner Wert (`SummaryLibraryTests`),
/// gespeichert als `summaries.json`.
struct SummaryIndex: Codable, Equatable {
    private(set) var summaries: [Summary] = []

    /// Neueste zuerst.
    var sorted: [Summary] {
        summaries.sorted { $0.importedAt > $1.importedAt }
    }

    var totalBytes: Int64 {
        summaries.reduce(0) { $0 + $1.byteSize }
    }

    func summary(_ id: UUID) -> Summary? {
        summaries.first { $0.id == id }
    }

    /// Suche im Titel und im ursprünglichen Dateinamen, ohne Groß/Klein.
    func matching(_ query: String) -> [Summary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.originalFileName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    mutating func add(_ summary: Summary) {
        summaries.removeAll { $0.id == summary.id }
        summaries.append(summary)
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Summary? {
        guard let index = summaries.firstIndex(where: { $0.id == id }) else { return nil }
        return summaries.remove(at: index)
    }

    mutating func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = summaries.firstIndex(where: { $0.id == id }) else { return }
        summaries[index].title = trimmed
    }

    mutating func setFolder(_ id: UUID, folderId: UUID?) {
        guard let index = summaries.firstIndex(where: { $0.id == id }) else { return }
        summaries[index].folderId = folderId
    }

    /// Leere Liste ohne Datei, `nil` bei unlesbarer Datei (dann keine
    /// "verwaisten" Dateien wegräumen, siehe `FileImport.removeOrphans`).
    static func loadValidated(from url: URL) -> SummaryIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return SummaryIndex() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SummaryIndex.self, from: data)
    }

    static func load(from url: URL) -> SummaryIndex {
        loadValidated(from: url) ?? SummaryIndex()
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
