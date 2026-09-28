import SwiftUI

/// Main screen. Understated, minimalist monitor interface.
/// Provides clear session state and diagnostics while minimizing visual noise.
struct MonitorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var audio: AudioRecorderService
    @ObservedObject private var logger = DiagnosticsLogger.shared

    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    statusHeaderCard
                    diagnosticsBanner
                    queuedUploadsView

                    if let err = model.lastErrorText {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    controlButton
                    statsPanel
                    sensorPanel
                    cameraPanel
                    ScreenBroadcastView()

                    Button {
                        showDiagnostics = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.path.ecg")
                            Text("Diagnostics & Logs")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Self-Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform.path.ecg")
                            if logger.errorCount > 0 {
                                Circle().fill(Color.orange).frame(width: 6, height: 6)
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .onAppear {
                model.reconcile(.viewAppeared)
            }
        }
    }

    // MARK: - Consolidated Status Card

    private var statusHeaderCard: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isMonitoring ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(audio.isRecording ? "Active" : (model.isMonitoring ? "Paused" : "Idle"))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                }

                Spacer()

                if model.isMonitoring {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(formatElapsed(model.elapsedSeconds))
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(UIColor.tertiarySystemFill))
                    .clipShape(Capsule())
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(model.serverOnline ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(model.serverOnline ? "Online" : "Offline")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if model.isMonitoring {
                levelMeter
            }

            if !model.isMonitoring && !model.isStarting && model.status != "Idle" {
                Text(model.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Minimalist Level Gauge

    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(UIColor.tertiarySystemFill))
                Capsule()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(audio.level))))
                    .animation(.linear(duration: 0.08), value: audio.level)
            }
        }
        .frame(height: 3)
    }

    // MARK: - Subdued Action Controls

    private var controlButton: some View {
        Button(action: { model.toggleMonitoring() }) {
            HStack(spacing: 6) {
                Image(systemName: model.isMonitoring ? "stop.fill" : "play.fill")
                    .font(.caption2.weight(.bold))
                Text(model.isStarting ? "Starting..." : (model.isMonitoring ? "End Session" : "Start Session"))
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                model.isMonitoring
                    ? Color.red.opacity(0.08)
                    : Color.accentColor.opacity(0.1)
            )
            .foregroundColor(model.isMonitoring ? .red : .accentColor)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(model.isMonitoring ? Color.red.opacity(0.2) : Color.accentColor.opacity(0.2), lineWidth: 1)
            )
            .cornerRadius(10)
        }
    }

    // MARK: - Queued Uploads Accessory

    @ViewBuilder
    private var queuedUploadsView: some View {
        if model.uploadQueue.pendingCount > 0 {
            Button {
                model.uploadQueue.retryNow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                    Text("\(model.uploadQueue.pendingCount) queued (\(model.uploadQueue.totalDiskBytes / 1024) KB)")
                        .font(.caption2.weight(.medium))
                    Spacer()
                    Text("Retry")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.tertiarySystemFill))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Diagnostics Accessory

    @ViewBuilder
    private var diagnosticsBanner: some View {
        if logger.errorCount > 0 || logger.warningCount > 0 {
            Button {
                showDiagnostics = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(logger.errorCount) warnings / issues recorded")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(UIColor.tertiarySystemFill))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Stats Panel

    private var statsPanel: some View {
        VStack(spacing: 6) {
            row("Status", model.status)
            row("Audio segments", "\(model.segmentsSent)")
            row("Locations sent", "\(model.locationsSent)")
            if model.settings.cameraEnabled {
                row("Photos sent", "\(model.photosSent)")
            }
            row("Telemetry pushes", "\(model.telemetrySent)")
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Sensor Panel

    private var sensorPanel: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .foregroundColor(.secondary)
                Text("Device Sensors").font(.subheadline.weight(.medium))
                Spacer()
            }
            row("Battery", model.telemetry.batteryLevel >= 0
                 ? "\(Int(model.telemetry.batteryLevel * 100))%"
                 : "N/A")
            row("Steps", "\(model.telemetry.steps)")
            row("Sensors active", model.telemetry.isActive ? "Yes" : "No")
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Camera Panel

    private var cameraPanel: some View {
        Group {
            if model.settings.cameraEnabled {
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "camera")
                            .foregroundColor(.secondary)
                        Text("Camera Capture").font(.subheadline.weight(.medium))
                        Spacer()
                        if model.isMonitoring {
                            Button {
                                model.camera.toggleFrontBack()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    row("Photos taken", "\(model.camera.photosTaken)")
                    row("Interval", "\(model.settings.cameraIntervalSeconds)s")
                    row("Capturing", model.camera.isCapturing ? "Active" : "Idle")
                }
                .padding(12)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Helpers

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundColor(.secondary); Spacer(); Text(v).foregroundColor(.primary).multilineTextAlignment(.trailing) }
            .font(.subheadline)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
