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

    /// Strenge der KI-Bewertung im Sprach-Modus (siehe `Zielnote`). Wird
    /// beim Start jeder Sprach-Session über `Zielnote.gespeichert` gelesen.
    @AppStorage(Zielnote.speicherSchluessel) private var zielnoteWert = Zielnote.standardWert
    /// Nur zur Anzeige, gewählt wird in `VoicePickerView`.
    @AppStorage(VoicePreference.sourceKey) private var speechSource: SpeechSource = .google

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        VoicePickerView()
                    } label: {
                        LabeledContent {
                            Text(speechSource.label)
                        } label: {
                            Label("Vorlesestimme", systemImage: "waveform")
                        }
                    }
                }

                Section {
                    Stepper(
                        value: $zielnoteWert,
                        in: Zielnote.minWert...Zielnote.maxWert,
                        step: Zielnote.schrittweite
                    ) {
                        Label("Zielnote: \(Zielnote(zielnoteWert).anzeige)", systemImage: "graduationcap")
                    }
                } header: {
                    Text("Bewertung im Sprach-Modus")
                } footer: {
                    Text("\(Zielnote(zielnoteWert).beschreibung) Wie du die Kernthemen formulierst, ist egal – auch umgangssprachlich ohne Fachwort zählt.")
                }

                // Claude-Konnektor: nur mit Konto, weil Gast-Karten
                // ausschließlich auf dem Gerät liegen und der Konnektor
                // (supabase/functions/teach-mcp) nur in Supabase schreiben kann.
                Section {
                    if mode == .cloud {
                        NavigationLink {
                            ConnectorView()
                        } label: {
                            Label("KI-Konnektor (Claude)", systemImage: "sparkles")
                        }
                    } else {
                        Label("KI-Konnektor (Claude)", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if mode == .guest {
                        Text("Nur mit Konto verfügbar: Im Gastmodus liegen deine Karten nur auf diesem iPhone, dort kann Claude nicht hineinschreiben.")
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
