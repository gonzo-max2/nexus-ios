import Foundation
import os
import UIKit

/// Thread-safe in-memory diagnostics ring buffer combined with Apple Unified Logging (os.Logger).
/// Provides live on-device diagnostic tracing for all subsystems without requiring an active Xcode debug session.
@MainActor
public final class DiagnosticsLogger: ObservableObject {
    public static let shared = DiagnosticsLogger()

    public enum Subsystem: String, CaseIterable, Codable, Sendable {
        case app = "APP"
        case audio = "AUDIO"
        case camera = "CAMERA"
        case location = "LOCATION"
        case network = "NETWORK"
        case queue = "QUEUE"
        case sensors = "SENSORS"

        var osLogCategory: String {
            switch self {
            case .app: return "Application"
            case .audio: return "AudioEngine"
            case .camera: return "CameraCapture"
            case .location: return "LocationService"
            case .network: return "IngestNetwork"
            case .queue: return "UploadQueue"
            case .sensors: return "SensorTelemetry"
            }
        }
    }

    public enum Level: String, CaseIterable, Codable, Comparable, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"

        public static func < (lhs: Level, rhs: Level) -> Bool {
            let order: [Level] = [.debug, .info, .warn, .error]
            guard let lIdx = order.firstIndex(of: lhs), let rIdx = order.firstIndex(of: rhs) else { return false }
            return lIdx < rIdx
        }

        var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warn: return .default
            case .error: return .error
            }
        }

        public var emoji: String {
            switch self {
            case .debug: return "🔍"
            case .info: return "ℹ️"
            case .warn: return "⚠️"
            case .error: return "🛑"
            }
        }
    }

    public struct LogEntry: Identifiable, Codable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let subsystem: Subsystem
        public let level: Level
        public let message: String

        public init(id: UUID = UUID(), timestamp: Date = Date(), subsystem: Subsystem, level: Level, message: String) {
            self.id = id
            self.timestamp = timestamp
            self.subsystem = subsystem
            self.level = level
            self.message = message
        }

        public var formattedTime: String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            return df.string(from: timestamp)
        }

        public var formattedLine: String {
            "[\(formattedTime)] [\(level.rawValue)] [\(subsystem.rawValue)] \(message)"
        }
    }

    @Published public private(set) var entries: [LogEntry] = []
    @Published public private(set) var warningCount: Int = 0
    @Published public private(set) var errorCount: Int = 0

    private let maxEntries: Int = 300
    private var osLoggers: [Subsystem: Logger] = [:]

    private init() {
        for sub in Subsystem.allCases {
            osLoggers[sub] = Logger(subsystem: "com.nexus.selfmonitor", category: sub.osLogCategory)
        }
        log("Diagnostics subsystem initialized. Ready for telemetry and traces.", subsystem: .app, level: .info)
    }

    /// Record a diagnostic event to both Apple Unified Logging and the in-memory ring buffer.
    /// Thread-safe and nonisolated so any background actor can call it synchronously.
    public nonisolated func log(_ message: String, subsystem: Subsystem, level: Level = .info) {
        let entry = LogEntry(subsystem: subsystem, level: level, message: message)
        
        // Mirror immediately to Apple Unified Logging (thread-safe by Apple design)
        let osLogger = Logger(subsystem: "com.nexus.selfmonitor", category: subsystem.osLogCategory)
        switch level {
        case .debug:
            osLogger.debug("\(message, privacy: .public)")
        case .info:
            osLogger.info("\(message, privacy: .public)")
        case .warn:
            osLogger.warning("\(message, privacy: .public)")
        case .error:
            osLogger.error("\(message, privacy: .public)")
        }

        // Dispatch to MainActor for SwiftUI state updates
        Task { @MainActor in
            self.appendEntry(entry)
        }
    }

    private func appendEntry(_ entry: LogEntry) {
        if entries.count >= maxEntries {
            entries.removeFirst(entries.count - maxEntries + 1)
        }
        entries.append(entry)

        if entry.level == .warn {
            warningCount += 1
        } else if entry.level == .error {
            errorCount += 1
        }
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
        warningCount = 0
        errorCount = 0
        log("Diagnostics buffer cleared by user.", subsystem: .app, level: .info)
    }

    /// Generates a comprehensive plain-text diagnostic snapshot for troubleshooting.
    public func generateExportReport(extraContext: [String: String] = [:]) -> String {
        var report = """
        ====================================================
        NEXUS SELF-MONITOR DIAGNOSTIC REPORT
        ====================================================
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        Device Model: \(UIDevice.current.model)
        System Name: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Battery Level: \(UIDevice.current.batteryLevel >= 0 ? "\(Int(UIDevice.current.batteryLevel * 100))%" : "Unknown")
        Battery State: \(batteryStateDescription)
        Total Recorded Warnings: \(warningCount)
        Total Recorded Errors: \(errorCount)
        Buffered Log Entries: \(entries.count)

        """

        if !extraContext.isEmpty {
            report += "--- OPERATIONAL CONTEXT ---\n"
            for (key, val) in extraContext.sorted(by: { $0.key < $1.key }) {
                report += "\(key): \(val)\n"
            }
            report += "\n"
        }

        report += "--- DIAGNOSTIC TRACE LOGS (CHRONOLOGICAL) ---\n"
        for e in entries {
            report += "\(e.formattedLine)\n"
        }
        report += "====================================================\n"

        return report
    }

    private var batteryStateDescription: String {
        switch UIDevice.current.batteryState {
        case .charging: return "Charging"
        case .full: return "Full"
        case .unplugged: return "Unplugged"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}
