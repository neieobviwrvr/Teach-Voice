import AVFoundation

/// Zentrale, EINZIGE Stelle, die die `AVAudioSession`-Kategorie setzt.
///
/// Vorher konfigurierten `SpeechService` und `AudioRecorder` unabhängig
/// voneinander JEWEILS EIGENE, unterschiedliche Kategorien/Modi
/// (.playback/.spokenAudio bzw. .playAndRecord/.measurement) -- die sich
/// gegenseitig überschrieben, sobald TTS und Aufnahme sich zeitlich
/// überlappen sollten (Barge-in im Hands-free-Modus: das Mikrofon soll schon
/// WÄHREND einer laufenden Ansage zuhören können, siehe
/// `HandsFreeStudyView.listenWhileSpeakingAndArbitrate`). Beide rufen jetzt
/// dieselbe Konfiguration auf, bevor sie loslegen:
///
/// - `.playAndRecord`: die einzige Kategorie, die gleichzeitiges Abspielen
///   UND Aufnehmen überhaupt erlaubt -- das allein reicht schon für Barge-in
///   (Aufnahme läuft, während TTS noch spielt), unabhängig vom Modus unten.
/// - `.measurement` (NICHT `.voiceChat`!): siehe ausführliche Begründung
///   unten -- kurz: `.voiceChat` hätte Echo-Unterdrückung gebracht, hat aber
///   live die Stille-Erkennung komplett kaputt gemacht, deshalb bewusst
///   wieder zurückgestellt.
/// - `.defaultToSpeaker`: OHNE diese Option leitet `.playAndRecord` auf dem
///   iPhone die Wiedergabe auf den kleinen Hörmuschel-Lautsprecher statt den
///   Hauptlautsprecher um -- eine leicht zu übersehende Falle.
///
/// Bewusst OHNE Gegenstück zum wiederholten Aktivieren/Deaktivieren
/// zwischendurch (z.B. nach jeder einzelnen Aufnahme) -- häufiges
/// setActive(false)/setActive(true) kann hörbare Klicks verursachen und
/// würde bei überlappendem TTS+STT genau die Session kappen, die beide noch
/// brauchen. `deactivate()` ist nur für den Moment gedacht, in dem eine
/// ganze Lern-/Hands-free-Sitzung endet (siehe `stopEverything()` in den
/// jeweiligen Views).
///
/// ZURÜCKGESTELLT von `.voiceChat` auf `.measurement` (Simon meldete: Stille-
/// Erkennung im Voice-only-Modus funktionierte nach dem `.voiceChat`-Wechsel
/// gar nicht mehr): `.voiceChat` schaltet neben Echo-Unterdrückung IMMER
/// zusätzlich Apples Automatic Gain Control + Rauschunterdrückung ein -- das
/// normalisiert leise Umgebungsgeräusche aktiv nach oben, wodurch die
/// Kalibrierung (`AudioRecorder.recordUntilSilence`, erste Sekunde) eine viel
/// zu hohe Schwelle berechnen konnte, die selbst echte Sprache nie mehr
/// eindeutig überschritt -- die App erkannte dann nie "User spricht" und
/// hörte bis zum 45s-Sicherheitsnetz einfach durch. `.measurement` liefert
/// dagegen die rohen, unverfälschten dB-Werte, auf die der ganze Kalibrierungs-
/// /Schwellwert-Algorithmus ausgelegt ist. Der Preis: keine Echo-Unterdrückung
/// mehr -- läuft die TTS-Ansage noch, während bereits aufgenommen wird, hört
/// das Mikrofon sie roh mit (kein Cancelling). Bewusster Kompromiss:
/// verlässliche Stille-Erkennung wiegt schwerer als perfekt echofreies
/// Barge-in, das sich hier ohne echtes Gerät ohnehin nicht fein justieren ließ.
enum AudioSessionCoordinator {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
