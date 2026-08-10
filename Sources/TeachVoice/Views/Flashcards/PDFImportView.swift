import SwiftUI
import UniformTypeIdentifiers

/// PDF-Import: bis zu 2 PDFs (aktuell für jeden Account gleich, siehe
/// `AuthManager.isPaidUser`) auswählen -> Text wird on-device extrahiert
/// (`PDFTextExtractor`, reiner Text, siehe dortige Doku zur Bild-Einschränkung)
/// -> GPT generiert bis zu N Frage+Musterantwort-Vorschläge pro Datei ->
/// User wählt per Checkbox aus, was tatsächlich als Karte angelegt wird.
///
/// Bewusst als eigener Screen statt in `AddFlashcardSheet` integriert: völlig
/// anderer Ablauf (mehrstufig, asynchron, mit Zwischen-Review), keine
/// sinnvolle gemeinsame View mit dem einfachen Erstellen-Formular.
struct PDFImportView: View {
    let subfolder: Subfolder

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var showFilePicker = false
    @State private var selectedURLs: [URL] = []
    @State private var isProcessing = false
    @State private var processingStatus = ""
    @State private var hasGenerated = false
    @State private var candidates: [ReviewCandidate] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    // Aktuell für jeden Account gleich – es gibt noch keine echte
    // Bezahlfunktion (siehe AuthManager.isPaidUser). Hier ist bewusst schon
    // der Anknüpfungspunkt für später vorbereitet, ohne eine erfundene
    // Paid-Zahl festzulegen, die Simon noch nicht entschieden hat.
    private let maxPDFCount = 2
    private let maxFileSizeBytes = 50 * 1024 * 1024

    private struct ReviewCandidate: Identifiable {
        let id = UUID()
        let question: GeneratedQuestion
        let sourceFileName: String
        var isSelected = true
    }

    private var existingCardCount: Int { library.flashcards(in: subfolder).count }
    private var remainingCapacity: Int { max(0, maxFlashcardsPerSubfolder - existingCardCount) }
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
            .navigationTitle("Aus PDF erstellen")
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
            Text("Nur Text wird ausgelesen – Diagramme/Bilder werden aktuell noch nicht berücksichtigt. In diesem Unterordner sind noch \(remainingCapacity) Plätze frei.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("PDFs auswählen") { showFilePicker = true }
                .buttonStyle(.borderedProminent)
                .disabled(remainingCapacity == 0)
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
        }
    }

    // MARK: - Phase 2: Anzahl wählen

    private var countSelectionSection: some View {
        VStack(spacing: 16) {
            Text("Ausgewählt:").font(.caption).foregroundStyle(.secondary)
            ForEach(selectedURLs, id: \.self) { url in
                Text(url.lastPathComponent).font(.footnote)
            }
            Spacer()
            Text("Wie viele Fragen sollen (pro Datei) generiert werden?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("GPT wählt eigenständig, wie viele davon inhaltlich wirklich eigenständig wichtig sind – das ist die Obergrenze, nicht garantiert die tatsächliche Zahl.")
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
                        text: extraction.text, maxQuestions: maxPerFile, accessToken: token
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
                        Text("\(selectedCount) von \(candidates.count) ausgewählt — max. \(remainingCapacity) passen noch in diesen Unterordner")
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
                Text("Ausgewählte speichern (\(selectedCount))").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .disabled(selectedCount == 0 || selectedCount > remainingCapacity || isSaving)
    }

    private func saveSelected() {
        isSaving = true
        errorMessage = nil
        Task {
            // Nur erfolgreich gespeicherte Kandidaten werden aus der Liste
            // entfernt – nicht ausgewählte UND fehlgeschlagene bleiben stehen.
            // Damit legt ein erneuter Tap auf "Speichern" nach einem
            // Teil-Fehlschlag nichts doppelt an, und der User sieht genau, was
            // (noch) fehlt, statt dass Karten lautlos verschwinden.
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
                errorMessage = "\(failedCount) Karte(n) konnten nicht gespeichert werden (z.B. weil der Unterordner voll wurde). Die übrigen wurden angelegt."
            } else {
                dismiss()
            }
        }
    }
}
