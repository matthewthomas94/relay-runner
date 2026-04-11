import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState

    var body: some View {
        Text(appState.statusText)

        Divider()

        Button("Play / Pause") { appState.ttsCommand("toggle") }
            .keyboardShortcut("p")
        Button("Replay") { appState.ttsCommand("replay") }
        Button("Skip") { appState.ttsCommand("skip") }

        Divider()

        Button("New Session\u{2026}") { appState.newSession() }

        if appState.isRunning {
            Button("Stop") { appState.stopServices() }
        }

        Divider()

        SettingsLink {
            Text("Settings\u{2026}")
        }

        Button("Quit Voice Terminal") {
            appState.stopServices()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
