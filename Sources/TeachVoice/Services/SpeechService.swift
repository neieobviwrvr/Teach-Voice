import AVFoundation

/// Liest Karteikarten-Text vor -- bevorzugt über Cloud-TTS (Google Cloud
/// WaveNet, siehe `CloudSpeechService`/`text-to-speech`-Edge-Function), mit
/// automatischem Fallback auf die native, kostenlose On-Device-TTS
/// (`AVSpeechSynthesizer`), falls kein Netz da ist oder der Cloud-Call
/// fehlschlägt.
///
/// Grund für den Wechsel weg von reinem on-device TTS: empirisch bestätigt
/// (siehe Chat-Historie), dass viele User real nur Apples Standard-
/// Kompaktstimme zur Verfügung haben -- Enhanced/Premium-Stimmen erfordern
/// manuellen Download in den Systemeinstellungen (oft hunderte MB, macht
/// niemand im Prüfungsstress), Siri-Stimmen sind für Drittanbieter-Apps
/// grundsätzlich gesperrt. Der lokale Fallback bleibt trotzdem bestehen --
/// die App soll auch ganz ohne Internet nutzbar sein, nur eben mit
/// schlechterer Stimmqualität.
///
/// Cloud-Antworten werden lokal gecacht (`AudioFileCache`, Hash aus
/// Text+Stimme) -- dieselbe Frage wird bei Spaced Repetition oft wiederholt
/// vorgelesen, aber nur beim ersten Mal tatsächlich synthetisiert.
@MainActor
final class SpeechService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    /// Der Hintergrund-Task, der den Cloud-Fetch (+ ggf. lokalen Fallback)
    /// einer einzelnen `speak()`-Anfrage antreibt. `stop()` bricht ihn immer
    /// zuerst ab -- sonst könnte eine gerade noch ladende alte Anfrage nach
    /// einem neuen `speak()`-Aufruf verspätet doch noch losplärren.
    private var cloudTask: Task<Void, Never>?
    /// Für `speakAndWait`: löst auf, sobald die aktuelle Ansage fertig ist --
    /// ob per lokalem Synthesizer (Delegate) oder per Cloud-Wiedergabe
    /// (AVAudioPlayer-Delegate), beide lösen dieselbe Continuation auf.
    private var pendingContinuation: CheckedContinuation<Void, Never>?
    /// Zählt jede Ansage hoch (und jedes `stop()`). Alles, was asynchron zu
    /// einer ÄLTEREN Ansage gehört -- ein verspätet geladenes Cloud-Audio,
    /// ein noch nicht gestarteter Task, ein verspäteter Delegate-Rückruf --,
    /// prüft vor dem Abspielen bzw. Beenden, ob es noch aktuell ist, und
    /// verwirft sich sonst. So kann nie eine alte Ansage über eine neue
    /// laufen oder deren `speakAndWait` vorzeitig beenden (genau das sah
    /// Simon beim Testen: erst Stille, dann mehrere Ansagen übereinander).
    private var generation = 0
    /// Die aktuell laufende lokale Ansage bzw. Cloud-Wiedergabe -- nur deren
    /// Delegate-Rückrufe dürfen `speakAndWait` beenden.
    private var currentUtterance: AVSpeechUtterance?

    private let auth: AuthManager

    init(auth: AuthManager) {
        self.auth = auth
        super.init()
        synthesizer.delegate = self
        // Kategorie wird NICHT hier fest gesetzt, sondern einheitlich über
        // AudioSessionCoordinator -- siehe dortige Doku, Grund ist Barge-in
        // (Mikrofon hört schon während einer laufenden Ansage mit).
    }

    /// `voice` überschreibt die normale Cloud-/Auto-Ermittlung komplett und
    /// erzwingt lokale Apple-Synthese -- nur für `VoicePickerView`s
    /// "Anhören"-Button gedacht, der GENAU DIESE eine on-device Stimme
    /// vorspielen will. Normale Aufrufstellen lassen den Parameter weg und
    /// bekommen den Cloud-Pfad (mit lokalem Fallback bei Fehler).
    func speak(_ text: String, voice: AVSpeechSynthesisVoice? = nil, languageHint: String? = nil) {
        guard !text.isEmpty else { return }
        stop()
        generation += 1
        let myGeneration = generation
        AudioSessionCoordinator.activate()

        if let voice {
            speakLocally(text, voice: voice, languageHint: languageHint, generation: myGeneration)
            return
        }

        // Optimistisch schon hier gesetzt (nicht erst wenn die Cloud-Antwort
        // tatsächlich eintrifft) -- sonst würde z.B. ein "Spielt ab…"-Button
        // während des kurzen Netzwerk-Ladens fälschlich "Vorlesen" anzeigen.
        isSpeaking = true
        cloudTask = Task { [weak self] in
            await self?.speakPreferCloud(text, languageHint: languageHint, generation: myGeneration)
        }
    }

    /// Lädt die Cloud-Stimme für diese Texte schon vorab in den Cache, ohne
    /// etwas abzuspielen -- z.B. die nächste Frage, während der User noch
    /// antwortet. Die spätere Ansage startet dann sofort statt nach einer
    /// Netzwerk-Pause. Fehler werden still ignoriert: beim eigentlichen
    /// Vorlesen greift ohnehin der normale Weg samt lokalem Fallback.
    /// Kostet nichts extra, weil genau diese Texte sonst kurz danach ohnehin
    /// geladen würden (gleicher Cache-Schlüssel wie `speak`).
    func prefetch(_ texts: [String]) async {
        let voiceKey = CloudSpeechConfig.voiceIdentifier
        for text in texts where !text.isEmpty {
            if Task.isCancelled { return }
            guard AudioFileCache.cachedFileURL(text: text, voice: voiceKey) == nil else { continue }
            do {
                let token = await auth.validAccessToken()
                let data = try await CloudSpeechService.synthesize(text: text, accessToken: token)
                _ = AudioFileCache.store(data, text: text, voice: voiceKey)
            } catch {
                return
            }
        }
    }

    /// Für den Hands-free-Modus: wartet, bis die Ansage fertig ist (Cloud
    /// ODER lokaler Fallback), bevor der nächste Schritt losläuft.
    func speakAndWait(_ text: String, languageHint: String? = nil) async {
        guard !text.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Reihenfolge wichtig: speak() ruft intern stop() auf, das eine
            // ggf. noch offene Continuation sofort auflöst. Würde man die neue
            // Continuation VOR speak() setzen, würde genau dieser stop()-
            // Aufruf sie sofort wieder auflösen, bevor die Ansage überhaupt
            // begonnen hat.
            speak(text, languageHint: languageHint)
            pendingContinuation = continuation
        }
    }

    func stop() {
        // Macht alles ungültig, was noch zu einer älteren Ansage unterwegs ist.
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        currentUtterance = nil
        audioPlayer?.stop()
        audioPlayer = nil
        cloudTask?.cancel()
        cloudTask = nil
        isSpeaking = false
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    // MARK: - Cloud-Pfad

    private func speakPreferCloud(_ text: String, languageHint: String?, generation myGeneration: Int) async {
        let voiceKey = CloudSpeechConfig.voiceIdentifier

        if let cached = AudioFileCache.cachedFileURL(text: text, voice: voiceKey) {
            playCloudAudio(fileURL: cached, text: text, languageHint: languageHint, generation: myGeneration)
            return
        }

        do {
            let token = await auth.validAccessToken()
            let data = try await CloudSpeechService.synthesize(text: text, accessToken: token)
            // Auch eine inzwischen überholte Antwort landet im Cache -- sie
            // ist bezahlt und wird beim nächsten Mal gebraucht --, wird aber
            // nicht mehr abgespielt (Prüfung in `playCloudAudio`).
            let cachedURL = AudioFileCache.store(data, text: text, voice: voiceKey)
            if let cachedURL {
                playCloudAudio(fileURL: cachedURL, text: text, languageHint: languageHint, generation: myGeneration)
            } else {
                // Schreiben in den Cache fehlgeschlagen (z.B. Speicher voll) --
                // trotzdem direkt aus den Bytes abspielen.
                playCloudAudio(data: data, text: text, languageHint: languageHint, generation: myGeneration)
            }
        } catch {
            // Kein Netz / Edge Function nicht erreichbar / Rate-Limit erreicht
            // -- App bleibt trotzdem benutzbar, nur mit schlechterer Stimme.
            speakLocally(text, voice: nil, languageHint: languageHint, generation: myGeneration)
        }
    }

    private func playCloudAudio(fileURL: URL, text: String, languageHint: String?, generation myGeneration: Int) {
        play(try? AVAudioPlayer(contentsOf: fileURL), text: text, languageHint: languageHint, generation: myGeneration)
    }

    private func playCloudAudio(data: Data, text: String, languageHint: String?, generation myGeneration: Int) {
        play(try? AVAudioPlayer(data: data), text: text, languageHint: languageHint, generation: myGeneration)
    }

    private func play(_ player: AVAudioPlayer?, text: String, languageHint: String?, generation myGeneration: Int) {
        // Inzwischen kam eine neuere Ansage oder ein stop(): nichts abspielen.
        guard myGeneration == generation else { return }
        if let player {
            // Delegate und Referenz VOR dem Start setzen, damit das Ende der
            // Wiedergabe garantiert dieser Ansage zugeordnet wird.
            player.delegate = self
            audioPlayer = player
            if player.play() {
                isSpeaking = true
                return
            }
            audioPlayer = nil
        }
        // Kaputte/nicht abspielbare Audiodaten: lieber lokal vorlesen, als
        // stumm zu bleiben -- und vor allem nie ein `speakAndWait` ewig hängen
        // lassen (das blockierte früher den ganzen Lernablauf).
        speakLocally(text, voice: nil, languageHint: languageHint, generation: myGeneration)
    }

    // MARK: - Lokaler Fallback (Apple TTS)

    private func speakLocally(_ text: String, voice: AVSpeechSynthesisVoice?, languageHint: String?, generation myGeneration: Int) {
        guard myGeneration == generation else { return }
        let utterance = makeUtterance(text, voice: voice, languageHint: languageHint)
        currentUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
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

    /// Wählt die lokale Fallback-Stimme für die gegebene Sprache:
    /// 0. Hat der User in `VoicePickerView` manuell eine Stimme gewählt
    ///    (`VoicePreference.selectedIdentifier`), hat die immer Vorrang --
    ///    ein ungültig gewordener Identifier liefert `nil` und fällt
    ///    automatisch auf `automaticVoice` zurück.
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
    /// KEINE Siri-Stimmen-Sonderbehandlung (gab es hier früher) -- empirisch
    /// bei Simon bestätigt: Apple gibt Drittanbieter-Apps über diese API
    /// keinen Zugriff auf die als "Siri-Stimme 1-4" gebrandeten Personas.
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

    fileprivate func finishSpeaking() {
        isSpeaking = false
        pendingContinuation?.resume()
        pendingContinuation = nil
    }

    /// Beendet nur, wenn der Rückruf zur GERADE laufenden lokalen Ansage
    /// gehört. Ein verspätetes "didCancel" einer gestoppten älteren Ansage
    /// würde sonst das `speakAndWait` der neuen Ansage vorzeitig auflösen --
    /// der Lernablauf liefe weiter (Signalton, Aufnahme), während die App
    /// noch spricht.
    ///
    /// Vergleich per Objekt-Identität (`===`) mit festgehaltener Referenz
    /// statt per Speicheradresse: so kann eine neue Ansage nie zufällig die
    /// Adresse einer gerade freigegebenen alten bekommen und verwechselt werden.
    fileprivate func finishIfCurrent(utterance: AVSpeechUtterance) {
        guard currentUtterance === utterance else { return }
        currentUtterance = nil
        finishSpeaking()
    }

    /// Wie oben, für die Cloud-Wiedergabe.
    fileprivate func finishIfCurrent(player: AVAudioPlayer) {
        guard audioPlayer === player else { return }
        audioPlayer = nil
        finishSpeaking()
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishIfCurrent(utterance: utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishIfCurrent(utterance: utterance) }
    }
}

extension SpeechService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishIfCurrent(player: player) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finishIfCurrent(player: player) }
    }
}
