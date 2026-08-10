import XCTest
@testable import TeachVoice

final class SubfolderVoiceMatcherTests: XCTestCase {

    private func makeSubfolder(name: String) -> Subfolder {
        Subfolder(id: UUID(), folderId: UUID(), userId: UUID(), name: name, position: 0, createdAt: Date(), updatedAt: Date())
    }

    func testMatchesByNumberWord() {
        let options = [makeSubfolder(name: "Kapitel Eins"), makeSubfolder(name: "Kapitel Zwei")]
        XCTAssertEqual(SubfolderVoiceMatcher.match(transcript: "die zweite bitte", options: options)?.name, "Kapitel Zwei")
        XCTAssertEqual(SubfolderVoiceMatcher.match(transcript: "1", options: options)?.name, "Kapitel Eins")
    }

    func testMatchesByNumberWordBeyondFive() {
        // Regressionstest für die Erweiterung auf 1-20, nötig seit
        // Unterordner unbegrenzt sind (0007_unlimited_subfolders.sql).
        let options = (1...12).map { makeSubfolder(name: "Kapitel \($0)") }
        XCTAssertEqual(SubfolderVoiceMatcher.match(transcript: "zwölf", options: options)?.name, "Kapitel 12")
        XCTAssertEqual(SubfolderVoiceMatcher.match(transcript: "die neunte", options: options)?.name, "Kapitel 9")
    }

    func testMatchesByNameSubstring() {
        let options = [makeSubfolder(name: "Kapitel Eins"), makeSubfolder(name: "Kapitel Zwei Vertiefung")]
        XCTAssertEqual(
            SubfolderVoiceMatcher.match(transcript: "kapitel zwei vertiefung bitte", options: options)?.name,
            "Kapitel Zwei Vertiefung"
        )
    }

    func testMatchesByLooseWordOverlapAsLastResort() {
        let options = [makeSubfolder(name: "Kapitel Eins Grundlagen"), makeSubfolder(name: "Kapitel Zwei Vertiefung")]
        XCTAssertEqual(
            SubfolderVoiceMatcher.match(transcript: "ich möchte gerne das mit Grundlagen lernen", options: options)?.name,
            "Kapitel Eins Grundlagen"
        )
    }

    func testReturnsNilWhenNothingMatches() {
        let options = [makeSubfolder(name: "Kapitel Eins"), makeSubfolder(name: "Kapitel Zwei")]
        XCTAssertNil(SubfolderVoiceMatcher.match(transcript: "asdf qwer xyz", options: options))
    }

    func testReturnsNilForEmptyTranscript() {
        let options = [makeSubfolder(name: "Kapitel Eins")]
        XCTAssertNil(SubfolderVoiceMatcher.match(transcript: "   ", options: options))
    }

    func testNumberWordOutOfRangeDoesNotCrash() {
        // Nur 1 Option, aber "fünf" gesagt -> darf nicht out-of-bounds crashen,
        // muss stattdessen weiter zu den anderen Erkennungsstufen fallen.
        let options = [makeSubfolder(name: "Einziger Ordner")]
        XCTAssertNil(SubfolderVoiceMatcher.match(transcript: "fünf", options: options))
    }

    func testYesNoRecognition() {
        XCTAssertEqual(SubfolderVoiceMatcher.matchYesNo(transcript: "ja klar"), true)
        XCTAssertEqual(SubfolderVoiceMatcher.matchYesNo(transcript: "nein danke"), false)
        XCTAssertNil(SubfolderVoiceMatcher.matchYesNo(transcript: "vielleicht"))
        XCTAssertNil(SubfolderVoiceMatcher.matchYesNo(transcript: ""))
    }
}
