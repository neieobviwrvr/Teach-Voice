import SwiftUI

/// Rein audio-getriebener Lernmodus: Frage wird vorgelesen, nach kurzer Pause
/// öffnet sich automatisch das Mikrofon, die Antwort wird aufgenommen bis der
/// User ~5 Sekunden am Stück still ist (kürzere Pausen gelten als bloßes
/// Nachdenken), automatisch transkribiert und bewertet – Ergebnis als kurzer
/// Ton + haptischer Puls (kein gesprochenes Feedback), dann sofort die
/// nächste Frage. Keine Buttons nötig außer optional zum vorzeitigen Beenden
/// bzw. zum manuellen Abgeben der Antwort.
///
/// Bewusst getrennt vom "Detail"-Lernmodus (`StudyView`): dort entscheidet
/// der User am Ende selbst (richtig/teilweise/falsch), hier automatisch per
/// GPT-Bewertung, weil man währenddessen ja nicht hinschauen/tippen soll.
/// Die Kartenreihenfolge folgt der Spaced-Repetition-Fälligkeit
/// (`SpacedRepetition.ordered`), nicht der ursprünglichen Karten-Reihenfolge.
struct HandsFreeStudyView: View {
    @State private var cards: [Flashcard]
    @State private var title: String

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcriber: WhisperTranscriber
    @Environment(\.dismiss) private var dismiss

    @StateObject private var speech = SpeechService()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var soundPlayer = SoundEffectPlayer()

    @State private var index = 0
    @State private var lastVerdict: Bool?
    @State private var statusText = "Bereit…"
    /// Solange true, wird gerade auf die Antwort gewartet – zeigt den
    /// "Lösung abgeben"-Fallback-Button für den Fall, dass die automatische
    /// Stille-Erkennung durch Umgebungslärm nicht zuverlässig auslöst.
    @State private var isListening = false
    @State private var sessionResults: [SessionResultEntry] = []
    @State private var showSubfolderPicker = false
    @State private var subfolderOptions: [Subfolder] = []

    /// Eigene, großzügigere Schwelle nur für das unmittelbare Ton-Feedback
    /// (statt der 65%/45%-Dreistufigkeit, die die Spaced-Repetition-Planung
    /// nutzt) – auf Wunsch bewusst bei 50%.
    private let handsFreeCorrectThreshold: Double = 50

    init(cards: [Flashcard], title: String = "Hands-free") {
        _cards = State(initialValue: SpacedRepetition.ordered(cards))
        _title = State(initialValue: title)
    }

    private var currentCard: Flashcard? {
        cards.indices.contains(index) ? cards[index] : nil
    }

    var body: some View {
        VStack(spacing: 24) {
            if let card = currentCard {
                Text("Karte \(index + 1) von \(cards.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(card.question)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                if let lastVerdict {
                    Image(systemName: lastVerdict ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(lastVerdict ? .green : .red)
                        .transition(.opacity)
                }

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

                Spacer()

                Button("Beenden", role: .destructive) {
                    stopEverythingAndClose()
                }
                .buttonStyle(.bordered)
            } else {
                SessionSummaryView(
                    results: sessionResults,
                    onRepeatSame: { restartSession() },
                    onPickDifferentSubfolder: { Task { await loadSubfolderOptions() } }
                )
            }
        }
        .padding()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await transcriber.prepareIfNeeded() }
        .task { await runLoop() }
        .onDisappear { stopEverything() }
        .alert("Mikrofonzugriff benötigt", isPresented: $recorder.permissionDenied) {
            Button("Zugriff erlauben") { MicrophonePermission.requestOrOpenSettings() }
            Button("Abbrechen", role: .cancel) { dismiss() }
        } message: {
            Text("Hands-free-Modus braucht Mikrofonzugriff, um deine Antworten zu erkennen.")
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

    private func runLoop() async {
        while !Task.isCancelled, cards.indices.contains(index) {
            guard let card = currentCard else { break }
            lastVerdict = nil

            statusText = "Frage wird vorgelesen…"
            await speech.speakAndWait(card.question)
            if Task.isCancelled { break }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { break }

            statusText = "Höre zu… (oder \"Lösung abgeben\" tippen)"
            isListening = true
            let url = await recorder.recordUntilSilence()
            isListening = false

            guard let url else {
                if recorder.permissionDenied {
                    statusText = "Mikrofonzugriff verweigert."
                    break
                }
                statusText = "Aufnahme fehlgeschlagen – weiter zur nächsten Frage."
                await soundPlayer.play(.failure)
                index += 1
                continue
            }
            if Task.isCancelled { break }

            statusText = "Transkribiere…"
            let text = await transcriber.transcribe(audioURL: url)
            if Task.isCancelled { break }

            guard let text, !text.isEmpty else {
                statusText = "Nichts verstanden – weiter zur nächsten Frage."
                await soundPlayer.play(.failure)
                index += 1
                continue
            }

            statusText = "Wird bewertet…"
            await gradeAndSignal(card: card, sttText: text)
            if Task.isCancelled { break }

            try? await Task.sleep(nanoseconds: 800_000_000)
            index += 1
        }

        if !Task.isCancelled {
            statusText = "Fertig!"
        }
    }

    private func gradeAndSignal(card: Flashcard, sttText: String) async {
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

            // Keine Selbsteinschätzung möglich (hands-free!) -> GPTs Deckung
            // ist die alleinige Signalquelle für die Spaced-Repetition-Planung,
            // gemappt auf dasselbe 3-Stufen-Schema wie im Detail-Modus.
            let srsUrteil = SpacedRepetition.urteil(fromDeckungProzent: result.deckungProzent)
            Task { await library.recordSpacedRepetitionOutcome(for: card, urteil: srsUrteil) }

            let isCorrect = result.deckungProzent >= handsFreeCorrectThreshold
            lastVerdict = isCorrect
            statusText = isCorrect ? "Richtig!" : "Leider falsch."
            HapticFeedback.play(for: isCorrect ? .richtig : .falsch)
            await soundPlayer.play(isCorrect ? .success : .failure)

            sessionResults.append(SessionResultEntry(
                question: card.question,
                isCorrect: isCorrect,
                label: isCorrect ? "Richtig" : "Falsch",
                percent: result.deckungProzent
            ))
        } catch {
            statusText = "Bewertung fehlgeschlagen."
            HapticFeedback.play(for: .falsch)
            await soundPlayer.play(.failure)
            sessionResults.append(SessionResultEntry(
                question: card.question,
                isCorrect: false,
                label: "Fehler",
                percent: 0
            ))
        }
    }

    private func stopEverything() {
        speech.stop()
        if recorder.isRecording { _ = recorder.stopRecording() }
    }

    private func stopEverythingAndClose() {
        stopEverything()
        dismiss()
    }

    private func restartSession() {
        cards = SpacedRepetition.ordered(cards)
        index = 0
        sessionResults = []
        lastVerdict = nil
        statusText = "Bereit…"
        Task { await runLoop() }
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
        lastVerdict = nil
        statusText = "Bereit…"
        Task { await runLoop() }
    }
}
