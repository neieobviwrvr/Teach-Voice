import SwiftUI

struct SubfolderListView: View {
    let folder: Folder

    @EnvironmentObject private var library: LibraryStore

    @State private var showAddSubfolder = false
    @State private var newSubfolderName = ""
    @State private var renamingSubfolder: Subfolder?
    @State private var renameText = ""
    @State private var showPDFImport = false

    var body: some View {
        List {
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
                        Text("\(library.flashcards(in: subfolder).count)/\(maxFlashcardsPerSubfolder) Karten")
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
        .navigationTitle(folder.name)
        .task { await library.loadSubfolders(for: folder) }
        .refreshable { await library.loadSubfolders(for: folder) }
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
}
