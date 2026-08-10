import SwiftUI

struct StudyView: View {
    let subfolder: Subfolder
    let cards: [Flashcard]

    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore
    // Geteilt über die ganze App-Sitzung (siehe TeachVoiceApp) statt pro
    // StudyView neu erzeugt – sonst würde das Whisper-Modell bei jedem
    // "Lernen starten" erneut vorbereitet/heruntergeladen.
    @EnvironmentObject private var transcriber: WhisperTranscriber

    @StateObject private var speech = SpeechService()
    @StateObject private var recorder = AudioRecorder()

    @State private var index = 0
    @State private var transcribedAnswer: String?
    @State private var isTranscribing = false
    @State private var isGrading = false
    @State private var gradingResult: GradingResult?
    @State private var gradingError: String?
    /// Der User hat immer das letzte Wort: die KI-Bewertung ist nur eine
    /// Einschätzung/Hilfestellung, vorbelegt mit ihrem Urteil, aber frei
    /// überschreibbar. Noch nicht persistiert – reine In-Session-Bestätigung,
    /// bis es eine Fortschritts-/Wiederholungs-Funktion gibt, die das braucht.
    @State private var selfAssessment: GradingResult.Urteil?

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

                    VStack(spacing: 12) {
                        Text(card.question)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Button {
                            speech.speak(card.question)
                        } label: {
                            Label(speech.isSpeaking ? "Spielt ab…" : "Frage nochmal vorlesen", systemImage: "speaker.wave.2.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                    whisperStatusView

                    recordButton

                    if let transcribedAnswer {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Deine Antwort:").font(.caption).foregroundStyle(.secondary)
                            Text(transcribedAnswer)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }

                    if isTranscribing {
                        ProgressView("Transkribiere…")
                    } else if isGrading {
                        ProgressView("Wird bewertet…")
                    } else if let gradingError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(gradingError, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                            if let transcribedAnswer, !transcribedAnswer.isEmpty {
                                Button("Bewertung erneut versuchen") {
                                    Task { await gradeCurrentAnswer(sttText: transcribedAnswer) }
                                }
                                .font(.footnote)
                            }
                        }
                    } else if let gradingResult {
                        gradingResultView(gradingResult, card: card)
                    }

                    Spacer(minLength: 12)

                    Button("Nächste Karte") {
                        nextCard()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isTranscribing || isGrading
                        || (index >= cards.count - 1 && transcribedAnswer == nil)
                    )
                } else {
                    ContentUnavailableView("Fertig!", systemImage: "checkmark.seal.fill", description: Text("Du hast alle Karten in diesem Unterordner durchgesprochen."))
                }
            }
            .padding()
        }
        .navigationTitle("Lernmodus")
        .navigationBarTitleDisplayMode(.inline)
        // Zwei getrennte .task-Modifier statt einem: die Frage soll sofort
        // vorgelesen werden, unabhängig davon, wie lange die (einmalige,
        // von TTS völlig unabhängige) Whisper-Vorbereitung braucht. Vorher
        // liefen beide nacheinander in einem Task, wodurch das Vorlesen auf
        // die Whisper-Vorbereitung warten musste.
        .task { if let card = currentCard { speech.speak(card.question) } }
        .task { await transcriber.prepareIfNeeded() }
        .onDisappear { speech.stop() }
        .alert("Mikrofonzugriff benötigt", isPresented: $recorder.permissionDenied) {
            Button("Zugriff erlauben") { MicrophonePermission.requestOrOpenSettings() }
            Button("Später", role: .cancel) {}
        } message: {
            Text("Ohne Mikrofonzugriff kann deine gesprochene Antwort nicht aufgenommen werden.")
        }
    }

    @ViewBuilder
    private func gradingResultView(_ result: GradingResult, card: Flashcard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: verdictIcon(result.urteil))
                Text(verdictLabel(result.urteil))
                    .font(.headline)
                Spacer()
                Text("\(Int(result.deckungProzent.rounded()))% getroffen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(verdictColor(result.urteil))

            Text(result.kurzesFeedback)
                .font(.subheadline)

            if !result.fehlendeElemente.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gefehlt hat:").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.fehlendeElemente, id: \.self) { element in
                        Label(element, systemImage: "circle")
                            .font(.caption)
                    }
                }
            }

            Divider()
            Text("Musterantwort:").font(.caption).foregroundStyle(.secondary)
            Text(card.answer).font(.caption)

            Divider()
            Text("Wie empfindest du deine Antwort selbst?")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                selfAssessmentButton(.richtig, label: "Richtig\n(gewusst)")
                selfAssessmentButton(.teilweise, label: "Teilweise richtig\n(fast gewusst)")
                selfAssessmentButton(.falsch, label: "Falsch\n(nicht gewusst)")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdictColor(result.urteil).opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Ein Selbsteinschätzungs-Button. Die KI-Bewertung dient nur als
    /// Vorschlag (vorbelegt in `gradeCurrentAnswer`) – der User kann jederzeit
    /// eine andere der drei Stufen wählen, das ist die eigentliche, finale
    /// Einschätzung.
    private func selfAssessmentButton(_ urteil: GradingResult.Urteil, label: String) -> some View {
        let isSelected = selfAssessment == urteil
        return Button {
            selfAssessment = urteil
        } label: {
            Text(label)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .tint(verdictColor(urteil))
        .background(
            isSelected ? verdictColor(urteil).opacity(0.3) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? verdictColor(urteil) : .clear, lineWidth: 2)
        )
    }

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

    @ViewBuilder
    private var whisperStatusView: some View {
        switch transcriber.state {
        case .downloading:
            Label("Whisper-base wird einmalig lokal geladen…", systemImage: "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            Label(
                recorder.isRecording ? "Aufnahme beenden" : "Antwort sprechen",
                systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill"
            )
            .font(.title3)
        }
        .buttonStyle(.borderedProminent)
        .tint(recorder.isRecording ? .red : .accentColor)
        .disabled(isTranscribing || isGrading)
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            guard let url = recorder.stopRecording() else { return }
            isTranscribing = true
            let text = await transcriber.transcribe(audioURL: url)
            isTranscribing = false

            guard let text, !text.isEmpty else {
                // Stiller Fehlerfall vorher: Whisper lieferte nichts (Fehler
                // oder leere Aufnahme) und es passierte einfach nichts mehr.
                transcribedAnswer = nil
                gradingError = "Transkription fehlgeschlagen oder leer – bitte nochmal versuchen."
                return
            }
            transcribedAnswer = text
            await gradeCurrentAnswer(sttText: text)
        } else {
            transcribedAnswer = nil
            gradingResult = nil
            gradingError = nil
            selfAssessment = nil
            await recorder.startRecording()
        }
    }

    private func gradeCurrentAnswer(sttText: String) async {
        guard let card = currentCard else { return }
        isGrading = true
        gradingError = nil
        defer { isGrading = false }

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
            gradingResult = result
            // Vorschlag vorbelegen – der User kann das jederzeit überschreiben.
            selfAssessment = result.urteil
            if !cacheStillValid {
                await library.cacheKernelemente(kernelemente, for: card, sourceHash: currentHash)
            }
        } catch {
            gradingError = error.localizedDescription
        }
    }

    private func nextCard() {
        transcribedAnswer = nil
        gradingResult = nil
        gradingError = nil
        selfAssessment = nil
        index += 1
        if let card = currentCard {
            speech.speak(card.question)
        }
    }
}
