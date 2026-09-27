import SwiftUI
import UIKit

/// In-app live diagnostics & debugging console.
/// Allows operators and users to inspect real-time traces across all subsystems,
/// verify queue status, check hardware state, and copy diagnostic bundles.
struct DiagnosticsView: View {
    @ObservedObject private var logger = DiagnosticsLogger.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSubsystem: DiagnosticsLogger.Subsystem? = nil
    @State private var filterLevel: DiagnosticsLogger.Level = .debug
    @State private var searchText: String = ""
    @State private var showCopiedAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                summaryHeader
                filterBar
                logList
            }
            .navigationTitle("Diagnostics & Traces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            copyDiagnosticReport()
                        } label: {
                            Label("Copy Diagnostic Report", systemImage: "doc.on.doc")
                        }

                        Button {
                            model.uploadQueue.retryNow()
                        } label: {
                            Label("Retry Queued Uploads Now", systemImage: "arrow.clockwise")
                        }

                        Divider()

                        Button(role: .destructive) {
                            logger.clear()
                        } label: {
                            Label("Clear In-Memory Logs", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Report Copied", isPresented: $showCopiedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Complete diagnostic report copied to clipboard. You can paste it into an issue report or message.")
            }
        }
    }

    // MARK: - Summary Header

    private var summaryHeader: some View {
        VStack(spacing: 6) {
            HStack {
                statBadge(label: "LOGS", value: "\(logger.entries.count)", color: .blue)
                statBadge(label: "WARNS", value: "\(logger.warningCount)", color: .orange)
                statBadge(label: "ERRORS", value: "\(logger.errorCount)", color: .red)
                statBadge(label: "QUEUE", value: "\(model.uploadQueue.pendingCount) (\(model.uploadQueue.totalDiskBytes / 1024)K)", color: .purple)
                Spacer()
            }

            HStack {
                Text("Session: \(model.settings.deviceId)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(model.serverOnline ? "● Ingest Online" : "○ Ingest Offline")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(model.serverOnline ? .green : .red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip(title: "ALL", isSelected: selectedSubsystem == nil) {
                        selectedSubsystem = nil
                    }
                    ForEach(DiagnosticsLogger.Subsystem.allCases, id: \.self) { sub in
                        filterChip(title: sub.rawValue, isSelected: selectedSubsystem == sub) {
                            selectedSubsystem = sub
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("Filter messages…", text: $searchText)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(UIColor.tertiarySystemBackground))
            .cornerRadius(8)
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background(Color(UIColor.systemBackground))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - Log List

    private var filteredEntries: [DiagnosticsLogger.LogEntry] {
        logger.entries.reversed().filter { entry in
            if let sel = selectedSubsystem, entry.subsystem != sel {
                return false
            }
            if !searchText.isEmpty {
                return entry.message.localizedCaseInsensitiveContains(searchText)
                    || entry.subsystem.rawValue.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    private var logList: some View {
        Group {
            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No diagnostic entries found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(filteredEntries) { entry in
                    logRow(for: entry)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
    }

    private func logRow(for entry: DiagnosticsLogger.LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.level.emoji)
                    .font(.caption2)
                Text(entry.formattedTime)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                Text("[\(entry.subsystem.rawValue)]")
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundColor(color(for: entry.subsystem))
                Spacer()
                Text(entry.level.rawValue)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(badgeColor(for: entry.level).opacity(0.18))
                    .foregroundColor(badgeColor(for: entry.level))
                    .cornerRadius(4)
            }

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(6)
    }

    // MARK: - Actions & Formatters

    private func copyDiagnosticReport() {
        let extraContext: [String: String] = [
            "Active Session": model.isMonitoring ? "Running" : "Idle",
            "Server URL": model.settings.serverURL,
            "Device ID": model.settings.deviceId,
            "Audio Segments Sent": "\(model.segmentsSent)",
            "Locations Sent": "\(model.locationsSent)",
            "Photos Sent": "\(model.photosSent)",
            "Telemetry Pushes": "\(model.telemetrySent)",
            "Queue Depth": "\(model.uploadQueue.pendingCount) items (\(model.uploadQueue.totalDiskBytes / 1024) KB)"
        ]
        let report = logger.generateExportReport(extraContext: extraContext)
        UIPasteboard.general.string = report
        showCopiedAlert = true
    }

    private func statBadge(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .cornerRadius(6)
    }

    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor : Color(UIColor.secondarySystemFill))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(12)
        }
    }

    private func color(for sub: DiagnosticsLogger.Subsystem) -> Color {
        switch sub {
        case .app: return .primary
        case .audio: return .orange
        case .camera: return .blue
        case .location: return .green
        case .network: return .indigo
        case .queue: return .purple
        case .sensors: return .teal
        }
    }

    private func badgeColor(for level: DiagnosticsLogger.Level) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}
