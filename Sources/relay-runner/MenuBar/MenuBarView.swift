import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Start Session\u{2026}") { appState.newSession() }

        if appState.isRunning {
            Button("Stop Session") { appState.stopServices() }
        }

        Divider()

        if appState.isRunning {
            Button("Record") { appState.toggleRecording() }
            Button("Replay") { appState.ttsCommand("replay") }
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

        Button("Quit Relay Runner") {
            appState.stopServices()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
