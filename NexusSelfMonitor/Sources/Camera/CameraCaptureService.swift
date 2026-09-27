import Foundation
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
    private var intervalSeconds = 10
    private var jpegQuality: CGFloat = 0.6

    private let sessionQueue = DispatchQueue(label: "com.nexus.camera.session", qos: .userInitiated)

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

    func start(intervalSeconds: Int, useFrontCamera: Bool = false) {
        guard !active else { return }
        active = true
        usingFront = useFrontCamera
        self.intervalSeconds = max(3, intervalSeconds)
        seq = 0
        photosTaken = 0
        lastError = nil
        captureInFlight = false

        guard setupSession() else {
            active = false
            return
        }

        registerNotifications()

        // Start session on background queue to avoid blocking main thread.
        sessionQueue.async { [weak self] in
            self?.captureSession?.startRunning()
            Task { @MainActor in
                self?.isCapturing = true
                // Fire immediately, then repeat.
                self?.capturePhoto()
                self?.timer = Timer.scheduledTimer(
                    withTimeInterval: TimeInterval(self?.intervalSeconds ?? 10),
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
        start(intervalSeconds: savedInterval, useFrontCamera: usingFront)
    }

    /// Reduce JPEG quality under memory pressure.
    func setLowMemoryMode(_ on: Bool) {
        jpegQuality = on ? 0.3 : 0.6
    }

    // MARK: - Session Setup

    private func setupSession() -> Bool {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .medium

        let position: AVCaptureDevice.Position = usingFront ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            lastError = "No \(usingFront ? "front" : "back") camera available."
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
        session.commitConfiguration()

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
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        Task { @MainActor in
            self.lastError = "Camera error: \(error.localizedDescription)"
            // Attempt auto-restart after a hardware glitch.
            if self.active, error.code == .mediaServicesWereReset {
                self.sessionQueue.async { [weak self] in
                    self?.captureSession?.startRunning()
                }
            }
        }
    }

    @objc nonisolated private func sessionWasInterrupted(_ notification: Notification) {
        Task { @MainActor in
            self.isCapturing = false
            self.captureInFlight = false
        }
    }

    @objc nonisolated private func sessionInterruptionEnded(_ notification: Notification) {
        Task { @MainActor in
            if self.active {
                self.sessionQueue.async { [weak self] in
                    self?.captureSession?.startRunning()
                    Task { @MainActor in self?.isCapturing = true }
                }
            }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraCaptureService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        Task { @MainActor in
            self.captureInFlight = false  // Always release the guard.

            if let error {
                self.lastError = "Photo: \(error.localizedDescription)"
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                self.lastError = "Photo: no data representation."
                return
            }

            // Compress with adaptive quality.
            let compressed = UIImage(data: data)?
                .jpegData(compressionQuality: self.jpegQuality) ?? data

            // Reject suspiciously small images (< 500 bytes = likely corrupt).
            guard compressed.count >= 500 else { return }

            let mySeq = self.seq
            self.seq += 1
            self.photosTaken += 1
            self.onPhoto?(compressed, mySeq)
        }
    }
}
