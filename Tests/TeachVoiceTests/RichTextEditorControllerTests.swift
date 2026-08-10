import XCTest
import UIKit
@testable import TeachVoice

/// Round-Trip-Tests für die Serialisierung/Deserialisierung zwischen dem
/// gespeicherten FlashcardMarkdown-String und der live editierten
/// `NSAttributedString` – genau die Logik, die ich beim Absichern des
/// Projekts als größtes ungetestetes Risiko in `RichAnswerEditor` identifiziert
/// hatte (eigene NSRange-Arithmetik, nie in echter Laufzeit ausprobiert).
/// serialize(deserialize(x)) muss für jeden gültigen FlashcardMarkdown-String x
/// wieder x ergeben – sonst würde beim erneuten Öffnen einer bearbeiteten
/// Karte lautlos Formatierung/Inhalt verloren gehen.
final class RichTextEditorControllerTests: XCTestCase {
    private let baseFont = UIFont.systemFont(ofSize: 17)

    private func roundTrip(_ text: String) -> String {
        let attributed = RichTextEditorController.deserialize(text, baseFont: baseFont)
        return RichTextEditorController.serialize(attributed)
    }

    func testPlainTextRoundTrips() {
        let original = "Ganz normaler Text ohne Formatierung."
        XCTAssertEqual(roundTrip(original), original)
    }

    func testBoldRoundTrips() {
        let original = "Vor **fett** nach"
        XCTAssertEqual(roundTrip(original), original)
    }

    func testBulletRoundTrips() {
        let original = "- Erster Punkt\n- Zweiter Punkt"
        XCTAssertEqual(roundTrip(original), original)
    }

    func testCombinedBoldAndBulletRoundTrips() {
        let original = "- **Wichtig**: Rest normal\nZweite Zeile ohne Punkt"
        XCTAssertEqual(roundTrip(original), original)
    }

    func testMultipleBoldSegmentsInOneLineRoundTrip() {
        let original = "**Eins** normal **Zwei**"
        XCTAssertEqual(roundTrip(original), original)
    }

    func testEmptyStringRoundTrips() {
        XCTAssertEqual(roundTrip(""), "")
    }

    func testEmptyLinesArePreserved() {
        let original = "Erste Zeile\n\nDritte Zeile nach Leerzeile"
        XCTAssertEqual(roundTrip(original), original)
    }

    func testBoldAcrossWholeLineRoundTrips() {
        let original = "**Komplett fett**"
        XCTAssertEqual(roundTrip(original), original)
    }
}
