import SwiftUI

/// Popup zum Anlegen ODER Bearbeiten einer Karteikarte: oben ein Block für die
/// Frage, darunter ein Block für die passende (Muster-)Antwort. Wird sowohl
/// vom Plus-Symbol im Unterordner (neue Karte) als auch per Tap auf eine
/// bestehende Karte (Bearbeiten) verwendet.
struct AddFlashcardSheet: View {
    let editing: Flashcard?
    let onSave: (_ question: String, _ answer: String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var question: String
    @State private var answer: String
    @State private var isSaving = false

    init(editing: Flashcard? = nil, onSave: @escaping (_ question: String, _ answer: String) async -> Bool) {
        self.editing = editing
        self.onSave = onSave
        _question = State(initialValue: editing?.question ?? "")
        _answer = State(initialValue: editing?.answer ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Frage") {
                    TextEditor(text: $question)
                        .frame(minHeight: 100)
                }
                Section("Antwort") {
                    TextEditor(text: $answer)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle(editing == nil ? "Neue Karteikarte" : "Karteikarte bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
                        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !q.isEmpty, !a.isEmpty else { return }
                        isSaving = true
                        Task {
                            let success = await onSave(q, a)
                            isSaving = false
                            if success { dismiss() }
                        }
                    }
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || isSaving)
                }
            }
        }
    }
}
