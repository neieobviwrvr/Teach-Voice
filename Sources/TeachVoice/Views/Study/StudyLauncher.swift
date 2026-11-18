import SwiftUI

/// Die zwei Lernmodi der App (Simons MVP-Entscheidung):
/// - `sprechen`: Frage wird vorgelesen, man antwortet laut, die KI prüft die
///   Kernthemen nach der Zielnote, danach bewertet man sich selbst
///   (`VoiceStudyView`).
/// - `tippen`: Anki-Stil ohne Mikrofon und ohne KI – Frage lesen, "Antwort
///   zeigen", selbst bewerten (`AnkiStudyView`).
enum StudyMode: Hashable {
    case sprechen
    case tippen
}

/// Was abgefragt werden soll, bevor der Modus gewählt ist: ein Unterordner
/// oder ein ganzer Ordner (alle Unterordner zusammen).
struct StudyScope: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let cards: [Flashcard]
}

/// Eine gestartete Lern-Session – Navigationsziel für beide Modi.
struct StudySessionRequest: Identifiable, Hashable {
    let id = UUID()
    let title: String
    /// Alle Karten des gewählten Bereichs. Abgefragt werden davon nur die
    /// fälligen und neuen, außer `nurFaellige` ist `false`.
    let allCards: [Flashcard]
    let mode: StudyMode
    let nurFaellige: Bool
}

/// Zielansicht für eine `StudySessionRequest`, je nach Modus.
struct StudySessionView: View {
    let request: StudySessionRequest

    var body: some View {
        switch request.mode {
        case .sprechen:
            VoiceStudyView(request: request)
        case .tippen:
            AnkiStudyView(request: request)
        }
    }
}

extension View {
    /// Fragt für einen gewählten Bereich (`scope`) den Lernmodus ab und
    /// meldet die fertige Session über `onStart`. Zeigt dabei, wie viele
    /// Karten fällig sind. Ist heute nichts fällig, werden alle Karten geübt.
    func studyModeDialog(
        scope: Binding<StudyScope?>,
        onStart: @escaping (StudySessionRequest) -> Void
    ) -> some View {
        modifier(StudyModeDialog(scope: scope, onStart: onStart))
    }
}

private struct StudyModeDialog: ViewModifier {
    @Binding var scope: StudyScope?
    let onStart: (StudySessionRequest) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Wie willst du lernen?",
            isPresented: Binding(
                get: { scope != nil },
                set: { if !$0 { scope = nil } }
            ),
            titleVisibility: .visible,
            presenting: scope
        ) { scope in
            let nurFaellige = !SpacedRepetition.sessionCards(scope.cards).isEmpty
            Button("Sprechen (Zielnote \(Zielnote.gespeichert.anzeige))") {
                onStart(StudySessionRequest(title: scope.title, allCards: scope.cards, mode: .sprechen, nurFaellige: nurFaellige))
            }
            Button("Tippen (Anki-Stil)") {
                onStart(StudySessionRequest(title: scope.title, allCards: scope.cards, mode: .tippen, nurFaellige: nurFaellige))
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { scope in
            Text(Self.message(for: scope))
        }
    }

    private static func message(for scope: StudyScope) -> String {
        let faellig = SpacedRepetition.sessionCards(scope.cards).count
        if faellig == 0 {
            return "\(scope.title): Heute ist nichts fällig. Du übst alle \(scope.cards.count) Karten."
        }
        return "\(scope.title): \(faellig) von \(scope.cards.count) Karten sind fällig oder neu. Falsche Karten kommen wieder, bis sie sitzen."
    }
}
