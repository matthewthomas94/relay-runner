import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState

    private var statusLabel: String {
        if appState.hasActiveSession {
            return "\u{25CF} Session Active"
        } else {
            return "\u{25CB} \(appState.statusText)"
        }
    }

    var body: some View {
        Text(statusLabel)

        // Setup progress / error — shown while STT is still warming up, or
        // when it failed to start. Presented as plain items (not buttons) so
        // the user can see the raw status without it feeling nag-like.
        let setupReadiness = appState.setupRuntimeReadiness
        if case .preparing(let status) = setupReadiness {
            Divider()
            Text("Setup: \(status)")
        }
        if let serviceStatus = MenuBarServiceLifecycleStatus(appState.serviceLifecycleMessage) {
            Divider()
            Button(serviceStatus.label) {
                appState.showServiceLifecycleDetail(serviceStatus.detail)
            }
            .help(serviceStatus.detail)
        }
        if case .failed(let message) = setupReadiness {
            Divider()
            Text("\u{26A0} \(message)")
            if let action = appState.sttEngineErrorTranslation?.action {
                Text(action)
            }
            Button("Retry Setup") { appState.retrySTTSetup() }
        }

        // Permission warnings surface here as plain menu items with a "Fix"
        // button. Kept above the session controls so the user notices before
        // they try to start a session that won't work.
        if !appState.permissions.missing.isEmpty {
            Divider()
            ForEach(appState.permissions.missing) { kind in
                Button("\u{26A0} Fix \(kind.displayName) permission") {
                    if kind == .microphone {
                        appState.permissions.requestMicrophonePrompt { _ in }
                    } else {
                        appState.permissions.openSettings(for: kind)
                    }
                }
            }
            Button("Re-run Setup Walkthrough\u{2026}") {
                appState.onboarding.showManualRedo()
            }
        }

        Divider()

        if appState.hasActiveSession {
            Button("End Session") { appState.endSession() }
        } else {
            Button("Start Session\u{2026}") { appState.newSession() }
        }

        Divider()

        Button("Record") { appState.toggleRecording() }
        Button("Replay") { appState.ttsCommand("replay") }

        Divider()

        Button("Show Workspace") { appState.toggleWorkspace() }
        Button("Show Status") { appState.showProgramStatus() }

        Button("Workspace Settings\u{2026}") { appState.showWorkspaceSettings() }
        .keyboardShortcut(",")

        Button("Check for Updates\u{2026}") {
            appState.checkForUpdates()
        }

        Button("Quit Relay Runner") {
            appState.stopServices()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
