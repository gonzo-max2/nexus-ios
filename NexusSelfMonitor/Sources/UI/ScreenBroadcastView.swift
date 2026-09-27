import SwiftUI
import ReplayKit

struct ScreenBroadcastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Live screen preview", systemImage: "iphone.radiowaves.left.and.right")
                .font(.headline)
            Text("Share this iPhone’s screen with your household dashboard, including other apps. Everyone using this phone should know when sharing is on.")
                .font(.footnote)
            if model.screenSharingEnabled {
                HStack {
                    BroadcastPicker()
                        .frame(width: 50, height: 50)
                        .accessibilityLabel("Open iOS screen broadcast controls")
                    Text("Tap the broadcast button, then Start Broadcast. iOS shows its recording indicator while sharing.")
                        .font(.footnote)
                }
                Button("Disable screen sharing", role: .destructive) { model.disableScreenSharing() }
            } else {
                Button("Enable screen sharing") { model.enableScreenSharing() }
            }
            Text("Live preview: up to 2 frames/sec. Start each new broadcast on this iPhone. Protected content may be blank; locking the phone or an interruption may end sharing.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .cornerRadius(12)
    }
}

private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        picker.preferredExtension = Bundle.main.object(forInfoDictionaryKey: "NexusBroadcastExtension") as? String
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
