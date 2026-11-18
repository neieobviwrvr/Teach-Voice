import SwiftUI

struct FlashcardListView: View {
    let subfolder: Subfolder

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAddCard = false
    @State private var editingCard: Flashcard?
    @State private var studyScope: StudyScope?
    @State private var studyRequest: StudySessionRequest?

    private var cards: [Flashcard] { library.flashcards(in: subfolder) }

    var body: some View {
        List {
            if !cards.isEmpty {
                Section {
                    Button {
                        studyScope = StudyScope(title: subfolder.name, cards: cards)
                    } label: {
                        Label("Lernen", systemImage: "graduationcap")
                    }
                }
            }

            Section {
                ForEach(cards) { card in
                    Button {
                        editingCard = card
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(flashcardMarkdown: card.question).font(.body)
                            Text(flashcardMarkdown: card.answer).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await library.deleteFlashcard(card) }
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                        Button {
                            editingCard = card
                        } label: {
                            Label("Bearbeiten", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                }
                .onDelete { offsets in
                    for index in offsets {
                        let card = cards[index]
                        Task { await library.deleteFlashcard(card) }
                    }
                }
            } header: {
                Text("\(cards.count) Karteikarten")
            } footer: {
                Text("Tippe auf eine Karte, um Frage oder Antwort nachträglich zu ändern.")
            }
        }
        .navigationTitle(subfolder.name)
        .navigationDestination(item: $studyRequest) { request in
            StudySessionView(request: request)
        }
        .studyModeDialog(scope: $studyScope) { request in
            studyRequest = request
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddCard = true
                } label: {
                    Label("Karteikarte hinzufügen", systemImage: "plus")
                }
            }
        }
        .overlay {
            if cards.isEmpty {
                ContentUnavailableView(
                    "Noch keine Karteikarten",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Tippe auf das Plus-Symbol, um Frage und Antwort einzugeben.")
                )
            }
        }
        .task { await library.loadFlashcards(for: subfolder) }
        .refreshable { await library.loadFlashcards(for: subfolder) }
        // Karten, die Claude über den KI-Konnektor angelegt hat, sofort
        // zeigen, wenn man in die App zurückwechselt. Nicht während einer
        // laufenden Lernsession, die ihre Karten beim Start mitbekommt.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, studyRequest == nil else { return }
            Task { await library.loadFlashcards(for: subfolder) }
        }
        .sheet(isPresented: $showAddCard) {
            AddFlashcardSheet { question, answer in
                await library.addFlashcard(question: question, answer: answer, to: subfolder)
            }
        }
        .sheet(item: $editingCard) { card in
            AddFlashcardSheet(editing: card) { question, answer in
                await library.updateFlashcard(card, question: question, answer: answer)
            }
        }
    }
}
