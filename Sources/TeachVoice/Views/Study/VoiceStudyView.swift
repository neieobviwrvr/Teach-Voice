import SwiftUI

/// Sprach-Modus (früher "Hands-free mit Eigenbewertung"): Frage wird
/// vorgelesen, das Mikrofon geht danach von selbst an, die KI prüft die
/// Kernthemen der Antwort, und man bewertet sich selbst mit Falsch/Teilweise/
/// Richtig. Die Selbsteinschätzung ist das Spaced-Repetition-Signal, die KI
/// schlägt sie anhand der Zielnote (Profil) nur vor.
///
/// Überarbeitet nach Simons Praxistest:
/// - Längere Denkpause: die Aufnahme endet erst nach `denkpause` Sekunden
///   Stille (vorher 3 s, da wurde man beim Nachdenken abgeschnitten). Wer
///   fertig ist, tippt "Fertig".
/// - Nach jeder Antwort, die nicht als richtig gilt, liest die App eine
///   KURZE richtige Antwort vor (`GradingResult.kurzloesung`, 1-2 Sätze).
/// - Wird nichts erkannt oder ist die KI nicht erreichbar, geht die Karte
///   nicht mehr verloren: man sieht die Musterantwort und bewertet selbst.
/// - Falsche Karten kommen in derselben Session wieder (`StudyQueue`).
struct VoiceStudyView: View {
    let request: StudySessionRequest

    /// Sekunden Stille NACH dem ersten Wort, bis die Aufnahme endet.
    private static let denkpause: TimeInterval = 8
    /// Sicherheitsnetz für die ganze Aufnahme (inkl. Nachdenken vor dem
    /// ersten Wort).
    private static let maxAufnahme: TimeInterval = 90

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcriber: WhisperTranscriber
    // App-weit geteilte Instanz (siehe TeachVoiceApp), damit nie zwei
    // Ansagen gleichzeitig laufen.
    @EnvironmentObject private var speech: SpeechService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var soundPlayer = SoundEffectPlayer()

    @State private var queue: StudyQueue
    @State private var zielnote = Zielnote.gespeichert
    @State private var phase: Phase = .vorbereiten
    /// Gesetzt, wenn die Vorbereitung (Mikrofon, Spracherkennung) scheitert.
    @State private var preparationError: String?
    @State private var feedback: Feedback?
    @State private var assessmentContinuation: CheckedContinuation<GradingResult.Urteil, Never>?
    /// Der Task, der `runLoop()` antreibt. `startLoop()` bricht einen alten
    /// immer zuerst ab, damit nie zwei Schleifen denselben Recorder teilen.
    @State private var loopTask: Task<Void, Never>?

    /// `vorbereiten`: Bevor die erste Frage kommt, ist alles bereit --
    /// Mikrofonzugriff geklärt, Spracherkennung geladen, Stimme für die
    /// ersten Fragen vorgeladen. Vorher startete der Ablauf sofort, und wer
    /// direkt nach dem App-Start lernte, bekam Stille, eine nicht
    /// verarbeitete Antwort und danach mehrere Ansagen auf einmal.
    private enum Phase {
        case vorbereiten, vorlesen, zuhoeren, transkribieren, bewerten, selbstbewertung, fertig
    }

    /// Wie viele kommende Fragen vor dem Start bzw. während des Antwortens
    /// schon als Audio vorgeladen werden.
    private static let vorladenAnzahl = 2
    /// Länger als so wartet die Vorbereitung nicht auf das Vorladen der
    /// Stimme (langsames Netz) -- dann wird die erste Frage eben normal geladen.
    private static let maxVorladeWartezeit: Double = 6

    /// Was nach einer Antwort angezeigt wird.
    private struct Feedback {
        let card: Flashcard
        /// Was Whisper verstanden hat (`nil`, wenn nichts erkannt wurde).
        let transcript: String?
        /// KI-Bewertung (`nil`, wenn nichts erkannt wurde oder die KI nicht
        /// erreichbar war – dann bewertet man nur anhand der Musterantwort).
        let result: GradingResult?
        let hinweis: String?
    }

