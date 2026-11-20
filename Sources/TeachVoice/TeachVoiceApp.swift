import SwiftUI

@main
struct TeachVoiceApp: App {
    @StateObject private var auth: AuthManager
    @StateObject private var library: LibraryStore
    // App-weit ein einziges Mal erzeugt (nicht pro StudyView-Besuch!), damit
    // das einmal geladene Whisper-Modell für die gesamte App-Sitzung im
    // Speicher bleibt und nicht bei jedem "Lernen starten" neu vorbereitet
    // (inkl. Download-Anzeige) werden muss.
    @StateObject private var transcriber = WhisperTranscriber()
    // Ebenfalls app-weit EIN einziges Mal erzeugt, seit vorher jede View ihr
    // eigenes SpeechService (= eigener AVSpeechSynthesizer) anlegte: mit
    // mehreren unabhängigen Synthesizer-Instanzen konnten sich zwei
    // Voice-Lines beim schnellen Navigieren zwischen Screens tatsächlich
    // überlappen (z.B. eine Stimmen-Vorschau in ProfileView + eine Frage in
    // StudyView gleichzeitig hörbar). `speak()` ruft intern IMMER zuerst
    // `stop()` auf einer laufenden Ansage auf -- das schützt aber nur
    // INNERHALB einer einzigen Instanz. Mit genau einer geteilten Instanz
    // gilt die Garantie "nie zwei Voice-Lines gleichzeitig" jetzt app-weit.
    // Braucht `auth` seit dem Wechsel auf Cloud-TTS (Google Cloud, siehe
    // CloudSpeechService) -- für den Access-Token bei eingeloggten Usern,
    // genau wie GradingService/QuestionGenerationService ihn schon brauchen.
    @StateObject private var speech: SpeechService
    // Podcasts (Tab "Podcasts"): nur auf dem Gerät, unabhängig vom Konto.
    // App-weit EIN Player, damit nie zwei Podcasts gleichzeitig laufen und
    // Lern-Audio ihn zuverlässig pausieren kann.
    @StateObject private var podcasts: PodcastStore
    @StateObject private var podcastPlayer: PodcastPlayer

    init() {
        let auth = AuthManager()
        _auth = StateObject(wrappedValue: auth)
        // Platzhalter-Repository beim Start – `RootView` stellt sofort auf
        // Remote (Cloud-Login) oder Local (Gastmodus) um, sobald der
        // tatsächliche Auth-Zustand feststeht.
        _library = StateObject(wrappedValue: LibraryStore(repository: LocalLibraryRepository()))
        _speech = StateObject(wrappedValue: SpeechService(auth: auth))
        let podcasts = PodcastStore()
        _podcasts = StateObject(wrappedValue: podcasts)
        _podcastPlayer = StateObject(wrappedValue: PodcastPlayer(store: podcasts))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(transcriber)
                .environmentObject(speech)
                .environmentObject(podcasts)
                .environmentObject(podcastPlayer)
                // Fängt den Rücksprung aus der Supabase-Bestätigungs-/Magic-
                // Link-Mail ab (Custom-URL-Schema "teachvoice://", siehe
                // project.yml CFBundleURLTypes + AuthManager.handleAuthRedirect)
                // -- ohne das landete der Mail-Link bisher in einer
                // Browser-Sackgasse (localhost:3000), ohne dass die App je
                // etwas vom bestätigten Login mitbekam.
                .onOpenURL { url in
                    Task { await auth.handleAuthRedirect(url: url) }
                }
        }
    }
}
