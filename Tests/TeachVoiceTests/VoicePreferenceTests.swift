import XCTest
@testable import TeachVoice

final class VoicePreferenceTests: XCTestCase {

    private let keys = [VoicePreference.sourceKey, VoicePreference.googleVoiceKey, VoicePreference.speakingRateKey]
    private var savedValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            savedValues[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = savedValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    // MARK: - Google-Stimme

    func testGoogleVoiceDefaultsToPreviousWaveNetVoice() {
        XCTAssertEqual(VoicePreference.googleVoice, .standard)
        XCTAssertEqual(CloudVoice.standard.id, "de-DE-Wavenet-G")
    }

    func testGoogleVoiceRoundTripAndUnknownIdFallsBack() {
        let despina = CloudVoice.mitID("de-DE-Chirp3-HD-Despina")
        XCTAssertNotNil(despina)
        VoicePreference.googleVoice = despina!
        XCTAssertEqual(VoicePreference.googleVoice.name, "Despina")

        UserDefaults.standard.set("de-DE-Studio-B", forKey: VoicePreference.googleVoiceKey)
        XCTAssertEqual(VoicePreference.googleVoice, .standard, "Nicht erlaubte Stimmen darf die App nie anfragen.")
    }

    func testVoiceListIsUniqueGermanAndContainsDefault() {
        let ids = CloudVoice.alle.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("de-DE-") })
        XCTAssertTrue(ids.contains(CloudVoice.standard.id))
    }

    // MARK: - Tempo

    func testSpeakingRateDefaultsToNormal() {
        XCTAssertEqual(VoicePreference.speakingRate, 1.0, accuracy: 0.0001)
    }

    func testSpeakingRateIsClampedAndRoundedToSteps() {
        VoicePreference.speakingRate = 0.83
        XCTAssertEqual(VoicePreference.speakingRate, 0.85, accuracy: 0.0001)
        VoicePreference.speakingRate = 0.2
        XCTAssertEqual(VoicePreference.speakingRate, VoicePreference.minSpeakingRate, accuracy: 0.0001)
        VoicePreference.speakingRate = 3.0
        XCTAssertEqual(VoicePreference.speakingRate, VoicePreference.maxSpeakingRate, accuracy: 0.0001)
    }

    func testRateLabelIsGerman() {
        XCTAssertEqual(VoicePreference.rateLabel(0.85), "0,85×")
        XCTAssertEqual(VoicePreference.rateLabel(1.0), "1,00×")
    }

    func testCacheKeyDiffersByVoiceAndRate() {
        let despina = CloudVoice.mitID("de-DE-Chirp3-HD-Despina")!
        let wavenet = CloudVoice.standard
        XCTAssertNotEqual(CloudSpeechConfig.cacheKey(voice: despina, speakingRate: 1.0),
                          CloudSpeechConfig.cacheKey(voice: wavenet, speakingRate: 1.0))
        XCTAssertNotEqual(CloudSpeechConfig.cacheKey(voice: despina, speakingRate: 0.85),
                          CloudSpeechConfig.cacheKey(voice: despina, speakingRate: 1.0))
        // Stepper-Rauschen darf keinen neuen Cache-Eintrag erzeugen.
        XCTAssertEqual(CloudSpeechConfig.cacheKey(voice: despina, speakingRate: 0.8500000000000001),
                       CloudSpeechConfig.cacheKey(voice: despina, speakingRate: 0.85))
    }

    // MARK: - Quelle

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
