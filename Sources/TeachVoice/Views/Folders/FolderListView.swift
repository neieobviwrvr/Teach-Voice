import SwiftUI

struct FolderListView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore

    @State private var showAddFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(library.folders) { folder in
                    NavigationLink(value: folder) {
                        Label(folder.name, systemImage: "folder.fill")
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let folder = library.folders[index]
                        Task { await library.deleteFolder(folder) }
                    }
                }
            }
            .navigationDestination(for: Folder.self) { folder in
                SubfolderListView(folder: folder)
            }
            .navigationTitle("Meine Ordner")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFolder = true
                    } label: {
                        Label("Ordner hinzufügen", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Abmelden", role: .destructive) {
                        auth.signOut()
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
            .alert("Fehler", isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? "")
            }
        }
    }
}
