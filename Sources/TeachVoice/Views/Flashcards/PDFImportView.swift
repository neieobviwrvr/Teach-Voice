import SwiftUI
import UniformTypeIdentifiers

/// PDF-Import: bis zu 2 PDFs (aktuell für jeden Account gleich, siehe
/// `AuthManager.isPaidUser`) auswählen -> Text wird on-device extrahiert
/// (`PDFTextExtractor`, reiner Text, siehe dortige Doku zur Bild-Einschränkung)
/// -> GPT generiert bis zu N Frage+Musterantwort-Vorschläge pro Datei ->
/// User wählt per Checkbox aus -> ein KOMPLETT NEUER Unterordner wird
/// angelegt und mit den ausgewählten Karten gefüllt.
///
/// Bewusst auf Ebene des Ober-Ordners (ausgelöst von `SubfolderListView`,
/// nicht mehr von `FlashcardListView`) – Simons explizite Entscheidung: PDF-
/// Import erzeugt einen neuen Unterordner, statt Karten in einen
/// bestehenden einzufügen.
struct PDFImportView: View {
    let folder: Folder

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var showFilePicker = false
    @State private var selectedURLs: [URL] = []
    @State private var subfolderName = ""
    // Default bewusst "kompakt" -- die sicherere Seite angesichts des
    // Problems, das diese Auswahl überhaupt ausgelöst hat (zu lange, ~50
    // Wörter lange Musterantworten). Kann jederzeit vor dem Tap auf einen
    // der Anzahl-Buttons auf "umfassend" umgestellt werden.
    @State private var answerStyle: AnswerStyle = .kompakt
    @State private var isProcessing = false
    @State private var processingStatus = ""
    @State private var hasGenerated = false
    @State private var candidates: [ReviewCandidate] = []
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Wird beim ersten Speichern-Tap gesetzt und danach wiederverwendet –
    /// ein erneuter Tap nach einem Teil-Fehlschlag legt keinen zweiten,
    /// leeren Unterordner an.
    @State private var createdSubfolder: Subfolder?

    // Aktuell für jeden Account gleich – es gibt noch keine echte
    // Bezahlfunktion (siehe AuthManager.isPaidUser).
    private let maxPDFCount = 2
    private let maxFileSizeBytes = 50 * 1024 * 1024

    private struct ReviewCandidate: Identifiable {
        let id = UUID()
        let question: GeneratedQuestion
        let sourceFileName: String
        var isSelected = true
    }

