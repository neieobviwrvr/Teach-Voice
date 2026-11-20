import SwiftUI
import UniformTypeIdentifiers

/// Tab "Podcasts" (Simons Wunsch 2026-11-20): eigene Audiodateien, z.B. die
/// NotebookLM-Podcasts zu den Folien, zwischenspeichern und anhören. Alles
/// nur auf diesem iPhone (`PodcastStore`), kein Supabase.
struct PodcastListView: View {
    @EnvironmentObject private var podcasts: PodcastStore
    @EnvironmentObject private var player: PodcastPlayer
    @EnvironmentObject private var library: LibraryStore
    @AppStorage(PodcastPlayer.autoDeleteKey) private var autoDeleteFinished = false

    @State private var showImporter = false
    @State private var importCount = 0
    @State private var importError: String?
    @State private var showPlayer = false
    @State private var renaming: Podcast?
    @State private var renameText = ""
    @State private var deleting: Podcast?

    var body: some View {
        NavigationStack {
            withDialogs(list)
                .navigationTitle("Podcasts")
                .toolbar { toolbarContent }
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [.audio],
                    allowsMultipleSelection: true
                ) { result in
                    handleImport(result)
                }
                .safeAreaInset(edge: .bottom) { miniPlayer }
                .sheet(isPresented: $showPlayer) {
                    PodcastPlayerView()
                }
        }
    }

    // MARK: - Liste

    @ViewBuilder
    private var list: some View {
        List {
            if importCount > 0 {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(importCount == 1 ? "Podcast wird importiert…" : "\(importCount) Podcasts werden importiert…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(sections, id: \.id) { section in
                Section {
                    ForEach(section.podcasts) { podcast in
                        row(podcast)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                }
            }
            if !podcasts.podcasts.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text(storageFooter)
                }
            }
        }
        .overlay {
            if podcasts.podcasts.isEmpty, importCount == 0 {
                ContentUnavailableView {
                    Label("Noch keine Podcasts", systemImage: "headphones")
                } description: {
                    Text("Tippe auf +, um Audiodateien aus der Dateien-App zu importieren – zum Beispiel deine NotebookLM-Podcasts. Sie bleiben nur auf diesem iPhone.")
                } actions: {
                    Button("Podcast importieren") { showImporter = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private struct PodcastSection {
        let id: String
        let title: String?
        let podcasts: [Podcast]
    }

    /// Nach Lern-Ordner gruppiert (in der Reihenfolge der Ordner), danach
    /// "Ohne Ordner". Ist nichts zugeordnet, eine Liste ohne Überschrift.
    private var sections: [PodcastSection] {
        let all = podcasts.podcasts
        let folderIds = Set(library.folders.map(\.id))
        var result: [PodcastSection] = []
        for folder in library.folders {
            let inFolder = all.filter { $0.folderId == folder.id }
            if !inFolder.isEmpty {
                result.append(PodcastSection(id: folder.id.uuidString, title: folder.name, podcasts: inFolder))
            }
        }
        let unassigned = all.filter { podcast in
            guard let folderId = podcast.folderId else { return true }
            return !folderIds.contains(folderId)
        }
        if !unassigned.isEmpty {
            result.append(PodcastSection(id: "ohne-ordner", title: result.isEmpty ? nil : "Ohne Ordner", podcasts: unassigned))
        }
        return result
    }

    private var storageFooter: String {
        let size = ByteCountFormatter.string(fromByteCount: podcasts.totalBytes, countStyle: .file)
        return "Belegt: \(size). Nur auf diesem iPhone, nicht im iCloud-Backup."
    }

    private func row(_ podcast: Podcast) -> some View {
        let isCurrent = player.currentId == podcast.id
        let size = ByteCountFormatter.string(fromByteCount: podcast.byteSize, countStyle: .file)
        let details = "\(PodcastProgress.durationLabel(podcast.duration)) · \(PodcastProgress.statusLabel(for: podcast)) · \(size)"
        let showsProgress = podcast.finishedAt == nil && podcast.position >= 1 && podcast.duration > 0

        return Button {
            player.play(podcast)
            showPlayer = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isCurrent && player.isPlaying ? "speaker.wave.2.fill" : (podcast.finishedAt != nil ? "checkmark.circle" : "play.circle"))
                    .font(.title2)
                    .foregroundStyle(podcast.finishedAt != nil && !isCurrent ? Color.secondary : Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(podcast.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if showsProgress {
                        ProgressView(value: min(podcast.position / podcast.duration, 1))
                            .tint(.accentColor)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = podcast
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                renameText = podcast.title
                renaming = podcast
            } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            folderMenu(for: podcast)
            Button(role: .destructive) {
                deleting = podcast
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func folderMenu(for podcast: Podcast) -> some View {
        Menu {
            Button {
                podcasts.setFolder(podcast.id, folderId: nil)
            } label: {
                if podcast.folderId == nil {
                    Label("Ohne Ordner", systemImage: "checkmark")
                } else {
                    Text("Ohne Ordner")
                }
            }
            ForEach(library.folders) { folder in
                Button {
                    podcasts.setFolder(podcast.id, folderId: folder.id)
                } label: {
                    if podcast.folderId == folder.id {
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

    // MARK: - Mini-Player

    @ViewBuilder
    private var miniPlayer: some View {
        if let current = player.currentPodcast {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text("\(PodcastProgress.clockLabel(player.currentTime)) / \(PodcastProgress.clockLabel(player.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .onTapGesture { showPlayer = true }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Toolbar & Dialoge

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Toggle("Gehörte automatisch löschen", isOn: $autoDeleteFinished)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Einstellungen")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showImporter = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Podcast importieren")
        }
    }

    /// Ausgelagert, damit der Type-Checker die Modifier-Kette in `body`
    /// nicht in einem Stück prüfen muss (siehe FolderListView).
    @ViewBuilder
    private func withDialogs<Content: View>(_ content: Content) -> some View {
        content
            .alert("Podcast umbenennen", isPresented: isRenaming) {
                TextField("Titel", text: $renameText)
                Button("Abbrechen", role: .cancel) { renaming = nil }
                Button("Speichern") {
                    if let renaming { podcasts.rename(renaming.id, to: renameText) }
                    renaming = nil
                }
            }
            .alert("Import fehlgeschlagen", isPresented: hasImportError) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .confirmationDialog(
                "Podcast löschen?",
                isPresented: isDeleting,
                titleVisibility: .visible,
                presenting: deleting
            ) { podcast in
                Button("Löschen", role: .destructive) {
                    player.stopIfPlaying(podcast.id)
                    podcasts.delete(podcast.id)
                    deleting = nil
                }
                Button("Abbrechen", role: .cancel) { deleting = nil }
            } message: { podcast in
                Text("„\(podcast.title)“ wird von diesem iPhone gelöscht. Das Original in NotebookLM bzw. in der Dateien-App bleibt erhalten.")
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
            let directory = podcasts.directory
            Task {
                var failures: [String] = []
                for url in urls {
                    do {
                        let podcast = try await PodcastImporter.importFile(from: url, into: directory)
                        podcasts.add(podcast)
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
