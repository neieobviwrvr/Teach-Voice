import XCTest
@testable import TeachVoice

/// Zusammenfassungen: Liste, Suche, Dateiart -- und die Ordner-Gruppierung,
/// die Podcasts und Zusammenfassungen teilen.
final class SummaryLibraryTests: XCTestCase {

    private func summary(_ title: String, file: String = "Kapitel3.pdf", folderId: UUID? = nil,
                         byteSize: Int64 = 1_000, importedAt: Date = Date()) -> Summary {
        let ext = (file as NSString).pathExtension
        return Summary(id: UUID(), title: title, fileName: "\(UUID().uuidString).\(ext)", originalFileName: file,
                       byteSize: byteSize, importedAt: importedAt, folderId: folderId)
    }

    private func folder(_ name: String) -> Folder {
        Folder(id: UUID(), userId: UUID(), name: name, position: 0, createdAt: Date(), updatedAt: Date())
    }

    func testKindFromExtension() {
        XCTAssertEqual(SummaryKind(fileExtension: "PDF"), .pdf)
        XCTAssertEqual(SummaryKind(fileExtension: "docx"), .document)
        XCTAssertEqual(SummaryKind(fileExtension: "pptx"), .presentation)
        XCTAssertEqual(SummaryKind(fileExtension: "xlsx"), .spreadsheet)
        XCTAssertEqual(SummaryKind(fileExtension: "md"), .text)
        XCTAssertEqual(SummaryKind(fileExtension: "heic"), .image)
        XCTAssertEqual(SummaryKind(fileExtension: "zip"), .other)
        XCTAssertEqual(summary("A", file: "Folien.pptx").kind, .presentation)
    }

    func testSearchMatchesTitleAndOriginalFileName() {
        var index = SummaryIndex()
        index.add(summary("Lernpsychologie", file: "kap1.pdf"))
        index.add(summary("Statistik", file: "Behaviorismus_Zusammenfassung.pdf"))
        XCTAssertEqual(index.matching("lern").map(\.title), ["Lernpsychologie"])
        XCTAssertEqual(index.matching("behaviorismus").map(\.title), ["Statistik"])
        XCTAssertEqual(index.matching("  ").count, 2, "Leere Suche zeigt alles")
    }

    func testNewestFirstTotalSizeAndRemove() {
        var index = SummaryIndex()
        let old = summary("Alt", byteSize: 10, importedAt: Date(timeIntervalSince1970: 1_000))
        let new = summary("Neu", byteSize: 32, importedAt: Date(timeIntervalSince1970: 2_000))
        index.add(old)
        index.add(new)
        XCTAssertEqual(index.sorted.map(\.title), ["Neu", "Alt"])
        XCTAssertEqual(index.totalBytes, 42)
        index.remove(new.id)
        XCTAssertEqual(index.sorted.map(\.title), ["Alt"])
    }

    func testRenameAndFolder() {
        var index = SummaryIndex()
        let item = summary("Kapitel 3")
        index.add(item)
        index.rename(item.id, to: "  ")
        XCTAssertEqual(index.summary(item.id)?.title, "Kapitel 3")
        index.rename(item.id, to: " Kapitel 3 – final ")
        XCTAssertEqual(index.summary(item.id)?.title, "Kapitel 3 – final")
        let folderId = UUID()
        index.setFolder(item.id, folderId: folderId)
        XCTAssertEqual(index.summary(item.id)?.folderId, folderId)
    }

    func testSurvivesSavingAndLoading() {
        var index = SummaryIndex()
        let item = summary("Kapitel 3", folderId: UUID())
        index.add(item)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summaries-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        index.save(to: url)
        let loaded = SummaryIndex.load(from: url)
        XCTAssertEqual(loaded.summaries.map(\.id), [item.id])
        XCTAssertEqual(loaded.summary(item.id)?.originalFileName, "Kapitel3.pdf")
        XCTAssertEqual(loaded.summary(item.id)?.folderId, item.folderId)
    }

    func testUnreadableIndexIsReportedNotEmptied() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("summaries-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("kaputt".utf8).write(to: url)
        XCTAssertNil(SummaryIndex.loadValidated(from: url))
    }

    func testDefaultTitle() {
        XCTAssertEqual(FileImport.defaultTitle(forFileName: "Kapitel_3_final.pdf", fallback: "Zusammenfassung"), "Kapitel 3 final")
        XCTAssertEqual(FileImport.defaultTitle(forFileName: "_.pdf", fallback: "Zusammenfassung"), "Zusammenfassung")
    }

    // MARK: - Ordner-Gruppierung

    func testGroupsByFolderOrderThenUnassigned() {
        let a = folder("Lernpsychologie")
        let b = folder("Statistik")
        let inB = summary("B1", folderId: b.id)
        let inA = summary("A1", folderId: a.id)
        let none = summary("Ohne")
        let unknownFolder = summary("Fremd", folderId: UUID())

        let sections = FolderGrouping.sections([inB, inA, none, unknownFolder], folders: [a, b]) { $0.folderId }
        XCTAssertEqual(sections.map(\.title), ["Lernpsychologie", "Statistik", "Ohne Ordner"])
        XCTAssertEqual(sections.last?.items.map(\.title), ["Ohne", "Fremd"],
                       "Ordner aus einem anderen Konto zählt als ohne Ordner")
    }

    func testWithoutAnyFolderThereIsNoHeader() {
        let sections = FolderGrouping.sections([summary("X"), summary("Y")], folders: [folder("A")]) { $0.folderId }
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections.first?.title)
    }
}
