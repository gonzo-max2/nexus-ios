import Foundation

/// User-editable configuration, persisted in UserDefaults. Nothing here is hidden;
/// the user sees and controls every field from the Settings screen.
struct Settings: Codable, Equatable {
    var serverURL: String = "http://localhost:8787"
    var deviceName: String = "My iPhone"
    var ingestToken: String = ""          // optional Bearer token; blank = none
    var segmentSeconds: Int = 5           // rolling audio segment length
    var locationEnabled: Bool = true
    var cameraEnabled: Bool = false        // periodic photo capture
    var cameraIntervalSeconds: Int = 10    // seconds between camera captures
    var backgroundEnabled: Bool = false   // keep logging while screen is off (worn use)

    /// Stable per-install identifier. Generated once, then persisted.
    var deviceId: String = ""

    static let storageKey = "nexus.selfmonitor.settings.v1"

    static func load() -> Settings {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey),
           var s = try? JSONDecoder().decode(Settings.self, from: data) {
            if s.deviceId.isEmpty { s.deviceId = UUID().uuidString; s.save() }
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
        return URL(string: s)
    }
}
