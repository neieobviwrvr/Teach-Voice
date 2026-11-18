import XCTest
@testable import TeachVoice

final class ZielnoteTests: XCTestCase {

    func testAnchorPointsOfTheScale() {
        XCTAssertEqual(Zielnote(1.0).richtigAbProzent, 95)
        XCTAssertEqual(Zielnote(2.0).richtigAbProzent, 80)
        XCTAssertEqual(Zielnote(3.0).richtigAbProzent, 65)
        XCTAssertEqual(Zielnote(4.0).richtigAbProzent, 50)
    }

    func testIntermediateGradesAreExact() {
        // 2,3 ist als Double nicht exakt darstellbar -- die Schwelle muss
        // trotzdem exakt 75,5 sein, sonst kippt ein Grenzwert ins Falsche.
        XCTAssertEqual(Zielnote(2.3).richtigAbProzent, 75.5)
        XCTAssertEqual(Zielnote(1.5).richtigAbProzent, 87.5)
        XCTAssertEqual(Zielnote(2.3).teilweiseAbProzent, 55.5)
    }

    func testUrteilThresholdsAreInclusive() {
        let note = Zielnote(2.3)
        XCTAssertEqual(note.urteil(fromDeckungProzent: 75.5), .richtig)
        XCTAssertEqual(note.urteil(fromDeckungProzent: 75.4), .teilweise)
        XCTAssertEqual(note.urteil(fromDeckungProzent: 55.5), .teilweise)
        XCTAssertEqual(note.urteil(fromDeckungProzent: 55.4), .falsch)
        XCTAssertEqual(note.urteil(fromDeckungProzent: 0), .falsch)
        XCTAssertEqual(note.urteil(fromDeckungProzent: 100), .richtig)
    }

    func testStricterGradeNeedsMoreCoverage() {
        let deckung = 80.0
        XCTAssertEqual(Zielnote(2.0).urteil(fromDeckungProzent: deckung), .richtig)
        XCTAssertEqual(Zielnote(1.3).urteil(fromDeckungProzent: deckung), .teilweise)
    }

    func testValuesAreClampedAndRoundedToOneDecimal() {
        XCTAssertEqual(Zielnote(0.5).zehntel, 10)
        XCTAssertEqual(Zielnote(5.0).zehntel, 40)
        // Stepper-Gleitkomma-Rauschen wie 2.3000000000000003 -> 2,3
        XCTAssertEqual(Zielnote(2.3000000000000003).zehntel, 23)
        XCTAssertEqual(Zielnote(2.2999999999999998).zehntel, 23)
    }

    func testGermanDisplay() {
        XCTAssertEqual(Zielnote(2.3).anzeige, "2,3")
        XCTAssertEqual(Zielnote(1.0).anzeige, "1,0")
        XCTAssertEqual(Zielnote(4.0).anzeige, "4,0")
    }

    func testDescriptionUsesGermanPercentFormat() {
        XCTAssertEqual(Zielnote(2.0).beschreibung, "Richtig ab 80 % der Kernthemen, teilweise richtig ab 60 %.")
        XCTAssertEqual(Zielnote(2.3).beschreibung, "Richtig ab 75,5 % der Kernthemen, teilweise richtig ab 55,5 %.")
    }
}
