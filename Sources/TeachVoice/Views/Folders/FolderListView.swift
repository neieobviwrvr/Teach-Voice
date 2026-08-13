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

    @EnvironmentObject private var library: LibraryStore

    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: Folder?
    @State private var renameText = ""
    @State private var showMicPermissionNotice = false
    @State private var isLoadingHandsFree = false
    @State private var showProfile = false
    // Neuer zentraler "Lernen"-Button (Simons Vorgabe): Ordner "fallen" per
    // Animation mindmap-artig heraus, statt direkt als Liste sichtbar zu
    // sein. Alle bisherigen Funktionen/Buttons bleiben erhalten, nur visuell
    // verkleinert bzw. nach unten verschoben (siehe `heroSection`,
    // `handsFreeSection`, `folderRows` weiter unten in `mainList`).
    @State private var showFolderMindMap = false
    // Ersetzt den statischen "Meine Ordner"-Titel: ein Dropdown oben links
    // wählt den "Oberordner" (= `Folder`), dessen UNTERORDNER dann im
    // "Lernen"-Mindmap herausfahren (Simons Vorgabe). Bei aktuell max. 1
    // Ordner/User (`maxFoldersPerUser`) zeigt das Dropdown heute meist nur
    // eine Option, ist aber bewusst allgemein gebaut für den Fall, dass das
    // Limit später gelockert wird.
    @State private var selectedFolder: Folder?

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

    /// Vorberechnet statt inline in den ConfirmationDialogs – Swifts
    /// Type-Checker kommt bei String-Verkettung direkt in einem ViewBuilder-
    /// Closure sonst leicht an seine Grenzen (siehe unten, `body` musste aus
    /// demselben Grund in mehrere Teilausdrücke aufgesplittet werden).
    private var strictnessExplanation: String {
        GradingStrictness.normal.description + "\n" + GradingStrictness.tryhard.description
    }

    var body: some View {
        NavigationStack {
            withFolderSelection(withHandsFreeDialogs(withCoreAlerts(navigationList)))
        }
    }

    // MARK: - Aufgesplittete Teilausdrücke (Compiler-Timeout-Workaround)
    //
    // Der komplette Bildschirm in EINEM einzigen verketteten Ausdruck ließ
    // Swifts Type-Checker beim ersten echten Build mit "unable to type-check
    // this expression in reasonable time" scheitern. Aufteilen in mehrere
    // Computed Properties/Methoden mit je eigener, expliziter Signatur behebt
    // das, weil jedes Stück unabhängig typgeprüft wird statt alles auf einmal.

    @ViewBuilder
    private var navigationList: some View {
        mainList
            .navigationDestination(for: Folder.self) { folder in
                SubfolderListView(folder: folder)
            }
            .navigationDestination(for: Subfolder.self) { subfolder in
                FlashcardListView(subfolder: subfolder)
            }
            .navigationDestination(item: $voiceOnlySubfolders) { subfolders in
                HandsFreeStudyView(subfolders: subfolders, strictness: voiceOnlyStrictness)
            }
            .navigationDestination(item: $eigenbewertungCards) { cards in
                HandsFreeSelfAssessmentStudyView(cards: cards, title: eigenbewertungTitle, strictness: eigenbewertungStrictness)
            }
            // Kein statischer Titel mehr -- das Oberordner-Dropdown in
            // `mainToolbar` übernimmt diese Rolle (Simons Vorgabe: "statt
            // 'Meine Ordner' ein Drop-Down-Menu"). `.inline`, damit die Bar
            // trotz fehlendem großen Titel kompakt bleibt.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { mainToolbar }
            .safeAreaInset(edge: .bottom) { addFolderBottomButton }
            .overlay { emptyStateOverlay }
            .task { await library.loadFolders() }
            // Proaktiver Hinweis: die App funktioniert im Kern erst richtig,
            // wenn der Mikrofonzugriff erlaubt ist (STT-Lernmodus).
            .task { showMicPermissionNotice = !MicrophonePermission.isGranted }
            .refreshable { await library.loadFolders() }
            .sheet(isPresented: $showProfile) {
                ProfileView(mode: mode)
            }
    }

    /// Ausgelagert (statt weiterer Modifier in `navigationList`), gleicher
    /// Grund wie bei `withCoreAlerts`/`withHandsFreeDialogs`: der
    /// Type-Checker ist in dieser View schon einmal an einer zu langen
    /// verketteten Modifier-Kette gescheitert.
    @ViewBuilder
    private func withFolderSelection<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: library.folders) { _, newFolders in
                syncSelectedFolder(with: newFolders)
            }
            .task(id: selectedFolder?.id) {
                if let selectedFolder {
                    await library.loadSubfolders(for: selectedFolder)
                }
            }
    }

    @ViewBuilder
    private var mainList: some View {
        List {
            heroSection

            if mode == .guest {
                Section {
                    Label("Gastmodus – Karten sind nur auf diesem Gerät gespeichert.", systemImage: "iphone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            handsFreeSection

            Section("Alle Ordner") {
                folderRows
            }
        }
    }

    // MARK: - Hero: zentraler "Lernen"-Button mit Mindmap-Reveal

    /// Die Unterordner des aktuell im Oberordner-Dropdown gewählten Ordners
    /// -- das ist jetzt die Grundlage für den Mindmap-Reveal (statt vorher
    /// die Ordner selbst), siehe Simons Vorgabe: "in der Animation beim
    /// 'Lernen'-Button nur die Unterordner herausgefahren, die in dem
    /// entsprechenden ausgewählten Oberordner [...] gehören".
    private var mindMapSubfolders: [Subfolder] {
        guard let selectedFolder else { return [] }
        return library.subfolders(in: selectedFolder)
    }

    /// Nimmt bewusst viel vertikalen Platz ein (füllt den sichtbaren Bereich
    /// beim Öffnen der App), damit Hands-free-Buttons und Ordnerliste
    /// darunter erst durch Scrollen sichtbar werden -- Simons ausdrückliche
    /// Vorgabe. `.listRowInsets`/`.listRowBackground(.clear)` entfernen die
    /// normale List-Zeilen-Optik, damit das freie Positionieren der
    /// Mindmap-Knoten nicht mit dem Standard-List-Layout kollidiert.
    @ViewBuilder
    private var heroSection: some View {
        Section {
            ZStack {
                ForEach(Array(mindMapSubfolders.enumerated()), id: \.element.id) { index, subfolder in
                    subfolderMindMapNode(subfolder, index: index, total: mindMapSubfolders.count)
                }
                learnButton
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var learnButton: some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                showFolderMindMap.toggle()
            }
        } label: {
            Text("Lernen")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(width: 130, height: 130)
                .background(Circle().fill(Color.accentColor))
                .shadow(radius: showFolderMindMap ? 12 : 4)
        }
        .buttonStyle(.plain)
        .disabled(mindMapSubfolders.isEmpty)
        .opacity(mindMapSubfolders.isEmpty ? 0.5 : 1)
    }

    /// Ein einzelner Unterordner-Knoten, der beim Antippen von "Lernen"
    /// mindmap-artig aus der Button-Mitte herausfährt -- gescoped auf den im
    /// Oberordner-Dropdown gewählten Ordner (`mindMapSubfolders`). Verteilung:
    /// ein Bogen von 180° (links) über oben bis 0° (rechts) -- bei nur einem
    /// Unterordner landet der Knoten mittig oberhalb des Buttons; bei
    /// mehreren fächern sie sich darüber auf (der eigentlich relevante Fall,
    /// da Unterordner bewusst unbegrenzt sind). Radius/Höhe wurden hier ohne
    /// echtes Gerät gewählt (kein lokaler Simulator verfügbar) -- ggf. nach
    /// dem ersten Test noch nachjustieren.
    private func subfolderMindMapNode(_ subfolder: Subfolder, index: Int, total: Int) -> some View {
        let angleDegrees: Double = total <= 1 ? 0 : -90 + (180.0 / Double(total - 1)) * Double(index)
        let angleRadians = angleDegrees * .pi / 180
        let radius: CGFloat = 120
        let dx = showFolderMindMap ? radius * sin(angleRadians) : 0
        let dy = showFolderMindMap ? -radius * cos(angleRadians) : 0

        return NavigationLink(value: subfolder) {
            Text(subfolder.name)
                .font(.footnote.bold())
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(.thickMaterial))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .offset(x: dx, y: dy)
        .scaleEffect(showFolderMindMap ? 1 : 0.01)
        .opacity(showFolderMindMap ? 1 : 0)
        .animation(
            .spring(response: 0.45, dampingFraction: 0.68).delay(Double(index) * 0.06),
            value: showFolderMindMap
        )
    }

    // MARK: - Hands-free (kompakt, siehe Simons Vorgabe: verkleinert)

    @ViewBuilder
    private var handsFreeSection: some View {
        Section {
            HStack(spacing: 8) {
                compactHandsFreeButton(title: "Voice only", systemImage: "waveform") {
                    await startVoiceOnlyFlow()
                }
                compactHandsFreeButton(title: "Eigenbewertung", systemImage: "hand.tap") {
                    await startEigenbewertungFlow()
                }
            }
        } footer: {
            Text("\"Voice only\": komplett per Sprache, die App fragt dich selbst welchen Unterordner du lernen willst, GPT bewertet allein. \"Eigenbewertung\": Unterordner per Pop-up wählen, nach jeder Frage entscheidest du selbst per Button.")
        }
    }

    /// Einheitlicher Ladezustand mit echtem Spinner statt reinem Text-Swap
    /// ("Lädt…") – konsistent mit dem Rest der App (PDFImportView, StudyView).
    /// Bewusst klein/kompakt (Simons Vorgabe) -- kleine Schrift, wenig
    /// Padding, nebeneinander statt volle Zeilenbreite wie vorher.
    private func compactHandsFreeButton(title: String, systemImage: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 2) {
                if isLoadingHandsFree {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                }
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isLoadingHandsFree)
    }

    @ViewBuilder
    private var folderRows: some View {
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

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showAddFolder = true
            } label: {
                Label("Ordner hinzufügen", systemImage: "plus")
            }
            .disabled(isFull)
        }
        // Ersetzt den früheren statischen Titel "Meine Ordner" (Simons
        // Vorgabe). Zeigt den Namen des gewählten Oberordners + Chevron;
        // Auswahl bestimmt, welche Unterordner im "Lernen"-Mindmap
        // herausfahren (siehe `mindMapSubfolders`). Zuerst deklariert, damit
        // es als das linkeste Element erscheint.
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                ForEach(library.folders) { folder in
                    Button {
                        selectedFolder = folder
                    } label: {
                        if folder.id == selectedFolder?.id {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedFolder?.name ?? "Ordner")
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
            }
            .disabled(library.folders.isEmpty)
        }
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showProfile = true
            } label: {
                Label("Profil", systemImage: "person.crop.circle")
            }
        }
    }

    /// Wählt automatisch einen Oberordner aus, sobald welche geladen sind
    /// (aktuell praktisch immer der einzige, siehe `maxFoldersPerUser`), und
    /// fängt den Fall ab, dass der bisher gewählte Ordner gelöscht wurde.
    private func syncSelectedFolder(with folders: [Folder]) {
        if selectedFolder == nil || !folders.contains(where: { $0.id == selectedFolder?.id }) {
            selectedFolder = folders.first
        }
    }

    @ViewBuilder
    private var addFolderBottomButton: some View {
        // Ohne die Caption ist für den User nicht erkennbar, WARUM der Button
        // ausgegraut ist, sobald der 1 Ordner (Hard-Limit) schon existiert –
        // wird nur bei isFull eingeblendet, um den Normalfall nicht unnötig
        // vollzutexten.
        VStack(spacing: 4) {
            Button {
                showAddFolder = true
            } label: {
                Label("Ordner hinzufügen", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isFull)

            if isFull {
                Text("Maximal 1 Ordner pro Account – lege stattdessen beliebig viele Unterordner darin an.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if library.folders.isEmpty && !library.isLoading {
            ContentUnavailableView(
                "Noch keine Ordner",
                systemImage: "folder",
                description: Text("Tippe auf \"Ordner hinzufügen\", um loszulegen.")
            )
        }
    }

    @ViewBuilder
    private func withCoreAlerts<Content: View>(_ content: Content) -> some View {
        content
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

    @ViewBuilder
    private func withHandsFreeDialogs<Content: View>(_ content: Content) -> some View {
        content
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
                Text(strictnessExplanation)
            }
            .confirmationDialog(
                "Unterordner für Hands-free wählen",
                isPresented: $showEigenbewertungSubfolderPicker,
                titleVisibility: .visible
            ) {
                eigenbewertungSubfolderPickerButtons
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
                Text(strictnessExplanation)
            }
    }

    @ViewBuilder
    private var eigenbewertungSubfolderPickerButtons: some View {
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
