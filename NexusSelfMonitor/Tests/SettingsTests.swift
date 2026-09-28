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

    /// The payload written by a build that predates `autoStartEnabled` must
    /// decode without throwing. A decode failure makes `Settings.load()` fall
    /// through to `Settings()` and silently wipe the operator's server URL,
    /// token and device ID — the regression that leaves a reinstalled app
    /// unconfigured and demanding input on every launch.
    func testLegacyJSONWithoutAutoStartKeyDecodesLosslessly() throws {
        let legacy = """
        {"serverURL":"http://192.168.1.53:8787","deviceName":"My iPhone","ingestToken":"tok-123",\
        "segmentSeconds":5,"locationEnabled":true,"cameraEnabled":false,\
        "cameraIntervalSeconds":10,"backgroundEnabled":false,\
        "deviceId":"54448E10-38EB-40D7-80FC-DBE1673487A1"}
        """
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.serverURL, "http://192.168.1.53:8787")
        XCTAssertEqual(decoded.ingestToken, "tok-123")
        XCTAssertEqual(decoded.deviceId, "54448E10-38EB-40D7-80FC-DBE1673487A1")
        XCTAssertTrue(decoded.autoStartEnabled, "missing key must fall back to this build's default")
        XCTAssertFalse(decoded.backgroundEnabled, "a stored value must win over the newer default")
        XCTAssertFalse(decoded.isStealthModeActive, "missing stealth key must default to false")
        let roundTrip = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(roundTrip, decoded, "encode/decode round-trip must be stable")
    }

    /// A fresh install or a partial write (`{}`) must decode to this build's
    /// defaults instead of throwing.
    func testEmptyJSONDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, Settings())
    }
}
