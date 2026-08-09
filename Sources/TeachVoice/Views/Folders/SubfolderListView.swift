import SwiftUI

struct SubfolderListView: View {
    let folder: Folder

    @EnvironmentObject private var library: LibraryStore

    @State private var showAddSubfolder = false
    @State private var newSubfolderName = ""
    @State private var renamingSubfolder: Subfolder?
    @State private var renameText = ""

    private var isFull: Bool { library.subfolders(in: folder).count >= maxSubfoldersPerFolder }

    var body: some View {
        List {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSubfolder = true
                } label: {
                    Label("Unterordner hinzufügen", systemImage: "plus")
                }
                .disabled(isFull)
            }
        }
        .overlay {
            if library.subfolders(in: folder).isEmpty {
                ContentUnavailableView(
                    "Noch keine Unterordner",
                    systemImage: "folder.badge.plus",
                    description: Text("Erstelle kostenfrei einen Unterordner für dein nächstes Thema.")
                )
            }
        }
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
    }
}
