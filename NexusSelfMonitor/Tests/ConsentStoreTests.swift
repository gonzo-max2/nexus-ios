import XCTest
@testable import NexusSelfMonitor

/// Consent must be granted exactly once per iPhone: a reinstall, re-sign or
/// container replacement must never re-show the consent gate. These tests pin
/// that contract with an in-memory keychain double, so no real keychain is
/// touched and nothing is flaky in CI.
final class ConsentStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "consent-store-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        if let defaults { defaults.removePersistentDomain(forName: suiteName) }
        defaults = nil
        super.tearDown()
    }

    /// The container was replaced (delete/reinstall): UserDefaults is empty but
    /// the keychain copy survived. The operator must NOT be asked again.
    func testConsentSurvivesContainerReplacement() {
        var keychain = false
        let store = ConsentStore(defaults: defaults,
                                  keychainRead: { keychain },
                                  keychainWrite: { keychain = $0 })
        store.setGranted(true)

        defaults.removePersistentDomain(forName: suiteName)  // the replacement

        let afterReinstall = ConsentStore(defaults: defaults,
                                          keychainRead: { keychain },
                                          keychainWrite: { keychain = $0 })
        XCTAssertTrue(afterReinstall.load(),
                      "consent must survive a container replacement, not re-ask")
    }

    /// A legacy install (defaults-only grant from a build without this store)
    /// is mirrored into the keychain on first load, so its next reinstall also
    /// stays granted.
    func testLegacyDefaultsGrantIsBackfilledIntoKeychain() {
        defaults.set(true, forKey: ConsentStore.defaultsKey)
        var keychain = false
        let store = ConsentStore(defaults: defaults,
                                  keychainRead: { keychain },
                                  keychainWrite: { keychain = $0 })

        XCTAssertTrue(store.load())
        XCTAssertTrue(keychain, "legacy grant must be mirrored into the keychain")
    }

    /// Keychain-only state (defaults already gone) is honoured as-is.
    func testKeychainOnlyGrantIsHonoured() {
        var keychain = true
        let store = ConsentStore(defaults: defaults,
                                  keychainRead: { keychain },
                                  keychainWrite: { keychain = $0 })
        XCTAssertTrue(store.load())
    }

    /// Revocation must clear BOTH copies — otherwise it would silently survive
    /// as granted through the keychain and revocation would mean nothing.
    func testRevokeClearsBothCopies() {
        var keychain = false
        let store = ConsentStore(defaults: defaults,
                                  keychainRead: { keychain },
                                  keychainWrite: { keychain = $0 })
        store.setGranted(true)
        store.setGranted(false)

        XCTAssertFalse(store.load())
        XCTAssertFalse(keychain, "revocation must delete the keychain copy")
        XCTAssertFalse(defaults.bool(forKey: ConsentStore.defaultsKey),
                       "revocation must clear the defaults copy")
    }

    /// A genuinely fresh install has no consent anywhere: the gate shows
    /// exactly once, then `grantConsent()` persists it durably.
    func testFreshInstallHasNoConsentUntilGranted() {
        var keychain = false
        let store = ConsentStore(defaults: defaults,
                                 keychainRead: { keychain },
                                 keychainWrite: { keychain = $0 })
        XCTAssertFalse(store.load())
        store.setGranted(true)
        XCTAssertTrue(store.load())
    }

    /// End-to-end through the model: grant and revoke flow into the store.
    @MainActor
    func testModelGrantAndRevokePersistThroughTheStore() throws {
        var keychain = false
        let store = ConsentStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)),
                                  keychainRead: { keychain },
                                  keychainWrite: { keychain = $0 })
        var settings = Settings()
        settings.serverURL = ""   // unconfigured: no start attempt is scheduled
        settings.ingestToken = ""
        let model = AppModel(settings: settings, consentStore: store,
                             automaticStartup: false)

        XCTAssertFalse(model.hasConsented, "fresh model must start un-granted")

        model.grantConsent()
        XCTAssertTrue(model.hasConsented)
        XCTAssertTrue(keychain, "grant must be persisted durably")

        model.revokeConsent()
        XCTAssertFalse(model.hasConsented)
        XCTAssertFalse(keychain, "revoke must clear the durable copy")
    }
}
