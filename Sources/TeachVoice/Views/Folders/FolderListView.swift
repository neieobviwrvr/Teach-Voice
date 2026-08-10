import SwiftUI

/// Ob die aktuell angezeigten Ordner aus Supabase (Cloud, E-Mail-Login) oder
/// rein lokal (Gastzugang) kommen – rein informativ für Banner/Abmelden-Label,
/// die eigentliche Datenquelle steuert `LibraryStore.useRepository`.
enum LibraryMode {
    case cloud
    case guest
}

struct FolderListView: View {
    let mode: LibraryMode

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore

    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @State private var showMicPermissionNotice = false
    @State private var handsFreeCards: [Flashcard]?
    @State private var handsFreeTitle = "Hands-free"
    @State private var isLoadingHandsFree = false
    @State private var showHandsFreeSubfolderPicker = false
    @State private var handsFreeSubfolderOptions: [Subfolder] = []

    private var isFull: Bool { library.folders.count >= maxFoldersPerUser }

    var body: some View {
        NavigationStack {
            List {
                if mode == .guest {
                    Section {
                        Label("Gastmodus – Karten sind nur auf diesem Gerät gespeichert.", systemImage: "iphone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await loadHandsFreeSubfolderOptions() }
                    } label: {
                        Label(
                            isLoadingHandsFree ? "Lädt…" : "Hands-free lernen",
                            systemImage: "waveform"
                        )
                    }
                    .disabled(isLoadingHandsFree)
                } footer: {
                    Text("Fragt automatisch die Karten eines gewählten Unterordners ab – rein per Sprache, kein Antippen nötig.")
                }

                ForEach(library.folders) { folder in
                    NavigationLink(value: folder) {
                        Label(folder.name, systemImage: "folder.fill")
                    }
                    .contextMenu {
                        Button {
                            renamingFolder = folder
                            renameText = folder.name
                        } label: {
                            Label("Umbenennen", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            Task { await library.deleteFolder(folder) }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await library.deleteFolder(folder) }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                        Button {
                            renamingFolder = folder
                            renameText = folder.name
                        } label: {
                            Label("Umbenennen", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                }
            }
            .navigationDestination(for: Folder.self) { folder in
                SubfolderListView(folder: folder)
            }
            .navigationDestination(item: $handsFreeCards) { cards in
                HandsFreeStudyView(cards: cards, title: handsFreeTitle)
            }
            .navigationTitle("Meine Ordner")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFolder = true
                    } label: {
                        Label("Ordner hinzufügen", systemImage: "plus")
                    }
                    .disabled(isFull)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(mode == .guest ? "Gastmodus verlassen" : "Abmelden", role: .destructive) {
                        auth.leaveCurrentSession()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showAddFolder = true
                } label: {
                    Label("Ordner hinzufügen", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFull)
                .padding()
            }
            .overlay {
                if library.folders.isEmpty && !library.isLoading {
                    ContentUnavailableView(
                        "Noch keine Ordner",
                        systemImage: "folder",
                        description: Text("Tippe auf \"Ordner hinzufügen\", um loszulegen.")
                    )
                }
            }
            .task { await library.loadFolders() }
            // Proaktiver Hinweis: die App funktioniert im Kern erst richtig,
            // wenn der Mikrofonzugriff erlaubt ist (STT-Lernmodus).
            .task { showMicPermissionNotice = !MicrophonePermission.isGranted }
            .refreshable { await library.loadFolders() }
            .alert("Neuer Ordner", isPresented: $showAddFolder) {
                TextField("Name", text: $newFolderName)
                Button("Abbrechen", role: .cancel) { newFolderName = "" }
                Button("Erstellen") {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { await library.addFolder(name: name) }
                    newFolderName = ""
                }
            }
            .alert("Ordner umbenennen", isPresented: Binding(
                get: { renamingFolder != nil },
                set: { if !$0 { renamingFolder = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Abbrechen", role: .cancel) { renamingFolder = nil }
                Button("Speichern") {
                    if let folder = renamingFolder {
                        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty {
                            Task { await library.renameFolder(folder, to: name) }
                        }
                    }
                    renamingFolder = nil
                }
            }
            .alert("Fehler", isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? "")
            }
            .alert("Mikrofonzugriff benötigt", isPresented: $showMicPermissionNotice) {
                Button("Zugriff erlauben") { MicrophonePermission.requestOrOpenSettings() }
                Button("Später", role: .cancel) {}
            } message: {
                Text("Teach (Voice) funktioniert im Kern erst richtig, wenn du den Mikrofonzugriff erlaubst – ohne ihn kann deine gesprochene Antwort im Lernmodus nicht erkannt werden.")
            }
            .confirmationDialog(
                "Unterordner für Hands-free wählen",
                isPresented: $showHandsFreeSubfolderPicker,
                titleVisibility: .visible
            ) {
                ForEach(handsFreeSubfolderOptions) { subfolder in
                    Button(subfolder.name) {
                        Task { await startHandsFree(for: subfolder) }
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            }
        }
    }

    /// Lädt alle Unterordner über alle Ordner hinweg (praktisch: den einen
    /// Ordner) und zeigt sie als Auswahl-Pop-up an, statt direkt loszulegen –
    /// Hands-free läuft immer nur über die Karten EINES gewählten Unterordners.
    private func loadHandsFreeSubfolderOptions() async {
        isLoadingHandsFree = true
        if library.folders.isEmpty { await library.loadFolders() }
        var options: [Subfolder] = []
        for folder in library.folders {
            if library.subfolders(in: folder).isEmpty { await library.loadSubfolders(for: folder) }
            options.append(contentsOf: library.subfolders(in: folder))
        }
        isLoadingHandsFree = false

        guard !options.isEmpty else {
            library.errorMessage = "Keine Unterordner vorhanden – lege zuerst einen an."
            return
        }
        handsFreeSubfolderOptions = options
        showHandsFreeSubfolderPicker = true
    }

    private func startHandsFree(for subfolder: Subfolder) async {
        if library.flashcards(in: subfolder).isEmpty {
            await library.loadFlashcards(for: subfolder)
        }
        let cards = library.flashcards(in: subfolder)
        guard !cards.isEmpty else {
            library.errorMessage = "\"\(subfolder.name)\" hat noch keine Karteikarten."
            return
        }
        handsFreeTitle = subfolder.name
        handsFreeCards = cards
    }
}
