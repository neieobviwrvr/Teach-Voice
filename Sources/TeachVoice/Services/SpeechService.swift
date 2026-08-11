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
        // Kategorie wird NICHT mehr hier fest gesetzt, sondern einheitlich
        // über AudioSessionCoordinator -- siehe dortige Doku, Grund ist
        // Barge-in (Mikrofon hört schon während einer laufenden Ansage mit).
    }

    /// `voice` überschreibt die normale Auto-/Präferenz-Ermittlung komplett –
    /// nur für `VoicePickerView`s "Anhören"-Button gedacht, der GENAU DIESE
    /// eine Stimme vorspielen will, egal was `VoicePreference`/Auto-Logik
    /// sonst wählen würde. Normale Aufrufstellen lassen den Parameter weg.
    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil, languageHint: String? = nil) {
        guard !text.isEmpty else { return }
        stop()
        AudioSessionCoordinator.activate()
        synthesizer.speak(makeUtterance(text, voice: voice, languageHint: languageHint))
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
            AudioSessionCoordinator.activate()
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

    private func makeUtterance(_ text: String, voice: AVSpeechSynthesisVoice? = nil, languageHint: String? = nil) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice ?? Self.preferredVoice(languageCode: languageHint ?? detectedLanguage(for: text))
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        return utterance
    }

    /// Sehr einfache Heuristik: deutsches Gerätegebietsschema als Default,
    /// da die App primär für deutschsprachige Studierende gedacht ist.
    private func detectedLanguage(for text: String) -> String {
        Locale.preferredLanguages.first ?? "de-DE"
    }

    /// Wählt die Stimme für die gegebene Sprache:
    /// 0. Hat der User in `VoicePickerView` manuell eine Stimme gewählt
    ///    (`VoicePreference.selectedIdentifier`), hat die immer Vorrang --
    ///    ein ungültig gewordener Identifier (z.B. Stimme zwischenzeitlich
    ///    wieder gelöscht) liefert `nil` und fällt automatisch auf `automaticVoice` zurück.
    static func preferredVoice(languageCode: String) -> AVSpeechSynthesisVoice? {
        if let identifier = VoicePreference.selectedIdentifier,
           let manual = AVSpeechSynthesisVoice(identifier: identifier) {
            return manual
        }
        return automaticVoice(languageCode: languageCode)
    }

    /// Die "Automatisch"-Kaskade OHNE die manuelle Auswahl aus
    /// `VoicePreference` -- eigenständig aufrufbar, damit `VoicePickerView`
    /// neben "Automatisch (empfohlen)" anzeigen kann, welche Stimme das
    /// GERADE konkret bedeutet.
    ///
    /// 1. Die beste heruntergeladene Enhanced/Premium-Stimme, falls
    ///    `AVSpeechSynthesisVoice.speechVoices()` der App überhaupt eine
    ///    solche meldet.
    /// 2. Sonst Apples Standard-Kompaktstimme (immer verfügbar, auch ganz
    ///    ohne jeden manuellen Download) als letzter Fallback.
    ///
    /// KEINE Siri-Stimmen-Sonderbehandlung mehr (gab es hier früher) --
    /// empirisch bei Simon bestätigt (`VoicePickerView`-Diagnose-Dump: 0 von
    /// 181 vom System gemeldeten Stimmen, über ALLE Sprachen, sind
    /// Siri-Stimmen): Apple gibt Drittanbieter-Apps über diese API keinen
    /// Zugriff auf die als "Siri-Stimme 1-4" gebrandeten Personas, auch
    /// nicht nach vollständigem Download + App-Neustart. Meine frühere
    /// Behauptung, das sei "inzwischen auch für Drittanbieter-Apps nutzbar",
    /// war schlicht falsch.
    static func automaticVoice(languageCode: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }

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
