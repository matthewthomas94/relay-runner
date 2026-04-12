import SwiftUI

@main
struct RelayRunnerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Relay Runner", systemImage: "waveform") {
            MenuBarView(appState: appState)
        }

        Settings {
            SettingsWindow(appState: appState)
        }
    }
}
