import CryptoKit
import Foundation

/// SHA-256 der Musterantwort, um lokal zu erkennen, ob der Kernelemente-Cache
/// noch zur aktuellen Musterantwort passt (Lazy-Caching für die STT-Bewertung).
/// Wird ausschließlich clientseitig berechnet – die Edge Function selbst ist
/// zustandslos und kennt diesen Hash nicht.
enum TextHash {
    static func sha256(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
