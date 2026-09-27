import Foundation

/// Shared only with the signed screen-broadcast extension through an App Group.
struct BroadcastConfiguration: Codable, Equatable {
    let serverURL: String
    let ingestToken: String
    let deviceId: String
    let deviceName: String
    var enabled: Bool

    private static var fileURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "NexusAppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("screen-broadcast.json")
    }

    static func load() -> BroadcastConfiguration? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        guard let url = Self.fileURL else {
            throw NSError(domain: "NexusScreen", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Screen sharing needs matching App Group signing for the app and broadcast extension."])
        }
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func disable() throws {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
