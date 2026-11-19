import SwiftUI

/// Tipp-Modus im Anki-Stil: Frage lesen, "Antwort zeigen", selbst bewerten.
/// Kein Mikrofon, keine KI, keine Kosten. Die Selbsteinschätzung geht wie im
/// Sprach-Modus ins Spaced-Repetition-System, und falsche Karten kommen in
/// derselben Session wieder (`StudyQueue`).
struct AnkiStudyView: View {
    let request: StudySessionRequest

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var speech: SpeechService
    @Environment(\.dismiss) private var dismiss

    @State private var queue: StudyQueue
    @State private var showAnswer = false
    @State private var isSaving = false

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
                if let card = queue.current {
                    Text(queue.progressText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    cardFace(card)

                    if showAnswer {
                        Text("Wie gut wusstest du es?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            assessmentButton(.falsch)
                            assessmentButton(.teilweise)
                            assessmentButton(.richtig)
                        }
                    } else {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { showAnswer = true }
                        } label: {
                            Text("Antwort zeigen").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    Button("Beenden", role: .destructive) { close() }
                        .buttonStyle(.bordered)
                } else {
                    SessionSummaryView(
                        queue: queue,
                        onRepeatAll: { restartWithAllCards() },
                        onClose: { close() }
                    )
                }
            }
            .padding()
        }
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { speech.stop() }
    }

    private func cardFace(_ card: Flashcard) -> some View {
        VStack(spacing: 16) {
            Text(flashcardMarkdown: card.question)
                .font(.title2)
                .multilineTextAlignment(.center)

            Button {
                speech.speak(FlashcardMarkdown.plainText(from: card.question))
            } label: {
                Label("Vorlesen", systemImage: "speaker.wave.2.fill")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            if showAnswer {
                Divider()
                Text(flashcardMarkdown: card.answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func assessmentButton(_ urteil: GradingResult.Urteil) -> some View {
        Button {
            assess(urteil)
        } label: {
            VStack(spacing: 2) {
                Text(urteil.label)
                // Wann FSRS die Karte bei dieser Bewertung wieder zeigt.
                if let card = queue.current {
                    Text(library.nextReviewLabel(for: card, urteil: urteil))
                        .font(.caption2)
                        .opacity(0.85)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(urteil.color)
        .controlSize(.large)
        .disabled(isSaving)
    }

    private func assess(_ urteil: GradingResult.Urteil) {
        guard let card = queue.current else { return }
        speech.stop()
        HapticFeedback.play(for: urteil)
        // Erst die Schlange weiterschalten (sofortige Reaktion), dann im
        // Hintergrund speichern. `isSaving` verhindert Doppel-Taps, die
        // sonst die NÄCHSTE Karte gleich mitbewerten würden.
        isSaving = true
        // Gleicher Zeitpunkt und Prüfungstermin für Runde und Speichern, damit
        // beide exakt denselben FSRS-Zustand berechnen.
        let now = Date()
        queue.record(urteil, now: now, examDate: library.examDate(for: card))
        showAnswer = false
        Task {
            await library.recordSpacedRepetitionOutcome(for: card, urteil: urteil, now: now)
            isSaving = false
        }
    }

    private func restartWithAllCards() {
        let fresh = request.allCards.compactMap { library.currentVersion(of: $0) }
        queue = StudyQueue(cards: SpacedRepetition.ordered(fresh))
        showAnswer = false
    }

    private func close() {
        speech.stop()
        dismiss()
    }
}
