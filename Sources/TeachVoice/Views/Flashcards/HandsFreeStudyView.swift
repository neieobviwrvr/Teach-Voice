import SwiftUI

/// "Hands-free (Voice only)": rein sprachgesteuertes Lernmenü nach Simons
/// Konzept ("Konzipierung Hands-free Modus (only voice).txt") – primär
/// sprachgesteuert, GPT bewertet allein, aber NICHT ausschließlich blind:
///
/// 1. TTS begrüßt und zählt alle Unterordner nummeriert auf -- ALLE
///    Unterordner sind dabei GLEICHZEITIG als Buttons sichtbar/antippbar auf
///    dem Bildschirm (nicht erst als Fallback nach gescheiterter
///    Spracherkennung, siehe `selectSubfolderViaVoice`).
/// 2. Ansage läuft KOMPLETT durch, danach ein kurzer Signalton
///    (`SoundEffectPlayer.Effect.ready`) -- erst DANN startet das Zuhören.
///    Bewusst NICHT mehr während der Ansage gleichzeitig (kein "Barge-in"
///    mehr): ohne echte Echo-Unterdrückung ließ sich die eigene Stimme der
///    App nicht zuverlässig von Umgebungslärm (z.B. vorbeifahrende Autos)
///    unterscheiden, siehe Chat-Historie. Der Signalton ist das etablierte
///    Muster (Alexa, Siri, Telefon-Menüs): klar, wann man dran ist, statt
///    Rätselraten. Die Unterordner-Buttons bleiben trotzdem die GANZE Zeit
///    (Ansage + Zuhören) sichtbar/antippbar -- ein Tap geht immer sofort,
///    unabhängig vom Signalton.
/// 3. Bei Unklarheit einmal nachfragen, danach nur noch auf einen Tap warten
///    (die Buttons sind ja die ganze Zeit schon sichtbar) -- nie ein
///    kompletter Hänger.
/// 4. Lernschleife: Frage vorlesen -> Signalton -> automatische Aufnahme
///    (Stille-Erkennung) -> Transkription+Bewertung -> Ton (richtig/falsch;
///    "teilweise" bekommt bewusst KEINEN Ton, sondern 1 Extra-Sekunde
///    Stille) -> 2,5s Pause -> weiter
/// 5. Nach Durchlauf: TTS nennt die Statistik UND sie wird gleichzeitig sichtbar
///    angezeigt (ohne Buttons – Weiterlernen bleibt hier bewusst rein
///    sprachgesteuert), dann fragt die App per Ja/Nein, ob man weiterlernen
///    will; bei "ja" wieder Unterordner-Auswahl wie in 1-2, bei "nein"
///    automatisch zurück zum Homescreen
///
/// TTS wird IMMER sofort abgebrochen, sobald diese View verlassen wird
/// (Beenden-Button, Zurück-Navigation/Swipe -- siehe `.onDisappear` unten),
/// und über die app-weit geteilte `SpeechService`-Instanz kann es nie zwei
/// gleichzeitig hörbare Voice-Lines geben, auch nicht screen-übergreifend
/// (siehe `TeachVoiceApp`).
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
    // App-weit geteilte Instanz (siehe TeachVoiceApp) statt pro View neu
    // erzeugt -- garantiert, dass nie zwei Voice-Lines gleichzeitig hörbar
    // sind, auch nicht über Screen-Grenzen hinweg.
    @EnvironmentObject private var speech: SpeechService

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var soundPlayer = SoundEffectPlayer()

    @State private var statusText = "Bereit…"
    @State private var currentSubfolderName: String?
    @State private var currentQuestion: String?
    @State private var cardIndex = 0
    @State private var cardCount = 0
    @State private var lastVerdict: GradingResult.Urteil?
    @State private var lastAnswer: String?
    @State private var isListening = false

    @State private var sessionResults: [SessionResultEntry] = []
    @State private var showingSummary = false

    // Solange nicht leer, sind während der Unterordner-Auswahl ALLE Optionen
    // direkt auf dem Bildschirm sichtbar UND antippbar (Simons ausdrückliche
    // Vorgabe) -- nicht mehr nur als Popup-Fallback nach zwei erfolglosen
    // Sprachversuchen wie vorher. Ein Tap während gerade zugehört wird,
    // beendet die Aufnahme sofort (siehe `chooseViaButton`); ob am Ende
    // wirklich der getippte oder ein per Sprache erkannter Unterordner
    // gewinnt, entscheidet `announceSubfoldersAndListen` (Sprache hat
    // Vorrang, Button zählt nur als Fallback ohne verwertbaren Sprach-Treffer).
    @State private var visibleSubfolderOptions: [Subfolder] = []
    @State private var pendingButtonChoice: Subfolder?

    // Sichtbarer Fallback-Picker für den manuellen "Anderen Unterordner
    // wählen"-Button auf dem End-Screen (`presentVisualSubfolderPicker`) --
    // NICHT mehr für die Sprach-Erstauswahl gebraucht, seit die Unterordner
    // dafür jetzt durchgehend als Buttons sichtbar sind (s.o.). Derselbe
    // `subfolderPickerContinuation` wird auch von `chooseViaButton` aufgelöst,
    // falls gerade NUR auf einen Tap gewartet wird (letzter Schritt in
    // `selectSubfolderViaVoice`, nach zwei erfolglosen Sprachversuchen).
    @State private var showVisualSubfolderPicker = false
    @State private var subfolderPickerContinuation: CheckedContinuation<Subfolder?, Never>?
    /// Der Hintergrund-Task, der `announceSubfoldersAndListen` antreibt
    /// (Ansage -> Signalton -> Zuhören -> Transkription). Gewinnt stattdessen
    /// ein Tap während der Ansage (siehe `chooseViaButton`), wird dieser Task
    /// abgebrochen statt verwaist weiterzulaufen.
    @State private var announceListenTask: Task<Void, Never>?
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

                if let lastAnswer {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Musterantwort:").font(.caption).foregroundStyle(.secondary)
                        Text(flashcardMarkdown: lastAnswer).font(.caption)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !visibleSubfolderOptions.isEmpty {
                    subfolderOptionButtons
                }

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

    /// Alle Unterordner als direkt antippbare Buttons, parallel zur
    /// Sprachauswahl sichtbar (siehe `visibleSubfolderOptions`-Kommentar).
    private var subfolderOptionButtons: some View {
        VStack(spacing: 8) {
            ForEach(visibleSubfolderOptions) { option in
                Button(option.name) {
                    chooseViaButton(option)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Tap auf einen der sichtbaren Unterordner-Buttons -- verhält sich je
    /// nach Phase unterschiedlich (Simons ausdrückliche Vorgabe: Buttons
    /// sollen schon WÄHREND die Ansage noch läuft klickbar sein und sofort
    /// wirken, nicht erst nachdem der Satz zu Ende gesprochen wurde):
    /// 1. Während die Ansage noch läuft (`isListening == false`, aber eine
    ///    Auswahl steht noch aus): löst SOFORT auf -- es gibt hier noch
    ///    keine konkurrierende Spracheingabe, die Vorrang haben müsste.
    /// 2. Während aktiv zugehört wird (`isListening == true`): merkt sich
    ///    die Wahl nur als Fallback und beendet die Aufnahme sofort (statt
    ///    bis zum natürlichen Stille-Timeout zu warten) -- ein zeitgleicher
    ///    Sprach-Treffer behält weiterhin Vorrang (Simons ausdrückliche
    ///    Vorgabe von weiter oben im Chat).
    /// 3. Nach zwei erfolglosen Sprachversuchen (`waitForButtonTapOnly`,
    ///    kein aktives Zuhören mehr): löst ebenfalls sofort auf.
    private func chooseViaButton(_ subfolder: Subfolder) {
        pendingButtonChoice = subfolder
        if isListening {
            recorder.requestManualStop()
        } else {
            speech.stop()
            resolveAnnounceListen(subfolder)
        }
    }

    /// Löst eine laufende `announceSubfoldersAndListen`-Continuation auf UND
    /// bricht den zugehörigen Hintergrund-Task ab, falls er noch läuft --
    /// sonst würde der verwaist im Hintergrund weiterlaufen (noch die
    /// Ansage zu Ende abwarten, ggf. transkribieren) und am Ende versuchen,
    /// dieselbe längst aufgelöste Continuation ein zweites Mal zu bedienen.
    private func resolveAnnounceListen(_ subfolder: Subfolder?) {
        subfolderPickerContinuation?.resume(returning: subfolder)
        subfolderPickerContinuation = nil
        announceListenTask?.cancel()
        announceListenTask = nil
    }

    // MARK: - Sprachmenü-Ablauf

    private func runMenu() async {
        guard !subfolders.isEmpty else {
            statusText = "Keine Unterordner vorhanden."
            return
        }

        var chosen = await selectSubfolderViaVoice(greeting: "Hallo, welchen Unterordner willst du lernen?")
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

            chosen = await decideNextSubfolder(announcing: summary)
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
    /// `announcing` ist die Rundenzusammenfassung + "Willst du weiterlernen?"
    /// -- wird NICHT blockierend vorgelesen, siehe `askContinueViaVoice`.
    private func decideNextSubfolder(announcing summary: String) async -> Subfolder? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Subfolder?, Never>) in
            nextStepContinuation = continuation
            pendingContinueTask = Task {
                let wantsMore = await askContinueViaVoice(afterAnnouncing: summary)
                if Task.isCancelled { return }
                guard nextStepContinuation != nil else { return } // schon per Button aufgelöst
                if wantsMore {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    // Summary-Screen verlassen BEVOR die Auswahl beginnt --
                    // sonst wären die Unterordner-Buttons (nur im "else"-Zweig
                    // von `body` gerendert) unsichtbar, obwohl
                    // `visibleSubfolderOptions` intern schon gesetzt ist.
                    showingSummary = false
                    let subfolder = await selectSubfolderViaVoice(greeting: "Welchen Unterordner willst du lernen?")
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

    /// Zählt (in der Reihenfolge TTS beschreibt) alle Unterordner auf UND
    /// macht sie GLEICHZEITIG als Buttons sichtbar/antippbar (Simons
    /// ausdrückliche Vorgabe) -- nicht mehr nur als Popup-Fallback nach zwei
    /// erfolglosen Sprachversuchen. `greeting` wird der Aufzählung
    /// vorangestellt, als EINE zusammenhängende Ansage.
    private func selectSubfolderViaVoice(greeting: String) async -> Subfolder? {
        visibleSubfolderOptions = subfolders
        defer { visibleSubfolderOptions = [] }

        let listText = subfolders.enumerated()
            .map { index, subfolder in "\(index + 1)) \(subfolder.name)" }
            .joined(separator: ". ")
        let announcement = greeting.isEmpty ? listText : "\(greeting) \(listText)"

        if let subfolder = await announceSubfoldersAndListen(announcement) {
            return subfolder
        }
        if Task.isCancelled { return nil }

        if let subfolder = await announceSubfoldersAndListen(
            "Das habe ich nicht verstanden. Sag die Nummer oder den Namen noch einmal, oder tippe direkt auf einen Unterordner."
        ) {
            return subfolder
        }
        if Task.isCancelled { return nil }

        // Buttons sind die ganze Zeit sichtbar geblieben -- als letzter
        // Schritt nur noch auf einen Tap warten, ohne weiter zuzuhören.
        statusText = "Tippe auf einen Unterordner."
        return await waitForButtonTapOnly()
    }

    /// Ansage läuft KOMPLETT durch (die Unterordner-Buttons bleiben dabei
    /// die ganze Zeit sichtbar/antippbar), DANN ein kurzer Signalton, DANN
    /// erst startet das Zuhören -- bewusst kein gleichzeitiges
    /// Aufnehmen+Ansagen mehr (Simons Entscheidung, siehe Datei-Kopf-
    /// Kommentar: ohne echte Echo-Unterdrückung ließ sich die eigene Stimme
    /// der App nicht zuverlässig von Umgebungslärm unterscheiden).
    ///
    /// Ein Tap auf einen Unterordner-Button wirkt während der Ansage/dem
    /// Signalton SOFORT (siehe `chooseViaButton`, Fall 1) -- über eine
    /// Continuation, die parallel zum eigentlichen Ablauf läuft. WÄHREND
    /// aktiv zugehört wird, beendet ein Tap die Aufnahme nur vorzeitig,
    /// erzwingt die Auswahl aber NICHT sofort (`chooseViaButton`, Fall 2) --
    /// ein per Sprache erkannter Treffer behält dort weiterhin Vorrang
    /// (Simons ausdrückliche Vorgabe).
    private func announceSubfoldersAndListen(_ announcement: String) async -> Subfolder? {
        pendingButtonChoice = nil
        return await withCheckedContinuation { (continuation: CheckedContinuation<Subfolder?, Never>) in
            subfolderPickerContinuation = continuation
            announceListenTask = Task {
                await speech.speakAndWait(announcement)
                if Task.isCancelled { return }
                await soundPlayer.play(.ready)
                if Task.isCancelled { return }
                guard subfolderPickerContinuation != nil else { return } // schon per Tap aufgelöst

                statusText = "Höre zu…"
                isListening = true
                let recording = await recorder.recordUntilSilence(silenceTimeout: 3.0)
                isListening = false
                guard subfolderPickerContinuation != nil else { return } // während Zuhören per Tap aufgelöst
                if Task.isCancelled { return }

                var matched: Subfolder?
                // `lastRecordingDetectedSpeech` spart die Transkription (und
                // damit Latenz), wenn erkennbar gar nichts gesagt wurde --
                // z.B. weil der User nur einen Button getippt hat.
                if let recording, recorder.lastRecordingDetectedSpeech,
                   let text = await transcriber.transcribe(audioURL: recording), !text.isEmpty {
                    matched = SubfolderVoiceMatcher.match(transcript: text, options: subfolders)
                }

                resolveAnnounceListen(matched ?? pendingButtonChoice)
            }
        }
    }

    /// Letzter Schritt, falls Sprache zweimal nichts Verwertbares lieferte:
    /// die Unterordner-Buttons sind weiterhin sichtbar (siehe
    /// `visibleSubfolderOptions`), hier wird nur noch ohne aktives Zuhören
    /// auf einen Tap gewartet (aufgelöst von `chooseViaButton`).
    private func waitForButtonTapOnly() async -> Subfolder? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Subfolder?, Never>) in
            subfolderPickerContinuation = continuation
        }
    }

    private func presentVisualSubfolderPicker() async -> Subfolder? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Subfolder?, Never>) in
            subfolderPickerContinuation = continuation
            showVisualSubfolderPicker = true
        }
    }

    /// `announcement` (Rundenzusammenfassung + "Willst du weiterlernen?")
    /// läuft komplett durch, dann Signalton, dann erst Zuhören -- siehe
    /// `announceSubfoldersAndListen`-Kommentar für die Begründung.
    private func askContinueViaVoice(afterAnnouncing announcement: String) async -> Bool {
        if let answer = await announceAndListenYesNo(announcement) { return answer }
        if Task.isCancelled { return false }
        if let answer = await announceAndListenYesNo("Das habe ich nicht verstanden. Sag bitte ja oder nein.") { return answer }
        return await presentVisualYesNoPicker()
    }

    private func announceAndListenYesNo(_ announcement: String) async -> Bool? {
        await speech.speakAndWait(announcement)
        if Task.isCancelled { return nil }
        await soundPlayer.play(.ready)
        if Task.isCancelled { return nil }

        statusText = "Höre zu… (ja/nein)"
        isListening = true
        let url = await recorder.recordUntilSilence(silenceTimeout: 2.5)
        isListening = false

        if Task.isCancelled { return nil }
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
            lastAnswer = nil

            statusText = "Frage wird vorgelesen…"
            await speech.speakAndWait(FlashcardMarkdown.plainText(from: card.question))
            if Task.isCancelled { break }
            await soundPlayer.play(.ready)
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
            lastAnswer = card.answer

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
        AudioSessionCoordinator.deactivate()
        // Verwaiste Hintergrund-Tasks beenden, statt sie im Hintergrund weiter
        // TTS/Mikrofon benutzen zu lassen, obwohl der Modus gerade verlassen
        // wird ("Beenden"-Button, Zurück-Navigation via .onDisappear).
        pendingContinueTask?.cancel()
        pendingContinueTask = nil
        announceListenTask?.cancel()
        announceListenTask = nil
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