    init(request: StudySessionRequest) {
        self.request = request
        let cards = request.nurFaellige
            ? SpacedRepetition.sessionCards(request.allCards)
            : SpacedRepetition.ordered(request.allCards)
        _queue = State(initialValue: StudyQueue(cards: cards))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let preparationError {
                    preparationFailedView(preparationError)
                } else if phase == .vorbereiten {
                    preparationView
                } else if queue.isFinished {
                    SessionSummaryView(
                        queue: queue,
                        onRepeatAll: { restartWithAllCards() },
                        onClose: { stopEverythingAndClose() }
                    )
                } else if let card = feedback?.card ?? queue.current {
                    questionHeader(card)
                    statusArea
                    if phase == .selbstbewertung, let feedback {
                        feedbackPanel(feedback)
                    }
                    Button("Beenden", role: .destructive) { stopEverythingAndClose() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { startLoop() }
        .onDisappear { stopEverything() }
        .alert("Mikrofonzugriff benötigt", isPresented: $recorder.permissionDenied) {
            Button("Zugriff erlauben") { MicrophonePermission.requestOrOpenSettings() }
            Button("Später", role: .cancel) {}
        } message: {
            Text("Ohne Mikrofonzugriff kann deine gesprochene Antwort nicht aufgenommen werden.")
        }
    }

    // MARK: - Ansicht

    private var preparationView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(preparationStatusText)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Beim allerersten Start lädt die App einmalig die Spracherkennung herunter. Das kann bis zu einer Minute dauern, danach geht es in Sekunden.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Abbrechen", role: .cancel) { stopEverythingAndClose() }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private var preparationStatusText: String {
        switch transcriber.state {
        case .ready, .transcribing:
            return "Stimme wird vorbereitet…"
        default:
            return "Spracherkennung wird geladen…"
        }
    }

    private func preparationFailedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
            Button {
                preparationError = nil
                startLoop()
            } label: {
                Text("Erneut versuchen").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button("Zurück") { stopEverythingAndClose() }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    private func questionHeader(_ card: Flashcard) -> some View {
        VStack(spacing: 12) {
            Text(queue.progressText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            // Kein pauschales .bold(): sonst geht die im Editor gesetzte
            // Fett-Markierung unter.
            Text(flashcardMarkdown: card.question)
                .font(.title2)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @ViewBuilder
    private var statusArea: some View {
        switch phase {
        case .vorbereiten, .vorlesen:
            Label("Frage wird vorgelesen…", systemImage: "speaker.wave.2")
                .foregroundStyle(.secondary)
        case .zuhoeren:
            VStack(spacing: 10) {
                Label("Ich höre zu – lass dir Zeit", systemImage: "mic.fill")
                    .foregroundStyle(.red)
                Text("Die Aufnahme endet nach \(Int(Self.denkpause)) Sekunden Stille. Bist du fertig oder weißt es nicht, tipp auf Fertig.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    recorder.requestManualStop()
                } label: {
                    Label("Fertig", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .transkribieren:
            ProgressView("Antwort wird erkannt…")
        case .bewerten:
            ProgressView("KI prüft die Kernthemen…")
        case .selbstbewertung, .fertig:
            EmptyView()
        }
    }

    @ViewBuilder
    private func feedbackPanel(_ feedback: Feedback) -> some View {
        let vorschlag = feedback.result.map { zielnote.urteil(fromDeckungProzent: $0.deckungProzent) }
        let kurzloesung = feedback.result?.kurzloesung?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        VStack(alignment: .leading, spacing: 14) {
            if let hinweis = feedback.hinweis {
                Label(hinweis, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let result = feedback.result, let vorschlag {
                // Als String gebaut (nicht als LocalizedStringKey-Literal),
                // damit das "%" nie als Format-Platzhalter gelesen wird.
                let info = "\(Int(result.deckungProzent.rounded())) % der Kontrollpunkte getroffen · KI-Vorschlag bei Zielnote \(zielnote.anzeige): \(vorschlag.label)"
                Text(info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !kurzloesung.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Kurz gesagt").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            speech.speak(kurzloesung)
                        } label: {
                            Label("Vorlesen", systemImage: "speaker.wave.2.fill")
                                .font(.caption)
                        }
                    }
                    Text(kurzloesung)
                        .font(.title3)
                }
            }

            if let punkte = feedback.result?.punkte, !punkte.isEmpty {
                kontrollpunkteListe(punkte)
            } else if let fehlend = feedback.result?.fehlendeElemente, !fehlend.isEmpty {
                // Ältere Server-Version ohne Einzelurteile.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gefehlt hat").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(fehlend, id: \.self) { element in
                        Label(element, systemImage: "circle").font(.caption)
                    }
                }
            }

            if kurzloesung.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Musterantwort").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(flashcardMarkdown: feedback.card.answer)
                }
            } else {
                DisclosureGroup("Ganze Musterantwort") {
                    Text(flashcardMarkdown: feedback.card.answer)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)
            }

            if let transcript = feedback.transcript {
                Text("Erkannt: \(transcript)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text("Wie war deine Antwort?")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                assessmentButton(.falsch, vorschlag: vorschlag, card: feedback.card)
                assessmentButton(.teilweise, vorschlag: vorschlag, card: feedback.card)
                assessmentButton(.richtig, vorschlag: vorschlag, card: feedback.card)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Checkliste aller Kontrollpunkte mit dem Einzelurteil der KI -- so ist
    /// nachvollziehbar, woher die Prozentzahl kommt.
    private func kontrollpunkteListe(_ punkte: [GradingResult.Punkt]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kontrollpunkte").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(punkte.enumerated()), id: \.offset) { _, punkt in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: punkt.status.symbol)
                        .foregroundStyle(punkt.status.color)
                    Text(punkt.text)
                        .font(.caption)
                        .foregroundStyle(punkt.status == .getroffen ? Color.secondary : Color.primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(punkt.status.accessibilityText): \(punkt.text)")
            }
        }
    }

    /// Der von der KI vorgeschlagene Button ist gefüllt, die anderen nur
    /// umrandet – ein Tap auf irgendeinen zählt.
    @ViewBuilder
    private func assessmentButton(_ urteil: GradingResult.Urteil, vorschlag: GradingResult.Urteil?, card: Flashcard) -> some View {
        let button = Button {
            assess(urteil)
        } label: {
            VStack(spacing: 2) {
                Text(urteil.label)
                // Wann FSRS die Karte bei dieser Bewertung wieder zeigt.
                Text(library.nextReviewLabel(for: queue.current ?? card, urteil: urteil))
                    .font(.caption2)
                    .opacity(0.85)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(urteil.color)
        .controlSize(.large)

        if vorschlag == nil || vorschlag == urteil {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    // MARK: - Ablauf

    private func runLoop() async {
        guard await prepare(), !Task.isCancelled else { return }

        while !Task.isCancelled, let card = queue.current {
            feedback = nil
            phase = .vorlesen
            await speech.speakAndWait(spokenQuestion(card))
            if Task.isCancelled { return }
            await soundPlayer.play(.ready)
            if Task.isCancelled { return }

            // Während der User antwortet, schon die nächsten Fragen als
            // Audio holen -- dann startet die nächste Ansage ohne Pause.
            let upcoming = queue.upcoming(Self.vorladenAnzahl + 1).dropFirst().map(spokenQuestion)
            Task { await speech.prefetch(Array(upcoming)) }

            // Sicherheitsnetz: nie aufnehmen, solange noch etwas vorgelesen wird.
            speech.stop()
            phase = .zuhoeren
            let url = await recorder.recordUntilSilence(silenceTimeout: Self.denkpause, maxDuration: Self.maxAufnahme)
            if Task.isCancelled || recorder.permissionDenied { return }

            var transcript: String?
            if let url {
                phase = .transkribieren
                transcript = await transcriber.transcribe(audioURL: url)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if Task.isCancelled { return }
            }

            let newFeedback: Feedback
            if let transcript, !transcript.isEmpty {
                phase = .bewerten
                newFeedback = await grade(card: card, transcript: transcript)
                if Task.isCancelled { return }
            } else {
                newFeedback = Feedback(
                    card: card, transcript: nil, result: nil,
                    hinweis: "Keine Antwort erkannt – hier ist die Musterantwort."
                )
            }

            let urteil = await waitForSelfAssessment(newFeedback)
            // Beim Verlassen der Ansicht wird die offene Bewertung nur
            // aufgelöst, damit der Task endet -- dann NICHTS speichern.
            if Task.isCancelled { return }

            // Gleicher Zeitpunkt und Prüfungstermin für Runde und Speichern,
            // damit beide exakt denselben FSRS-Zustand berechnen.
            let now = Date()
            queue.record(urteil, percent: newFeedback.result?.deckungProzent, now: now, examDate: library.examDate(for: card))
            await library.recordSpacedRepetitionOutcome(for: card, urteil: urteil, now: now)
        }

        if !Task.isCancelled, queue.isFinished {
            feedback = nil
            phase = .fertig
            await speech.speakAndWait(summarySentence())
        }
    }

    /// Macht vor der ersten Frage alles startklar und zeigt solange die
    /// Vorbereitungs-Ansicht: Mikrofonzugriff klären, Spracherkennung laden
    /// (beim ersten App-Start inkl. Download), die ersten Fragen als Audio
    /// vorladen. Liefert `false`, wenn es ohne Mikrofon oder Spracherkennung
    /// nicht weitergeht (`preparationError` erklärt dann warum).
    private func prepare() async -> Bool {
        phase = .vorbereiten
        preparationError = nil

        // Stimme parallel vorladen, während Mikrofon und Whisper geklärt werden.
        let firstQuestions = queue.upcoming(Self.vorladenAnzahl).map(spokenQuestion)
        let prefetchTask = Task { await speech.prefetch(firstQuestions) }

        guard await recorder.requestPermission() else {
            prefetchTask.cancel()
            recorder.permissionDenied = true
            preparationError = "Ohne Mikrofonzugriff kann der Sprach-Modus deine Antwort nicht hören. Erlaube den Zugriff in den Einstellungen oder lerne im Tipp-Modus."
            return false
        }
        if Task.isCancelled { return false }

        await transcriber.prepareIfNeeded()
        if Task.isCancelled { return false }
        if case .failed = transcriber.state {
            prefetchTask.cancel()
            preparationError = "Die Spracherkennung konnte nicht geladen werden. Prüfe deine Internetverbindung (nur beim ersten Mal nötig) und versuche es erneut."
            return false
        }

        await waitAtMost(Self.maxVorladeWartezeit, for: prefetchTask)
        return !Task.isCancelled
    }

    /// Wartet auf `task`, aber höchstens `seconds` Sekunden. Der Task selbst
    /// läuft danach im Hintergrund weiter.
    private func waitAtMost(_ seconds: Double, for task: Task<Void, Never>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Genau der Text, der vorgelesen wird -- muss für Vorladen und Ansage
    /// identisch sein, sonst greift der Audio-Cache nicht.
    private func spokenQuestion(_ card: Flashcard) -> String {
        FlashcardMarkdown.plainText(from: card.question)
    }

    private func grade(card: Flashcard, transcript: String) async -> Feedback {
        // Kernelemente-Cache aus dem aktuellen Stand der Karte lesen: die
        // Kopie in der Warteschlange kennt einen in dieser Session gerade erst
        // gespeicherten Cache noch nicht (sonst zahlt jede Wiederholung die
        // Extraktion erneut).
        let cacheSource = library.currentVersion(of: card) ?? card
        let currentHash = TextHash.sha256(card.answer)
        let cacheStillValid = cacheSource.kernelementeSourceHash == currentHash

        do {
            let token = await auth.validAccessToken()
            let (kernelemente, result) = try await GradingService.grade(
                question: card.question,
                answer: card.answer,
                cachedKernelemente: cacheStillValid ? cacheSource.kernelemente : nil,
                sttText: transcript,
                accessToken: token
            )
            if !cacheStillValid {
                await library.cacheKernelemente(kernelemente, for: cacheSource, sourceHash: currentHash)
            }
            return Feedback(card: card, transcript: transcript, result: result, hinweis: nil)
        } catch {
            return Feedback(
                card: card, transcript: transcript, result: nil,
                hinweis: "KI-Bewertung gerade nicht erreichbar – vergleiche selbst mit der Musterantwort."
            )
        }
    }

    /// Zeigt das Feedback, liest bei nicht-richtiger Antwort die Kurzlösung
    /// vor und wartet auf den Tap auf Falsch/Teilweise/Richtig.
    private func waitForSelfAssessment(_ newFeedback: Feedback) async -> GradingResult.Urteil {
        feedback = newFeedback
        phase = .selbstbewertung

        if let result = newFeedback.result {
            let kurzloesung = result.kurzloesung?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if zielnote.urteil(fromDeckungProzent: result.deckungProzent) != .richtig, !kurzloesung.isEmpty {
                // Bewusst nicht abwarten: die Buttons sind sofort antippbar,
                // ein Tap bricht das Vorlesen ab.
                speech.speak(kurzloesung)
            } else {
                HapticFeedback.play(for: .richtig)
            }
        } else if newFeedback.transcript == nil {
            speech.speak("Keine Antwort erkannt.")
        }

        return await withCheckedContinuation { continuation in
            assessmentContinuation = continuation
        }
    }

    private func assess(_ urteil: GradingResult.Urteil) {
        speech.stop()
        HapticFeedback.play(for: urteil)
        assessmentContinuation?.resume(returning: urteil)
        assessmentContinuation = nil
    }

    private func summarySentence() -> String {
        let clause = StudySessionSummarySpeech.statsClause(
            richtig: queue.count(of: .richtig),
            teilweise: queue.count(of: .teilweise),
            falsch: queue.count(of: .falsch)
        )
        guard let clause else { return "Fertig!" }
        return "Fertig! Auf Anhieb hast du \(clause) beantwortet."
    }

    // MARK: - Steuerung

    private func startLoop() {
        loopTask?.cancel()
        loopTask = Task { await runLoop() }
    }

    private func stopEverything() {
        loopTask?.cancel()
        loopTask = nil
        speech.stop()
        if recorder.isRecording { _ = recorder.stopRecording() }
        AudioSessionCoordinator.deactivate()
        // Offene Bewertung auflösen, damit der abgebrochene Task endet. Weil
        // der Task schon gecancelt ist, speichert `runLoop` dafür nichts.
        assessmentContinuation?.resume(returning: .falsch)
        assessmentContinuation = nil
    }

    private func stopEverythingAndClose() {
        stopEverything()
        dismiss()
    }

    private func restartWithAllCards() {
        stopEverything()
        let fresh = request.allCards.compactMap { library.currentVersion(of: $0) }
        queue = StudyQueue(cards: SpacedRepetition.ordered(fresh))
        feedback = nil
        phase = .vorbereiten
        startLoop()
    }
}

extension GradingResult.Punkt.Status {
    var symbol: String {
        switch self {
        case .getroffen: return "checkmark.circle.fill"
        case .teilweise: return "circle.lefthalf.filled"
        case .fehlt: return "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .getroffen: return .green
        case .teilweise: return .orange
        case .fehlt: return .red
        }
    }

    var accessibilityText: String {
        switch self {
        case .getroffen: return "Getroffen"
        case .teilweise: return "Teilweise"
        case .fehlt: return "Fehlt"
        }
    }
}

extension GradingResult.Urteil {
    var label: String {
        switch self {
        case .richtig: return "Richtig"
        case .teilweise: return "Teilweise"
        case .falsch: return "Falsch"
        }
    }

    var color: Color {
        switch self {
        case .richtig: return .green
        case .teilweise: return .orange
        case .falsch: return .red
        }
    }
}
