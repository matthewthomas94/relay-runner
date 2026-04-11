import SwiftUI

@main
struct VoiceTerminalApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Voice Terminal", systemImage: "waveform") {
            MenuBarView(appState: appState)
        }

        Settings {
            SettingsWindow(appState: appState)
        }
    }
}
