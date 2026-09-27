import Foundation
import Combine
import AVFoundation
import UIKit

/// Captures periodic JPEG photos from the device camera and delivers them
/// via `onPhoto` for upload. Uses AVCaptureSession with a photo output.
///
/// Hardening:
///  - Session runtime error observer (auto-restart on hardware glitch)
///  - Session interruption handling (phone call steals camera)
///  - Guard against capture while session is not running
///  - Photo delegate completion guard (prevent double-fire)
///  - Session start/stop on background queue to avoid main thread hang
///  - Memory-adaptive JPEG quality
@MainActor
final class CameraCaptureService: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var lastError: String?
    @Published private(set) var photosTaken = 0

    /// (jpegData, sequenceIndex)
    var onPhoto: ((Data, Int) -> Void)?

    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var timer: Timer?
    private var seq = 0
    private var active = false
    private var usingFront = false
    private var captureInFlight = false   // Prevent overlapping captures
    private var captureID: Int64?
    private var intervalSeconds = 10
    private var jpegQuality: CGFloat = 0.6

    private let sessionQueue = DispatchQueue(label: "com.nexus.camera.session", qos: .userInitiated)
    private let imageQueue = DispatchQueue(label: "com.nexus.camera.jpeg", qos: .utility)

    // MARK: - Permission

    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: - Lifecycle

    func start(intervalSeconds: Int, useFrontCamera: Bool = false, resetSequence: Bool = true) {
        guard !active else { return }
        active = true
        usingFront = useFrontCamera
        self.intervalSeconds = max(3, intervalSeconds)
        if resetSequence {
            seq = 0
            photosTaken = 0
        }
        lastError = nil
        captureInFlight = false

        guard setupSession(), let session = captureSession else {
            active = false
            return
        }

        registerNotifications()

        // Start session on background queue to avoid blocking main thread.
        sessionQueue.async { [weak self] in
            session.startRunning()
            Task { @MainActor [weak self] in
                guard let self, self.active, self.captureSession === session else { return }
                self.isCapturing = session.isRunning
                // Fire immediately, then repeat.
                self.capturePhoto()
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(
                    withTimeInterval: TimeInterval(self.intervalSeconds),
                    repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.capturePhoto() }
                }
            }
        }
    }

    func stop() {
        active = false
        timer?.invalidate()
        timer = nil
        captureInFlight = false
        captureID = nil
        unregisterNotifications()

        let session = captureSession
        sessionQueue.async {
            session?.stopRunning()
        }
        captureSession = nil
        photoOutput = nil
        isCapturing = false
    }

    func toggleFrontBack() {
        guard active else { return }
        let savedInterval = intervalSeconds
        stop()
        usingFront.toggle()
        start(intervalSeconds: savedInterval, useFrontCamera: usingFront, resetSequence: false)
    }

    /// Reduce JPEG quality under memory pressure.
    func setLowMemoryMode(_ on: Bool) {
        jpegQuality = on ? 0.3 : 0.6
    }

    // MARK: - Session Setup

    private func setupSession() -> Bool {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .medium

        let position: AVCaptureDevice.Position = usingFront ? .front : .back

        // Multi-device discovery covering iPhone XR single 12MP wide rear and 7MP TrueDepth front camera
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTrueDepthCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        )
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            lastError = "No \(usingFront ? "front" : "back") camera available."
            DiagnosticsLogger.shared.log("Failed to find camera device for position \(usingFront ? "front" : "back")",
                                         subsystem: .camera, level: .error)
            return false
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                lastError = "Cannot add camera input."
                return false
            }
            session.addInput(input)
        } catch {
            lastError = "Camera input: \(error.localizedDescription)"
            return false
        }

        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            lastError = "Cannot add photo output."
            return false
        }
        session.addOutput(output)

        captureSession = session
        photoOutput = output
        return true
    }

    // MARK: - Capture

    private func capturePhoto() {
        guard active,
              let output = photoOutput,
              let session = captureSession,
              session.isRunning,
              !captureInFlight else { return }

        captureInFlight = true
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        captureID = settings.uniqueID
        settings.flashMode = .off
        output.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Notifications

    private func registerNotifications() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError, object: captureSession)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted, object: captureSession)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sessionInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded, object: captureSession)
    }

    private func unregisterNotifications() {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: nil)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionInterruptionEnded, object: nil)
    }

    @objc nonisolated private func sessionRuntimeError(_ notification: Notification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError,
              let session = notification.object as? AVCaptureSession else { return }
        Task { @MainActor in
            guard self.active, self.captureSession === session else { return }
            self.lastError = "Camera error: \(error.localizedDescription)"
            self.captureInFlight = false
            self.captureID = nil
            // Attempt auto-restart after a hardware glitch.
            if self.active, error.code == .mediaServicesWereReset {
                self.restartSession(session)
            }
        }
    }

    @objc nonisolated private func sessionWasInterrupted(_ notification: Notification) {
        guard let session = notification.object as? AVCaptureSession else { return }
        Task { @MainActor in
            guard self.active, self.captureSession === session else { return }
            self.isCapturing = false
            self.captureInFlight = false
            self.captureID = nil
        }
    }

    @objc nonisolated private func sessionInterruptionEnded(_ notification: Notification) {
        guard let session = notification.object as? AVCaptureSession else { return }
        Task { @MainActor in
            guard self.active, self.captureSession === session else { return }
            self.restartSession(session)
        }
    }

    private func restartSession(_ session: AVCaptureSession) {
        sessionQueue.async { [weak self] in
            session.startRunning()
            Task { @MainActor [weak self] in
                guard let self, self.active, self.captureSession === session else { return }
                self.isCapturing = session.isRunning
            }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraCaptureService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        Task { @MainActor in
            let id = photo.resolvedSettings.uniqueID
            guard self.active, self.photoOutput === output, self.captureID == id else { return }

            if let error {
                self.captureInFlight = false
                self.captureID = nil
                self.lastError = "Photo: \(error.localizedDescription)"
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                self.captureInFlight = false
                self.captureID = nil
                self.lastError = "Photo: no data representation."
                return
            }

            let quality = self.jpegQuality
            self.imageQueue.async { [weak self] in
                let compressed = autoreleasepool {
                    UIImage(data: data)?.jpegData(compressionQuality: quality) ?? data
                }
                Task { @MainActor [weak self] in
                    guard let self, self.active, self.photoOutput === output, self.captureID == id else { return }
                    self.captureInFlight = false
                    self.captureID = nil
                    guard compressed.count >= 500 else { return }
                    let mySeq = self.seq
                    self.seq += 1
                    self.photosTaken += 1
                    self.onPhoto?(compressed, mySeq)
                }
            }
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                                  error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            guard self.active, self.photoOutput === output,
                  self.captureID == resolvedSettings.uniqueID else { return }
            self.captureInFlight = false
            self.captureID = nil
            self.lastError = "Photo capture: \(error.localizedDescription)"
        }
    }
}
