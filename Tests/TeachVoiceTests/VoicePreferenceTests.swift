import XCTest
@testable import TeachVoice

final class VoicePreferenceTests: XCTestCase {

    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: VoicePreference.sourceKey)
        UserDefaults.standard.removeObject(forKey: VoicePreference.sourceKey)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: VoicePreference.sourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: VoicePreference.sourceKey)
        }
        super.tearDown()
    }

    func testDefaultsToGoogleLikeBefore() {
        XCTAssertEqual(VoicePreference.source, .google)
    }

    func testRoundTrip() {
        VoicePreference.source = .iphone
        XCTAssertEqual(VoicePreference.source, .iphone)
        VoicePreference.source = .google
        XCTAssertEqual(VoicePreference.source, .google)
    }

    func testUnknownStoredValueFallsBackToGoogle() {
        UserDefaults.standard.set("irgendwas", forKey: VoicePreference.sourceKey)
        XCTAssertEqual(VoicePreference.source, .google)
    }

    func testRawValuesMatchAppStorage() {
        // @AppStorage speichert den rawValue -- muss zu `VoicePreference.source` passen.
        XCTAssertEqual(SpeechSource.iphone.rawValue, "iphone")
        XCTAssertEqual(SpeechSource.google.rawValue, "google")
    }
}
