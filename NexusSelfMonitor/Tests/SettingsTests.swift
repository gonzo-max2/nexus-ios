import XCTest
@testable import NexusSelfMonitor

final class SettingsTests: XCTestCase {
    func testHTTPServerURLsAreNormalized() {
        var settings = Settings()
        for value in ["http://192.168.1.2:8787", "https://example.com/ingest"] {
            settings.serverURL = "  \(value)///\n"
            XCTAssertEqual(settings.baseURL?.absoluteString, value)
        }
    }

    func testInvalidServerURLsAreRejectedBeforeNetworking() {
        var settings = Settings()
        for value in ["", "localhost:8787", "/relative", "file:///tmp/data", "ftp://example.com",
                      "https://", "https://example.com?token=1", "https://example.com#fragment",
                      "https://user:password@example.com"] {
            settings.serverURL = value
            XCTAssertNil(settings.baseURL, value)
        }
    }
}
