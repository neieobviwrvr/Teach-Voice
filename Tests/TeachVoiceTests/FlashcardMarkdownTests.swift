import XCTest
@testable import TeachVoice

/// `FlashcardMarkdown` sitzt im kritischen Pfad JEDER angezeigten/vorgelesenen
/// Frage und Antwort (StudyView, beide Hands-free-Modi, Listen-Vorschau) –
/// ein Bug hier würde nicht nur das neue Rich-Text-Feature betreffen, sondern
/// die Kernfunktion der ganzen App. Deshalb besonders gründlich getestet.
final class FlashcardMarkdownTests: XCTestCase {

    // MARK: - plainText (TTS + GPT-Frage-Bereinigung)

    func testPlainTextRemovesBoldMarkers() {
        XCTAssertEqual(FlashcardMarkdown.plainText(from: "Das ist **wichtig** hier."), "Das ist wichtig hier.")
    }

    func testPlainTextRemovesBulletPrefixPerLine() {
        let input = "- Erster Punkt\n- Zweiter Punkt\nKein Punkt"
        XCTAssertEqual(FlashcardMarkdown.plainText(from: input), "Erster Punkt\nZweiter Punkt\nKein Punkt")
    }

    func testPlainTextHandlesEmptyString() {
        XCTAssertEqual(FlashcardMarkdown.plainText(from: ""), "")
    }

    func testPlainTextHandlesTextWithoutAnyFormatting() {
        XCTAssertEqual(FlashcardMarkdown.plainText(from: "Ganz normaler Text."), "Ganz normaler Text.")
    }

    func testPlainTextHandlesUnmatchedBoldMarker() {
        // Nur ein "**" ohne Partner darf nicht crashen.
        XCTAssertEqual(FlashcardMarkdown.plainText(from: "Kaputt** markiert"), "Kaputt markiert")
    }

    func testPlainTextHandlesShortLineWithDashPrefixOnly() {
        // "- " selbst als komplette Zeile (dropFirst(2) auf einen 1-Zeichen-String
        // "-" darf nicht crashen) – Regressionstest für den Bug, den man sich beim
        // naiven dropFirst(2) leicht einhandelt.
        XCTAssertEqual(FlashcardMarkdown.plainText(from: "-"), "-")
        XCTAssertEqual(FlashcardMarkdown.plainText(from: "- "), "")
    }

    // MARK: - attributedString (Anzeige)

    func testAttributedStringPreservesPlainTextContent() {
        let result = FlashcardMarkdown.attributedString(from: "Hallo **Welt**")
        XCTAssertEqual(String(result.characters), "Hallo Welt")
    }

    func testAttributedStringMarksBoldSegmentAsStronglyEmphasized() {
        let result = FlashcardMarkdown.attributedString(from: "Vor **fett** nach")
        // Finde den Run, der "fett" enthält, und prüfe die Emphase.
        var foundBoldRun = false
        for run in result.runs {
            let substring = String(result.characters[run.range])
            if substring == "fett" {
                foundBoldRun = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            }
        }
        XCTAssertTrue(foundBoldRun, "Der 'fett'-Textlauf sollte als stronglyEmphasized markiert sein.")
    }

    func testAttributedStringHandlesEmptyString() {
        let result = FlashcardMarkdown.attributedString(from: "")
        XCTAssertEqual(String(result.characters), "")
    }

    func testAttributedStringHandlesMultipleBulletLines() {
        let result = FlashcardMarkdown.attributedString(from: "- Eins\n- Zwei")
        // Der Bullet-Marker "•" muss vor jeder Zeile auftauchen, der Bindestrich
        // selbst darf nicht mehr sichtbar sein.
        let text = String(result.characters)
        XCTAssertTrue(text.contains("•"))
        XCTAssertFalse(text.contains("- Eins"))
        XCTAssertTrue(text.contains("Eins"))
        XCTAssertTrue(text.contains("Zwei"))
    }
}
