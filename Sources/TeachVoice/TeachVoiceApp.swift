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

    init() {
        let auth = AuthManager()
        _auth = StateObject(wrappedValue: auth)
        // Platzhalter-Repository beim Start – `RootView` stellt sofort auf
        // Remote (Cloud-Login) oder Local (Gastmodus) um, sobald der
        // tatsächliche Auth-Zustand feststeht.
        _library = StateObject(wrappedValue: LibraryStore(repository: LocalLibraryRepository()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(library)
                .environmentObject(transcriber)
        }
    }
}
