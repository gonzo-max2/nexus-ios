import SwiftUI

/// First-run consent gate. The app cannot record until this is accepted, and it
/// can be revoked at any time from Settings. This screen is the ethical core of
/// the app: it makes the monitoring explicit and opt-in.
struct ConsentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Self-Monitor")
                    .font(.largeTitle.bold())
                Text("This app records **your own** audio and location and streams them to **your own** dashboard. Please read before continuing.")
                    .font(.headline)

                Group {
                    bullet("It records only while you have a session running, and shows a red “● RECORDING” banner the whole time.")
                    bullet("iOS additionally shows its orange microphone dot whenever the mic is live — including in the background. Recording can never be silent.")
                    bullet("You are responsible for informing people around you and for following the laws where you are. Recording others without the consent they’re entitled to may be illegal.")
                    bullet("You can stop instantly, and delete everything stored for this device from the dashboard or Settings.")
                    bullet("Optional screen sharing shows other apps on your dashboard. It starts only through the iPhone’s visible Start Broadcast control and can be stopped with the iOS recording indicator.")
                    bullet("There is no hidden mode or automatic recording on launch. Stop monitoring in the app; stop screen sharing using the iOS recording indicator or Disable screen sharing.")
                }

                Toggle("I understand and consent to recording my own audio and location.",
                       isOn: $accepted)
                    .padding(.top, 4)

                Button {
                    model.grantConsent()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(accepted ? Color.accentColor : Color.gray.opacity(0.4))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(!accepted)
            }
            .padding()
        }
    }

    @State private var accepted = false

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundColor(.accentColor)
            Text(text)
        }
    }
}
