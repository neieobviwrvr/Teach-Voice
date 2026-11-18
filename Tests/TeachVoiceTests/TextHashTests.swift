import XCTest
@testable import TeachVoice

final class TextHashTests: XCTestCase {

    func testSameTextProducesSameHash() {
        XCTAssertEqual(TextHash.sha256("Working Memory ist ein Speichersystem."), TextHash.sha256("Working Memory ist ein Speichersystem."))
    }

    func testDifferentTextProducesDifferentHash() {
        XCTAssertNotEqual(TextHash.sha256("Text A"), TextHash.sha256("Text B"))
    }

    func testWhitespaceOnlyDifferenceIsNormalizedAway() {
        // Trimmt führende/nachfolgende Whitespace – sonst würde eine reine
        // Formatierungsänderung (z.B. versehentliches Leerzeichen beim
        // Bearbeiten) den Kernelemente-Cache unnötig invalidieren.
        XCTAssertEqual(TextHash.sha256("  Musterantwort  "), TextHash.sha256("Musterantwort"))
    }

    func testMeaningfulEditChangesHash() {
        // Genau der Fall, für den der Hash überhaupt existiert: bearbeitete
        // Musterantwort -> Kernelemente-Cache muss invalidieren.
        XCTAssertNotEqual(TextHash.sha256("Musterantwort Version 1"), TextHash.sha256("Musterantwort Version 2"))
    }

    func testMatchesServerSideAnswerHash() {
        // Fester Prüfwert (SHA-256 der getrimmten UTF-8-Antwort, berechnet
        // unabhängig mit Python). Der Konnektor speichert die von Claude
        // gelieferten Kontrollpunkte unter genau diesem Hash
        // (supabase/functions/_shared/answerHash.ts) -- weicht die App davon
        // ab, würden die Punkte ignoriert und neu extrahiert.
        let answer = "  - blendet innere Vorg\u{00E4}nge aus\n- wissenschaftlich unfruchtbar  \n"
        XCTAssertEqual(TextHash.sha256(answer), "5e2e5d4658d533101e262a914a78f8f421eb65eac58b4e7a77c14dee6b48166b")
    }

    func testHashIsLowercaseHex() {
        let hash = TextHash.sha256("Test")
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
