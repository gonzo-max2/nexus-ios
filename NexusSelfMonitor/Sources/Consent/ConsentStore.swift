import Foundation
import Security

/// Durable, one-time consent persistence.
///
/// `UserDefaults` alone loses the consent flag whenever the app container is
/// replaced — which happens on delete/reinstall and on some re-sign cycles —
/// so the operator would be asked to consent again after every install. This
/// store mirrors the flag into the keychain, which survives container
/// replacement, so consent is granted exactly once per iPhone instead of once
/// per install.
///
/// Caveats, stated honestly:
///  - Keychain items live in the signing identity's access group, so a re-sign
///    with a *different* Apple ID / team makes the item invisible and consent
///    is asked again (correct: that is a different trust domain).
///  - Revoking from Settings clears both copies, so revocation still means
///    revocation.
struct ConsentStore {
    /// Existing UserDefaults key, kept identical so installs that already
    /// granted consent stay granted without a migration step.
    static let defaultsKey = "nexus.selfmonitor.consented.v1"

    private static let keychainService = "com.nexus.selfmonitor.consent"
    private static let keychainAccount = "v1"
    private static let grantedValue = "granted"

    private let defaults: UserDefaults
    private let keychainRead: () -> Bool
    private let keychainWrite: (Bool) -> Void

    init(defaults: UserDefaults = .standard,
         keychainRead: @escaping () -> Bool = ConsentStore.readKeychain,
         keychainWrite: @escaping (Bool) -> Void = ConsentStore.writeKeychain) {
        self.defaults = defaults
        self.keychainRead = keychainRead
        self.keychainWrite = keychainWrite
    }

    /// Production store: standard defaults + this app's keychain item.
    static let live = ConsentStore()

    /// Reads consent from both durable copies.
    ///
    /// A legacy `UserDefaults`-only grant is backfilled into the keychain so
    /// the *next* container replacement does not ask again. Keychain-only
    /// grants (container already replaced) are honoured as-is.
    func load() -> Bool {
        let defaultsGranted = defaults.bool(forKey: Self.defaultsKey)
        let keychainGranted = keychainRead()
        if defaultsGranted, !keychainGranted {
            keychainWrite(true)  // backfill; best effort
            return true
        }
        return defaultsGranted || keychainGranted
    }

    /// Persists consent to both copies; `false` removes them.
    func setGranted(_ granted: Bool) {
        defaults.set(granted, forKey: Self.defaultsKey)
        keychainWrite(granted)
    }

    // MARK: - Live keychain
    // (Internal, not private: they are the default arguments of `init`, and
    // default arguments must be accessible wherever the initializer is called.)

    static func readKeychain() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return false }
        return String(data: data, encoding: .utf8) == grantedValue
    }

    static func writeKeychain(_ granted: Bool) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        // Best-effort upsert: delete first, re-add only when granting.
        let deleteStatus = SecItemDelete(base as CFDictionary)
        guard granted else { return }

        let add = base.merging([
            kSecValueData as String: Data(grantedValue.utf8),
            // Readable from a headless/background launch shortly after boot;
            // the auto-start daemon may start the app before the screen unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            DiagnosticsLogger.shared.log(
                "Consent keychain backfill failed: OSStatus \(status)",
                subsystem: .app, level: .warn)
        }
        _ = deleteStatus
    }
}
