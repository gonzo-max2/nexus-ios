import ReplayKit
import CoreImage
import ImageIO

/// User-started, visible ReplayKit broadcast. Drops frames under load; never
/// queues old screen content or records screen history to disk.
final class SampleHandler: RPBroadcastSampleHandler {
    private let worker = DispatchQueue(label: "com.nexus.screen.broadcast", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.httpMaximumConnectionsPerHost = 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    // All mutable state below is confined to worker.
    private var configuration: BroadcastConfiguration?
    private var sessionId: String?
    private var active = false
    private var paused = false
    private var uploading = false
    private var sequence = 0
    private var lastFrameTime: TimeInterval = 0
    private var task: URLSessionTask?
    private var consentTimer: DispatchSourceTimer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        worker.async { [weak self] in self?.startBroadcast() }
    }

    private func startBroadcast() {
        guard let config = BroadcastConfiguration.load(), config.enabled,
              !config.ingestToken.isEmpty,
              let url = URL(string: config.serverURL), ["http", "https"].contains(url.scheme ?? "") else {
            fail("Open Self-Monitor and enable screen sharing with a server URL and access token first.")
            return
        }
        configuration = config
        active = true
        paused = false
        sequence = 0
        var request = makeRequest(path: "api/v1/session", config: config)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "deviceId": config.deviceId, "deviceName": config.deviceName,
                "consentAcknowledged": true,
                "startedAt": Int64(Date().timeIntervalSince1970 * 1000)
            ])
        } catch { fail(error.localizedDescription); return }
        task = network.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.worker.async {
                guard self.active else { return }
                guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200,
                      let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sid = object["sessionId"] as? String, !sid.isEmpty else {
                    self.fail("Cannot connect screen broadcast. Check the server address, network, and access token.")
                    return
                }
                self.sessionId = sid
                self.task = nil
            }
        }
        task?.resume()
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            guard BroadcastConfiguration.load() == self.configuration else {
                self.fail("Screen sharing was disabled or its settings changed. Start a new broadcast from the iPhone.")
                return
            }
        }
        consentTimer = timer
        timer.resume()
    }

    override func broadcastPaused() { worker.async { [weak self] in self?.paused = true } }
    override func broadcastResumed() { worker.async { [weak self] in self?.paused = false } }
    override func broadcastFinished() { worker.async { [weak self] in self?.stopBroadcast() } }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Consume ReplayKit's buffer before returning. At most two frames/sec
        // are encoded, and only while the previous upload has completed.
        worker.sync {
            guard active, !paused, !uploading, let config = configuration, let sid = sessionId else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastFrameTime >= 0.5 else { return }
            lastFrameTime = now
            autoreleasepool {
                let orientationValue = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey,
                    attachmentModeOut: nil) as? NSNumber)?.uint32Value ?? 1
                let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
                let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
                let scale = min(1, min(720 / image.extent.width, 1280 / image.extent.height))
                let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                guard let jpeg = context.jpegRepresentation(of: scaled, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                            options: [quality: 0.55]),
                      jpeg.count <= 1024 * 1024 else { return }
                var request = makeRequest(path: "api/v1/screen", config: config)
                request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                request.setValue(config.deviceId, forHTTPHeaderField: "X-Device-Id")
                request.setValue(sid, forHTTPHeaderField: "X-Session-Id")
                request.setValue(String(sequence), forHTTPHeaderField: "X-Seq")
                sequence += 1
                uploading = true
                task = network.uploadTask(with: request, from: jpeg) { [weak self] _, response, _ in
                    guard let self else { return }
                    self.worker.async {
                        self.uploading = false
                        self.task = nil
                        guard self.active else { return }
                        if let code = (response as? HTTPURLResponse)?.statusCode,
                           [401, 403, 409, 503].contains(code) {
                            self.fail("Screen broadcast was refused by the server (HTTP \(code)). Check the access token and restart sharing.")
                        }
                    }
                }
                task?.resume()
            }
        }
    }

    private func makeRequest(path: String, config: BroadcastConfiguration) -> URLRequest {
        // URL validated once before registration; stored config is immutable during a broadcast.
        let url = URL(string: config.serverURL)!.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.ingestToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func stopBroadcast() {
        active = false
        consentTimer?.cancel()
        consentTimer = nil
        task?.cancel()
        task = nil
        uploading = false
        if let config = configuration, let sid = sessionId {
            var request = makeRequest(path: "api/v1/screen/stop", config: config)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["deviceId": config.deviceId, "sessionId": sid])
            network.dataTask(with: request).resume()
        }
        sessionId = nil
    }

    private func fail(_ message: String) {
        stopBroadcast()
        finishBroadcastWithError(NSError(domain: "NexusScreen", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
