import XCTest
@testable import TeachVoice

/// Podcasts: Hörstelle, Liste, Speicher-Regel fürs Komprimieren.
final class PodcastLibraryTests: XCTestCase {

    private func podcast(duration: TimeInterval = 1800, position: TimeInterval = 0,
                         byteSize: Int64 = 14_000_000, importedAt: Date = Date()) -> Podcast {
        Podcast(id: UUID(), title: "Kapitel 3", fileName: "\(UUID().uuidString).m4a", duration: duration,
                byteSize: byteSize, importedAt: importedAt, wasCompressed: false,
                position: position, finishedAt: nil, folderId: nil)
    }

    // MARK: - Komprimieren ja/nein

    func testHighBitrateGetsCompressed() {
        // 30 min mit 128 kbit/s ≈ 28,8 MB
        XCTAssertTrue(PodcastImportRule.shouldCompress(byteSize: 28_800_000, duration: 1800))
        // Unkomprimiertes WAV erst recht
        XCTAssertTrue(PodcastImportRule.shouldCompress(byteSize: 158_000_000, duration: 1800))
    }

    func testLowBitrateIsCopiedAsIs() {
        // 30 min mit 64 kbit/s ≈ 14,4 MB -- schon Sprachqualität
        XCTAssertFalse(PodcastImportRule.shouldCompress(byteSize: 14_400_000, duration: 1800))
        XCTAssertFalse(PodcastImportRule.shouldCompress(byteSize: 1_000, duration: 0), "Unbekannte Länge nie umrechnen")
    }

    func testTitleAndExtensionFromFileName() {
        XCTAssertEqual(PodcastImportRule.defaultTitle(forFileName: "Kapitel_3_Lernpsychologie.m4a"), "Kapitel 3 Lernpsychologie")
        XCTAssertEqual(PodcastImportRule.defaultTitle(forFileName: "_.m4a"), "Podcast")
        XCTAssertEqual(PodcastImportRule.fileExtension(forFileName: "Folie.M4A"), "m4a")
        XCTAssertEqual(PodcastImportRule.fileExtension(forFileName: "ohne-endung"), "m4a")
    }

    // MARK: - Weiterhören

    func testResumesSlightlyBeforeTheSavedPosition() {
        XCTAssertEqual(PodcastProgress.resumePosition(position: 600, duration: 1800, finished: false), 597)
        XCTAssertEqual(PodcastProgress.resumePosition(position: 1, duration: 1800, finished: false), 0)
    }

    func testFinishedPodcastStartsFromTheBeginning() {
        XCTAssertEqual(PodcastProgress.resumePosition(position: 1800, duration: 1800, finished: true), 0)
        XCTAssertEqual(PodcastProgress.resumePosition(position: 1797, duration: 1800, finished: false), 0,
                       "Die letzten Sekunden zählen schon als zu Ende")
    }

    func testRewindingAfterFinishingMarksItUnheardAgain() {
        var index = PodcastIndex()
        let item = podcast()
        index.add(item)
        index.markFinished(item.id)
        XCTAssertNotNil(index.podcast(item.id)?.finishedAt)

        index.setPosition(item.id, position: 300)
        XCTAssertNil(index.podcast(item.id)?.finishedAt)
        XCTAssertEqual(index.podcast(item.id)?.position, 300)
    }

    func testPositionIsClampedToTheDuration() {
        var index = PodcastIndex()
        let item = podcast(duration: 100)
        index.add(item)
        index.setPosition(item.id, position: 500)
        XCTAssertEqual(index.podcast(item.id)?.position, 100)
        index.setPosition(item.id, position: -5)
        XCTAssertEqual(index.podcast(item.id)?.position, 0)
    }

    // MARK: - Liste

    func testNewestFirstAndTotalSize() {
        var index = PodcastIndex()
        let old = podcast(byteSize: 10, importedAt: Date(timeIntervalSince1970: 1_000))
        let new = podcast(byteSize: 32, importedAt: Date(timeIntervalSince1970: 2_000))
        index.add(old)
        index.add(new)
        XCTAssertEqual(index.sorted.map(\.id), [new.id, old.id])
        XCTAssertEqual(index.totalBytes, 42)

        index.remove(old.id)
        XCTAssertEqual(index.totalBytes, 32)
    }

    func testRenameIgnoresEmptyTitles() {
        var index = PodcastIndex()
        let item = podcast()
        index.add(item)
        index.rename(item.id, to: "   ")
        XCTAssertEqual(index.podcast(item.id)?.title, "Kapitel 3")
        index.rename(item.id, to: "  Kapitel 4 ")
        XCTAssertEqual(index.podcast(item.id)?.title, "Kapitel 4")
    }

    func testSurvivesSavingAndLoading() {
        var index = PodcastIndex()
        var item = podcast(position: 42)
        item.folderId = UUID()
        index.add(item)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("podcasts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        index.save(to: url)
        let loaded = PodcastIndex.load(from: url)
        XCTAssertEqual(loaded.podcasts.map(\.id), [item.id])
        XCTAssertEqual(loaded.podcast(item.id)?.position, 42)
        XCTAssertEqual(loaded.podcast(item.id)?.folderId, item.folderId)
    }

    func testUnreadableIndexIsReportedNotEmptied() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("podcasts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("kaputt".utf8).write(to: url)
        XCTAssertNil(PodcastIndex.loadValidated(from: url),
                     "Sonst würde der Store alle Audiodateien als verwaist löschen")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("gibt-es-nicht-\(UUID().uuidString).json")
        XCTAssertEqual(PodcastIndex.loadValidated(from: missing)?.podcasts.count, 0)
    }

    // MARK: - Anzeige

    func testLabels() {
        XCTAssertEqual(PodcastProgress.durationLabel(1800), "30 min")
        XCTAssertEqual(PodcastProgress.durationLabel(3900), "1 h 05 min")
        XCTAssertEqual(PodcastProgress.durationLabel(42), "42 s")
        XCTAssertEqual(PodcastProgress.clockLabel(754), "12:34")
        XCTAssertEqual(PodcastProgress.clockLabel(3723), "1:02:03")
        XCTAssertEqual(PodcastProgress.rateLabel(1.0), "1×")
        XCTAssertEqual(PodcastProgress.rateLabel(1.25), "1,25×")
        XCTAssertEqual(PodcastProgress.rateLabel(1.5), "1,5×")
        XCTAssertEqual(PodcastProgress.rateLabel(2.0), "2×")
    }

    func testStatusLabel() {
        XCTAssertEqual(PodcastProgress.statusLabel(for: podcast()), "neu")
        XCTAssertEqual(PodcastProgress.statusLabel(for: podcast(duration: 1800, position: 1080)), "noch 12 min")
        var finished = podcast()
        finished.finishedAt = Date()
        XCTAssertEqual(PodcastProgress.statusLabel(for: finished), "gehört")
    }
}
