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

    /// Aktueller Stand des Ordners aus dem Store (z.B. mit gerade geändertem
    /// Prüfungstermin) -- `folder` ist nur der Stand beim Öffnen.
    private var currentFolder: Folder {
        library.folders.first { $0.id == folder.id } ?? folder
    }

    var body: some View {
        List {
            examSection

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

    // MARK: - Prüfungstermin

    /// Optionaler Prüfungstermin für diesen Ordner. FSRS zieht Wiederholungen,
    /// die erst danach fällig wären, vor (siehe `FSRSScheduler`).
    private var examSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { currentFolder.examAt != nil },
                set: { enabled in
                    let date = enabled ? Self.normalizedExamDate(Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()) : nil
                    Task { await library.setExamDate(date, for: currentFolder) }
                }
            )) {
                Label("Prüfungstermin", systemImage: "calendar")
            }

            if let examAt = currentFolder.examAt {
                DatePicker(
                    "Datum",
                    selection: Binding(
                        get: { examAt },
                        set: { newDate in
                            Task { await library.setExamDate(Self.normalizedExamDate(newDate), for: currentFolder) }
                        }
                    ),
                    in: Calendar.current.startOfDay(for: Date())...,
                    displayedComponents: .date
                )
            }
        } footer: {
            Text(examFooter)
        }
    }

    private var examFooter: String {
        guard let examAt = currentFolder.examAt else {
            return "Optional: Mit Prüfungstermin plant die App so, dass jede Karte vor der Prüfung noch mindestens einmal drankommt."
        }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()), to: calendar.startOfDay(for: examAt)).day ?? 0
        if days < 0 {
            return "Die Prüfung ist vorbei – es wird wieder ganz normal mit FSRS geplant."
        }
        if days == 0 {
            return "Die Prüfung ist heute. Viel Erfolg!"
        }
        return "Noch \(days) Tag\(days == 1 ? "" : "e"). Wiederholungen, die erst nach der Prüfung dran wären, zieht die App vor – je näher die Prüfung, desto kürzer die Abstände."
    }

    /// Prüfungen liegen tagsüber: auf 12 Uhr setzen, damit der Termin sicher
    /// auf den gewählten Lerntag fällt (Tagesgrenze 4 Uhr, siehe FSRSScheduler).
    private static func normalizedExamDate(_ date: Date) -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
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
