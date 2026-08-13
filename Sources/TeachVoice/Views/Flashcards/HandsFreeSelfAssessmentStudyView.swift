import SwiftUI

/// "Hands-free lernen (Eigenbewertung)": Frage wird automatisch vorgelesen
/// und die Antwort automatisch aufgenommen (adaptive Stille-Erkennung) wie im
/// reinen Voice-only-Modus – aber nach der GPT-Bewertung erscheinen die drei
/// Selbsteinschätzungs-Buttons und die Schleife wartet auf einen Tap, statt
/// automatisch per Ton weiterzuschalten. Die Selbsteinschätzung ist dann auch
/// das maßgebliche Spaced-Repetition-Signal, genau wie im Detail-Modus.
///
/// Bewusst mit dem sichtbaren Pop-up (nicht dem Sprachmenü aus
/// `HandsFreeStudyView`) für Unterordner-Auswahl und Rundenabschluss: da man
/// hier ohnehin pro Frage antippen muss, ist ein zusätzliches Sprachmenü nur
/// für die Navigation unnötige Komplexität. Am Rundenende wird die Statistik
/// trotzdem zusätzlich vorgelesen (nicht nur angezeigt).
struct HandsFreeSelfAssessmentStudyView: View {
    @State private var cards: [Flashcard]
    @State private var title: String
    let strictness: GradingStrictness

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcriber: WhisperTranscriber
    @Environment(\.dismiss) private var dismiss
    // App-weit geteilte Instanz (siehe TeachVoiceApp) statt pro View neu
    // erzeugt -- garantiert, dass nie zwei Voice-Lines gleichzeitig hörbar
    // sind, auch nicht über Screen-Grenzen hinweg.
    @EnvironmentObject private var speech: SpeechService

    @StateObject private var recorder = AudioRecorder()

    @State private var index = 0
    @State private var statusText = "Bereit…"
    @State private var isListening = false
    @State private var sessionResults: [SessionResultEntry] = []

    @State private var awaitingSelfAssessment = false
    @State private var pendingGradingResult: GradingResult?
    @State private var selfAssessmentContinuation: CheckedContinuation<GradingResult.Urteil, Never>?

    @State private var showSubfolderPicker = false
    @State private var subfolderOptions: [Subfolder] = []

    /// Der Hintergrund-Task, der `runLoop()` antreibt. `restartSession()` und
    /// `switchTo(subfolder:)` starten sonst über `Task { await runLoop() }`
    /// einen ZWEITEN, unabhängigen Loop, während der alte (z.B. noch bei der
    /// Abschluss-Ansage) im Hintergrund weiterläuft – beide würden sich dann
    /// denselben Recorder/Speech-Service teilen. `startLoop()` bricht den
    /// alten deshalb immer zuerst ab.
    @State private var loopTask: Task<Void, Never>?

    init(cards: [Flashcard], title: String, strictness: GradingStrictness) {
        _cards = State(initialValue: SpacedRepetition.ordered(cards))
        _title = State(initialValue: title)
        self.strictness = strictness
    }

