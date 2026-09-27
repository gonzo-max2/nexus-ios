import SwiftUI

/// Main screen. Deliberately loud about recording state — the banner and meter
/// make it impossible to forget the mic is live.
/// Hardened with in-app diagnostics integration and live subsystem health warnings.
struct MonitorView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var audio: AudioRecorderService
    @ObservedObject private var logger = DiagnosticsLogger.shared

    @State private var showSettings = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    serverStatusBar
                    recordingBanner
                    levelMeter
                    elapsedTimerView
                    diagnosticsBanner
                    statsPanel
                    sensorPanel
                    cameraPanel
                    ScreenBroadcastView()

                    if let err = model.lastErrorText {
                        Text(err)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if model.uploadQueue.pendingCount > 0 {
                        Button {
                            model.uploadQueue.retryNow()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .foregroundColor(.orange)
                                Text("\(model.uploadQueue.pendingCount) queued (\(model.uploadQueue.totalDiskBytes / 1024) KB) · Tap to retry")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.orange)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(8)
                        }
                    }

                    Button(action: { model.toggleMonitoring() }) {
                        Text(model.isStarting ? "Cancel start" : (model.isMonitoring ? "Stop" : "Start recording"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(model.isMonitoring ? Color.red : Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }

                    Button {
                        showDiagnostics = true
                    } label: {
                        HStack {
                            Image(systemName: "stethoscope")
                            Text("Open Live Diagnostics & Traces")
                        }
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            .navigationTitle("Self-Monitor")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform.path.ecg")
                            if logger.errorCount > 0 {
                                Circle().fill(Color.red).frame(width: 6, height: 6)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
        }
    }

    // MARK: - Diagnostics Banner

    @ViewBuilder
    private var diagnosticsBanner: some View {
        if logger.errorCount > 0 || logger.warningCount > 0 {
            Button {
                showDiagnostics = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: logger.errorCount > 0 ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundColor(logger.errorCount > 0 ? .red : .orange)
                    Text("\(logger.errorCount) errors, \(logger.warningCount) warnings in system log")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .background(Color(logger.errorCount > 0 ? UIColor.systemRed : UIColor.systemOrange).opacity(0.12))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Server Status

    private var serverStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.serverOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(model.serverOnline ? "Server online" : "Server offline")
                .font(.caption)
                .foregroundColor(model.serverOnline ? .green : .red)
            Spacer()
            Text(model.settings.serverURL)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Recording Banner

    private var recordingBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isMonitoring ? Color.red : Color.gray)
                .frame(width: 14, height: 14)
                .opacity(model.isMonitoring ? 1 : 0.5)
            Text(audio.isRecording ? "● RECORDING & STREAMING" : (model.isMonitoring ? "Microphone paused" : "Not recording"))
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding()
        .background(model.isMonitoring ? Color.red.opacity(0.12) : Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Level Meter

    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15))
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(audio.level))
                    .animation(.linear(duration: 0.1), value: audio.level)
            }
        }
        .frame(height: 12)
        .opacity(model.isMonitoring ? 1 : 0.4)
    }

    // MARK: - Elapsed Timer

    private var elapsedTimerView: some View {
        Group {
            if model.isMonitoring {
                HStack {
                    Image(systemName: "timer")
                        .foregroundColor(.orange)
                    Text(formatElapsed(model.elapsedSeconds))
                        .font(.system(.title2, design: .monospaced).weight(.medium))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(10)
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
        .padding()
        .background(Color.gray.opacity(0.08))
        .cornerRadius(12)
    }

    // MARK: - Sensor Panel

    private var sensorPanel: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "sensor.tag.radiowaves.forward")
                Text("Device Sensors").font(.subheadline.weight(.semibold))
                Spacer()
            }
            row("Battery", model.telemetry.batteryLevel >= 0
                 ? "\(Int(model.telemetry.batteryLevel * 100))%"
                 : "N/A")
            row("Steps", "\(model.telemetry.steps)")
            row("Sensors active", model.telemetry.isActive ? "Yes" : "No")
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .cornerRadius(12)
    }

    // MARK: - Camera Panel

    private var cameraPanel: some View {
        Group {
            if model.settings.cameraEnabled {
                VStack(spacing: 6) {
                    HStack {
                        Image(systemName: "camera")
                        Text("Camera Capture").font(.subheadline.weight(.semibold))
                        Spacer()
                        if model.isMonitoring {
                            Button {
                                model.camera.toggleFrontBack()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .font(.caption)
                            }
                        }
                    }
                    row("Photos taken", "\(model.camera.photosTaken)")
                    row("Interval", "\(model.settings.cameraIntervalSeconds)s")
                    row("Capturing", model.camera.isCapturing ? "Active" : "Idle")
                }
                .padding()
                .background(Color.gray.opacity(0.08))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Helpers

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundColor(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }
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
