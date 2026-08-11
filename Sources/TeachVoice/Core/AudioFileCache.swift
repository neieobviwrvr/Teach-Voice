import Foundation

/// Lokaler Datei-Cache für per Cloud-TTS synthetisierte Audioclips, geschlüsselt
/// über einen Hash aus Text+Stimme (`TextHash`, wie schon für den Kernelemente-
/// Cache verwendet). Grund: dieselbe Karteikarten-Frage wird bei Spaced
/// Repetition oft wiederholt vorgelesen -- ohne diesen Cache würde jedes
/// erneute Anhören einen neuen (wenn auch günstigen) Cloud-TTS-Call auslösen.
///
/// Bewusst im `.cachesDirectory` statt Application Support -- das sind reine,
/// jederzeit neu erzeugbare Daten (ein Cache-Miss löst einfach eine neue
/// Synthese aus), genau die Art Inhalt, die iOS bei Speicherdruck ohne
/// Rückfrage löschen darf.
///
/// Rein lokal, kein Server-Storage -- funktioniert dadurch identisch für
/// Cloud- und Gastmodus, wie der Rest der App.
enum AudioFileCache {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("CloudSpeechCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheKey(text: String, voice: String) -> String {
        TextHash.sha256("\(voice)|\(text)")
    }

    private static func fileURL(text: String, voice: String) -> URL {
        directory.appendingPathComponent("\(cacheKey(text: text, voice: voice)).mp3")
    }

    /// `nil`, falls für diesen Text+Stimme noch kein Clip gecacht ist.
    static func cachedFileURL(text: String, voice: String) -> URL? {
        let url = fileURL(text: text, voice: voice)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Schreibt den Clip in den Cache und liefert seine URL zurück, oder `nil`
    /// falls das Schreiben fehlschlägt (dann wird beim nächsten Mal einfach
    /// erneut synthetisiert -- kein harter Fehler wert).
    @discardableResult
    static func store(_ data: Data, text: String, voice: String) -> URL? {
        let url = fileURL(text: text, voice: voice)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
