import SwiftUI

/// Gemeinsamer End-Screen für beide Lernmodi: wie viele Karten auf Anhieb
/// richtig/teilweise/falsch waren, wie oft wiederholt wurde, aufklappbare
/// Detailliste pro Karte, und "Alle Karten nochmal üben".
struct SessionSummaryView: View {
    let queue: StudyQueue
    let onRepeatAll: () -> Void
    let onClose: () -> Void

    @State private var showDetails = false

    private var summaryText: String {
        let total = queue.firstAttempts.count
        guard total > 0 else { return "Heute war nichts zu lernen." }
        var text = "Auf Anhieb: \(queue.count(of: .richtig)) richtig, \(queue.count(of: .teilweise)) teilweise, \(queue.count(of: .falsch)) falsch (von \(total))."
        if queue.repetitions > 0 {
            text += " Dazu \(queue.repetitions) Wiederholung\(queue.repetitions == 1 ? "" : "en"), bis alles saß."
        }
        return text
    }

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                "Fertig!",
                systemImage: "checkmark.seal.fill",
                description: Text(summaryText)
            )

            if !queue.firstAttempts.isEmpty {
                DisclosureGroup("Details anzeigen", isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(queue.firstAttempts) { attempt in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: attempt.urteil))
                                    .foregroundStyle(attempt.urteil.color)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(FlashcardMarkdown.plainText(from: attempt.card.question))
                                        .font(.caption)
                                        .lineLimit(2)
                                    Text(detailText(for: attempt))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(spacing: 10) {
                Button("Alle Karten nochmal üben") { onRepeatAll() }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button("Zurück") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func detailText(for attempt: StudyQueue.Attempt) -> String {
        guard let percent = attempt.percent else { return attempt.urteil.label }
        return "\(attempt.urteil.label) – \(Int(percent.rounded())) % der Kernthemen"
    }

    private func icon(for urteil: GradingResult.Urteil) -> String {
        switch urteil {
        case .richtig: return "checkmark.circle.fill"
        case .teilweise: return "circle.lefthalf.filled"
        case .falsch: return "xmark.circle.fill"
        }
    }
}
