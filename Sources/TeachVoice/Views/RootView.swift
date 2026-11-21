import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var transcriber: WhisperTranscriber

    var body: some View {
        Group {
            if auth.isAuthenticated {
                MainTabView(mode: .cloud)
            } else if auth.isGuest {
                MainTabView(mode: .guest)
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

/// Tab-Leiste unten (seit 2026-11-20): "Lernen" = der bisherige Startscreen,
/// "Podcasts" = eigene Audiodateien, "Zusammenfassungen" = fertige
/// Zusammenfassungen als Dateien -- beides nur auf diesem iPhone. Während einer
/// Lern-Session ist die Leiste ausgeblendet (`StudySessionView`), damit man
/// nicht mitten in der Abfrage den Tab wechselt.
struct MainTabView: View {
    let mode: LibraryMode

    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            FolderListView(mode: mode)
                .tabItem { Label("Lernen", systemImage: "rectangle.stack") }
                .tag(AppRouter.Tab.lernen)
            PodcastListView()
                .tabItem { Label("Podcasts", systemImage: "headphones") }
                .tag(AppRouter.Tab.podcasts)
            SummaryListView()
                .tabItem { Label("Zusammenfassungen", systemImage: "doc.text") }
                .tag(AppRouter.Tab.zusammenfassungen)
        }
        // Datei aus dem Teilen-Menü einer anderen App wird gerade übernommen.
        .overlay(alignment: .top) {
            if let fileName = router.importingFileName {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("„\(fileName)“ wird übernommen…")
                        .font(.footnote)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: router.importingFileName)
        .alert(
            router.importResult?.title ?? "",
            isPresented: hasImportResult,
            presenting: router.importResult
        ) { _ in
            Button("OK", role: .cancel) { router.importResult = nil }
        } message: { result in
            Text(result.message)
        }
    }

    private var hasImportResult: Binding<Bool> {
        Binding(get: { router.importResult != nil }, set: { if !$0 { router.importResult = nil } })
    }
}
