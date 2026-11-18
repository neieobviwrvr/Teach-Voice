import XCTest
@testable import TeachVoice

/// Die App muss sowohl die neue Server-Antwort (Einzelurteil pro
/// Kontrollpunkt) als auch die alte (ohne `punkte`, ohne `kurzloesung`)
/// verstehen -- sonst bricht die Bewertung, solange `grade-answer` noch nicht
/// neu deployt ist.
final class GradingResultDecodingTests: XCTestCase {

    func testDecodesNewResponseWithPerPointVerdicts() throws {
        let json = """
        {
          "kernelemente_getroffen": 1,
          "deckung_prozent": 75,
          "getroffene_elemente": ["blendet innere Vorgänge aus"],
          "fehlende_elemente": ["wissenschaftlich unfruchtbar"],
          "urteil": "richtig",
          "kurzes_feedback": "",
          "kurzloesung": "Außerdem gilt er als wissenschaftlich unfruchtbar.",
          "punkte": [
            {"text": "blendet innere Vorgänge aus", "status": "getroffen", "beleg": "bezieht geistige Vorgänge nicht ein"},
            {"text": "wissenschaftlich unfruchtbar", "status": "teilweise", "beleg": "bringt wissenschaftlich wenig"}
          ]
        }
        """
        let result = try JSONDecoder().decode(GradingResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.deckungProzent, 75)
        XCTAssertEqual(result.punkte?.map(\.status), [.getroffen, .teilweise])
        XCTAssertEqual(result.punkte?.first?.beleg, "bezieht geistige Vorgänge nicht ein")
        XCTAssertEqual(result.kurzloesung, "Außerdem gilt er als wissenschaftlich unfruchtbar.")
    }

    func testDecodesOldResponseWithoutNewFields() throws {
        let json = """
        {
          "kernelemente_getroffen": 1,
          "deckung_prozent": 50,
          "getroffene_elemente": ["a"],
          "fehlende_elemente": ["b"],
          "urteil": "teilweise",
          "kurzes_feedback": "Fast."
        }
        """
        let result = try JSONDecoder().decode(GradingResult.self, from: Data(json.utf8))

        XCTAssertNil(result.punkte)
        XCTAssertNil(result.kurzloesung)
        XCTAssertEqual(result.fehlendeElemente, ["b"])
    }
}
