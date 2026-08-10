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
    @State private var isLoadingHandsFree = false

    // "Hands-free (Voice only)": Unterordner-Auswahl passiert per Sprachmenü
    // INNERHALB der View – hier wird nur die Unterordner-Liste vorgeladen und
    // die Bewertungs-Strenge abgefragt.
    @State private var voiceOnlySubfolders: [Subfolder]?
    @State private var voiceOnlyStrictness: GradingStrictness = .normal
    @State private var pendingVoiceOnlySubfolders: [Subfolder] = []
    @State private var showVoiceOnlyStrictnessPicker = false

    // "Hands-free lernen (Eigenbewertung)": sichtbares Pop-up zur Auswahl,
    // da man dort ohnehin pro Frage antippen muss.
    @State private var eigenbewertungCards: [Flashcard]?
    @State private var eigenbewertungTitle = "Hands-free"
    @State private var eigenbewertungStrictness: GradingStrictness = .normal
    @State private var showEigenbewertungSubfolderPicker = false
    @State private var eigenbewertungSubfolderOptions: [Subfolder] = []
    @State private var pendingEigenbewertungCards: [Flashcard] = []
    @State private var pendingEigenbewertungTitle = ""
    @State private var showEigenbewertungStrictnessPicker = false

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
                        Task { await startVoiceOnlyFlow() }
                    } label: {
                        Label(
                            isLoadingHandsFree ? "Lädt…" : "Hands-free (Voice only)",
                            systemImage: "waveform"
                        )
                    }
                    .disabled(isLoadingHandsFree)

                    Button {
                        Task { await startEigenbewertungFlow() }
                    } label: {
                        Label(
                            isLoadingHandsFree ? "Lädt…" : "Hands-free lernen (Eigenbewertung)",
                            systemImage: "hand.tap"
                        )
                    }
                    .disabled(isLoadingHandsFree)
                } footer: {
                    Text("\"Voice only\": komplett per Sprache, die App fragt dich selbst welchen Unterordner du lernen willst, GPT bewertet allein. \"Eigenbewertung\": Unterordner per Pop-up wählen, nach jeder Frage entscheidest du selbst per Button.")
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
            .navigationDestination(item: $voiceOnlySubfolders) { subfolders in
                HandsFreeStudyView(subfolders: subfolders, strictness: voiceOnlyStrictness)
            }
            .navigationDestination(item: $eigenbewertungCards) { cards in
                HandsFreeSelfAssessmentStudyView(cards: cards, title: eigenbewertungTitle, strictness: eigenbewertungStrictness)
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
                "Wie streng bewerten?",
                isPresented: $showVoiceOnlyStrictnessPicker,
                titleVisibility: .visible
            ) {
                ForEach(GradingStrictness.allCases) { strictness in
                    Button(strictness.label) {
                        voiceOnlyStrictness = strictness
                        voiceOnlySubfolders = pendingVoiceOnlySubfolders
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text(GradingStrictness.normal.description + "\n" + GradingStrictness.tryhard.description)
            }
            .confirmationDialog(
                "Unterordner für Hands-free wählen",
                isPresented: $showEigenbewertungSubfolderPicker,
                titleVisibility: .visible
            ) {
                if eigenbewertungSubfolderOptions.count > 1 {
                    let totalCards = eigenbewertungSubfolderOptions.reduce(0) { $0 + library.flashcards(in: $1).count }
                    Button("Alle Unterordner lernen (\(eigenbewertungSubfolderOptions.count) Unterordner, \(totalCards) Karten)") {
                        Task { await prepareEigenbewertung(subfolders: eigenbewertungSubfolderOptions, title: "Alle Unterordner") }
                    }
                }
                ForEach(eigenbewertungSubfolderOptions) { subfolder in
                    Button("\(subfolder.name) (\(library.flashcards(in: subfolder).count) Karten)") {
                        Task { await prepareEigenbewertung(subfolders: [subfolder], title: subfolder.name) }
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            }
            .confirmationDialog(
                "Wie streng bewerten?",
                isPresented: $showEigenbewertungStrictnessPicker,
                titleVisibility: .visible
            ) {
                ForEach(GradingStrictness.allCases) { strictness in
                    Button(strictness.label) {
                        eigenbewertungTitle = pendingEigenbewertungTitle
                        eigenbewertungStrictness = strictness
                        eigenbewertungCards = pendingEigenbewertungCards
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text(GradingStrictness.normal.description + "\n" + GradingStrictness.tryhard.description)
            }
        }
    }

    // MARK: - Hands-free (Voice only)

    private func startVoiceOnlyFlow() async {
        isLoadingHandsFree = true
        let options = await loadAllSubfolders()
        isLoadingHandsFree = false
        guard !options.isEmpty else {
            library.errorMessage = "Keine Unterordner vorhanden – lege zuerst einen an."
            return
        }
        pendingVoiceOnlySubfolders = options
        showVoiceOnlyStrictnessPicker = true
    }

    // MARK: - Hands-free lernen (Eigenbewertung)

    private func startEigenbewertungFlow() async {
        isLoadingHandsFree = true
        let options = await loadAllSubfolders()
        for subfolder in options where library.flashcards(in: subfolder).isEmpty {
            await library.loadFlashcards(for: subfolder)
        }
        isLoadingHandsFree = false
        guard !options.isEmpty else {
            library.errorMessage = "Keine Unterordner vorhanden – lege zuerst einen an."
            return
        }
        eigenbewertungSubfolderOptions = options
        showEigenbewertungSubfolderPicker = true
    }

    private func prepareEigenbewertung(subfolders: [Subfolder], title: String) async {
        let cards = subfolders.flatMap { library.flashcards(in: $0) }
        guard !cards.isEmpty else {
            library.errorMessage = "Keine Karteikarten vorhanden."
            return
        }
        pendingEigenbewertungTitle = title
        pendingEigenbewertungCards = cards
        showEigenbewertungStrictnessPicker = true
    }

    // MARK: - Gemeinsam

    private func loadAllSubfolders() async -> [Subfolder] {
        if library.folders.isEmpty { await library.loadFolders() }
        var options: [Subfolder] = []
        for folder in library.folders {
            if library.subfolders(in: folder).isEmpty { await library.loadSubfolders(for: folder) }
            options.append(contentsOf: library.subfolders(in: folder))
        }
        return options
    }
}