    private var selectedCount: Int { candidates.filter(\.isSelected).count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding()
                }
                currentPhase
            }
            .navigationTitle("Unterordner aus PDF erstellen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true
        ) { result in
            handleFileImportResult(result)
        }
    }

    @ViewBuilder
    private var currentPhase: some View {
        if hasGenerated {
            reviewSection
        } else if isProcessing {
            processingSection
        } else if !selectedURLs.isEmpty {
            countSelectionSection
        } else {
            filePickerSection
        }
    }

    // MARK: - Phase 1: Dateien wählen

    private var filePickerSection: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Bis zu \(maxPDFCount) PDFs auswählen (je max. 50MB)")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Nur Text wird ausgelesen – Diagramme/Bilder werden aktuell noch nicht berücksichtigt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("PDFs auswählen") { showFilePicker = true }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
    }

    private func handleFileImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            guard urls.count <= maxPDFCount else {
                errorMessage = "Maximal \(maxPDFCount) PDFs gleichzeitig."
                return
            }
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if accessed { url.stopAccessingSecurityScopedResource() }
                if let size, size > maxFileSizeBytes {
                    let mb = Double(size) / 1_048_576
                    errorMessage = "\(url.lastPathComponent) ist zu groß (\(String(format: "%.1f", mb))MB, Maximum 50MB)."
                    return
                }
            }
            errorMessage = nil
            selectedURLs = urls
            if subfolderName.isEmpty {
                subfolderName = urls[0].deletingPathExtension().lastPathComponent
            }
        }
    }

    // MARK: - Phase 2: Name + Anzahl wählen

    private var countSelectionSection: some View {
        VStack(spacing: 16) {
            Text("Ausgewählt:").font(.caption).foregroundStyle(.secondary)
            ForEach(selectedURLs, id: \.self) { url in
                Text(url.lastPathComponent).font(.footnote)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Name des neuen Unterordners").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $subfolderName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            Divider().padding(.vertical, 4)
            Text("Wie sollen die Musterantworten sein?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack(spacing: 12) {
                styleButton(.kompakt)
                styleButton(.umfassend)
            }
            .padding(.horizontal)

            Spacer()
            Text("Wie viele Fragen sollen (pro Datei) generiert werden?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("GPT füllt nicht künstlich auf, wenn weniger wirklich wichtig ist.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            countButton(label: "Wenig", subtitle: "bis zu 12", value: 12)
            countButton(label: "Mittel", subtitle: "bis zu 18", value: 18)
            countButton(label: "Viele", subtitle: "bis zu 25", value: 25)
            Spacer()
        }
        .padding()
    }

    private var isNameValid: Bool { !subfolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func styleButton(_ style: AnswerStyle) -> some View {
        let isSelected = answerStyle == style
        return Button {
            answerStyle = style
        } label: {
            VStack(spacing: 2) {
                Text(style.label).font(.subheadline.bold())
                Text(style.subtitle).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : .secondary)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    private func countButton(label: String, subtitle: String, value: Int) -> some View {
        Button {
            startProcessing(maxPerFile: value)
        } label: {
            VStack {
                Text(label).font(.headline)
                Text(subtitle).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(!isNameValid)
    }

    // MARK: - Phase 3: Verarbeitung

    private var processingSection: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
            Text(processingStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }

    private func startProcessing(maxPerFile: Int) {
        isProcessing = true
        errorMessage = nil
        Task {
            var collected: [ReviewCandidate] = []

            for (index, url) in selectedURLs.enumerated() {
                processingStatus = "Datei \(index + 1) von \(selectedURLs.count) wird gelesen…"

                let extraction = await Task.detached(priority: .userInitiated) { () -> PDFTextExtractor.Result? in
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    return PDFTextExtractor.extract(from: url)
                }.value

                guard let extraction, !extraction.text.isEmpty else {
                    errorMessage = "\(url.lastPathComponent) konnte nicht gelesen werden (kein Text gefunden oder beschädigtes PDF)."
                    continue
                }

                processingStatus = extraction.wasTruncated
                    ? "\(url.lastPathComponent): nur die ersten \(extraction.includedPages) von \(extraction.totalPages) Seiten wurden berücksichtigt (zu lang) – Fragen werden generiert…"
                    : "\(url.lastPathComponent): Fragen werden generiert…"

                do {
                    let token = await auth.validAccessToken()
                    let generated = try await QuestionGenerationService.generate(
                        text: extraction.text, maxQuestions: maxPerFile, answerStyle: answerStyle, accessToken: token
                    )
                    collected.append(contentsOf: generated.map {
                        ReviewCandidate(question: $0, sourceFileName: url.lastPathComponent)
                    })
                } catch {
                    errorMessage = "Fragengenerierung für \(url.lastPathComponent) fehlgeschlagen: \(error.localizedDescription)"
                }
            }

            candidates = collected
            isProcessing = false
            hasGenerated = true
        }
    }

    // MARK: - Phase 4: Review

    private var reviewSection: some View {
        VStack(spacing: 0) {
            if candidates.isEmpty {
                ContentUnavailableView(
                    "Keine Vorschläge",
                    systemImage: "doc.questionmark",
                    description: Text("GPT konnte aus den Dateien nichts Verwertbares extrahieren.")
                )
            } else {
                List {
                    Section {
                        ForEach($candidates) { $candidate in
                            candidateRow($candidate)
                        }
                    } header: {
                        Text("\(selectedCount) von \(candidates.count) ausgewählt")
                    }
                }
                saveButton
            }
        }
    }

    private func candidateRow(_ candidate: Binding<ReviewCandidate>) -> some View {
        Button {
            candidate.wrappedValue.isSelected.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: candidate.wrappedValue.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(candidate.wrappedValue.isSelected ? Color.accentColor : Color.secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.wrappedValue.question.frage).font(.subheadline.bold())
                    Text(candidate.wrappedValue.question.musterantwort).font(.caption).foregroundStyle(.secondary)
                    Text(candidate.wrappedValue.sourceFileName).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var saveButton: some View {
        Button {
            saveSelected()
        } label: {
            if isSaving {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("Unterordner \"\(subfolderName)\" mit \(selectedCount) Karten anlegen").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .disabled(selectedCount == 0 || isSaving)
    }

    private func saveSelected() {
        isSaving = true
        errorMessage = nil
        Task {
            guard let subfolder = await resolvedSubfolder() else {
                isSaving = false
                errorMessage = "Unterordner \"\(subfolderName)\" konnte nicht angelegt werden."
                return
            }

            // Nur erfolgreich gespeicherte Kandidaten werden aus der Liste
            // entfernt – siehe Kommentar in resolvedSubfolder(): ein erneuter
            // Tap nach Teil-Fehlschlag legt weder den Unterordner noch
            // bereits gespeicherte Karten doppelt an.
            var remaining: [ReviewCandidate] = []
            var failedCount = 0

            for candidate in candidates {
                guard candidate.isSelected else {
                    remaining.append(candidate)
                    continue
                }
                let success = await library.addFlashcard(
                    question: candidate.question.frage, answer: candidate.question.musterantwort, to: subfolder
                )
                if !success {
                    failedCount += 1
                    remaining.append(candidate)
                }
            }

            candidates = remaining
            isSaving = false

            if failedCount > 0 {
                errorMessage = "\(failedCount) Karte(n) konnten nicht gespeichert werden. Die übrigen wurden im neuen Unterordner \"\(subfolderName)\" angelegt. Tippe erneut auf Speichern für einen weiteren Versuch."
            } else {
                dismiss()
            }
        }
    }

    private func resolvedSubfolder() async -> Subfolder? {
        if let createdSubfolder { return createdSubfolder }
        let name = subfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let created = await library.addSubfolder(name: name, to: folder)
        createdSubfolder = created
        return created
    }
}
