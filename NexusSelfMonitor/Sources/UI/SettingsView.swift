import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Settings()
    @State private var showDeleteConfirm = false
    @State private var showDiagnostics = false
    @State private var deleteError: String?
    @State private var deleteSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $draft.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Ingest token (optional)", text: $draft.ingestToken)
                }
                Section("This device") {
                    TextField("Device name", text: $draft.deviceName)
                    LabeledContent("Device ID", value: draft.deviceId)
                        .font(.caption)
                }
                Section("Audio") {
                    Stepper("Segment length: \(draft.segmentSeconds)s",
                            value: $draft.segmentSeconds, in: 2...30)
                }
                Section("Camera") {
                    Toggle("Enable periodic photo capture", isOn: $draft.cameraEnabled)
                    if draft.cameraEnabled {
                        Stepper("Photo interval: \(draft.cameraIntervalSeconds)s",
                                value: $draft.cameraIntervalSeconds, in: 3...120)
                    }
                }
                Section("Location & Background") {
                    Toggle("Include my location", isOn: $draft.locationEnabled)
                    Toggle("Keep logging in background (worn use)", isOn: $draft.backgroundEnabled)
                        .disabled(!draft.locationEnabled)
                }
                Section("Diagnostics & Storage") {
                    LabeledContent("Queued Uploads", value: "\(model.uploadQueue.pendingCount) items (\(model.uploadQueue.totalDiskBytes / 1024) KB)")
                    Button {
                        showDiagnostics = true
                    } label: {
                        HStack {
                            Image(systemName: "stethoscope")
                            Text("Open Live Diagnostics Console")
                        }
                    }
                    if model.uploadQueue.pendingCount > 0 {
                        Button {
                            model.uploadQueue.retryNow()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry Queued Items Now")
                            }
                        }
                    }
                }
                Section {
                    Button("Delete all my data from server", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } footer: {
                    if deleteSuccess {
                        Text("✓ All your data has been deleted from the server.")
                            .foregroundColor(.green)
                    }
                    if let err = deleteError {
                        Text("Delete failed: \(err)")
                            .foregroundColor(.red)
                    }
                }
                Section {
                    Button("Revoke consent & stop", role: .destructive) {
                        model.revokeConsent()
                        dismiss()
                    }
                } footer: {
                    Text("Revoking consent stops any active session and returns you to the consent screen.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.settings = draft
                        model.persistSettings()
                        dismiss()
                    }.disabled(model.isMonitoring)
                }
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
            }
            .onAppear { draft = model.settings }
            .alert("Delete all data?", isPresented: $showDeleteConfirm) {
                Button("Delete Everything", role: .destructive) {
                    Task {
                        do {
                            try await model.deleteDeviceData()
                            deleteSuccess = true
                            deleteError = nil
                        } catch {
                            deleteError = error.localizedDescription
                            deleteSuccess = false
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all stored audio, photos, and telemetry for this device from the server. This cannot be undone.")
            }
        }
    }
}
