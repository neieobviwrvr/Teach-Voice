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
        }
    }
}
