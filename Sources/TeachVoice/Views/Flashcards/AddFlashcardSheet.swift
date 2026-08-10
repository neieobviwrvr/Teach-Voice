import SwiftUI

/// Popup zum Anlegen ODER Bearbeiten einer Karteikarte: oben ein Block für die
/// Frage, darunter ein Block für die passende (Muster-)Antwort. Wird sowohl
/// vom Plus-Symbol im Unterordner (neue Karte) als auch per Tap auf eine
/// bestehende Karte (Bearbeiten) verwendet.
///
/// Beide Felder unterstützen Fett-Formatierung (siehe `RichAnswerEditor`);
/// nur die Antwort zusätzlich Aufzählungspunkte. Fett bei der Frage ist rein
/// fürs eigene Lernen gedacht (Simons ausdrückliche Vorgabe) und hat KEINE
/// Auswirkung auf GPT – `GradingService.grade` entfernt die Formatierung aus
/// der Frage wieder, bevor sie an die Edge Function geht. Fett/Punkte in der
/// Antwort bleiben dagegen erhalten und fließen bewusst als Signal in die
/// Kernelemente-Extraktion ein (siehe `grade-answer/index.ts`).
struct AddFlashcardSheet: View {
    let editing: Flashcard?
    let onSave: (_ question: String, _ answer: String) async -> Bool
    @Environment(\.dismiss) private var dismiss

    @StateObject private var questionController: RichTextEditorController
    @StateObject private var answerController: RichTextEditorController
    @State private var isSaving = false

    init(editing: Flashcard? = nil, onSave: @escaping (_ question: String, _ answer: String) async -> Bool) {
        self.editing = editing
        self.onSave = onSave
        _questionController = StateObject(wrappedValue: RichTextEditorController(text: editing?.question ?? "", supportsBullets: false))
        _answerController = StateObject(wrappedValue: RichTextEditorController(text: editing?.answer ?? "", supportsBullets: true))
    }

    private var trimmedQuestion: String { questionController.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedAnswer: String { answerController.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Frage") {
                    FormattedTextField(controller: questionController)
                }
                Section("Antwort") {
                    FormattedTextField(controller: answerController)
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
                        let q = trimmedQuestion
                        let a = trimmedAnswer
                        guard !q.isEmpty, !a.isEmpty else { return }
                        isSaving = true
                        Task {
                            let success = await onSave(q, a)
                            isSaving = false
                            if success { dismiss() }
                        }
                    }
                    .disabled(trimmedQuestion.isEmpty || trimmedAnswer.isEmpty || isSaving)
                }
            }
        }
    }
}
