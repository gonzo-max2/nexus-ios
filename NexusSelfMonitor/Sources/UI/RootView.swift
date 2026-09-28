import SwiftUI

/// Routes between the one-time consent gate and the main monitor screen.
struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.settings.isStealthModeActive {
            StealthView()
        } else if model.hasConsented {
            MonitorView(audio: model.audio)
        } else {
            ConsentView()
        }
    }
}
