import SwiftUI

struct FlashcardListView: View {
    let subfolder: Subfolder

    @EnvironmentObject private var library: LibraryStore
    @State private var showAddCard = false
    @State private var editingCard: Flashcard?

    private var cards: [Flashcard] { library.flashcards(in: subfolder) }
    private var isFull: Bool { cards.count >= maxFlashcardsPerSubfolder }

    var body: some View {
        List {
            if !cards.isEmpty {
                Section {
                    NavigationLink {
                        StudyView(subfolder: subfolder, cards: cards)
                    } label: {
                        Label("Lernen starten (Sprachmodus)", systemImage: "waveform")
                    }
                }
            }

            Section {
                ForEach(cards) { card in
                    Button {
                        editingCard = card
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.question).font(.body)
                            Text(card.answer).font(.caption).foregroundStyle(.secondary)
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
                Text("\(cards.count)/\(maxFlashcardsPerSubfolder) Karteikarten")
            } footer: {
                Text("Tippe auf eine Karte, um Frage oder Antwort nachträglich zu ändern.")
            }
        }
        .navigationTitle(subfolder.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddCard = true
                } label: {
                    Label("Karteikarte hinzufügen", systemImage: "plus")
                }
                .disabled(isFull)
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
