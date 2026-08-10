import AVFoundation

/// Liest Karteikarten-Text über die native, kostenlose On-Device-TTS des iPhones vor.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingContinuation: CheckedContinuation<Void, Never>?
    /// Zählt, wie viele Utterances aus dem aktuellen Aufruf noch ausstehen –
    /// nötig für `speakSequenceAndWait`, wo mehrere Utterances hintereinander
    /// in der Warteschlange stehen und erst die LETZTE die Continuation
    /// auflösen darf, nicht schon die erste.
    private var remainingUtterances = 0

    override init() {
        super.init()
        synthesizer.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    func speak(_ text: String, languageHint: String? = nil) {
        guard !text.isEmpty else { return }
        stop()
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(makeUtterance(text, languageHint: languageHint))
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
            remainingUtterances = 1
            pendingContinuation = continuation
        }
    }

    /// Liest mehrere Textabschnitte nacheinander vor, mit einer festen Pause
    /// zwischen den Abschnitten (z.B. die Unterordner-Aufzählung im
    /// Hands-free-Sprachmenü: eine Pause nach jedem Namen, statt alles in
    /// einem Rutsch vorzulesen, damit man die einzelnen Namen auch versteht).
    func speakSequenceAndWait(_ segments: [String], pauseBetween: TimeInterval, languageHint: String? = nil) async {
        let nonEmpty = segments.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        stop()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            try? AVAudioSession.sharedInstance().setActive(true)
            for (index, text) in nonEmpty.enumerated() {
                let utterance = makeUtterance(text, languageHint: languageHint)
                if index < nonEmpty.count - 1 {
                    utterance.postUtteranceDelay = pauseBetween
                }
                synthesizer.speak(utterance)
            }
            remainingUtterances = nonEmpty.count
            pendingContinuation = continuation
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        remainingUtterances = 0
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    private func makeUtterance(_ text: String, languageHint: String?) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: languageHint ?? detectedLanguage(for: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return utterance
    }

    /// Sehr einfache Heuristik: deutsches Gerätegebietsschema als Default,
    /// da die App primär für deutschsprachige Studierende gedacht ist.
    private func detectedLanguage(for text: String) -> String {
        Locale.preferredLanguages.first ?? "de-DE"
    }

    fileprivate func utteranceDidFinishOrCancel() {
        guard remainingUtterances > 0 else { return }
        remainingUtterances -= 1
        if remainingUtterances == 0 {
            pendingContinuation?.resume()
            pendingContinuation = nil
        }
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.utteranceDidFinishOrCancel()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.utteranceDidFinishOrCancel()
        }
    }
}
