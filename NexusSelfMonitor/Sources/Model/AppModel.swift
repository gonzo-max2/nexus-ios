import Foundation
import SwiftUI
import CoreLocation
import UIKit

/// Central coordinator. Owns settings + consent state and drives a monitoring
/// session end to end: consent -> permissions -> register session -> stream
/// audio segments + location + photos + sensor telemetry -> stop.
///
/// Hardening features:
///  - Background task protection for in-flight uploads
///  - Memory warning observer to shed non-essential work
///  - Scene phase handling (reclaim audio on foreground, protect on background)
///  - Crash recovery: persists session state so we can resume after jetsam
///  - Comprehensive DiagnosticsLogger instrumentation across all events
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings
    @Published var hasConsented: Bool
    @Published private(set) var isMonitoring = false
    @Published private(set) var status: String = "Idle"
    @Published private(set) var lastErrorText: String?
    @Published private(set) var segmentsSent = 0
    @Published private(set) var locationsSent = 0
    @Published private(set) var photosSent = 0
    @Published private(set) var telemetrySent = 0
    @Published private(set) var serverOnline = false
    @Published private(set) var elapsedSeconds: Int = 0

    let audio = AudioRecorderService()
    let location = LocationService()
    let camera = CameraCaptureService()
    let telemetry = DeviceTelemetryService()
    let uploadQueue = UploadQueue()
    private var client: IngestClient
    private var sessionId: String?
    private var sessionStartDate: Date?
    private var elapsedTimer: Timer?
    private var healthTimer: Timer?

    /// Background task identifier — prevents iOS from killing us mid-upload.
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    private static let consentKey   = "nexus.selfmonitor.consented.v1"
    private static let sessionKey   = "nexus.selfmonitor.activeSession.v1"
    private static let sessionTsKey  = "nexus.selfmonitor.sessionStart.v1"

    init() {
        let s = Settings.load()
        self.settings = s
        self.client = IngestClient(settings: s)
        self.hasConsented = UserDefaults.standard.bool(forKey: Self.consentKey)

        DiagnosticsLogger.shared.log("NexusSelfMonitor AppModel initialized. Device: '\(s.deviceName)' (\(s.deviceId))",
                                     subsystem: .app, level: .info)

        // Wire the upload queue's retry handler.
        uploadQueue.setUploadHandler { [weak self] item in
            guard let self else { return false }
            return await self.retryQueuedItem(item)
        }

        // Observe memory warnings to shed non-critical streams.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.handleMemoryWarning()
            }

        // Start health check polling.
        startHealthPolling()

        // Attempt crash recovery — if we were recording when we got killed.
        attemptCrashRecovery()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func persistSettings() {
        settings.save()
        client = IngestClient(settings: settings)
        DiagnosticsLogger.shared.log("Settings updated and persisted. Target server: \(settings.serverURL)",
                                     subsystem: .app, level: .info)
    }

    func grantConsent() {
        hasConsented = true
        UserDefaults.standard.set(true, forKey: Self.consentKey)
        DiagnosticsLogger.shared.log("User consent granted.", subsystem: .app, level: .info)
    }

    func revokeConsent() {
        stop()
        hasConsented = false
        UserDefaults.standard.set(false, forKey: Self.consentKey)
        DiagnosticsLogger.shared.log("User consent revoked by operator.", subsystem: .app, level: .warn)
    }

    func toggleMonitoring() {
        if isMonitoring { stop() } else { Task { await start() } }
    }

    // MARK: - Scene Phase Handling

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            DiagnosticsLogger.shared.log("Scene became active (Foreground)", subsystem: .app, level: .debug)
            if isMonitoring && !audio.isRecording && sessionId != nil {
                DiagnosticsLogger.shared.log("Reclaiming audio session on foreground return", subsystem: .audio, level: .info)
                audio.reclaimSession(segmentSeconds: settings.segmentSeconds)
            }
            endBackgroundTask()

        case .background:
            DiagnosticsLogger.shared.log("Scene entered background", subsystem: .app, level: .debug)
            if isMonitoring {
                beginBackgroundTask()
            }

        case .inactive:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Start Session

    func start() async {
        guard hasConsented, !isMonitoring else { return }
        lastErrorText = nil
        status = "Requesting microphone…"
        DiagnosticsLogger.shared.log("Requesting microphone permission...", subsystem: .audio, level: .info)

        let micOK = await audio.requestPermission()
        guard micOK else {
            let msg = "Microphone permission denied. Enable it in Settings > Privacy."
            lastErrorText = msg
            status = "Idle"
            DiagnosticsLogger.shared.log(msg, subsystem: .audio, level: .error)
            return
        }

        if settings.cameraEnabled {
            DiagnosticsLogger.shared.log("Requesting camera permission...", subsystem: .camera, level: .info)
            let camOK = await camera.requestPermission()
            if !camOK {
                let msg = "Camera permission denied. Periodic photos will be skipped."
                lastErrorText = msg
                DiagnosticsLogger.shared.log(msg, subsystem: .camera, level: .warn)
            }
        }

        status = "Registering session…"
        DiagnosticsLogger.shared.log("Connecting to server to register session...", subsystem: .network, level: .info)
        do {
            sessionId = try await client.startSession()
        } catch {
            lastErrorText = error.localizedDescription
            status = "Idle"
            DiagnosticsLogger.shared.log("Failed to register session: \(error.localizedDescription)", subsystem: .network, level: .error)
            return
        }

        segmentsSent = 0
        locationsSent = 0
        photosSent = 0
        telemetrySent = 0

        persistSessionState()

        // Wire audio segment uploads
        audio.onSegment = { [weak self] url, seq, startedAt, durationMs in
            guard let self else { return }
            Task { await self.handleSegment(url: url, seq: seq, startedAt: startedAt, durationMs: durationMs) }
        }

        // Wire location uploads
        if settings.locationEnabled {
            location.onLocation = { [weak self] loc in
                guard let self else { return }
                Task { await self.handleLocation(loc) }
            }
            location.start(background: settings.backgroundEnabled)
        }

        // Wire camera photo uploads
        if settings.cameraEnabled {
            camera.onPhoto = { [weak self] data, seq in
                guard let self else { return }
                Task { await self.handlePhoto(data: data, seq: seq) }
            }
            camera.start(intervalSeconds: settings.cameraIntervalSeconds)
        }

        // Wire sensor telemetry
        telemetry.onTelemetry = { [weak self] snapshot in
            guard let self else { return }
            Task { await self.handleTelemetry(snapshot) }
        }
        telemetry.start(intervalSeconds: 5)

        audio.start(segmentSeconds: settings.segmentSeconds)
        uploadQueue.startProcessing()
        isMonitoring = true
        status = "Recording & streaming"

        DiagnosticsLogger.shared.log("Session started successfully. Monitoring active.", subsystem: .app, level: .info)

        // Elapsed timer
        sessionStartDate = Date()
        elapsedSeconds = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStartDate else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    // MARK: - Stop Session

    func stop() {
        guard isMonitoring else { return }
        DiagnosticsLogger.shared.log("Stopping active monitoring session...", subsystem: .app, level: .info)

        audio.stop()
        location.stop()
        camera.stop()
        telemetry.stop()
        audio.onSegment = nil
        location.onLocation = nil
        camera.onPhoto = nil
        telemetry.onTelemetry = nil
        uploadQueue.stopProcessing()
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        if let sid = sessionId {
            beginBackgroundTask()
            Task {
                await client.stopSession(sessionId: sid)
                endBackgroundTask()
            }
        }
        clearSessionState()
        sessionId = nil
        sessionStartDate = nil
        isMonitoring = false
        status = "Idle"
        DiagnosticsLogger.shared.log("Monitoring session fully stopped.", subsystem: .app, level: .info)
    }

    // MARK: - Audio Segment Handler

    private func handleSegment(url: URL, seq: Int, startedAt: Int64, durationMs: Int) async {
        guard let sid = sessionId else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        beginBackgroundTask()
        defer { endBackgroundTask() }

        do {
            try await client.uploadSegment(sessionId: sid, seq: seq, fileURL: url,
                                           startedAt: startedAt, durationMs: durationMs)
            segmentsSent += 1
            DiagnosticsLogger.shared.log("Streamed audio segment #\(seq) (\(durationMs / 1000)s)",
                                         subsystem: .audio, level: .debug)
        } catch {
            uploadQueue.enqueueFile(
                kind: "audio", ext: "m4a", contentType: "audio/mp4",
                sessionId: sid, seq: seq, startedAt: startedAt,
                durationMs: durationMs, fileURL: url)
            lastErrorText = "Upload queued: \(error.localizedDescription)"
            DiagnosticsLogger.shared.log("Audio segment #\(seq) upload failed, queued: \(error.localizedDescription)",
                                         subsystem: .audio, level: .warn)
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Location Handler

    private func handleLocation(_ loc: CLLocation) async {
        guard let sid = sessionId else { return }

        // Sanity filter
        guard loc.horizontalAccuracy >= 0,
              loc.horizontalAccuracy < 100,
              abs(loc.timestamp.timeIntervalSinceNow) < 20 else {
            return
        }

        do {
            try await client.sendLocation(
                sessionId: sid,
                lat: loc.coordinate.latitude, lng: loc.coordinate.longitude,
                accuracy: loc.horizontalAccuracy,
                speed: loc.speed >= 0 ? loc.speed : nil,
                heading: loc.course >= 0 ? loc.course : nil)
            locationsSent += 1
        } catch {
            lastErrorText = "Location: \(error.localizedDescription)"
            DiagnosticsLogger.shared.log("Location send failed: \(error.localizedDescription)",
                                         subsystem: .location, level: .warn)
        }
    }

    // MARK: - Photo Handler

    private func handlePhoto(data: Data, seq: Int) async {
        guard let sid = sessionId else { return }

        beginBackgroundTask()
        defer { endBackgroundTask() }

        do {
            try await client.uploadMedia(
                sessionId: sid, kind: "photo", ext: "jpg",
                contentType: "image/jpeg", seq: seq, data: data,
                startedAt: Date().epochMillis, durationMs: nil)
            photosSent += 1
            DiagnosticsLogger.shared.log("Streamed camera photo #\(seq) (\(data.count / 1024) KB)",
                                         subsystem: .camera, level: .debug)
        } catch {
            uploadQueue.enqueue(
                kind: "photo", ext: "jpg", contentType: "image/jpeg",
                sessionId: sid, seq: seq, startedAt: Date().epochMillis,
                durationMs: nil, data: data)
            lastErrorText = "Photo queued: \(error.localizedDescription)"
            DiagnosticsLogger.shared.log("Photo #\(seq) upload failed, queued: \(error.localizedDescription)",
                                         subsystem: .camera, level: .warn)
        }
    }

    // MARK: - Telemetry Handler

    private func handleTelemetry(_ snapshot: [String: Any]) async {
        guard let sid = sessionId else { return }
        do {
            try await client.sendTelemetry(sessionId: sid, telemetry: snapshot)
            telemetrySent += 1
        } catch {
            // Best effort telemetry
        }
    }

    // MARK: - Upload Queue Retry Handler

    private func retryQueuedItem(_ item: UploadQueue.QueueItem) async -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: item.filePath)) else { return false }

        beginBackgroundTask()
        defer { endBackgroundTask() }

        do {
            try await client.uploadMedia(
                sessionId: item.sessionId, kind: item.kind, ext: item.ext,
                contentType: item.contentType, seq: item.seq, data: data,
                startedAt: item.startedAt, durationMs: item.durationMs)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Health Polling

    private func startHealthPolling() {
        checkServerHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkServerHealth() }
        }
    }

    private func checkServerHealth() {
        Task {
            do {
                let h = try await client.checkHealth()
                serverOnline = h.ok
            } catch {
                serverOnline = false
            }
        }
    }

    // MARK: - Delete Device Data

    func deleteDeviceData() async throws {
        DiagnosticsLogger.shared.log("Requesting deletion of all device data on server...", subsystem: .app, level: .info)
        try await client.deleteDevice()
        DiagnosticsLogger.shared.log("Device data purged from server.", subsystem: .app, level: .info)
    }

    // MARK: - Background Task Protection

    private func beginBackgroundTask() {
        guard bgTaskId == .invalid else { return }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "nexus.upload") { [weak self] in
            DiagnosticsLogger.shared.log("Background task expired by iOS watchdog.", subsystem: .app, level: .warn)
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    // MARK: - Memory Warning

    private func handleMemoryWarning() {
        DiagnosticsLogger.shared.log("System memory warning received! Shedding non-critical streams.",
                                     subsystem: .app, level: .warn)

        if camera.isCapturing {
            camera.stop()
            camera.onPhoto = nil
            lastErrorText = "Camera paused due to system memory pressure."
            DiagnosticsLogger.shared.log("Camera capture shed under memory pressure.", subsystem: .camera, level: .warn)
        }

        if telemetry.isActive {
            telemetry.stop()
            telemetry.onTelemetry = nil
            DiagnosticsLogger.shared.log("Sensor telemetry shed under memory pressure.", subsystem: .sensors, level: .warn)
        }
    }

    // MARK: - Crash Recovery

    private func persistSessionState() {
        UserDefaults.standard.set(sessionId, forKey: Self.sessionKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.sessionTsKey)
    }

    private func clearSessionState() {
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        UserDefaults.standard.removeObject(forKey: Self.sessionTsKey)
    }

    private func attemptCrashRecovery() {
        guard hasConsented,
              let savedSid = UserDefaults.standard.string(forKey: Self.sessionKey),
              !savedSid.isEmpty else { return }

        let ts = UserDefaults.standard.double(forKey: Self.sessionTsKey)
        let age = Date().timeIntervalSince1970 - ts

        guard age < 3600 else {
            clearSessionState()
            return
        }

        DiagnosticsLogger.shared.log("Detected interrupted session from previous run (age: \(Int(age))s). Auto-recovering session.",
                                     subsystem: .app, level: .warn)
        clearSessionState()
        Task { await start() }
    }
}
