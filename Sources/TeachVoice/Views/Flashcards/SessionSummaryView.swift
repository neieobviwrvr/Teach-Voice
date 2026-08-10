import SwiftUI

/// Ein Lernergebnis für die End-Screen-Statistik – unabhängig davon, ob es aus
/// dem Detail- oder Hands-free-Modus stammt.
struct SessionResultEntry: Identifiable {
    let id = UUID()
    let question: String
    let isCorrect: Bool
    let label: String
    let percent: Double
}

/// Gemeinsamer End-Screen für beide Lernmodi (Detail + Hands-free), nachdem
/// alle Karten eines Unterordners durchgespielt wurden: Gesamt-Statistik,
/// aufklappbare Detailliste pro Karte, und zwei Weiter-Optionen.
struct SessionSummaryView: View {
    let results: [SessionResultEntry]
    let onRepeatSame: () -> Void
    let onPickDifferentSubfolder: () -> Void

    @State private var showDetails = false

    private var correctCount: Int { results.filter(\.isCorrect).count }
    private var percent: Int {
        guard !results.isEmpty else { return 0 }
        return Int((Double(correctCount) / Double(results.count) * 100).rounded())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView(
                    "Fertig!",
                    systemImage: "checkmark.seal.fill",
                    description: Text("\(correctCount) von \(results.count) richtig beantwortet (\(percent)%)")
                )

                if !results.isEmpty {
                    DisclosureGroup("Details anzeigen", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(results) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: entry.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(entry.isCorrect ? .green : .red)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.question).font(.caption).lineLimit(2)
                                        Text("\(entry.label) – \(Int(entry.percent.rounded()))%")
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
                    Button("Unterordner wiederholen") { onRepeatSame() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    Button("Anderen Unterordner wählen") { onPickDifferentSubfolder() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
    }
}
