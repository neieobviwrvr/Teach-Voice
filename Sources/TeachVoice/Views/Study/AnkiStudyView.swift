import SwiftUI

/// Tipp-Modus im Anki-Stil (Vorbild: Anki/StudyFlash): Frage lesen, Karte
/// antippen, dann mit Nochmal/Schwer/Gut/Einfach bewerten. Kein Mikrofon,
/// keine KI, keine Kosten. Jede Bewertung geht direkt in FSRS -- dieselben
/// Karten und derselbe Lernstand wie im Sprach-Modus. "Nochmal"-Karten kommen
/// in derselben Runde wieder (`StudyQueue`).
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
        _queue = State(initialValue: StudyQueue(cards: request.sessionCards))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let card = queue.current {
                    countersRow
                    cardView(card)

                    if showAnswer {
                        HStack(spacing: 8) {
                            ForEach(FSRSRating.allCases, id: \.self) { rating in
                                ratingButton(rating, card: card)
                            }
                        }
                    } else {
                        Button {
                            flip()
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

    // MARK: - Ansicht

    /// Neu · Nochmal · Wiederholen, wie die farbigen Zähler in Anki/StudyFlash.
    private var countersRow: some View {
        let counts = queue.counts
        return HStack(spacing: 0) {
            counter(counts.neu, label: "Neu", color: .blue)
            Divider().frame(height: 24)
            counter(counts.nochmal, label: "Nochmal", color: .red)
            Divider().frame(height: 24)
            counter(counts.wiederholen, label: "Wiederholen", color: .green)
        }
        .frame(maxWidth: .infinity)
    }

    private func counter(_ value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("\(value)").font(.title3.monospacedDigit())
            }
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func cardView(_ card: Flashcard) -> some View {
        VStack(spacing: 16) {
            HStack {
                if queue.currentIsRepetition {
                    Label("Nochmal", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if card.fsrsStability == nil {
                    Label("Neu", systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                Spacer()
                Button {
                    speech.speak(FlashcardMarkdown.plainText(from: showAnswer ? card.answer : card.question))
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Vorlesen")
            }

            Text(flashcardMarkdown: card.question)
                .font(showAnswer ? Font.headline : Font.title2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if showAnswer {
                Divider()
                Text(flashcardMarkdown: card.answer)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("Tippe auf die Karte, um die Antwort zu sehen", systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture {
            if !showAnswer { flip() }
        }
    }

    /// Einer der vier Bewertungs-Buttons, mit dem Abstand, nach dem FSRS die
    /// Karte bei dieser Bewertung wieder zeigt.
    private func ratingButton(_ rating: FSRSRating, card: Flashcard) -> some View {
        Button {
            assess(rating)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: rating.symbol)
                    .font(.title3)
                Text(rating.label)
                    .font(.footnote.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(library.nextReviewLabel(for: card, rating: rating))
                    .font(.caption2)
                    .opacity(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(rating.color)
        .disabled(isSaving)
    }

    // MARK: - Aktionen

    private func flip() {
        withAnimation(.easeOut(duration: 0.2)) { showAnswer = true }
    }

    private func assess(_ rating: FSRSRating) {
        guard let card = queue.current else { return }
        speech.stop()
        HapticFeedback.play(for: GradingResult.Urteil(rating))
        // Erst die Schlange weiterschalten (sofortige Reaktion), dann im
        // Hintergrund speichern. `isSaving` verhindert Doppel-Taps, die
        // sonst die NÄCHSTE Karte gleich mitbewerten würden.
        isSaving = true
        // Gleicher Zeitpunkt und Prüfungstermin für Runde und Speichern, damit
        // beide exakt denselben FSRS-Zustand berechnen.
        let now = Date()
        queue.record(rating, now: now, examDate: library.examDate(for: card))
        showAnswer = false
        Task {
            await library.recordSpacedRepetitionOutcome(for: card, rating: rating, now: now)
            isSaving = false
        }
    }

    private func restartWithAllCards() {
        // "Alle Karten nochmal üben": alle am Stück, mit aktuellem FSRS-Stand.
        let fresh = request.allCards.compactMap { library.currentVersion(of: $0) }
        queue = StudyQueue(cards: fresh)
        showAnswer = false
    }

    private func close() {
        speech.stop()
        dismiss()
    }
}

extension FSRSRating {
    var symbol: String {
        switch self {
        case .again: return "arrow.counterclockwise"
        case .hard: return "tortoise"
        case .good: return "checkmark.circle"
        case .easy: return "star"
        }
    }

    var color: Color {
        switch self {
        case .again: return .red
        case .hard: return .orange
        case .good: return .blue
        case .easy: return .green
        }
    }
}
