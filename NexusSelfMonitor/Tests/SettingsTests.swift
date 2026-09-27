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

    /// A build without injected credentials must not resolve to the literal
    /// `$(NAME)` placeholder, or the app would try to reach a bogus host.
    func testUnsubstitutedPlaceholderIsTreatedAsAbsent() {
        XCTAssertEqual(Settings.buildInjectedValue(forKey: "NexusKeyThatIsNotSetAtAll"), "")
        XCTAssertEqual(Settings.buildInjectedValue(forKey: "NoSuchInfoPlistKey"), "")
    }

    /// Opt-in safety defaults: nothing may begin recording implicitly, and the
    /// wrapped background mode must stay off until the operator asks for it.
    func testMonitoringDefaultsAreOptIn() {
        let settings = Settings()
        XCTAssertTrue(settings.autoStartEnabled)
        XCTAssertTrue(settings.backgroundEnabled)
        XCTAssertFalse(settings.cameraEnabled)
    }
}
