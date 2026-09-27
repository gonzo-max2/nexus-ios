import Foundation
import Combine
import CoreMotion
import UIKit

/// Collects device sensor telemetry with maximum battery and CPU efficiency.
///
/// Hardening features:
///  - Eliminates high-frequency 10Hz main thread callback floods by using gentle 1Hz sampling / on-demand reads
///  - Gracefully handles missing hardware sensors on iPad, iPod, or Simulator
///  - Handles Motion & Fitness privacy permission denials without crashing
///  - Sanitizes NaN and infinite sensor values
///  - Integrated with DiagnosticsLogger
@MainActor
final class DeviceTelemetryService: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var steps: Int = 0

    var onTelemetry: (([String: Any]) -> Void)?

    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private var pollTimer: Timer?
    private var sessionStart: Date?

    private var accel: [String: Double] = ["x": 0, "y": 0, "z": 0]
    private var gyro: [String: Double] = ["x": 0, "y": 0, "z": 0]
    private var pressure: Double = 0.0     // kPa
    private var relativeAlt: Double = 0.0  // meters since start

    private var pedometerActive = false
    private var altimeterActive = false

    func start(intervalSeconds: Int = 5) {
        guard !isActive else { return }
        isActive = true
        sessionStart = Date()
        let started = sessionStart
        steps = 0
        pressure = 0
        relativeAlt = 0
        accel = ["x": 0, "y": 0, "z": 0]
        gyro = ["x": 0, "y": 0, "z": 0]

        DiagnosticsLogger.shared.log("Starting sensor telemetry service (interval: \(intervalSeconds)s)",
                                     subsystem: .sensors, level: .info)

        // Enable battery monitoring
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()

        // Configure Accelerometer with gentle 1.0s sampling to prevent CPU wakeups
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 1.0
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
                guard let self, self.isActive, self.sessionStart == started,
                      let d = data, error == nil else { return }
                self.accel = [
                    "x": self.sanitize(d.acceleration.x),
                    "y": self.sanitize(d.acceleration.y),
                    "z": self.sanitize(d.acceleration.z)
                ]
            }
        } else {
            DiagnosticsLogger.shared.log("Accelerometer hardware unavailable.", subsystem: .sensors, level: .debug)
        }

        // Configure Gyroscope
        if motionManager.isGyroAvailable {
            motionManager.gyroUpdateInterval = 1.0
            motionManager.startGyroUpdates(to: .main) { [weak self] data, error in
                guard let self, self.isActive, self.sessionStart == started,
                      let d = data, error == nil else { return }
                self.gyro = [
                    "x": self.sanitize(d.rotationRate.x),
                    "y": self.sanitize(d.rotationRate.y),
                    "z": self.sanitize(d.rotationRate.z)
                ]
            }
        } else {
            DiagnosticsLogger.shared.log("Gyroscope hardware unavailable.", subsystem: .sensors, level: .debug)
        }

        // Configure Altimeter
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeterActive = true
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                guard let self, self.isActive, self.sessionStart == started else { return }
                if let error {
                    DiagnosticsLogger.shared.log("Altimeter error: \(error.localizedDescription)",
                                                 subsystem: .sensors, level: .warn)
                    self.altimeter.stopRelativeAltitudeUpdates()
                    self.altimeterActive = false
                    return
                }
                if let d = data {
                    self.pressure = self.sanitize(d.pressure.doubleValue)
                    self.relativeAlt = self.sanitize(d.relativeAltitude.doubleValue)
                }
            }
        } else {
            DiagnosticsLogger.shared.log("Barometer/Altimeter hardware unavailable.", subsystem: .sensors, level: .debug)
        }

        // Configure Pedometer
        if CMPedometer.isStepCountingAvailable() {
            pedometerActive = true
            pedometer.startUpdates(from: sessionStart ?? Date()) { [weak self] data, error in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive, self.sessionStart == started else { return }
                    if let error {
                        DiagnosticsLogger.shared.log("Pedometer access denied or error: \(error.localizedDescription)",
                                                     subsystem: .sensors, level: .warn)
                        self.pedometer.stopUpdates()
                        self.pedometerActive = false
                        return
                    }
                    if let d = data {
                        self.steps = d.numberOfSteps.intValue
                    }
                }
            }
        } else {
            DiagnosticsLogger.shared.log("Step counter hardware unavailable.", subsystem: .sensors, level: .debug)
        }

        // Periodic snapshot push timer
        let interval = max(2, intervalSeconds)
        pollTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pushSnapshot() }
        }
        pollTimer?.tolerance = 1
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        pollTimer?.invalidate()
        pollTimer = nil

        if motionManager.isAccelerometerActive {
            motionManager.stopAccelerometerUpdates()
        }
        if motionManager.isGyroActive {
            motionManager.stopGyroUpdates()
        }
        if altimeterActive {
            altimeter.stopRelativeAltitudeUpdates()
            altimeterActive = false
        }
        if pedometerActive {
            pedometer.stopUpdates()
            pedometerActive = false
        }

        UIDevice.current.isBatteryMonitoringEnabled = false
        sessionStart = nil

        DiagnosticsLogger.shared.log("Stopped sensor telemetry service.", subsystem: .sensors, level: .info)
    }

    private func updateBattery() {
        let level = UIDevice.current.batteryLevel
        batteryLevel = level >= 0 ? level : -1.0
    }

    private func pushSnapshot() {
        guard isActive else { return }
        updateBattery()

        let snapshot: [String: Any] = [
            "timestamp": Date().epochMillis,
            "battery": [
                "level": batteryLevel >= 0 ? Double(batteryLevel) : 0.0,
                "state": batteryStateName
            ] as [String: Any],
            "sensors": [
                "accelerometer": accel,
                "gyroscope": gyro
            ] as [String: Any],
            "motion": [
                "steps": steps,
                "relativeAltitude": relativeAlt
            ] as [String: Any],
            "pressure": pressure,
            "steps": steps
        ]

        onTelemetry?(snapshot)
    }

    private func sanitize(_ val: Double) -> Double {
        if val.isNaN || val.isInfinite { return 0.0 }
        return val
    }

    private var batteryStateName: String {
        switch UIDevice.current.batteryState {
        case .charging:  return "charging"
        case .full:      return "full"
        case .unplugged: return "unplugged"
        case .unknown:   return "unknown"
        @unknown default: return "unknown"
        }
    }
}
