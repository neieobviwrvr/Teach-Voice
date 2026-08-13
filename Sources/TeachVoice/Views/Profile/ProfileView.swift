import SwiftUI

/// Ersetzt den früheren direkten "Abmelden"-Button im Toolbar von
/// `FolderListView`: statt einer sofortigen destruktiven Aktion oben links
/// gibt es jetzt einen Profil-Einstieg, unter dem sowohl die Vorlesestimme
/// gewählt (`VoicePickerView`) als auch abgemeldet werden kann.
struct ProfileView: View {
    let mode: LibraryMode

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    // Simon: "einen Button hin, der diesen speziellen User komplett löscht.
    // Frage beim klicken nach 'Willst du wirklich alles unwiederuflich
    // löschen?' hin." -- nur im Cloud-Modus gezeigt, Gastmodus hat keinen
    // Server-Account (dort reicht "Ordner verwalten" -> alle Ordner löschen
    // für denselben "alles weg"-Effekt, siehe ON DELETE CASCADE).
    @State private var showDeleteAccountConfirmation = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        VoicePickerView()
                    } label: {
                        Label("Vorlesestimme wählen", systemImage: "waveform")
                    }
                }

                Section {
                    Button(mode == .guest ? "Gastmodus verlassen" : "Abmelden", role: .destructive) {
                        auth.leaveCurrentSession()
                        dismiss()
                    }
                }

                if mode == .cloud {
                    Section {
                        Button(role: .destructive) {
                            showDeleteAccountConfirmation = true
                        } label: {
                            if isDeletingAccount {
                                HStack {
                                    ProgressView()
                                    Text("Wird gelöscht…")
                                }
                            } else {
                                Text("Account löschen")
                            }
                        }
                        .disabled(isDeletingAccount)
                    } footer: {
                        Text("Löscht deinen Account und ALLE deine Ordner, Unterordner und Karteikarten unwiderruflich vom Server.")
                    }
                }
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .alert("Account löschen", isPresented: $showDeleteAccountConfirmation) {
                Button("Abbrechen", role: .cancel) {}
                Button("Löschen", role: .destructive) {
                    Task { await deleteAccount() }
                }
            } message: {
                Text("Willst du wirklich alles unwiderruflich löschen?")
            }
            .alert("Fehler", isPresented: Binding(
                get: { deleteAccountError != nil },
                set: { if !$0 { deleteAccountError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteAccountError ?? "")
            }
        }
    }

    private func deleteAccount() async {
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await auth.deleteAccount()
            dismiss()
        } catch let error as APIError {
            deleteAccountError = error.errorDescription
        } catch {
            deleteAccountError = error.localizedDescription
        }
    }
}
