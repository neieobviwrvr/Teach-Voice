import SwiftUI

/// Popup, das beim Tippen auf das Plus-Symbol im Unterordner erscheint:
/// oben ein Block für die Frage, darunter ein Block für die passende Antwort.
struct AddFlashcardSheet: View {
    let onSave: (_ question: String, _ answer: String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var answer = ""
    @State private var isSaving = false

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
            .navigationTitle("Neue Karteikarte")
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
