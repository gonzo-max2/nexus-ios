import Foundation
import Combine
import AVFoundation

/// Records the user's own microphone as a sequence of complete, self-contained
/// AAC/.m4a segments. Each finished segment is handed to `onSegment` for upload.
///
/// Hardening:
///  - Retry recorder start up to 3 times with backoff
///  - Audio interruption handling (phone calls, Siri, alarms)
///  - Route change handling (headphones unplug, BT disconnect)
///  - Stale segment guard (reject 0-byte or corrupt files)
///  - Orphan temp file cleanup on start
///  - reclaimSession() for foreground return after background
///  - Meter timer uses weak self to prevent retain cycles
@MainActor
final class AudioRecorderService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var level: Float = 0
    @Published private(set) var lastError: String?

    /// (fileURL, seq, startedAtEpochMillis, durationMs)
    var onSegment: ((URL, Int, Int64, Int) -> Void)?

    private var recorder: AVAudioRecorder?
    private var seq = 0
    private var segmentSeconds = 5
    private var segmentStartedAt: Int64 = 0
    private var meterTimer: Timer?
    private var active = false
    private var interrupted = false
    private var startRetryCount = 0
    private var retryTask: Task<Void, Never>?
    private let maxStartRetries = 3

    private let settingsFormat: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 22050.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    // MARK: - Permission

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Start / Stop

    func start(segmentSeconds: Int) {
        guard !active else { return }
        self.segmentSeconds = max(2, segmentSeconds)
        self.active = true
        self.seq = 0
        self.interrupted = false
        self.startRetryCount = 0
        lastError = nil

        cleanupOrphanSegments()

        guard configureAudioSession() else {
            active = false
            return
        }

        registerForInterruptions()
        registerForRouteChanges()
        startNextSegment()
        startMeter()
    }

    func stop() {
        active = false
        retryTask?.cancel()
        retryTask = nil
        interrupted = false
        meterTimer?.invalidate(); meterTimer = nil
        discardCurrentSegment()
        isRecording = false
        level = 0
        unregisterNotifications()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Called by AppModel when returning to foreground — reclaims the audio
    /// session if iOS released it while we were backgrounded.
    func reclaimSession(segmentSeconds: Int) {
        guard active else { return }
        self.segmentSeconds = max(2, segmentSeconds)
        self.startRetryCount = 0

        // Re-configure the audio session — it may have been deactivated.
        if !configureAudioSession() {
            lastError = "Failed to reclaim audio session."
            return
        }

        // If the recorder was interrupted or stopped, start a fresh segment.
        if recorder == nil || !isRecording {
            interrupted = false
            startNextSegment()
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() -> Bool {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.allowBluetooth, .defaultToSpeaker, .mixWithOthers])
            try s.setActive(true)
            return true
        } catch {
            lastError = "Audio session: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Segment Management

    private func startNextSegment() {
        guard active, !interrupted else { return }
        retryTask?.cancel()
        retryTask = nil

        // Defensive: stop any dangling recorder.
        discardCurrentSegment()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg_\(UUID().uuidString)_\(seq).m4a")

        do {
            let r = try AVAudioRecorder(url: url, settings: settingsFormat)
            r.delegate = self
            r.isMeteringEnabled = true
            segmentStartedAt = Date().epochMillis

            guard r.record(forDuration: TimeInterval(segmentSeconds)) else {
                // Retry with backoff.
                try? FileManager.default.removeItem(at: url)
                retryStartSegment()
                return
            }
            recorder = r
            isRecording = true
            lastError = nil
            startRetryCount = 0  // Reset on success.
        } catch {
            lastError = "Recorder init: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: url)
            retryStartSegment()
        }
    }

    private func retryStartSegment() {
        startRetryCount += 1
        guard startRetryCount <= maxStartRetries, active else {
            lastError = "Recorder failed after \(maxStartRetries) retries."
            isRecording = false
            return
        }
        // Exponential backoff: 0.5s, 1s, 2s
        let delay = TimeInterval(0.5 * Double(1 << (startRetryCount - 1)))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.startNextSegment()
        }
    }

    private func discardCurrentSegment() {
        guard let current = recorder else { return }
        recorder = nil
        current.delegate = nil
        current.stop()
        try? FileManager.default.removeItem(at: current.url)
        isRecording = false
        level = 0
    }

    // MARK: - Level Meter

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let r = self.recorder, r.isRecording else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)
                let clamped = max(-60, db)
                self.level = (clamped + 60) / 60
            }
        }
    }

    // MARK: - Orphan Cleanup

    /// Remove leftover seg_*.m4a files from previous runs that were never uploaded.
    private func cleanupOrphanSegments() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("seg_")
                             && file.pathExtension == "m4a" {
            // A recently finished segment may still belong to an in-flight upload.
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  Date().timeIntervalSince(modified) > 86_400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Interruption Handling

    private func registerForInterruptions() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    private func registerForRouteChanges() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    private func unregisterNotifications() {
        NotificationCenter.default.removeObserver(self,
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(self,
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    @objc nonisolated private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        Task { @MainActor in
            guard self.active else { return }
            switch type {
            case .began:
                self.interrupted = true
                self.recorder?.pause()
                self.isRecording = false
                self.lastError = "Audio interrupted (phone call / Siri)."

            case .ended:
                self.interrupted = false
                self.startRetryCount = 0
                let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
                    ?? true
                if shouldResume && self.active {
                    if !self.configureAudioSession() {
                        self.lastError = "Session reactivation failed after interruption."
                        return
                    }
                    // Discard the interrupted segment and start fresh.
                    self.discardCurrentSegment()
                    self.startNextSegment()
                }

            @unknown default:
                break
            }
        }
    }

    @objc nonisolated private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }

        Task { @MainActor in
            if reason == .oldDeviceUnavailable && self.active && !self.interrupted {
                // Input device yanked — restart segment to pick up new input.
                self.discardCurrentSegment()
                self.startRetryCount = 0
                self.startNextSegment()
            }
        }
    }

    // MARK: - AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in
            guard self.recorder === recorder, self.active else { return }
            self.recorder = nil
            self.isRecording = false
            let mySeq = self.seq
            self.seq += 1

            if flag {
                // Validate: reject 0-byte or suspiciously small files (< 100 bytes = corrupt).
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
                if fileSize >= 100, let onSegment = self.onSegment {
                    onSegment(url, mySeq, self.segmentStartedAt, self.segmentSeconds * 1000)
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            } else {
                try? FileManager.default.removeItem(at: url)
            }

            if self.active && !self.interrupted {
                self.startRetryCount = 0
                self.startNextSegment()
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder, self.active else { return }
            self.lastError = "Encode error: \(error?.localizedDescription ?? "unknown")"
            self.discardCurrentSegment()
            if self.active && !self.interrupted {
                self.startRetryCount = 0
                self.startNextSegment()
            }
        }
    }
}
