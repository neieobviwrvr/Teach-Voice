import SwiftUI

@main
struct TeachVoiceApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var library: LibraryStore

    init() {
        let auth = AuthManager()
        _auth = StateObject(wrappedValue: auth)
        _library = StateObject(wrappedValue: LibraryStore(auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(library)
        }
    }
}