    private var currentCard: Flashcard? {
        cards.indices.contains(index) ? cards[index] : nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let card = currentCard {
                    Text("Karte \(index + 1) von \(cards.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    // Kein pauschales .bold() – sonst geht die manuell im
                    // Editor gesetzte Fett-Markierung unter (siehe StudyView).
                    Text(flashcardMarkdown: card.question)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if isListening {
                        Button {
                            recorder.requestManualStop()
                        } label: {
                            Label("Lösung abgeben", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if awaitingSelfAssessment, let result = pendingGradingResult {
                        VStack(spacing: 10) {
                            Text("\(Int(result.deckungProzent.rounded()))% getroffen")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(result.kurzesFeedback)
                                .font(.subheadline)
                            if !result.fehlendeElemente.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Gefehlt hat:").font(.caption).foregroundStyle(.secondary)
                                    ForEach(result.fehlendeElemente, id: \.self) { element in
                                        Label(element, systemImage: "circle").font(.caption)
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Musterantwort:").font(.caption).foregroundStyle(.secondary)
                                Text(flashcardMarkdown: card.answer).font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Wie empfindest du deine Antwort selbst?")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                selfAssessmentButton(.falsch, label: "Falsch")
                                selfAssessmentButton(.teilweise, label: "Teilweise")
                                selfAssessmentButton(.richtig, label: "Richtig")
                            }
                        }
                        .padding()
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Button("Beenden", role: .destructive) { stopEverythingAndClose() }
                        .buttonStyle(.bordered)
                } else {
                    SessionSummaryView(
                        results: sessionResults,
                        onRepeatSame: { restartSession() },
                        onPickDifferentSubfolder: { Task { await loadSubfolderOptions() } }
                    )
                    Button("Zurück zum Homescreen") { stopEverythingAndClose() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await transcriber.prepareIfNeeded() }
        .task { startLoop() }
        .onDisappear { stopEverything() }
        .alert("Mikrofonzugriff benötigt", isPresented: $recorder.permissionDenied) {
            Button("Zugriff erlauben") { MicrophonePermission.requestOrOpenSettings() }
            Button("Später", role: .cancel) {}
        } message: {
            Text("Ohne Mikrofonzugriff kann deine gesprochene Antwort nicht aufgenommen werden.")
        }
        .confirmationDialog("Unterordner wählen", isPresented: $showSubfolderPicker, titleVisibility: .visible) {
            ForEach(subfolderOptions) { option in
                Button(option.name) {
                    Task { await switchTo(subfolder: option) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func selfAssessmentButton(_ urteil: GradingResult.Urteil, label: String) -> some View {
        Button(label) {
            HapticFeedback.play(for: urteil)
            selfAssessmentContinuation?.resume(returning: urteil)
            selfAssessmentContinuation = nil
        }
        .buttonStyle(.borderedProminent)
        .tint(verdictColor(urteil))
    }

    private func verdictColor(_ urteil: GradingResult.Urteil) -> Color {
        switch urteil {
        case .richtig: return .green
        case .teilweise: return .orange
        case .falsch: return .red
        }
    }

    private func runLoop() async {
        while !Task.isCancelled, cards.indices.contains(index) {
            guard let card = currentCard else { break }
            awaitingSelfAssessment = false
            pendingGradingResult = nil

            // Barge-in (Simons ausdrückliche Vorgabe: "Frage schon tausend Mal
            // gehört, will vorzeitig antworten"): das Mikrofon hört schon
            // WÄHREND die Frage noch vorgelesen wird mit, statt erst danach +
            // fester Pause. onSpeechDetected bricht die Ansage bereits im
            // Moment des ERSTEN erkannten Wortes ab -- nicht erst, wenn die
            // ganze Antwort fertig aufgenommen ist.
            statusText = "Frage wird vorgelesen – du kannst direkt antworten…"
            speech.speak(FlashcardMarkdown.plainText(from: card.question))

            isListening = true
            let url = await recorder.recordUntilSilence(onSpeechDetected: { speech.stop() }, isPlaybackActive: { speech.isSpeaking })
            isListening = false
            // Absicherung, falls "Lösung abgeben" getippt wurde, ohne dass
            // vorher Sprache erkannt wurde.
            speech.stop()

            guard let url else {
                if recorder.permissionDenied { break }
                statusText = "Aufnahme fehlgeschlagen – weiter zur nächsten Frage."
                index += 1
                continue
            }
            if Task.isCancelled { break }

            statusText = "Transkribiere…"
            let text = await transcriber.transcribe(audioURL: url)
            if Task.isCancelled { break }

            guard let text, !text.isEmpty else {
                statusText = "Nichts verstanden – weiter zur nächsten Frage."
                index += 1
                continue
            }

            statusText = "Wird bewertet…"
            await gradeThenWaitForSelfAssessment(card: card, sttText: text)
            if Task.isCancelled { break }

            index += 1
        }

        if !Task.isCancelled, !cards.indices.contains(index) {
            let richtig = sessionResults.filter { $0.label == "Richtig" }.count
            let teilweise = sessionResults.filter { $0.label == "Teilweise richtig" }.count
            let falsch = sessionResults.count - richtig - teilweise
            let statsClause = StudySessionSummarySpeech.statsClause(richtig: richtig, teilweise: teilweise, falsch: falsch)
            let summary = statsClause.map { "Du hast das Deck vollständig gelernt und davon \($0) beantwortet." }
                ?? "Du hast das Deck vollständig gelernt."
            await speech.speakAndWait(summary)
        }
    }

    private func gradeThenWaitForSelfAssessment(card: Flashcard, sttText: String) async {
        let currentHash = TextHash.sha256(card.answer)
        let cacheStillValid = card.kernelementeSourceHash == currentHash
        let cachedKernelemente = cacheStillValid ? card.kernelemente : nil

        do {
            let token = await auth.validAccessToken()
            let (kernelemente, result) = try await GradingService.grade(
                question: card.question,
                answer: card.answer,
                cachedKernelemente: cachedKernelemente,
                sttText: sttText,
                accessToken: token
            )
            if !cacheStillValid {
                await library.cacheKernelemente(kernelemente, for: card, sourceHash: currentHash)
            }

            let suggested = strictness.urteil(fromDeckungProzent: result.deckungProzent)
            statusText = "Wie empfindest du deine Antwort?"
            let finalUrteil = await withCheckedContinuation { (continuation: CheckedContinuation<GradingResult.Urteil, Never>) in
                pendingGradingResult = result
                awaitingSelfAssessment = true
                selfAssessmentContinuation = continuation
            }
            awaitingSelfAssessment = false

            sessionResults.append(SessionResultEntry(
                question: card.question,
                isCorrect: finalUrteil == .richtig,
                label: verdictLabel(finalUrteil),
                percent: result.deckungProzent
            ))
            _ = suggested // Vorschlag diente nur der Vorbelegung/Anzeige, nicht der Zählung.
            await library.recordSpacedRepetitionOutcome(for: card, urteil: finalUrteil)
        } catch {
            statusText = "Bewertung fehlgeschlagen."
            sessionResults.append(SessionResultEntry(question: card.question, isCorrect: false, label: "Fehler", percent: 0))
        }
    }

    private func verdictLabel(_ urteil: GradingResult.Urteil) -> String {
        switch urteil {
        case .richtig: return "Richtig"
        case .teilweise: return "Teilweise richtig"
        case .falsch: return "Falsch"
        }
    }

    /// Startet `runLoop()` als neuen, verfolgbaren Task – bricht dabei IMMER
    /// zuerst einen eventuell noch laufenden alten Loop ab (siehe
    /// `loopTask`-Kommentar). Zentrale Stelle statt `Task { await runLoop() }`
    /// an jeder Aufrufstelle einzeln zu schreiben.
    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { await runLoop() }
    }

    private func stopEverything() {
        speech.stop()
        if recorder.isRecording { _ = recorder.stopRecording() }
        AudioSessionCoordinator.deactivate()
        loopTask?.cancel()
        loopTask = nil
        // `selfAssessmentContinuation` bewusst NICHT hier mitauflösen: ein
        // untergeschobenes Urteil (z.B. "falsch") würde echte
        // Spaced-Repetition-Daten für eine Karte schreiben, die der User nie
        // wirklich eingeschätzt hat. Bleibt sie offen, verschwindet sie beim
        // Verlassen der View einfach mit ihr (harmlos, höchstens eine
        // Konsolen-Warnung) statt einen falschen Lernstand zu speichern.
    }

    private func stopEverythingAndClose() {
        stopEverything()
        dismiss()
    }

    private func restartSession() {
        cards = SpacedRepetition.ordered(cards)
        index = 0
        sessionResults = []
        statusText = "Bereit…"
        startLoop()
    }

    private func loadSubfolderOptions() async {
        var options: [Subfolder] = []
        if library.folders.isEmpty { await library.loadFolders() }
        for folder in library.folders {
            if library.subfolders(in: folder).isEmpty { await library.loadSubfolders(for: folder) }
            options.append(contentsOf: library.subfolders(in: folder))
        }
        subfolderOptions = options
        showSubfolderPicker = true
    }

    private func switchTo(subfolder: Subfolder) async {
        if library.flashcards(in: subfolder).isEmpty {
            await library.loadFlashcards(for: subfolder)
        }
        let newCards = library.flashcards(in: subfolder)
        guard !newCards.isEmpty else {
            library.errorMessage = "\"\(subfolder.name)\" hat noch keine Karteikarten."
            return
        }
        cards = SpacedRepetition.ordered(newCards)
        title = subfolder.name
        index = 0
        sessionResults = []
        statusText = "Bereit…"
        startLoop()
    }
}
