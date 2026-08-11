import XCTest
@testable import TeachVoice

final class AnswerStyleTests: XCTestCase {

    func testRawValuesMatchEdgeFunctionContract() {
        // Muss exakt mit den in generate-questions/index.ts erwarteten
        // Raw-Values ("kompakt"/"umfassend") übereinstimmen -- ein Tippfehler
        // hier würde serverseitig unbemerkt auf den Default zurückfallen.
        XCTAssertEqual(AnswerStyle.kompakt.rawValue, "kompakt")
        XCTAssertEqual(AnswerStyle.umfassend.rawValue, "umfassend")
    }

    func testAllCasesHaveDistinctLabels() {
        let labels = Set(AnswerStyle.allCases.map(\.label))
        XCTAssertEqual(labels.count, AnswerStyle.allCases.count)
    }

    func testIdMatchesRawValue() {
        for style in AnswerStyle.allCases {
            XCTAssertEqual(style.id, style.rawValue)
        }
    }
}
