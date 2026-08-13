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
    // Per GeometryReader gemessene Breite der Hero-Section -- Grundlage für
    // die komplette Mindmap-Geometrie (`mindMapSlots`). Startwert 375 =
    // schmalstes von iOS 17 unterstütztes iPhone; wird beim ersten Layout
    // sofort durch den echten Messwert ersetzt (unsichtbar, da die Pillen
    // bis zum ersten "Lernen"-Tap ohnehin ausgeblendet sind).
    @State private var heroMeasuredWidth: CGFloat = 375
    // Ersetzt den statischen "Meine Ordner"-Titel: ein Dropdown oben links
    // wählt den "Oberordner" (= `Folder`), dessen UNTERORDNER dann im
    // "Lernen"-Mindmap herausfahren (Simons Vorgabe). `maxFoldersPerUser`
    // (aktuell 2, extra zum Testen dieses Dropdowns gelockert) begrenzt die
    // Auswahl noch, das Dropdown ist aber bewusst allgemein für mehr gebaut.
    @State private var selectedFolder: Folder?
    // Simon: "füge unter den Buttons für Voice-Only und Eigenbewertung einen
    // Button an für extra Ordner und die generelle Ordnerverwaltung" -- jetzt
    // wo `maxFoldersPerUser` auf 2 gelockert ist (s.u.), lohnt sich ein
    // eigener schneller Einstieg dafür statt nur die "Alle Ordner"-Section
    // ganz unten in der Liste.
    @State private var showFolderManagement = false

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
            .sheet(isPresented: $showFolderManagement) {
                folderManagementSheet
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
    /// normale List-Zeilen-Optik.
    ///
    /// Simons drei harte Invarianten (nach zwei fehlgeschlagenen
    /// Radial-Varianten -- erst Pillen über dem Screenrand, dann hinter dem
    /// Button, dann übereinander): (1) alle Pillen KOMPLETT im Bild,
    /// (2) keine Pille im/hinter dem "Lernen"-Button, (3) keine Pillen
    /// übereinander -- auf jeder Displaygröße/iOS-Version. Ein echter Kreis
    /// um den Button kann das ab 3 Pillen NICHT erfüllen: seitlich neben
    /// einem 130pt breiten Button ist auf einem 375pt-Screen kein Platz für
    /// eine lesbare Pille (65pt Button-Radius + Abstand + halbe Pillenbreite
    /// + Randabstand > halbe Screenbreite) -- das ist Geometrie, kein
    /// Tuning-Problem. Deshalb fahren die Pillen jetzt als Fächer NACH OBEN
    /// aus dem Button heraus, in Reihen zu je 1-3 (abhängig von der
    /// GEMESSENEN Breite), zeilenweise gestapelt; Positionen und Breiten
    /// kommen aus `mindMapSlots`, wodurch die drei Invarianten per
    /// KONSTRUKTION erfüllt sind statt pro Winkel erhofft. Die
    /// Ausfahr-Animation (Spring aus der Button-Mitte, gestaffelt) ist
    /// dieselbe wie bei der Radial-Variante.
    @ViewBuilder
    private var heroSection: some View {
        let rowCount = mindMapRowCount(count: mindMapSubfolders.count, containerWidth: heroMeasuredWidth)
        let slots = mindMapSlots(count: mindMapSubfolders.count, containerWidth: heroMeasuredWidth)
        let shift = mindMapButtonShift(rowCount: rowCount)
        Section {
            GeometryReader { geo in
                ZStack {
                    ForEach(Array(mindMapSubfolders.enumerated()), id: \.element.id) { index, subfolder in
                        if index < slots.count {
                            subfolderMindMapNode(subfolder, index: index, slot: slots[index], buttonShift: shift)
                        }
                    }
                    learnButton
                        .offset(y: shift)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear { heroMeasuredWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newWidth in
                    heroMeasuredWidth = newWidth
                }
            }
            .frame(maxWidth: .infinity)
            // Höhe wächst mit der Reihenzahl (viele Unterordner -> mehr
            // Reihen), bleibt aber nie unter den bisherigen 340pt.
            .frame(height: mindMapHeroHeight(rowCount: rowCount))
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

    /// Eine berechnete Zielposition + Breiten-Budget für genau eine Pille im
    /// Mindmap-Fächer. `x`/`y` sind Offsets relativ zur Button-Mitte.
    private struct MindMapSlot {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
    }

    /// Alle Maße der Mindmap-Geometrie an EINEM Ort -- Reihen-Layout,
    /// Button-Verschiebung und Höhenberechnung müssen von exakt denselben
    /// Werten ausgehen, sonst driften Rechnung und Darstellung auseinander
    /// (die Wurzel der letzten drei Positionierungs-Bugs).
    private enum MindMapGeometry {
        /// .footnote + 2×10pt vertikales Padding ≈ 36pt Pillenhöhe.
        static let pillHeight: CGFloat = 36
        /// Abstand Pille↔Pille, horizontal wie vertikal.
        static let gap: CGFloat = 10
        /// Mindestabstand jeder Pille zum linken/rechten Screenrand.
        static let edgeBuffer: CGFloat = 10
        /// Button-Mitte -> Mitte der untersten Reihe. 96 - 18 (halbe
        /// Pillenhöhe) = 78pt Abstand der Pillen-Unterkante zur Button-Mitte
        /// >= 65 (Button-Radius) + 13 Luft -> Invariante (2) erfüllt.
        static let firstRowDistance: CGFloat = 96
        /// Vertikaler Reihenabstand = pillHeight + gap -> Invariante (3)
        /// zwischen Reihen erfüllt.
        static let rowPitch: CGFloat = 46
        /// Unter dieser Breite wird keine weitere Spalte mehr aufgemacht
        /// (lieber 2 lesbare als 4 unlesbare Pillen pro Reihe).
        static let minPillWidth: CGFloat = 105
        static let maxPillWidth: CGFloat = 150
        /// Button-Radius (65) + Luft nach unten.
        static let buttonBottomExtent: CGFloat = 80
        static let topPadding: CGFloat = 8
    }

    /// Wieviele Pillen nebeneinander in eine Reihe passen -- aus der echten
    /// gemessenen Breite, gedeckelt auf 3 (auf iPads wären sonst absurd
    /// viele Spalten möglich). Auf allen von iOS 17 unterstützten iPhones
    /// (>= 375pt) ergibt das 3.
    private func mindMapColumns(containerWidth: CGFloat) -> Int {
        let usable = containerWidth - 2 * MindMapGeometry.edgeBuffer
        let fitting = Int((usable + MindMapGeometry.gap) / (MindMapGeometry.minPillWidth + MindMapGeometry.gap))
        return max(1, min(3, fitting))
    }

    private func mindMapRowCount(count: Int, containerWidth: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let cols = mindMapColumns(containerWidth: containerWidth)
        return (count + cols - 1) / cols
    }

    /// Berechnet für ALLE Pillen gemeinsam die Zielpositionen: Reihen zu je
    /// `mindMapColumns` Pillen, von der untersten Reihe (direkt über dem
    /// Button) nach oben gefüllt, jede Reihe horizontal zentriert, alle
    /// Pillen einheitlich breit. Weil die Positionen als EIN Gitter
    /// berechnet werden (statt pro Pille unabhängig wie bei den
    /// Radial-Varianten), sind Überlappungen zwischen Pillen per
    /// Konstruktion ausgeschlossen -- der Abstand benachbarter Zentren ist
    /// immer exakt Pillenbreite+gap bzw. rowPitch.
    private func mindMapSlots(count: Int, containerWidth: CGFloat) -> [MindMapSlot] {
        guard count > 0 else { return [] }
        let cols = mindMapColumns(containerWidth: containerWidth)
        let usable = containerWidth - 2 * MindMapGeometry.edgeBuffer
        // Bei weniger Pillen als Spalten dürfen die Pillen breiter sein
        // (z.B. 2 Pillen à 150pt statt 2 à 113pt).
        let effectiveCols = min(cols, count)
        let pillWidth = min(
            MindMapGeometry.maxPillWidth,
            (usable - CGFloat(effectiveCols - 1) * MindMapGeometry.gap) / CGFloat(effectiveCols)
        )

        var slots: [MindMapSlot] = []
        var placed = 0
        var row = 0
        while placed < count {
            let inThisRow = min(cols, count - placed)
            let rowWidth = CGFloat(inThisRow) * pillWidth + CGFloat(inThisRow - 1) * MindMapGeometry.gap
            let y = -(MindMapGeometry.firstRowDistance + MindMapGeometry.rowPitch * CGFloat(row))
            for column in 0..<inThisRow {
                let x = -rowWidth / 2 + pillWidth / 2 + CGFloat(column) * (pillWidth + MindMapGeometry.gap)
                slots.append(MindMapSlot(x: x, y: y, width: pillWidth))
            }
            placed += inThisRow
            row += 1
        }
        return slots
    }

    /// Höhe des Pillen-Bereichs oberhalb der Button-Mitte (oberste Reihe +
    /// halbe Pillenhöhe + Luft).
    private func mindMapTopExtent(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return MindMapGeometry.firstRowDistance
            + MindMapGeometry.rowPitch * CGFloat(rowCount - 1)
            + MindMapGeometry.pillHeight / 2
            + MindMapGeometry.topPadding
    }

    /// Verschiebt den Button aus der ZStack-Mitte nach unten, damit der
    /// (nach oben wachsende) Pillen-Fächer und der Button zusammen vertikal
    /// zentriert sind, statt dass oben der Platz ausgeht während unten
    /// Leerraum bleibt.
    private func mindMapButtonShift(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return (mindMapTopExtent(rowCount: rowCount) - MindMapGeometry.buttonBottomExtent) / 2
    }

    /// Hero-Höhe: mindestens die bisherigen 340pt, wächst aber mit, sobald
    /// viele Unterordner mehr Reihen brauchen -- dadurch bleibt Invariante
    /// (1) auch bei beliebig vielen vom User erstellten Unterordnern erfüllt
    /// (die Section wird höher und scrollt in der List, nichts ragt heraus).
    private func mindMapHeroHeight(rowCount: Int) -> CGFloat {
        max(340, mindMapTopExtent(rowCount: rowCount) + MindMapGeometry.buttonBottomExtent)
    }

    /// Eine einzelne Unterordner-Pille, die beim Antippen von "Lernen" per
    /// Spring-Animation aus der Button-Mitte an ihre berechnete Slot-Position
    /// fährt (gestaffelt über `index`) -- gescoped auf den im
    /// Oberordner-Dropdown gewählten Ordner (`mindMapSubfolders`).
    private func subfolderMindMapNode(_ subfolder: Subfolder, index: Int, slot: MindMapSlot, buttonShift: CGFloat) -> some View {
        Button {
            // Springt DIREKT in Hands-free (Voice only) für GENAU diesen
            // Unterordner (Simon: "will ich direkt ins 'Handsfree Voice
            // only' geschickt werden, allerdings ohne die Abfrage welcher
            // Ordner gelernt werden soll") -- reicht dafür bewusst dieselbe
            // Strictness-Auswahl (`showVoiceOnlyStrictnessPicker`) und
            // denselben Navigations-Mechanismus (`voiceOnlySubfolders`) wie
            // der "Voice only"-Button in `handsFreeSection`, nur mit genau
            // einem vorausgewählten Unterordner statt allen.
            // `HandsFreeStudyView` überspringt die Sprach-Nachfrage
            // automatisch, sobald ihr nur ein einziger Unterordner übergeben
            // wird (siehe `selectSubfolderViaVoice`).
            pendingVoiceOnlySubfolders = [subfolder]
            showVoiceOnlyStrictnessPicker = true
        } label: {
            Text(subfolder.name)
                .font(.footnote.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // maxWidth = Slot-Budget minus horizontales Padding (2×14):
                // kurze Namen bekommen eine snugge Pille, lange schrumpfen/
                // kürzen INNERHALB des Budgets statt es zu sprengen.
                .frame(maxWidth: slot.width - 28)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(.thickMaterial))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        // Eingeklappt sitzt die Pille auf der (verschobenen) Button-Mitte,
        // ausgeklappt auf ihrem Slot -- dieselbe "fährt aus dem Button
        // heraus"-Optik wie bei der Radial-Variante.
        .offset(
            x: showFolderMindMap ? slot.x : 0,
            y: buttonShift + (showFolderMindMap ? slot.y : 0)
        )
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
            Button {
                showFolderManagement = true
            } label: {
                Label("Ordner verwalten", systemImage: "folder.badge.gearshape")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } footer: {
            Text("\"Voice only\": komplett per Sprache, die App fragt dich selbst welchen Unterordner du lernen willst, GPT bewertet allein. \"Eigenbewertung\": Unterordner per Pop-up wählen, nach jeder Frage entscheidest du selbst per Button. \"Ordner verwalten\": weitere Ordner anlegen, umbenennen oder löschen.")
        }
    }

    /// Eigenes Sheet statt nur die ohnehin vorhandene "Alle Ordner"-Section
    /// ganz unten zu nutzen -- Simons Vorgabe war ein direkter Button dafür.
    /// Reicht `folderRows` (samt Swipe-Actions/Kontextmenü) unverändert
    /// durch; "Ordner hinzufügen" hier löst dieselbe `showAddFolder`-Alert
    /// wie der Rest der View aus (gleicher, geteilter State).
    @ViewBuilder
    private var folderManagementSheet: some View {
        // Eigener, unabhängiger NavigationStack (Sheet-Präsentation) -- teilt
        // sich KEINE .navigationDestination-Registrierungen mit dem
        // Root-Stack in `navigationList`, deshalb hier eine eigene für
        // `Folder.self` nötig, sonst würde ein Tap auf einen Ordner in
        // diesem Sheet wirkungslos verpuffen.
        NavigationStack {
            List {
                folderRows
            }
            .navigationDestination(for: Folder.self) { folder in
                SubfolderListView(folder: folder)
            }
            .overlay { emptyStateOverlay }
            .navigationTitle("Ordner verwalten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fertig") { showFolderManagement = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFolder = true
                    } label: {
                        Label("Ordner hinzufügen", systemImage: "plus")
                    }
                    .disabled(isFull)
                }
            }
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
    /// (den ersten, falls noch keiner gewählt ist), und fängt den Fall ab,
    /// dass der bisher gewählte Ordner gelöscht wurde.
    private func syncSelectedFolder(with folders: [Folder]) {
        if selectedFolder == nil || !folders.contains(where: { $0.id == selectedFolder?.id }) {
            selectedFolder = folders.first
        }
    }

    @ViewBuilder
    private var addFolderBottomButton: some View {
        // Ohne die Caption ist für den User nicht erkennbar, WARUM der Button
        // ausgegraut ist, sobald das Hard-Limit (`maxFoldersPerUser`) schon
        // erreicht ist – wird nur bei isFull eingeblendet, um den Normalfall
        // nicht unnötig vollzutexten.
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
                Text("Maximal \(maxFoldersPerUser) Ordner pro Account – lege stattdessen beliebig viele Unterordner darin an.")
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
