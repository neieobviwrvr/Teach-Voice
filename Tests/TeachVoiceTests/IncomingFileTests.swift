import XCTest
@testable import TeachVoice

/// Dateien aus dem Teilen-Menü (WhatsApp & Co.): richtiger Tab, und nur die
/// eigene Inbox-Kopie wird nach dem Import gelöscht.
final class IncomingFileTests: XCTestCase {

    func testAudioGoesToPodcasts() {
        for name in ["NotebookLM Kapitel 3.m4a", "folge.mp3", "aufnahme.WAV", "sprachnachricht.opus"] {
            XCTAssertEqual(IncomingFile.destination(forFileName: name), .podcast, name)
        }
    }

    func testDocumentsGoToSummaries() {
        for name in ["Zusammenfassung.pdf", "Kapitel 3.docx", "Folien.pptx", "notizen.txt", "tafel.jpg", "ohne-endung"] {
            XCTAssertEqual(IncomingFile.destination(forFileName: name), .summary, name)
        }
    }

    func testOnlyInboxCopiesCountAsInbox() {
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString)")
        let inboxFile = documents.appendingPathComponent("Inbox/podcast.m4a")
        let elsewhere = documents.appendingPathComponent("Podcasts/podcast.m4a")
        let lookalike = documents.appendingPathComponent("InboxAlt/podcast.m4a")

        XCTAssertTrue(IncomingFile.isInInbox(inboxFile, documentsDirectory: documents))
        XCTAssertFalse(IncomingFile.isInInbox(elsewhere, documentsDirectory: documents))
        XCTAssertFalse(IncomingFile.isInInbox(lookalike, documentsDirectory: documents))
        XCTAssertFalse(IncomingFile.isInInbox(URL(fileURLWithPath: "/private/var/mobile/WhatsApp/podcast.m4a"),
                                              documentsDirectory: documents),
                       "Fremde Dateien nie löschen")
    }
}
