import SwiftUI

/// "Hands-free (Voice only)": rein sprachgesteuertes Lernmenü nach Simons
/// Konzept ("Konzipierung Hands-free Modus (only voice).txt") – komplett
/// automatisch, GPT bewertet allein, kein Antippen nötig (außer optional zum
/// Beenden oder als Absicherung, falls Spracherkennung mal nicht klappt):
///
/// 1. TTS begrüßt und fragt, welchen Unterordner man lernen will
/// 2. TTS zählt alle Unterordner nummeriert auf
/// 3. Mikrofon hört Zahl oder Name -> lokaler Abgleich (`SubfolderVoiceMatcher`),
///    bei Unklarheit einmal nachfragen, danach sichtbares Auswahl-Pop-up als
///    Fallback (nie ein kompletter Hänger)
/// 4. Lernschleife: Frage vorlesen -> automatische Aufnahme (Stille-Erkennung)
///    -> Transkription+Bewertung -> Ton (richtig/falsch; "teilweise" bekommt
///    bewusst KEINEN Ton, sondern 1 Extra-Sekunde Stille) -> 2,5s Pause -> weiter
/// 5. Nach Durchlauf: TTS nennt die Statistik UND sie wird gleichzeitig sichtbar
///    angezeigt (ohne Buttons – Weiterlernen bleibt hier bewusst rein
///    sprachgesteuert), dann fragt die App per Ja/Nein, ob man weiterlernen
///    will; bei "ja" wieder Unterordner-Auswahl wie in 2-3, bei "nein"
///    automatisch zurück zum Homescreen
///
/// Für die zweite Variante mit Selbsteinschätzungs-Buttons pro Frage siehe
/// `HandsFreeSelfAssessmentStudyView` ("Hands-free lernen (Eigenbewertung)") –
/// bewusst eine eigene View, da dieser Modus wegen der ohnehin nötigen Taps
/// eher zum sichtbaren Pop-up-Ablauf als zum Sprachmenü passt.
struct HandsFreeStudyView: View {
    let subfolders: [Subfolder]
    let strictness: GradingStrictness

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcriber: WhisperTranscriber
    @Environment(\.dismiss) private var dismiss

    @StateObject private var speech = SpeechService()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var soundPlayer = SoundEffectPlayer()

    @State private var statusText = "Bereit…"
    @State private var currentSubfolderName: String?
    @State private var currentQuestion: String?
    @State private var cardIndex = 0
    @State private var cardCount = 0
    @State private var lastVerdict: GradingResult.Urteil?
    @State private var isListening = false

    @State private var sessionResults: [SessionResultEntry] = []
    @State private var showingSummary = false

    // Sichtbarer Fallback-Picker, falls Sprache zweimal nicht erkannt wird –
    // UND gleichzeitig der Weg für den manuellen "Anderen Unterordner
    // wählen"-Button auf dem End-Screen (derselbe Picker, zwei Auslöser).
    @State private var showVisualSubfolderPicker = false
    @State private var subfolderPickerContinuation: CheckedContinuation<Subfolder?, Never>?
    @State private var showVisualYesNoFallback = false
    @State private var yesNoContinuation: CheckedContinuation<Bool, Never>?

