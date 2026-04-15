import SwiftUI

@main
struct RelayRunnerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: appState.hasActiveSession ? "waveform.circle.fill" : "waveform")
        }

        Settings {
            SettingsWindow(appState: appState)
        }
    }
}
