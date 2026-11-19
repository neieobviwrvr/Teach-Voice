import XCTest
@testable import TeachVoice

/// "Halten zum Nachdenken": solange der Kreis gedrückt ist, beendet Stille
/// die Aufnahme nie; sonst gilt die 8-Sekunden-Denkpause nach dem ersten Wort.
final class RecordingStopRuleTests: XCTestCase {

    private func stop(
        speech: Bool = true,
        silence: TimeInterval = 0,
        total: TimeInterval = 10,
        holding: Bool = false
    ) -> Bool {
        RecordingStopRule.shouldStop(
            hasDetectedSpeech: speech,
            silenceElapsed: silence,
            silenceTimeout: 8,
            totalElapsed: total,
            maxDuration: 90,
            holding: holding,
            maxHoldDuration: 300
        )
    }

    func testEightSecondsOfSilenceAfterSpeakingStops() {
        XCTAssertFalse(stop(silence: 7.8))
        XCTAssertTrue(stop(silence: 8))
    }

    func testSilenceBeforeTheFirstWordDoesNotStop() {
        XCTAssertFalse(stop(speech: false, silence: 30, total: 30))
    }

    func testWithoutHoldingTheSafetyNetIsNinetySeconds() {
        XCTAssertFalse(stop(speech: false, total: 89.8))
        XCTAssertTrue(stop(speech: false, total: 90))
    }

    func testHoldingIgnoresSilence() {
        XCTAssertFalse(stop(silence: 20, total: 40, holding: true))
    }

    func testHoldingExtendsTheLimitToFiveMinutes() {
        XCTAssertFalse(stop(silence: 100, total: 120, holding: true))
        XCTAssertFalse(stop(total: 299.8, holding: true))
        XCTAssertTrue(stop(total: 300, holding: true))
    }

    func testElapsedLabel() {
        XCTAssertEqual(HoldToThinkButton.elapsedLabel(7.9), "0:07")
        XCTAssertEqual(HoldToThinkButton.elapsedLabel(83), "1:23")
        XCTAssertEqual(HoldToThinkButton.elapsedLabel(-1), "0:00")
    }
}
