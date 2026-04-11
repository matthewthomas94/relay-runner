import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    @Environment(\.openSettings) private var openSettings

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

        Button("Settings\u{2026}") {
            openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                // Bring settings window to front (skip overlay panels which ignore mouse)
                for window in NSApp.windows where window.isVisible && !window.ignoresMouseEvents {
                    window.orderFrontRegardless()
                }
            }
        }
        .keyboardShortcut(",")

        Button("Quit Voice Terminal") {
            appState.stopServices()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
