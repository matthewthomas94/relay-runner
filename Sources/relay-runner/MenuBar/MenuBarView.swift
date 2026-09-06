import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState

    var body: some View {
        // Setup progress / error — shown while STT is still warming up, or
        // when it failed to start. Presented as plain items (not buttons) so
        // the user can see the raw status without it feeling nag-like.
        let setupReadiness = appState.setupRuntimeReadiness
        if case .preparing(let status) = setupReadiness {
            Text("Setup: \(status)")
            Divider()
        }
        if let serviceStatus = MenuBarServiceLifecycleStatus(appState.serviceLifecycleMessage) {
            Button(serviceStatus.label) {
                appState.showServiceLifecycleDetail(serviceStatus.detail)
            }
            .help(serviceStatus.detail)
            Divider()
        }
        if case .failed(let message) = setupReadiness {
            Text("\u{26A0} \(message)")
            if let action = appState.sttEngineErrorTranslation?.action {
                Text(action)
            }
            Button("Retry Setup") { appState.retrySTTSetup() }
                .disabled(appState.isFirstRunExperienceActive)
            Divider()
        }

        // Permission warnings surface here as plain menu items with a "Fix"
        // button. Kept above the workspace controls so the user notices them.
        if !appState.permissions.missing.isEmpty {
            ForEach(appState.permissions.missing) { kind in
                Button("\u{26A0} Fix \(kind.displayName) permission") {
                    if kind == .microphone {
                        appState.permissions.requestMicrophonePrompt { _ in }
                    } else {
                        appState.permissions.openSettings(for: kind)
                    }
                }
                .disabled(appState.isFirstRunExperienceActive)
            }
            Button("Re-run Setup Walkthrough\u{2026}") {
                appState.onboarding.showManualRedo()
            }
            .disabled(appState.isFirstRunExperienceActive)
            Divider()
        }

        if appState.hasActiveSession {
            Button("End Session") { appState.endSession() }
                .disabled(appState.isFirstRunExperienceActive)
            Divider()
        }

        Button("Show Workspace") { appState.toggleWorkspace() }
            .disabled(appState.isFirstRunExperienceActive)
        Button("Show Status") { appState.showProgramStatus() }
            .disabled(appState.isFirstRunExperienceActive)

        Button("Workspace Settings") { appState.showWorkspaceSettings() }
            .keyboardShortcut(",")
            .disabled(appState.isFirstRunExperienceActive)

        Button("Check for Updates") {
            appState.checkForUpdates()
        }
        .disabled(appState.isFirstRunExperienceActive)

        Button("Quit Relay Runner") {
            appState.stopServices()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
