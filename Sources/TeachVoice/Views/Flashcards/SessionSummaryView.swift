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
    /// `nil` blendet die Buttons komplett aus – für den "Voice only"-Modus,
    /// wo die Statistik zwar sichtbar UND vorgelesen wird, das Weiterlernen
    /// aber bewusst rein sprachgesteuert bleibt statt per Antippen.
    var onRepeatSame: (() -> Void)? = nil
    var onPickDifferentSubfolder: (() -> Void)? = nil

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
                                    Image(systemName: icon(for: entry))
                                        .foregroundStyle(color(for: entry))
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

                if onRepeatSame != nil || onPickDifferentSubfolder != nil {
                    VStack(spacing: 10) {
                        if let onRepeatSame {
                            Button("Unterordner wiederholen") { onRepeatSame() }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                        }
                        if let onPickDifferentSubfolder {
                            Button("Anderen Unterordner wählen") { onPickDifferentSubfolder() }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding()
        }
    }

    // Bewusst über das `label` (nicht nur `isCorrect`) unterschieden: sonst
    // fällt "teilweise richtig" optisch mit "komplett falsch" zusammen (beide
    // isCorrect == false), obwohl der Rest der App (StudyView,
    // HandsFreeStudyView) dafür konsequent eine eigene dritte Farbe/Icon
    // (orange, halb gefüllter Kreis) verwendet.
    private func icon(for entry: SessionResultEntry) -> String {
        switch entry.label {
        case "Richtig": return "checkmark.circle.fill"
        case "Teilweise richtig": return "circle.lefthalf.filled"
        default: return "xmark.circle.fill"
        }
    }

    private func color(for entry: SessionResultEntry) -> Color {
        switch entry.label {
        case "Richtig": return .green
        case "Teilweise richtig": return .orange
        default: return .red
        }
    }
}
