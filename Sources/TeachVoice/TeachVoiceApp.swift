import SwiftUI

@main
struct TeachVoiceApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var library: LibraryStore

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
        }
    }
}
