import XCTest
@testable import TeachVoice

/// Regressionstests exakt gegen die drei Beispiele, die Simon beim Festlegen
/// dieser Logik selbst vorgegeben hat – falls sich hier je etwas verschiebt
/// (z.B. durch eine spätere Refaktorierung), soll der Test sofort rot werden.
final class StudySessionSummarySpeechTests: XCTestCase {

    func testExampleTwoRichtigOneTeilweiseZeroFalsch() {
        let result = StudySessionSummarySpeech.statsClause(richtig: 2, teilweise: 1, falsch: 0)
        XCTAssertEqual(result, "zwei Fragen richtig und eine Frage teilweise richtig")
    }

    func testExampleOneRichtigZeroTeilweiseThreeFalsch() {
        let result = StudySessionSummarySpeech.statsClause(richtig: 1, teilweise: 0, falsch: 3)
        XCTAssertEqual(result, "eine Frage richtig und drei Fragen falsch")
    }

    func testExampleTwoRichtigTwoTeilweiseOneFalsch() {
        let result = StudySessionSummarySpeech.statsClause(richtig: 2, teilweise: 2, falsch: 1)
        XCTAssertEqual(result, "zwei Fragen richtig, zwei Fragen teilweise richtig und eine Frage falsch")
    }

    func testAllZeroReturnsNil() {
        // Leere Session o.ä. – der Aufrufer muss dann selbst einen Satz
        // ohne Statistik-Teil bauen, siehe VoiceStudyView.summarySentence.
        XCTAssertNil(StudySessionSummarySpeech.statsClause(richtig: 0, teilweise: 0, falsch: 0))
    }

    func testSingleCategoryOnly() {
        XCTAssertEqual(StudySessionSummarySpeech.statsClause(richtig: 3, teilweise: 0, falsch: 0), "drei Fragen richtig")
    }

    func testSingleCardExactlyOne() {
        XCTAssertEqual(StudySessionSummarySpeech.statsClause(richtig: 1, teilweise: 0, falsch: 0), "eine Frage richtig")
    }

    func testTenIsStillANumberWord() {
        let result = StudySessionSummarySpeech.statsClause(richtig: 10, teilweise: 0, falsch: 0)
        XCTAssertEqual(result, "zehn Fragen richtig")
    }

    func testLargerCountsFallBackToDigits() {
        // Keine Kartenlimits mehr -- über 10 kommen Ziffern statt Zahlwörtern.
        let result = StudySessionSummarySpeech.statsClause(richtig: 42, teilweise: 0, falsch: 0)
        XCTAssertEqual(result, "42 Fragen richtig")
    }
}
