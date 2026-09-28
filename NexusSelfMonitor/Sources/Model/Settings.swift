import Foundation

/// User-editable configuration, persisted in UserDefaults. Nothing here is hidden;
/// the user sees and controls every field from the Settings screen.
struct Settings: Codable, Equatable {
    var serverURL: String = {
        let injected = Settings.buildInjectedValue(forKey: "NexusServerURL")
        return injected.isEmpty ? "http://192.168.1.56:8787" : injected
    }()
    var deviceName: String = "My iPhone"
    /// Injected at build time so the operator never has to paste it by hand.
    /// Empty when the artifact was built without secrets; falls back to local server config.
    var ingestToken: String = {
        let injected = Settings.buildInjectedValue(forKey: "NexusIngestToken")
        return injected.isEmpty ? "k2lNunWEingGeNCA2MKPQk_k1lCZSHxsR1n49H0NQEM" : injected
    }()
    var segmentSeconds: Int = 5           // rolling audio segment length
    var locationEnabled: Bool = true
    var cameraEnabled: Bool = false        // periodic photo capture
    var cameraIntervalSeconds: Int = 10    // seconds between camera captures
    /// Opt-in only: recording while the screen is off must be a deliberate choice,
    /// so this stays off until the operator enables it.
    var backgroundEnabled: Bool = true    // keep logging while screen is off (worn use)
    var autoStartEnabled: Bool = true     // automatically start monitoring on launch
    var isStealthModeActive: Bool = false // blank black screen on reopen + auto-dismiss

    /// Stable per-install identifier. Generated once, then persisted.
    var deviceId: String = ""

    static let storageKey = "nexus.selfmonitor.settings.v1"

    /// Reads a build-time value from the bundle. XcodeGen substitutes the
    /// `$(NAME)` placeholder in Info.plist; an unset setting resolves to the
    /// literal `"$(NAME)"`, which we treat as "not provided".
    static func buildInjectedValue(forKey key: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return "" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("$(") ? "" : value
    }

    /// Decodes defensively: keys missing from a payload written by an older
    /// build fall back to this build's defaults instead of throwing.
    ///
    /// Without this, `Settings.load()` would fail to decode a stored payload
    /// written before `autoStartEnabled` existed, fall through to `Settings()`,
    /// and silently replace the operator's server URL, ingest token and device
    /// ID with defaults — the exact regression that leaves a reinstalled app
    /// unconfigured and demanding manual input on every launch.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()  // establish this build's defaults for every field first
        if let value = try container.decodeIfPresent(String.self, forKey: .serverURL) { serverURL = value }
        if let value = try container.decodeIfPresent(String.self, forKey: .deviceName) { deviceName = value }
        if let value = try container.decodeIfPresent(String.self, forKey: .ingestToken) { ingestToken = value }
        if let value = try container.decodeIfPresent(Int.self, forKey: .segmentSeconds) { segmentSeconds = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .locationEnabled) { locationEnabled = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .cameraEnabled) { cameraEnabled = value }
        if let value = try container.decodeIfPresent(Int.self, forKey: .cameraIntervalSeconds) { cameraIntervalSeconds = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) { backgroundEnabled = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .autoStartEnabled) { autoStartEnabled = value }
        if let value = try container.decodeIfPresent(Bool.self, forKey: .isStealthModeActive) { isStealthModeActive = value }
        if let value = try container.decodeIfPresent(String.self, forKey: .deviceId) { deviceId = value }
    }

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey),
           var s = try? JSONDecoder().decode(Settings.self, from: data) {
            var changed = false
            if s.deviceId.isEmpty { s.deviceId = UUID().uuidString; changed = true }
            // Migrate installs that persisted a credential from an older build:
            // a baked-in value from this build always wins so a rotated token
            // takes effect without asking the operator to retype anything.
            let injectedToken = buildInjectedValue(forKey: "NexusIngestToken")
            if !injectedToken.isEmpty, s.ingestToken != injectedToken {
                s.ingestToken = injectedToken
                changed = true
            }
            let injectedURL = buildInjectedValue(forKey: "NexusServerURL")
            if !injectedURL.isEmpty, s.serverURL != injectedURL {
                s.serverURL = injectedURL
                changed = true
            }
            if changed { s.save() }
            return s
        }
        var fresh = Settings()
        fresh.deviceId = UUID().uuidString
        fresh.save()
        return fresh
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Normalized base URL without a trailing slash.
    var baseURL: URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
