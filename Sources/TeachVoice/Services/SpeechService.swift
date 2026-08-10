import AVFoundation

/// Liest Karteikarten-Text über die native, kostenlose On-Device-TTS des iPhones vor.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    func speak(_ text: String, languageHint: String? = nil) {
        guard !text.isEmpty else { return }
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: languageHint ?? detectedLanguage(for: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(utterance)
    }

    /// Für den Hands-free-Modus: wartet, bis die Frage fertig vorgelesen ist,
    /// bevor der nächste Schritt (Mikro freigeben) losläuft.
    func speakAndWait(_ text: String, languageHint: String? = nil) async {
        guard !text.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Reihenfolge wichtig: speak() ruft intern stop() auf, das einen
            // ggf. noch offenen pendingContinuation sofort auflöst. Würde man
            // die neue Continuation VOR speak() setzen, würde genau dieser
            // stop()-Aufruf sie sofort wieder auflösen, bevor die Ansage
            // überhaupt begonnen hat – speakAndWait kehrte dann quasi sofort
            // zurück statt wirklich auf das Ende der Sprachausgabe zu warten.
            speak(text, languageHint: languageHint)
            pendingContinuation = continuation
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    /// Sehr einfache Heuristik: deutsches Gerätegebietsschema als Default,
    /// da die App primär für deutschsprachige Studierende gedacht ist.
    private func detectedLanguage(for text: String) -> String {
        Locale.preferredLanguages.first ?? "de-DE"
    }

    fileprivate func resolvePendingContinuation() {
        pendingContinuation?.resume()
        pendingContinuation = nil
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.resolvePendingContinuation()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.resolvePendingContinuation()
        }
    }
}
