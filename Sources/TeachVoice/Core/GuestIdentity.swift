import Foundation

/// Stabile, rein lokale User-ID für den Gastmodus. Verlässt nie das Gerät,
/// dient nur dazu, dieselben Codable-Modelle (`userId`-Feld) wie im
/// Cloud-Modus wiederzuverwenden.
enum GuestIdentity {
    private static let key = "teachvoice.guestUserId"

    static var id: UUID {
        if let stored = UserDefaults.standard.string(forKey: key), let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let created = UUID()
        UserDefaults.standard.set(created.uuidString, forKey: key)
        return created
    }
}
