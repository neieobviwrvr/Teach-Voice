import Foundation

/// Der "persönliche Claude-Link" für den Konnektor: die Konnektor-URL mit dem
/// Schlüssel als letztem Pfad-Segment, z.B.
/// `https://<ref>.supabase.co/functions/v1/teach-mcp/tvk_…`.
///
/// Warum der Schlüssel im Link steckt statt in einem Request-Header: Claude
/// bietet beim Hinzufügen eigener Konnektoren in normalen Konten keine
/// Header an (nur als Beta für einzelne Organisationen). Die URL kann man
/// dagegen überall einfügen, auch im kostenlosen Abo. `teach-mcp` liest den
/// Schlüssel aus dem Pfad (siehe `supabase/functions/teach-mcp/index.ts`).
///
/// Der Server kennt nur einen Hash des Schlüssels. Damit die App den Link
/// auch später noch anzeigen kann, liegt der Klartext-Schlüssel zusätzlich
/// im Keychain DIESES Geräts, getrennt pro Konto.
enum ConnectorLink {
    static func make(base: String, key: String) -> String {
        var trimmed = base
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return "\(trimmed)/\(key)"
    }

    /// Passt ein gespeicherter Schlüssel zum aktiven Schlüssel auf dem Server
    /// (erkennbar am angezeigten Präfix)? Verhindert, dass nach einem auf
    /// einem anderen Gerät erzeugten Schlüssel ein veralteter Link erscheint.
    static func matches(_ key: String, activePrefix: String?) -> Bool {
        guard let activePrefix, !activePrefix.isEmpty else { return false }
        return key.hasPrefix(activePrefix)
    }

    static func storedKey(for userId: UUID) -> String? {
        Keychain.get(storageKey(for: userId))
    }

    static func store(_ key: String, for userId: UUID) {
        Keychain.set(key, for: storageKey(for: userId))
    }

    static func removeStoredKey(for userId: UUID) {
        Keychain.remove(storageKey(for: userId))
    }

    private static func storageKey(for userId: UUID) -> String {
        "connectorKey.\(userId.uuidString)"
    }
}
