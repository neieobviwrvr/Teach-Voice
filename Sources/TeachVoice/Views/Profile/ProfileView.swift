import SwiftUI

/// Ersetzt den früheren direkten "Abmelden"-Button im Toolbar von
/// `FolderListView`: statt einer sofortigen destruktiven Aktion oben links
/// gibt es jetzt einen Profil-Einstieg, unter dem sowohl die Vorlesestimme
/// gewählt (`VoicePickerView`) als auch abgemeldet werden kann.
struct ProfileView: View {
    let mode: LibraryMode

    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

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
            }
            .navigationTitle("Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
