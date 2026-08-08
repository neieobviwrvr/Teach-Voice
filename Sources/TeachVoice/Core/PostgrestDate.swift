import Foundation

/// PostgREST liefert Timestamps mit Mikrosekunden-Genauigkeit
/// (z.B. "2026-08-08T10:23:45.123456+00:00"), `ISO8601DateFormatter` erwartet
/// mit `.withFractionalSeconds` aber genau 3 Nachkommastellen. Diese Funktion
/// normalisiert die Nachkommastellen, bevor geparst wird.
enum PostgrestDate {
    static func parse(_ string: String) -> Date? {
        let normalized = normalizeFractionalSeconds(string)

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: normalized) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: normalized)
    }

    private static func normalizeFractionalSeconds(_ string: String) -> String {
        guard let dotRange = string.range(of: ".") else { return string }

        // Finde das Ende der Nachkommastellen (erstes Zeichen, das kein Digit ist).
        let afterDot = string[dotRange.upperBound...]
        guard let endIndex = afterDot.firstIndex(where: { !$0.isNumber }) else { return string }

        var fractional = String(afterDot[..<endIndex])
        if fractional.count > 3 {
            fractional = String(fractional.prefix(3))
        } else if fractional.count < 3 {
            fractional += String(repeating: "0", count: 3 - fractional.count)
        }

        return string[..<dotRange.lowerBound] + "." + fractional + string[endIndex...]
    }
}
