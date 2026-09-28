import SwiftUI
import UIKit

/// Stealth view that renders a pure black, blank screen.
/// When the app is opened in stealth mode, no UI or monitoring dashboard is displayed.
/// Tapping the screen or waiting a brief moment automatically suspends the app to the background.
struct StealthView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.suspendToBackground()
        }
        .onAppear {
            model.reconcile(.viewAppeared)
            model.suspendToBackground(afterDelaySeconds: 1.0)
        }
        .statusBarHidden(true)
    }
}
