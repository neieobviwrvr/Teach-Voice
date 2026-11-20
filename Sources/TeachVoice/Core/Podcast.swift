import Foundation

/// Ein importierter Podcast (z.B. ein NotebookLM-Audio-Overview zu den
/// eigenen Folien). Liegt NUR auf diesem iPhone -- kein Supabase, kein
/// iCloud-Backup (Simons Wunsch 2026-11-20: "ohne Supabase und ohne den
/// Speicher vollzumüllen").
struct Podcast: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    /// Nur der Dateiname im Podcast-Ordner, nie ein voller Pfad: der Pfad
    /// des App-Containers kann sich bei Updates ändern.
    let fileName: String
    let duration: TimeInterval
    let byteSize: Int64
    let importedAt: Date
    /// Beim Import auf Sprachqualität heruntergerechnet (sonst unverändert
    /// kopiert).
    let wasCompressed: Bool
    /// Zuletzt gehörte Stelle in Sekunden.
    var position: TimeInterval
    /// Bis zum Ende gehört.
    var finishedAt: Date?
    /// Optional einem Lern-Ordner zugeordnet. Ordner gehören zum gerade
    /// aktiven Konto (Cloud oder Gast); ein Ordner, der dort nicht existiert,
    /// wird einfach als "Ohne Ordner" angezeigt.
    var folderId: UUID?
}

/// Die Liste aller Podcasts als reiner Wert -- testbar ohne Dateien
/// (`PodcastLibraryTests`). Gespeichert als `podcasts.json` im Podcast-Ordner.
struct PodcastIndex: Codable, Equatable {
    private(set) var podcasts: [Podcast] = []

    /// Neueste zuerst.
    var sorted: [Podcast] {
        podcasts.sorted { $0.importedAt > $1.importedAt }
    }

    var totalBytes: Int64 {
        podcasts.reduce(0) { $0 + $1.byteSize }
    }

    func podcast(_ id: UUID) -> Podcast? {
        podcasts.first { $0.id == id }
    }

    mutating func add(_ podcast: Podcast) {
        podcasts.removeAll { $0.id == podcast.id }
        podcasts.append(podcast)
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Podcast? {
        guard let index = podcasts.firstIndex(where: { $0.id == id }) else { return nil }
        return podcasts.remove(at: index)
    }

    mutating func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    mutating func setFolder(_ id: UUID, folderId: UUID?) {
        update(id) { $0.folderId = folderId }
    }

    /// Hörstelle merken. Wer nach dem Durchhören zurückspult, hört den
    /// Podcast erneut -- dann gilt er nicht mehr als gehört.
    mutating func setPosition(_ id: UUID, position: TimeInterval) {
        update(id) { podcast in
            podcast.position = max(0, min(position, podcast.duration))
            if podcast.finishedAt != nil, !PodcastProgress.isAtEnd(position: position, duration: podcast.duration) {
                podcast.finishedAt = nil
            }
        }
    }

    mutating func markFinished(_ id: UUID, at date: Date = Date()) {
        update(id) { podcast in
            podcast.finishedAt = date
            podcast.position = podcast.duration
        }
    }

    private mutating func update(_ id: UUID, _ change: (inout Podcast) -> Void) {
        guard let index = podcasts.firstIndex(where: { $0.id == id }) else { return }
        change(&podcasts[index])
    }

    /// Leere Liste, wenn es die Datei (noch) nicht gibt. `nil`, wenn sie
    /// existiert, sich aber nicht lesen lässt -- dann darf der Store keine
    /// "verwaisten" Audiodateien wegräumen, sonst wären alle Podcasts weg.
    static func loadValidated(from url: URL) -> PodcastIndex? {
        guard FileManager.default.fileExists(atPath: url.path) else { return PodcastIndex() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PodcastIndex.self, from: data)
    }

    static func load(from url: URL) -> PodcastIndex {
        loadValidated(from: url) ?? PodcastIndex()
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Wo ein Podcast weiterläuft und wie Zeiten angezeigt werden.
enum PodcastProgress {
    /// Die letzten Sekunden zählen schon als "zu Ende gehört" -- NotebookLM-
    /// Overviews enden mit einer kurzen Verabschiedung.
    static let endTolerance: TimeInterval = 5

    static func isAtEnd(position: TimeInterval, duration: TimeInterval) -> Bool {
        duration > 0 && position >= duration - endTolerance
    }

    /// Weiterhören an der gemerkten Stelle, 3 s davor (den letzten Satz noch
    /// einmal hören). Fertig gehörte Podcasts beginnen von vorn.
    static func resumePosition(position: TimeInterval, duration: TimeInterval, finished: Bool) -> TimeInterval {
        if finished || isAtEnd(position: position, duration: duration) { return 0 }
        return max(0, position - 3)
    }

    /// "32 min", "1 h 05 min", "45 s".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "12:34" bzw. "1:02:03" für die Zeitanzeige im Player.
    static func clockLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1×", "1,25×", "1,5×", "2×".
    static func rateLabel(_ rate: Float) -> String {
        var text = String(format: "%.2f", rate)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",") + "×"
    }

    /// "noch 12 min", "gehört", "neu".
    static func statusLabel(for podcast: Podcast) -> String {
        if podcast.finishedAt != nil { return "gehört" }
        if podcast.position < 1 { return "neu" }
        return "noch " + durationLabel(podcast.duration - podcast.position)
    }
}

/// Wann ein Import heruntergerechnet wird.
enum PodcastImportRule {
    /// Zielformat: AAC mono, 64 kbit/s -- für zwei Stimmen gut verständlich,
    /// 30 Minuten ≈ 14 MB.
    static let targetBitRate = 64_000
    static let targetSampleRate = 44_100
    /// Erst ab dieser Datenrate lohnt das Umrechnen. Darunter wird die Datei
    /// unverändert kopiert (kein Qualitätsverlust, keine Wartezeit).
    static let compressAboveBitsPerSecond: Double = 96_000

    static func shouldCompress(byteSize: Int64, duration: TimeInterval) -> Bool {
        guard duration > 0, byteSize > 0 else { return false }
        return Double(byteSize) * 8 / duration > compressAboveBitsPerSecond
    }

    /// Titel aus dem Dateinamen, ohne Endung; Unterstriche werden Leerzeichen.
    static func defaultTitle(forFileName fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "Podcast" : base
    }

    /// Endung der Kopie: die des Originals, sonst m4a.
    static func fileExtension(forFileName fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "m4a" : ext
    }
}
