import Foundation
import UniformTypeIdentifiers

/// Wohin eine von außen geteilte Datei gehört.
enum IncomingFile {
    enum Destination: Equatable {
        case podcast
        case summary
    }

    /// Audio -> Podcasts, alles andere -> Zusammenfassungen. "opus"
    /// (WhatsApp-Sprachnachrichten) kennt iOS nicht als Audio-Typ, gehört
    /// aber trotzdem zu den Podcasts -- dort meldet der Import sauber, falls
    /// die Datei nicht abspielbar ist.
    static func destination(forFileName fileName: String) -> Destination {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if ["opus", "ogg", "oga"].contains(ext) { return .podcast }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) { return .podcast }
        return .summary
    }

    /// Liegt die Datei in Documents/Inbox? Dorthin kopiert iOS Dateien, die
    /// eine andere App mit Teach "öffnet" (`LSSupportsOpeningDocumentsInPlace`
    /// = false). Nur diese Kopien darf Teach nach dem Import löschen.
    static func isInInbox(_ url: URL, documentsDirectory: URL) -> Bool {
        let inbox = documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        return file.hasPrefix(inbox + "/")
    }
}

/// Tab-Auswahl und Annahme von Dateien aus dem Teilen-Menü anderer Apps
/// (Simon, 2026-11-21: "direkt aus WhatsApp in Teach importieren").
@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable {
        case lernen, podcasts, zusammenfassungen
    }

    struct ImportResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var selectedTab: Tab = .lernen
    /// Name der Datei, die gerade übernommen wird (für den Hinweis oben).
    @Published private(set) var importingFileName: String?
    /// Ergebnis des letzten Imports -- als Meldung angezeigt.
    @Published var importResult: ImportResult?

    private let podcasts: PodcastStore
    private let summaries: SummaryStore

    init(podcasts: PodcastStore, summaries: SummaryStore) {
        self.podcasts = podcasts
        self.summaries = summaries
    }

    /// Von `onOpenURL` mit einer Datei-URL aufgerufen.
    func handleIncomingFile(_ url: URL) {
        Task { await importIncoming(url) }
    }

    private func importIncoming(_ url: URL) async {
        let fileName = url.lastPathComponent
        let destination = IncomingFile.destination(forFileName: fileName)
        selectedTab = destination == .podcast ? .podcasts : .zusammenfassungen
        importingFileName = fileName
        defer {
            importingFileName = nil
            // Die Inbox-Kopie nie liegen lassen -- das Original bleibt in der
            // teilenden App (z.B. im WhatsApp-Chat), sonst läge die Datei doppelt auf dem iPhone.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            if IncomingFile.isInInbox(url, documentsDirectory: documents) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            switch destination {
            case .podcast:
                let podcast = try await PodcastImporter.importFile(from: url, into: podcasts.directory)
                podcasts.add(podcast)
                importResult = ImportResult(title: "Zu Podcasts hinzugefügt", message: "„\(podcast.title)“")
            case .summary:
                try await summaries.importFile(from: url)
                let title = FileImport.defaultTitle(forFileName: fileName, fallback: "Zusammenfassung")
                importResult = ImportResult(title: "Zu Zusammenfassungen hinzugefügt", message: "„\(title)“")
            }
        } catch {
            importResult = ImportResult(title: "Import fehlgeschlagen", message: "\(fileName): \(error.localizedDescription)")
        }
    }
}
