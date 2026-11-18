import SwiftUI

struct SubfolderListView: View {
    let folder: Folder

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var showAddSubfolder = false
    @State private var newSubfolderName = ""
    @State private var renamingSubfolder: Subfolder?
    @State private var renameText = ""
    @State private var showPDFImport = false
    @State private var studyScope: StudyScope?
    @State private var studyRequest: StudySessionRequest?
    @State private var isPreparingStudy = false

    var body: some View {
        List {
            if library.subfolders(in: folder).count > 1 {
                Section {
                    Button {
                        Task { await startWholeFolder() }
                    } label: {
                        HStack {
                            Label("Ganzen Ordner lernen", systemImage: "graduationcap")
                            if isPreparingStudy {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isPreparingStudy)
                } footer: {
                    Text("Fragt die Karten aller Unterordner zusammen ab.")
                }
            }

            // Bewusst zentriert statt oben rechts im Toolbar (Simons
            // Entscheidung) – der Haupt-Einstiegspunkt für neue Unterordner,
            // sowohl manuell als auch per PDF-Import, der jetzt hier statt in
            // FlashcardListView lebt (er erstellt einen KOMPLETTEN neuen
            // Unterordner samt Karten, statt Karten in einen bestehenden
            // einzufügen).
            Section {
                HStack {
                    Spacer()
                    Menu {
                        Button {
                            showAddSubfolder = true
                        } label: {
                            Label("Manuell erstellen", systemImage: "folder.badge.plus")
                        }
                        Button {
                            showPDFImport = true
                        } label: {
                            Label("Aus PDF erstellen", systemImage: "doc.text.magnifyingglass")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 44))
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            // Als Zeile INNERHALB der Liste statt als `.overlay` – ein
            // Overlay würde den zentrierten Plus-Button oben sonst
            // mitverdecken, statt nur "kein Inhalt" zu signalisieren.
            if library.subfolders(in: folder).isEmpty {
                Section {
                    ContentUnavailableView(
                        "Noch keine Unterordner",
                        systemImage: "folder.badge.plus",
                        description: Text("Tippe oben auf das Plus, um manuell oder per PDF-Import einen Unterordner anzulegen.")
                    )
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(library.subfolders(in: folder)) { subfolder in
                NavigationLink(value: subfolder) {
                    VStack(alignment: .leading) {
                        Label(subfolder.name, systemImage: "folder")
                        Text("\(library.flashcards(in: subfolder).count) Karten")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button {
                        renamingSubfolder = subfolder
                        renameText = subfolder.name
                    } label: {
                        Label("Umbenennen", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        Task { await library.deleteSubfolder(subfolder) }
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await library.deleteSubfolder(subfolder) }
                    } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                    Button {
                        renamingSubfolder = subfolder
                        renameText = subfolder.name
                    } label: {
                        Label("Umbenennen", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        }
        .navigationDestination(for: Subfolder.self) { subfolder in
            FlashcardListView(subfolder: subfolder)
        }
        .navigationDestination(item: $studyRequest) { request in
            StudySessionView(request: request)
        }
        .studyModeDialog(scope: $studyScope) { request in
            studyRequest = request
        }
        .navigationTitle(folder.name)
        // Lädt auch die Karten aller Unterordner, damit die Kartenzahlen
        // stimmen und "Ganzen Ordner lernen" alles kennt.
        .task { await library.loadAllFlashcards(for: folder, force: true) }
        .refreshable { await library.loadAllFlashcards(for: folder, force: true) }
        // Was Claude über den KI-Konnektor angelegt hat, sofort zeigen, wenn
        // man in die App zurückwechselt. Nicht während einer Lern-Session.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, studyRequest == nil else { return }
            Task { await library.loadAllFlashcards(for: folder, force: true) }
        }
        .alert("Neuer Unterordner", isPresented: $showAddSubfolder) {
            TextField("Name", text: $newSubfolderName)
            Button("Abbrechen", role: .cancel) { newSubfolderName = "" }
            Button("Erstellen") {
                let name = newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                Task { await library.addSubfolder(name: name, to: folder) }
                newSubfolderName = ""
            }
        }
        .alert("Unterordner umbenennen", isPresented: Binding(
            get: { renamingSubfolder != nil },
            set: { if !$0 { renamingSubfolder = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Abbrechen", role: .cancel) { renamingSubfolder = nil }
            Button("Speichern") {
                if let subfolder = renamingSubfolder {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        Task { await library.renameSubfolder(subfolder, to: name) }
                    }
                }
                renamingSubfolder = nil
            }
        }
        .sheet(isPresented: $showPDFImport) {
            PDFImportView(folder: folder)
        }
    }

    private func startWholeFolder() async {
        isPreparingStudy = true
        await library.loadAllFlashcards(for: folder, force: true)
        isPreparingStudy = false
        let cards = library.allFlashcards(in: folder)
        guard !cards.isEmpty else {
            library.errorMessage = "In \"\(folder.name)\" gibt es noch keine Karteikarten."
            return
        }
        studyScope = StudyScope(title: folder.name, cards: cards)
    }
}
