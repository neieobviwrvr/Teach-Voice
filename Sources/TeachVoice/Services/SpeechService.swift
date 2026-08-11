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
        utterance.voice = Self.preferredVoice(languageCode: languageHint ?? detectedLanguage(for: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return utterance
    }

    /// Sehr einfache Heuristik: deutsches Gerätegebietsschema als Default,
    /// da die App primär für deutschsprachige Studierende gedacht ist.
    private func detectedLanguage(for text: String) -> String {
        Locale.preferredLanguages.first ?? "de-DE"
    }

    /// Wählt automatisch die beste auf DIESEM Gerät bereits heruntergeladene
    /// Stimme für die gegebene Sprache, statt blind Apples Standard-
    /// Kompaktstimme zu nehmen:
    /// 1. Eine Siri-Stimme, falls unter Einstellungen -> Bedienungshilfen ->
    ///    Gesprochener Inhalt -> Stimmen heruntergeladen (Simons Fall: "Siri
    ///    Stimme 2") -- diese sind inzwischen auch für Drittanbieter-Apps über
    ///    `AVSpeechSynthesisVoice.speechVoices()` nutzbar, nicht mehr
    ///    Siri selbst vorbehalten. Bewusst über den Namen/die Kennung
    ///    gesucht statt eine feste ID hart zu hinterlegen -- die kann sich je
    ///    nach iOS-Version/Region unterscheiden, und so wird automatisch
    ///    genau die eine gefunden, die tatsächlich heruntergeladen ist.
    /// 2. Sonst die beste andere heruntergeladene Enhanced/Premium-Stimme.
    /// 3. Sonst Apples Standard-Kompaktstimme (immer verfügbar, auch ganz
    ///    ohne jeden manuellen Download) als letzter Fallback.
    static func preferredVoice(languageCode: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }

        if let siri = candidates.first(where: {
            $0.name.localizedCaseInsensitiveContains("siri") || $0.identifier.localizedCaseInsensitiveContains("siri")
        }) {
            return siri
        }
        if let premium = candidates.first(where: { $0.quality == .premium }) {
            return premium
        }
        if let enhanced = candidates.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: languageCode)
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
