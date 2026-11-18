import XCTest
@testable import TeachVoice

final class ConnectorLinkTests: XCTestCase {

    private let base = "https://example.supabase.co/functions/v1/teach-mcp"
    private let key = "tvk_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"

    func testKeyBecomesLastPathSegment() {
        XCTAssertEqual(
            ConnectorLink.make(base: base, key: key),
            "https://example.supabase.co/functions/v1/teach-mcp/tvk_abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"
        )
    }

    func testTrailingSlashesOnBaseAreNotDoubled() {
        XCTAssertEqual(ConnectorLink.make(base: base + "/", key: key), ConnectorLink.make(base: base, key: key))
        XCTAssertEqual(ConnectorLink.make(base: base + "//", key: key), ConnectorLink.make(base: base, key: key))
    }

    func testStoredKeyMustMatchActivePrefix() {
        XCTAssertTrue(ConnectorLink.matches(key, activePrefix: "tvk_abcdef"))
        XCTAssertFalse(ConnectorLink.matches(key, activePrefix: "tvk_XYZ123"), "Ein auf einem anderen Gerät erzeugter Schlüssel darf keinen alten Link zeigen.")
        XCTAssertFalse(ConnectorLink.matches(key, activePrefix: nil))
        XCTAssertFalse(ConnectorLink.matches(key, activePrefix: ""))
    }
}
