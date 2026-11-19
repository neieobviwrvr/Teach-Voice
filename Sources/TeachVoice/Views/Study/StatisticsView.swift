import Charts
import SwiftUI

/// Statistik für einen Ordner oder Unterordner: Fortschritt, wie viel du
/// gerade weißt (FSRS-Abrufwahrscheinlichkeit), Prüfungsprognose und
/// Lernverlauf (aus `review_logs`).
struct StatisticsView: View {
    enum Scope {
        case folder(Folder)
        case subfolder(Subfolder)
    }

    let scope: Scope

    @EnvironmentObject private var library: LibraryStore
    @State private var logs: [ReviewLog] = []
    @State private var isLoading = true

    private var title: String {
        switch scope {
        case .folder(let folder): return folder.name
        case .subfolder(let subfolder): return subfolder.name
        }
    }

    private var cards: [Flashcard] {
        switch scope {
        case .folder(let folder): return library.allFlashcards(in: folder)
        case .subfolder(let subfolder): return library.flashcards(in: subfolder)
        }
    }

    private var examDate: Date? {
        switch scope {
        case .folder(let folder): return library.folders.first { $0.id == folder.id }?.examAt
        case .subfolder(let subfolder): return library.examDate(forSubfolderId: subfolder.id)
        }
    }

    var body: some View {
        let stats = LearningStats.compute(cards: cards, examDate: examDate)
        let cardIDs = Set(cards.map(\.id))
        let history = LearningHistory.compute(logs: logs.filter { cardIDs.contains($0.flashcardId) })

        return List {
            if isLoading {
                HStack {
                    ProgressView()
                    Text("Wird geladen…")
                }
            }

            progressSection(stats)
            knowledgeSection(stats)
            examSection(stats)
            dueSection(stats)
            historySection(history)

            if case .folder(let folder) = scope, library.subfolders(in: folder).count > 1 {
                subfolderSection(folder)
            }
        }
        .navigationTitle("Statistik")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - Abschnitte

    private func progressSection(_ stats: LearningStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(stats.learned) von \(stats.total) Karten gelernt")
                    .font(.title3.bold())
                ProgressView(value: stats.total == 0 ? 0 : Double(stats.learned) / Double(stats.total))
                Text(stats.new == 0 ? String("Alle Karten wurden schon mindestens einmal gelernt.") : String("\(stats.new) noch neu"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("\(title) · Fortschritt")
        }
    }

    private func knowledgeSection(_ stats: LearningStats) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Du weißt aktuell geschätzt \(Self.percent(stats.knownNow)) dieses Bereichs")
                    .font(.title3.bold())
                if let learnedOnly = stats.knownNowLearned, stats.new > 0 {
                    Text("Von den \(stats.learned) gelernten Karten: \(Self.percent(learnedOnly)). Neue Karten zählen als 0 %.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Wie viel du gerade weißt")
        } footer: {
            Text("FSRS schätzt für jede gelernte Karte, wie wahrscheinlich du sie genau jetzt noch weißt – je länger die letzte Wiederholung her ist und je weniger stabil die Karte sitzt, desto niedriger.")
        }
    }

    @ViewBuilder
    private func examSection(_ stats: LearningStats) -> some View {
        if let exam = stats.exam {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Am Prüfungstag voraussichtlich \(Self.percent(exam.withPlan)) abrufbar")
                        .font(.title3.bold())
                    Text("wenn du nach Plan wiederholst – noch \(exam.daysLeft) Tag\(exam.daysLeft == 1 ? "" : "e") bis zum \(exam.examDate.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.subheadline)
                    Text("Ohne weiteres Lernen wären es nur \(Self.percent(exam.withoutReview)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Prüfung")
            } footer: {
                Text("Annahme für „nach Plan“: Du wiederholst jede Karte, sobald sie fällig ist, und weißt sie dann (Bewertung „Gut“). Neue Karten lernst du ab heute. Die echte Zahl hängt davon ab, wie gut du die Karten tatsächlich weißt.")
            }
        } else if examDate == nil {
            Section {
                Text("Leg in der Ordner-Ansicht einen Prüfungstermin fest, dann siehst du hier, wie viel du am Prüfungstag voraussichtlich weißt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Prüfung")
            }
        }
    }

    private func dueSection(_ stats: LearningStats) -> some View {
        Section("Fällig") {
            LabeledContent("Heute", value: "\(stats.dueToday) Karten")
            LabeledContent("Nächste 7 Tage", value: "\(stats.dueNext7Days) Karten")
            if stats.new > 0 {
                LabeledContent("Neu", value: "\(stats.new) Karten")
            }
        }
    }

    private func historySection(_ history: LearningHistory) -> some View {
        Section {
            LabeledContent("Serie", value: "\(history.streak) Tag\(history.streak == 1 ? "" : "e") am Stück")
            LabeledContent("Lerntage (\(history.windowDays) Tage)", value: "\(history.activeDays)")
            LabeledContent("Heute bewertet", value: "\(history.reviewsToday) Karten")

            Chart(history.perDay) { day in
                BarMark(
                    x: .value("Tag", day.date, unit: .day),
                    y: .value("Bewertungen", day.reviews)
                )
                .foregroundStyle(Color.accentColor)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.day().month(.defaultDigits))
                }
            }
            .frame(height: 140)
            .padding(.vertical, 4)
        } header: {
            Text("Lernverlauf")
        } footer: {
            Text("Bewertungen pro Tag in den letzten 14 Tagen. Ein Lerntag beginnt um 4 Uhr. Der Verlauf wird ab diesem Update aufgezeichnet.")
        }
    }

    private func subfolderSection(_ folder: Folder) -> some View {
        Section("Unterordner") {
            ForEach(library.subfolders(in: folder)) { subfolder in
                let subStats = LearningStats.compute(
                    cards: library.flashcards(in: subfolder),
                    examDate: nil
                )
                NavigationLink {
                    StatisticsView(scope: .subfolder(subfolder))
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subfolder.name)
                        Text("\(subStats.learned)/\(subStats.total) gelernt · weißt du zu \(Self.percent(subStats.knownNow))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Laden

    private func load() async {
        isLoading = true
        switch scope {
        case .folder(let folder):
            await library.loadAllFlashcards(for: folder, force: true)
        case .subfolder(let subfolder):
            await library.loadFlashcards(for: subfolder)
        }
        let since = Calendar.current.date(byAdding: .day, value: -40, to: Date()) ?? Date()
        logs = await library.reviewLogs(since: since)
        isLoading = false
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }
}
