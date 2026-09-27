import Foundation

/// Request/response shapes mirroring docs/PROTOCOL.md. Kept intentionally small.
enum Wire {
    struct SessionRequest: Encodable {
        let deviceId: String
        let deviceName: String
        let consentAcknowledged: Bool
        let startedAt: Int64
    }
    struct SessionResponse: Decodable {
        let sessionId: String
    }
    struct LocationRequest: Encodable {
        let deviceId: String
        let sessionId: String
        let lat: Double
        let lng: Double
        let accuracy: Double?
        let speed: Double?
        let heading: Double?
        let timestamp: Int64
    }
    struct StopRequest: Encodable {
        let deviceId: String
        let sessionId: String
    }
}

/// Epoch-milliseconds helper used across the app.
extension Date {
    var epochMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
