import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcriber: WhisperTranscriber

    var body: some View {
        Group {
            if auth.isAuthenticated {
                FolderListView(mode: .cloud)
            } else if auth.isGuest {
                FolderListView(mode: .guest)
            } else {
                AuthView()
            }
        }
        .animation(.default, value: auth.isAuthenticated)
        .animation(.default, value: auth.isGuest)
        // Datenquelle des LibraryStore folgt dem Auth-Modus: Cloud-Login hat
        // Vorrang vor Gastmodus (falls beides gleichzeitig gesetzt wäre).
        .onChange(of: auth.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                library.useRepository(RemoteLibraryRepository(auth: auth))
            } else if auth.isGuest {
                library.useRepository(LocalLibraryRepository())
            }
        }
        .onChange(of: auth.isGuest) { _, isGuest in
            guard !auth.isAuthenticated, isGuest else { return }
            library.useRepository(LocalLibraryRepository())
        }
        .task {
            if auth.isAuthenticated {
                library.useRepository(RemoteLibraryRepository(auth: auth))
            } else if auth.isGuest {
                library.useRepository(LocalLibraryRepository())
            }
        }
        // Whisper so früh wie möglich im Hintergrund vorbereiten (App-Start),
        // statt erst wenn der User im Lernmodus tatsächlich aufnehmen will –
        // die einmalige CoreML-Modell-Kompilierung soll idealerweise schon
        // erledigt sein, während man noch durch die Ordner navigiert.
        .task { await transcriber.prepareIfNeeded() }
    }
}
