import XCTest
import CoreGraphics
@testable import TeachVoice

/// Kreis an den Rand ziehen = überspringen mit Lösung -- aber ein leichtes
/// Abrutschen beim Nachdenken darf nie die Antwort verwerfen.
final class HoldReleaseRuleTests: XCTestCase {

    /// iPhone-Fenster in Punkten; der Kreis sitzt unten in der Mitte.
    private let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
    private let circleCenter = CGPoint(x: 196, y: 762)

    func testReleasingInTheMiddleIsNotASkip() {
        let moved = CGPoint(x: 196, y: 400)
        XCTAssertFalse(HoldReleaseRule.isInSkipZone(location: moved, start: circleCenter, bounds: bounds))
    }

    func testEveryEdgeCounts() {
        let edges = [
            CGPoint(x: 5, y: 500),     // links
            CGPoint(x: 390, y: 500),   // rechts
            CGPoint(x: 196, y: 10),    // oben
            CGPoint(x: 196, y: 845),   // unten
        ]
        for point in edges {
            XCTAssertTrue(HoldReleaseRule.isInSkipZone(location: point, start: circleCenter, bounds: bounds),
                          "Rand bei \(point) muss überspringen")
        }
    }

    func testSmallSlipNearTheBottomIsNotASkip() {
        // Kreis unten angefasst und beim Nachdenken ein Stück abgerutscht.
        let start = CGPoint(x: 196, y: 805)
        let slipped = CGPoint(x: 200, y: 840)
        XCTAssertFalse(HoldReleaseRule.isInSkipZone(location: slipped, start: start, bounds: bounds))
    }

    func testUnknownWindowNeverSkips() {
        XCTAssertFalse(HoldReleaseRule.isInSkipZone(location: CGPoint(x: 1, y: 1), start: circleCenter, bounds: .zero))
    }

    func testReleaseDecision() {
        XCTAssertEqual(HoldReleaseRule.release(heldFor: 2, inSkipZone: false), .submit)
        XCTAssertEqual(HoldReleaseRule.release(heldFor: 0.2, inSkipZone: false), .tap,
                       "Kurzes Antippen gibt nichts ab")
        XCTAssertEqual(HoldReleaseRule.release(heldFor: 0.3, inSkipZone: true), .skipWithSolution,
                       "Schnelles Wegwischen an den Rand überspringt auch")
        XCTAssertEqual(HoldReleaseRule.release(heldFor: 30, inSkipZone: true), .skipWithSolution)
    }
}
