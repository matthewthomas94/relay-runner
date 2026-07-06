import AppKit
import SwiftUI

/// Ignore SIGPIPE process-wide. Any write to a closed socket or FIFO will
/// surface as an EPIPE return value at the call site, which we already
/// check — without this, the kernel kills the whole process the moment a
/// peer (voice_bridge.py, relay-actions-mcp, or an MCP propose_action
/// client) goes away mid-write. Must run before any I/O is set up.
private let _installSIGPIPEHandler: Void = {
    signal(SIGPIPE, SIG_IGN)
}()

@main
struct RelayRunnerApp: App {
    @NSApplicationDelegateAdaptor(RelayRunnerAppDelegate.self) private var appDelegate
    @State private var appState: AppState?
    @State private var updaterController: RelayUpdaterController?

    init() {
        _ = _installSIGPIPEHandler
        let context = RelayInstallerContext.current()
        appDelegate.handlesDockReopenWithSettings = context == nil
        let updaterController = context == nil
            ? RelayUpdaterController(installerContext: context)
            : nil
        _updaterController = State(initialValue: updaterController)
        _appState = State(initialValue: context == nil ? AppState(
            checkForUpdates: { [weak updaterController] in
                updaterController?.checkForUpdates()
            }
        ) : nil)

        if let context {
            DispatchQueue.main.async {
                RelayInstallerWindowController.shared.show(context: context)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let appState {
                MenuBarView(appState: appState)
            } else {
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        } label: {
            if let appState {
                // Red dot badge signals a missing permission — per PRD this is a
                // passive indicator, not a nag. The menu dropdown has the "Fix"
                // actions; this just makes the user notice something's wrong.
                    Image(appState.hasActiveSession ? "TrayIconActive" : "TrayIcon", bundle: RelayRunnerResources.bundle)
                        .renderingMode(.original)
                        .overlay(alignment: .topTrailing) {
                            if !appState.permissions.allGranted {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -2)
                        }
                    }
                    .background(SettingsOpenerRegistrationView(appState: appState))
            } else {
                EmptyView()
            }
        }

        Settings {
            if let appState {
                SettingsWindow(appState: appState)
            } else {
                EmptyView()
            }
        }
    }
}

private struct SettingsOpenerRegistrationView: View {
    @Bindable var appState: AppState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                SettingsPresenter.register {
                    appState.showWorkspaceSettings()
                }
            }
    }
}
