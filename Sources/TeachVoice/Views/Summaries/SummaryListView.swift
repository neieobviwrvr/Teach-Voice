import SwiftUI
import QuickLook
import UniformTypeIdentifiers

/// Tab "Zusammenfassungen" (Simons Wunsch 2026-11-20): fertige
/// Zusammenfassungen als Dateien (PDF, Word, PowerPoint, Text, Bilder) aus
/// der Dateien-App übernehmen und in der App ansehen. Nur auf diesem iPhone
/// (`SummaryStore`), kein Supabase. Anzeige über QuickLook -- dort gibt es
/// auch Teilen, Suchen im PDF und Markieren.
struct SummaryListView: View {
    @EnvironmentObject private var summaries: SummaryStore
    @EnvironmentObject private var library: LibraryStore

    @State private var searchText = ""
    @State private var showImporter = false
    @State private var importCount = 0
    @State private var importError: String?
    @State private var previewURL: URL?
    @State private var renaming: Summary?
    @State private var renameText = ""
    @State private var deleting: Summary?

    /// Was QuickLook zeigen kann und wofür man Zusammenfassungen braucht.
    private static let importTypes: [UTType] = [
        .pdf, .text, .plainText, .rtf, .image, .presentation, .spreadsheet,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.openxmlformats.presentationml.presentation"),
        UTType("com.microsoft.powerpoint.ppt"),
        UTType("com.apple.iwork.pages.sffpages"),
        UTType("com.apple.iwork.keynote.sffkey"),
        UTType("net.daringfireball.markdown"),
    ].compactMap { $0 }

    var body: some View {
        NavigationStack {
            withDialogs(list)
                .navigationTitle("Zusammenfassungen")
                .searchable(text: $searchText, prompt: "Titel suchen")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showImporter = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Zusammenfassung importieren")
                    }
                }
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: Self.importTypes,
                    allowsMultipleSelection: true
                ) { result in
                    handleImport(result)
                }
                .quickLookPreview($previewURL)
        }
    }

    // MARK: - Liste

    private var visible: [Summary] {
        summaries.index.matching(searchText)
    }

    @ViewBuilder
    private var list: some View {
        List {
            if importCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(importCount == 1 ? "Datei wird importiert…" : "\(importCount) Dateien werden importiert…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(FolderGrouping.sections(visible, folders: library.folders) { $0.folderId }) { section in
                Section {
                    ForEach(section.items) { summary in
                        row(summary)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
            if !summaries.summaries.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text(storageFooter)
                }
            }
        }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if summaries.summaries.isEmpty, importCount == 0 {
            ContentUnavailableView {
                Label("Noch keine Zusammenfassungen", systemImage: "doc.text")
            } description: {
                Text("Tippe auf +, um fertige Zusammenfassungen aus der Dateien-App zu übernehmen – PDF, Word, PowerPoint, Text oder Bilder. Sie liegen nur auf diesem iPhone.")
            } actions: {
                Button("Datei importieren") { showImporter = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if !searchText.isEmpty, visible.isEmpty {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var storageFooter: String {
        let size = ByteCountFormatter.string(fromByteCount: summaries.totalBytes, countStyle: .file)
        return "Belegt: \(size). Nur auf diesem iPhone."
    }

    private func row(_ summary: Summary) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: summary.byteSize, countStyle: .file)
        let date = summary.importedAt.formatted(date: .numeric, time: .omitted)
        let details = "\(summary.kind.label) · \(size) · \(date)"

        return Button {
            previewURL = summaries.fileURL(for: summary)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: summary.kind.symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = summary
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                renameText = summary.title
                renaming = summary
            } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            folderMenu(for: summary)
            Button(role: .destructive) {
                deleting = summary
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func folderMenu(for summary: Summary) -> some View {
        Menu {
            Button {
                summaries.setFolder(summary.id, folderId: nil)
            } label: {
                if summary.folderId == nil {
                    Label("Ohne Ordner", systemImage: "checkmark")
                } else {
                    Text("Ohne Ordner")
                }
            }
            ForEach(library.folders) { folder in
                Button {
                    summaries.setFolder(summary.id, folderId: folder.id)
                } label: {
                    if summary.folderId == folder.id {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
        } label: {
            Label("Ordner zuordnen", systemImage: "folder")
        }
    }

    // MARK: - Dialoge

    /// Ausgelagert, damit der Type-Checker die Modifier-Kette in `body`
    /// nicht in einem Stück prüfen muss (siehe FolderListView).
    @ViewBuilder
    private func withDialogs<Content: View>(_ content: Content) -> some View {
        content
            .alert("Umbenennen", isPresented: isRenaming) {
                TextField("Titel", text: $renameText)
                Button("Abbrechen", role: .cancel) { renaming = nil }
                Button("Speichern") {
                    if let renaming { summaries.rename(renaming.id, to: renameText) }
                    renaming = nil
                }
            }
            .alert("Import fehlgeschlagen", isPresented: hasImportError) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .confirmationDialog(
                "Zusammenfassung löschen?",
                isPresented: isDeleting,
                titleVisibility: .visible,
                presenting: deleting
            ) { summary in
                Button("Löschen", role: .destructive) {
                    summaries.delete(summary.id)
                    deleting = nil
                }
                Button("Abbrechen", role: .cancel) { deleting = nil }
            } message: { summary in
                Text("„\(summary.title)“ wird von diesem iPhone gelöscht. Das Original in der Dateien-App bleibt erhalten.")
            }
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var hasImportError: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    // MARK: - Import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            importCount = urls.count
            Task {
                var failures: [String] = []
                for url in urls {
                    do {
                        try await summaries.importFile(from: url)
                    } catch {
                        failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                    importCount = max(0, importCount - 1)
                }
                importCount = 0
                if !failures.isEmpty { importError = failures.joined(separator: "\n") }
            }
        }
    }
}
