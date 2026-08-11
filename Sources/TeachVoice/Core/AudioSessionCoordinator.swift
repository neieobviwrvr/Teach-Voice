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
///   UND Aufnehmen überhaupt erlaubt.
/// - `.voiceChat`: aktiviert Apples eingebaute Echo-Unterdrückung (AEC).
///   Ohne die würde das Mikrofon die eigene TTS-Ausgabe aus dem Lautsprecher
///   mit aufnehmen und sowohl die adaptive Stille-Erkennung als auch die
///   Transkription verwirren.
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
/// WICHTIG: dieser gesamte Barge-in-Mechanismus (gleichzeitiges
/// Abspielen+Aufnehmen, Echo-Unterdrückung, adaptive Stille-Schwelle
/// während laufender Wiedergabe) ließ sich hier NICHT auf einem echten Gerät
/// verifizieren (kein Mac/Simulator in dieser Umgebung) -- Simon sollte das
/// nach dem nächsten Build gezielt gegenprüfen, das ist der unsicherste Teil
/// dieser Änderung.
enum AudioSessionCoordinator {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.duckOthers, .defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
