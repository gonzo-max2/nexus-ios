import Foundation
import Combine
import CoreLocation

/// Wraps CLLocationManager for high-fidelity location telemetry.
///
/// Hardening features:
///  - Safe allowsBackgroundLocationUpdates guarding to prevent NSInternalInconsistencyException crashes
///  - Modern iOS 14+ locationManagerDidChangeAuthorization implementation
///  - Strict accuracy filtering (<100m) and stale fix rejection (>15s old)
///  - Diagnostic logging and error categorization
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var authStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isUpdating: Bool = false
    @Published private(set) var lastError: String?

    /// Called for each accepted valid fix.
    var onLocation: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    private var wantBackground: Bool = false
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10.0
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authStatus = manager.authorizationStatus
    }

    func start(background: Bool) {
        wantsUpdates = true
        wantBackground = background
        lastError = nil

        DiagnosticsLogger.shared.log("Starting location tracking (background requested: \(background))",
                                     subsystem: .location, level: .info)

        switch manager.authorizationStatus {
        case .notDetermined:
            DiagnosticsLogger.shared.log("Requesting WhenInUse location authorization",
                                         subsystem: .location, level: .info)
            manager.requestWhenInUseAuthorization()

        case .authorizedWhenInUse:
            if background {
                DiagnosticsLogger.shared.log("Requesting Always location authorization for background mode",
                                             subsystem: .location, level: .info)
                manager.requestAlwaysAuthorization()
            }
            configureAndStart(enableBackground: false)

        case .authorizedAlways:
            configureAndStart(enableBackground: background)

        case .denied, .restricted:
            lastError = "Location permission denied. Please enable in Settings."
            DiagnosticsLogger.shared.log("Location access denied or restricted.",
                                         subsystem: .location, level: .warn)

        @unknown default:
            break
        }
    }

    func stop() {
        wantsUpdates = false
        wantBackground = false
        manager.stopUpdatingLocation()
        safeSetBackgroundLocation(enabled: false)
        isUpdating = false
        DiagnosticsLogger.shared.log("Stopped location tracking.", subsystem: .location, level: .info)
    }

    // MARK: - Private Helpers

    private func configureAndStart(enableBackground: Bool) {
        guard wantsUpdates else { return }
        safeSetBackgroundLocation(enabled: enableBackground)
        manager.startUpdatingLocation()
        isUpdating = true
    }

    /// Safeguards against NSInternalInconsistencyException when UIBackgroundModes does not contain 'location'
    /// or when authorization is not .authorizedAlways.
    private func safeSetBackgroundLocation(enabled: Bool) {
        guard enabled else {
            manager.allowsBackgroundLocationUpdates = false
            return
        }

        let bgModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        let hasLocationBgMode = bgModes.contains("location")

        if hasLocationBgMode && manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            DiagnosticsLogger.shared.log("Enabled background location updates with OS indicator.",
                                         subsystem: .location, level: .info)
        } else {
            manager.allowsBackgroundLocationUpdates = false
            if enabled {
                DiagnosticsLogger.shared.log("Background location updates unavailable (Requires 'Always' authorization).",
                                             subsystem: .location, level: .warn)
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            self.authStatus = status
            DiagnosticsLogger.shared.log("Location authorization status changed to: \(self.statusName(status))",
                                         subsystem: .location, level: .info)

            guard self.wantsUpdates else { return }
            switch status {
            case .authorizedAlways:
                self.configureAndStart(enableBackground: self.wantBackground)
            case .authorizedWhenInUse:
                if self.wantBackground {
                    manager.requestAlwaysAuthorization()
                }
                self.configureAndStart(enableBackground: false)
            case .denied, .restricted:
                self.lastError = "Location access denied."
                self.stop()
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        Task { @MainActor in
            guard self.wantsUpdates else { return }
            // Filter 1: Inaccurate fix (negative or > 100 meters)
            guard loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= 100.0 else {
                DiagnosticsLogger.shared.log("Filtered inaccurate GPS fix (accuracy: \(Int(loc.horizontalAccuracy))m)",
                                             subsystem: .location, level: .debug)
                return
            }

            // Filter 2: Stale fix (> 15 seconds old)
            let ageSeconds = abs(loc.timestamp.timeIntervalSinceNow)
            guard ageSeconds <= 15.0 else {
                DiagnosticsLogger.shared.log("Filtered stale GPS fix (age: \(Int(ageSeconds))s)",
                                             subsystem: .location, level: .debug)
                return
            }

            self.lastLocation = loc
            self.lastError = nil
            self.onLocation?(loc)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if let clError = error as? CLError {
                switch clError.code {
                case .denied:
                    self.lastError = "Location denied by system."
                    DiagnosticsLogger.shared.log("Location error: access denied.",
                                                 subsystem: .location, level: .warn)
                    self.stop()
                case .locationUnknown:
                    // Transient error, system is acquiring fix
                    DiagnosticsLogger.shared.log("GPS searching for signal...",
                                                 subsystem: .location, level: .debug)
                default:
                    self.lastError = "Location error: \(clError.localizedDescription)"
                    DiagnosticsLogger.shared.log("Location error: \(clError.localizedDescription)",
                                                 subsystem: .location, level: .warn)
                }
            } else {
                self.lastError = error.localizedDescription
                DiagnosticsLogger.shared.log("Location error: \(error.localizedDescription)",
                                             subsystem: .location, level: .warn)
            }
        }
    }

    private func statusName(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown"
        }
    }
}