    /// Löst die "was kommt nach dieser Runde"-Entscheidung auf – entweder
    /// durch den sprachgesteuerten Ablauf (Ja/Nein + Unterordner-Auswahl) ODER
    /// durch den manuellen "Anderen Unterordner wählen"-Button auf dem
    /// End-Screen, je nachdem was zuerst eintrifft.
    @State private var nextStepContinuation: CheckedContinuation<Subfolder?, Never>?
    /// Der Hintergrund-Task, der den sprachgesteuerten "weiterlernen?"-Ablauf
    /// aus `decideNextSubfolder()` antreibt. Gewinnt stattdessen der manuelle
    /// Button (oder wird der Modus verlassen), wird dieser Task explizit
    /// abgebrochen statt verwaist weiterzulaufen – sonst würde er im
    /// Hintergrund weiter TTS/Mikrofon benutzen, während längst der nächste
    /// Unterordner/die nächste Frage denselben Recorder braucht.
    @State private var pendingContinueTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 24) {
            if showingSummary {
                SessionSummaryView(
                    results: sessionResults,
                    onPickDifferentSubfolder: {
                        Task {
                            if let subfolder = await presentVisualSubfolderPicker() {
                                resolveNextStep(subfolder)
                            }
                        }
                    }
                )
                Button("Zurück zum Homescreen") { stopEverythingAndClose() }
                    .buttonStyle(.borderedProminent)
            } else {
                if let currentSubfolderName {
                    Text(currentSubfolderName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if cardCount > 0 {
                        Text("Karte \(cardIndex) von \(cardCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let currentQuestion {
                    // Kein pauschales .bold() – sonst geht die manuell im
                    // Editor gesetzte Fett-Markierung unter (siehe StudyView).
                    Text(flashcardMarkdown: currentQuestion)
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                if let lastVerdict {
                    Image(systemName: verdictIcon(lastVerdict))
                        .font(.system(size: 48))
                        .foregroundStyle(verdictColor(lastVerdict))
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
            }

            Button("Beenden", role: .destructive) {
                stopEverythingAndClose()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .navigationTitle("Hands-free (Voice only)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await transcriber.prepareIfNeeded() }
        .task { await runMenu() }
        .onDisappear { stopEverything() }
        .alert("Mikrofonzugriff benötigt", isPresented: $recorder.permissionDenied) {
            Button("Zugriff erlauben") { MicrophonePermission.requestOrOpenSettings() }
            Button("Abbrechen", role: .cancel) { dismiss() }
        } message: {
            Text("Hands-free-Modus braucht Mikrofonzugriff, um deine Antworten zu erkennen.")
        }
        .confirmationDialog("Unterordner wählen", isPresented: $showVisualSubfolderPicker, titleVisibility: .visible) {
            ForEach(subfolders) { option in
                Button(option.name) {
                    subfolderPickerContinuation?.resume(returning: option)
                    subfolderPickerContinuation = nil
                }
            }
            Button("Abbrechen", role: .cancel) {
                subfolderPickerContinuation?.resume(returning: nil)
                subfolderPickerContinuation = nil
            }
        } message: {
            Text("Deine Spracheingabe konnte nicht eindeutig zugeordnet werden.")
        }
        .confirmationDialog("Weiterlernen?", isPresented: $showVisualYesNoFallback, titleVisibility: .visible) {
            Button("Ja, weiterlernen") {
                yesNoContinuation?.resume(returning: true)
                yesNoContinuation = nil
            }
            Button("Nein, beenden", role: .cancel) {
                yesNoContinuation?.resume(returning: false)
                yesNoContinuation = nil
            }
        }
    }

    // MARK: - Sprachmenü-Ablauf

    private func runMenu() async {
        guard !subfolders.isEmpty else {
            statusText = "Keine Unterordner vorhanden."
            return
        }

        await speech.speakAndWait("Hallo, welchen Unterordner willst du lernen?")
        if Task.isCancelled { return }

        var chosen = await selectSubfolderViaVoice()
        while let subfolder = chosen, !Task.isCancelled {
            showingSummary = false
            sessionResults = []
            let stats = await studyLoop(subfolder: subfolder)
            if Task.isCancelled { return }

            // Statistik gleichzeitig anzeigen (sichtbar, ohne Buttons) UND vorlesen.
            showingSummary = true
            let statsClause = StudySessionSummarySpeech.statsClause(
                richtig: stats.richtig, teilweise: stats.teilweise, falsch: stats.falsch
            )
            let summary: String
            if let statsClause {
                summary = "Du hast das Deck vollständig gelernt und davon \(statsClause) beantwortet. "
                    + "Willst du einen anderen Unterordner lernen?"
            } else {
                summary = "Du hast das Deck vollständig gelernt. Willst du einen anderen Unterordner lernen?"
            }
            await speech.speakAndWait(summary)
            if Task.isCancelled { return }

            chosen = await decideNextSubfolder()
            if Task.isCancelled { return }
            guard chosen != nil else {
                dismiss()
                return
            }
            showingSummary = false
        }
    }

    /// Wartet auf die "was kommt als Nächstes"-Entscheidung – entweder über
    /// den normalen Sprachablauf (Ja/Nein, dann Unterordner nennen) oder,
    /// falls der User stattdessen den "Anderen Unterordner wählen"-Button auf
    /// dem End-Screen tippt, direkt darüber. Was zuerst eintrifft, gewinnt.
    private func decideNextSubfolder() async -> Subfolder? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Subfolder?, Never>) in
            nextStepContinuation = continuation
            pendingContinueTask = Task {
                let wantsMore = await askContinueViaVoice()
                if Task.isCancelled { return }
                guard nextStepContinuation != nil else { return } // schon per Button aufgelöst
                if wantsMore {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    await speech.speakAndWait("Welchen Unterordner willst du lernen?")
                    if Task.isCancelled { return }
                    let subfolder = await selectSubfolderViaVoice()
                    resolveNextStep(subfolder)
                } else {
                    resolveNextStep(nil)
                }
            }
        }
    }

    /// Löst die Entscheidung auf UND beendet – falls noch aktiv – die
    /// sprachgesteuerte Gegenseite. Wird das vom Sprachablauf selbst
    /// aufgerufen, ist das Abbrechen ein No-Op (der Task ist ja gerade dabei,
    /// sich selbst zu beenden); gewinnt stattdessen ein manueller Button,
    /// stoppt es zuverlässig den sonst verwaist weiterlaufenden Sprach-Task.
    private func resolveNextStep(_ subfolder: Subfolder?) {
        nextStepContinuation?.resume(returning: subfolder)
        nextStepContinuation = nil
        pendingContinueTask?.cancel()
        pendingContinueTask = nil
    }

    /// Zählt (in der Reihenfolge TTS_2 beschreibt) alle Unterordner auf,
    /// hört per Sprache zu, versucht bei Unklarheit einmal erneut, und
    /// fällt danach auf das sichtbare Pop-up zurück statt zu hängen.
    private func selectSubfolderViaVoice() async -> Subfolder? {
        let listText = subfolders.enumerated()
            .map { index, subfolder in "\(index + 1)) \(subfolder.name)" }
            .joined(separator: ". ")
        await speech.speakAndWait(listText)
        if Task.isCancelled { return nil }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        if let match = await listenAndMatchSubfolder() {
            return match
        }
        await speech.speakAndWait("Das habe ich nicht verstanden. Bitte sag die Nummer oder den Namen des Unterordners noch einmal.")
        if Task.isCancelled { return nil }
        if let match = await listenAndMatchSubfolder() {
            return match
        }
        return await presentVisualSubfolderPicker()
    }

    private func listenAndMatchSubfolder() async -> Subfolder? {
        statusText = "Höre zu…"
        isListening = true
        let url = await recorder.recordUntilSilence(silenceTimeout: 3.0)
        isListening = false
        guard let url else { return nil }
        guard let text = await transcriber.transcribe(audioURL: url), !text.isEmpty else { return nil }
        return SubfolderVoiceMatcher.match(transcript: text, options: subfolders)
    }

    private func presentVisualSubfolderPicker() async -> Subfolder? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Subfolder?, Never>) in
            subfolderPickerContinuation = continuation
            showVisualSubfolderPicker = true
        }
    }

    private func askContinueViaVoice() async -> Bool {
        if let answer = await listenAndMatchYesNo() { return answer }
        await speech.speakAndWait("Das habe ich nicht verstanden. Sag bitte ja oder nein.")
        if Task.isCancelled { return false }
        if let answer = await listenAndMatchYesNo() { return answer }
        return await presentVisualYesNoPicker()
    }

    private func listenAndMatchYesNo() async -> Bool? {
        statusText = "Höre zu… (ja/nein)"
        isListening = true
        let url = await recorder.recordUntilSilence(silenceTimeout: 2.5)
        isListening = false
        guard let url else { return nil }
        guard let text = await transcriber.transcribe(audioURL: url), !text.isEmpty else { return nil }
        return SubfolderVoiceMatcher.matchYesNo(transcript: text)
    }

    private func presentVisualYesNoPicker() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            yesNoContinuation = continuation
            showVisualYesNoFallback = true
        }
    }

    // MARK: - Lernschleife für einen Unterordner

    private func studyLoop(subfolder: Subfolder) async -> (richtig: Int, teilweise: Int, falsch: Int) {
        currentSubfolderName = subfolder.name
        if library.flashcards(in: subfolder).isEmpty {
            await library.loadFlashcards(for: subfolder)
        }
        let cards = SpacedRepetition.ordered(library.flashcards(in: subfolder))
        cardCount = cards.count
        guard !cards.isEmpty else {
            statusText = "Dieser Unterordner hat keine Karteikarten."
            return (0, 0, 0)
        }

        var richtig = 0, teilweise = 0, falsch = 0

        for (index, card) in cards.enumerated() {
            if Task.isCancelled { break }
            cardIndex = index + 1
            currentQuestion = card.question
            lastVerdict = nil

            statusText = "Frage wird vorgelesen…"
            await speech.speakAndWait(FlashcardMarkdown.plainText(from: card.question))
            if Task.isCancelled { break }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { break }

            statusText = "Höre zu… (oder \"Lösung abgeben\" tippen)"
            isListening = true
            let url = await recorder.recordUntilSilence()
            isListening = false

            guard let url else {
                if recorder.permissionDenied { break }
                statusText = "Aufnahme fehlgeschlagen – weiter zur nächsten Frage."
                falsch += 1
                sessionResults.append(SessionResultEntry(question: card.question, isCorrect: false, label: "Fehler", percent: 0))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            if Task.isCancelled { break }

            statusText = "Transkribiere…"
            let text = await transcriber.transcribe(audioURL: url)
            if Task.isCancelled { break }

            guard let text, !text.isEmpty else {
                statusText = "Nichts verstanden – weiter zur nächsten Frage."
                falsch += 1
                sessionResults.append(SessionResultEntry(question: card.question, isCorrect: false, label: "Nicht verstanden", percent: 0))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            statusText = "Wird bewertet…"
            guard let urteil = await gradeAndResolve(card: card, sttText: text) else { continue }

            switch urteil {
            case .richtig: richtig += 1
            case .teilweise: teilweise += 1
            case .falsch: falsch += 1
            }

            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }

        return (richtig, teilweise, falsch)
    }

    /// Bewertet die Antwort und löst Ton/Vibration/SRS aus. `nil` heißt:
    /// Fehler, Karte wird übersprungen, keine Zählung.
    private func gradeAndResolve(card: Flashcard, sttText: String) async -> GradingResult.Urteil? {
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

            let urteil = strictness.urteil(fromDeckungProzent: result.deckungProzent)
            Task { await library.recordSpacedRepetitionOutcome(for: card, urteil: urteil) }
            HapticFeedback.play(for: urteil)
            lastVerdict = urteil

            sessionResults.append(SessionResultEntry(
                question: card.question,
                isCorrect: urteil == .richtig,
                label: verdictLabel(urteil),
                percent: result.deckungProzent
            ))

            switch urteil {
            case .richtig:
                statusText = "Richtig!"
                await soundPlayer.play(.success)
            case .falsch:
                statusText = "Leider falsch."
                await soundPlayer.play(.failure)
            case .teilweise:
                // Bewusst kein Ton – stattdessen 1 Extra-Sekunde Stille.
                statusText = "Teilweise richtig."
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            return urteil
        } catch {
            statusText = "Bewertung fehlgeschlagen."
            HapticFeedback.play(for: .falsch)
            await soundPlayer.play(.failure)
            return nil
        }
    }

    // MARK: - Hilfsfunktionen

    private func verdictLabel(_ urteil: GradingResult.Urteil) -> String {
        switch urteil {
        case .richtig: return "Richtig"
        case .teilweise: return "Teilweise richtig"
        case .falsch: return "Falsch"
        }
    }

    private func verdictIcon(_ urteil: GradingResult.Urteil) -> String {
        switch urteil {
        case .richtig: return "checkmark.circle.fill"
        case .teilweise: return "circle.lefthalf.filled"
        case .falsch: return "xmark.circle.fill"
        }
    }

    private func verdictColor(_ urteil: GradingResult.Urteil) -> Color {
        switch urteil {
        case .richtig: return .green
        case .teilweise: return .orange
        case .falsch: return .red
        }
    }

    private func stopEverything() {
        speech.stop()
        if recorder.isRecording { _ = recorder.stopRecording() }
        // Verwaisten Sprach-Task beenden, statt ihn im Hintergrund weiter TTS/
        // Mikrofon benutzen zu lassen, obwohl der Modus gerade verlassen wird
        // ("Beenden"-Button, Zurück-Navigation via .onDisappear).
        pendingContinueTask?.cancel()
        pendingContinueTask = nil
        // Offene Continuations nicht verwaist lassen (sonst nur eine
        // Konsolen-Warnung, aber sauberer, sie definiert aufzulösen).
        nextStepContinuation?.resume(returning: nil)
        nextStepContinuation = nil
        subfolderPickerContinuation?.resume(returning: nil)
        subfolderPickerContinuation = nil
        yesNoContinuation?.resume(returning: false)
        yesNoContinuation = nil
    }

    private func stopEverythingAndClose() {
        stopEverything()
        dismiss()
    }
}
