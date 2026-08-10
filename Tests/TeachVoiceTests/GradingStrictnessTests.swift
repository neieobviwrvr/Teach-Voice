import XCTest
@testable import TeachVoice

final class GradingStrictnessTests: XCTestCase {

    func testNormalThresholds() {
        XCTAssertEqual(GradingStrictness.normal.urteil(fromDeckungProzent: 65), .richtig)
        XCTAssertEqual(GradingStrictness.normal.urteil(fromDeckungProzent: 64.9), .teilweise)
        XCTAssertEqual(GradingStrictness.normal.urteil(fromDeckungProzent: 45), .teilweise)
        XCTAssertEqual(GradingStrictness.normal.urteil(fromDeckungProzent: 44.9), .falsch)
        XCTAssertEqual(GradingStrictness.normal.urteil(fromDeckungProzent: 0), .falsch)
        XCTAssertEqual(GradingStrictness.normal.urteil(fromDeckungProzent: 100), .richtig)
    }

    func testTryhardThresholds() {
        XCTAssertEqual(GradingStrictness.tryhard.urteil(fromDeckungProzent: 85), .richtig)
        XCTAssertEqual(GradingStrictness.tryhard.urteil(fromDeckungProzent: 84.9), .teilweise)
        XCTAssertEqual(GradingStrictness.tryhard.urteil(fromDeckungProzent: 65), .teilweise)
        XCTAssertEqual(GradingStrictness.tryhard.urteil(fromDeckungProzent: 64.9), .falsch)
    }

    func testSameDeckungCanDifferBetweenModes() {
        // Genau die von Simon bewusst akzeptierte Konsequenz: dieselbe Deckung
        // kann je nach Modus unterschiedlich eingestuft werden.
        let deckung = 70.0
        XCTAssertEqual(GradingStrictness.normal.urteil(fromDeckungProzent: deckung), .richtig)
        XCTAssertEqual(GradingStrictness.tryhard.urteil(fromDeckungProzent: deckung), .teilweise)
    }
}
