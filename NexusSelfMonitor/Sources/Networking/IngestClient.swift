import Foundation

/// Robust async HTTP client to the ingest server with granular error classification.
/// All calls are explicit, authenticated, and logged to DiagnosticsLogger.
actor IngestClient {
    private let settings: Settings
    private let session: URLSession

    init(settings: Settings) {
        self.settings = settings
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20.0
        cfg.timeoutIntervalForResource = 45.0
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    public enum ClientError: LocalizedError {
        case badURL
        case offline
        case rateLimited(retryAfter: Int?)
        case consentRefused
        case unauthorized
        case http(code: Int, body: String)
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .badURL:
                return "Invalid server URL."
            case .offline:
                return "Network connection appears to be offline."
            case let .rateLimited(retryAfter):
                if let sec = retryAfter {
                    return "Rate limit exceeded. Retry after \(sec)s."
                }
                return "Rate limit exceeded. Server is throttling requests."
            case .consentRefused:
                return "Server refused request: consent was not acknowledged."
            case .unauthorized:
                return "Unauthorized: invalid or missing ingest bearer token."
            case let .http(code, body):
                return "Server returned HTTP \(code): \(body)"
            case let .decodingFailed(detail):
                return "Failed to parse server response: \(detail)"
            }
        }

        public var isTransient: Bool {
            switch self {
            case .offline, .rateLimited:
                return true
            case let .http(code, _):
                return code >= 500 || code == 408
            case .badURL, .consentRefused, .unauthorized, .decodingFailed:
                return false
            }
        }
    }

    private func makeRequest(_ path: String, method: String, contentType: String, timeout: TimeInterval = 20.0) throws -> URLRequest {
        guard let base = settings.baseURL,
              let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            DiagnosticsLogger.shared.log("Malformed URL with path '\(path)'", subsystem: .network, level: .error)
            throw ClientError.badURL
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("NexusSelfMonitor-iOS/1.0", forHTTPHeaderField: "User-Agent")

        if !settings.ingestToken.isEmpty {
            req.setValue("Bearer \(settings.ingestToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func executeData(for req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.http(code: -1, body: "Non-HTTP response")
            }
            return (data, http)
        } catch let err as URLError {
            if err.code == .notConnectedToInternet || err.code == .networkConnectionLost || err.code == .timedOut {
                DiagnosticsLogger.shared.log("Network transport error: \(err.localizedDescription)", subsystem: .network, level: .warn)
                throw ClientError.offline
            }
            throw err
        }
    }

    // MARK: - API Calls

    /// Register a consented session; returns the server-issued sessionId.
    func startSession() async throws -> String {
        var req = try makeRequest("/api/v1/session", method: "POST", contentType: "application/json")
        let payload = Wire.SessionRequest(
            deviceId: settings.deviceId,
            deviceName: settings.deviceName,
            consentAcknowledged: true,
            startedAt: Date().epochMillis)
        req.httpBody = try JSONEncoder().encode(payload)

        DiagnosticsLogger.shared.log("Initiating session registration for device '\(settings.deviceName)'",
                                     subsystem: .network, level: .info)

        let (data, resp) = try await executeData(for: req)
        try handleStatus(resp.statusCode, data: data)

        do {
            let res = try JSONDecoder().decode(Wire.SessionResponse.self, from: data)
            DiagnosticsLogger.shared.log("Session started successfully. ID: \(res.sessionId)",
                                         subsystem: .network, level: .info)
            return res.sessionId
        } catch {
            throw ClientError.decodingFailed(error.localizedDescription)
        }
    }

    func sendLocation(sessionId: String, lat: Double, lng: Double,
                      accuracy: Double?, speed: Double?, heading: Double?) async throws {
        var req = try makeRequest("/api/v1/location", method: "POST", contentType: "application/json", timeout: 15.0)
        let payload = Wire.LocationRequest(
            deviceId: settings.deviceId, sessionId: sessionId,
            lat: lat, lng: lng, accuracy: accuracy, speed: speed, heading: heading,
            timestamp: Date().epochMillis)
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await executeData(for: req)
        guard resp.statusCode == 202 || resp.statusCode == 200 else {
            try handleStatus(resp.statusCode, data: data)
            return
        }
    }

    /// Upload one complete audio segment file as a raw body.
    func uploadSegment(sessionId: String, seq: Int, fileURL: URL,
                       startedAt: Int64, durationMs: Int) async throws {
        var req = try makeRequest("/api/v1/audio", method: "POST", contentType: "audio/mp4", timeout: 30.0)
        req.setValue(settings.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
        req.setValue(String(seq), forHTTPHeaderField: "X-Seq")
        req.setValue(String(startedAt), forHTTPHeaderField: "X-Started-At")
        req.setValue(String(durationMs), forHTTPHeaderField: "X-Duration-Ms")

        do {
            let (data, response) = try await session.upload(for: req, fromFile: fileURL)
            guard let resp = response as? HTTPURLResponse else {
                throw ClientError.http(code: -1, body: "Non-HTTP response")
            }
            guard resp.statusCode == 201 else {
                try handleStatus(resp.statusCode, data: data)
                return
            }
        } catch let err as URLError {
            if err.code == .notConnectedToInternet || err.code == .networkConnectionLost || err.code == .timedOut {
                throw ClientError.offline
            }
            throw err
        }
    }

    func stopSession(sessionId: String) async {
        guard var req = try? makeRequest("/api/v1/session/stop", method: "POST", contentType: "application/json", timeout: 10.0) else { return }
        req.httpBody = try? JSONEncoder().encode(Wire.StopRequest(deviceId: settings.deviceId, sessionId: sessionId))
        _ = try? await executeData(for: req)
        DiagnosticsLogger.shared.log("Stopped session on server: \(sessionId)", subsystem: .network, level: .info)
    }

    /// Upload any generic media blob (e.g. periodic photo).
    func uploadMedia(sessionId: String, kind: String, ext: String,
                     contentType: String, seq: Int, data mediaData: Data,
                     startedAt: Int64, durationMs: Int?) async throws {
        var req = try makeRequest("/api/v1/media", method: "POST", contentType: contentType, timeout: 30.0)
        req.setValue(settings.deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue(sessionId, forHTTPHeaderField: "X-Session-Id")
        req.setValue(String(seq), forHTTPHeaderField: "X-Seq")
        req.setValue(String(startedAt), forHTTPHeaderField: "X-Started-At")
        req.setValue(kind, forHTTPHeaderField: "X-Media-Kind")
        req.setValue(ext, forHTTPHeaderField: "X-File-Ext")
        if let d = durationMs {
            req.setValue(String(d), forHTTPHeaderField: "X-Duration-Ms")
        }
        req.httpBody = mediaData

        let (respData, resp) = try await executeData(for: req)
        guard resp.statusCode == 201 else {
            try handleStatus(resp.statusCode, data: respData)
            return
        }
    }

    struct HealthResponse: Decodable {
        let ok: Bool
        let uptimeSec: Int?
        let devices: Int?
    }

    func checkHealth() async throws -> HealthResponse {
        let req = try makeRequest("/api/v1/health", method: "GET", contentType: "application/json", timeout: 8.0)
        let (data, resp) = try await executeData(for: req)
        guard resp.statusCode == 200 else {
            try handleStatus(resp.statusCode, data: data)
            throw ClientError.http(code: resp.statusCode, body: "Health check failed")
        }
        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }

    func deleteDevice() async throws {
        let path = "/api/v1/device/\(settings.deviceId)"
        var req = try makeRequest(path, method: "DELETE", contentType: "application/json")
        req.httpMethod = "DELETE"
        let (data, resp) = try await executeData(for: req)
        guard resp.statusCode == 200 else {
            try handleStatus(resp.statusCode, data: data)
            return
        }
        DiagnosticsLogger.shared.log("Purged remote device data for \(settings.deviceId)", subsystem: .network, level: .info)
    }

    func sendTelemetry(sessionId: String?, telemetry: [String: Any]) async throws {
        var req = try makeRequest("/api/v1/telemetry", method: "POST", contentType: "application/json", timeout: 10.0)
        var payload: [String: Any] = telemetry
        payload["deviceId"] = settings.deviceId
        if let sid = sessionId { payload["sessionId"] = sid }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await executeData(for: req)
        guard resp.statusCode == 202 || resp.statusCode == 200 else {
            try handleStatus(resp.statusCode, data: data)
            return
        }
    }

    // MARK: - Status Validation

    private func handleStatus(_ code: Int, data: Data) throws {
        let body = String(decoding: data, as: UTF8.self)
        switch code {
        case 200...299:
            return
        case 401:
            DiagnosticsLogger.shared.log("HTTP 401 Unauthorized", subsystem: .network, level: .error)
            throw ClientError.unauthorized
        case 403:
            DiagnosticsLogger.shared.log("HTTP 403 Consent Refused", subsystem: .network, level: .error)
            throw ClientError.consentRefused
        case 429:
            DiagnosticsLogger.shared.log("HTTP 429 Rate limited by ingest server", subsystem: .network, level: .warn)
            throw ClientError.rateLimited(retryAfter: 10)
        default:
            DiagnosticsLogger.shared.log("HTTP \(code) Error: \(body)", subsystem: .network, level: .error)
            throw ClientError.http(code: code, body: body)
        }
    }
}
