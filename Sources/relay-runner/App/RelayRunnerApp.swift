import SwiftUI

private let resourceBundle: Bundle = {
    // When running from a .app bundle, resources live at Contents/Resources/.
    // SPM's default Bundle.module looks next to the executable, which doesn't
    // match the macOS .app layout — fall through to that only in dev builds.
    if let url = Bundle.main.resourceURL?.appendingPathComponent("relay-runner_relay-runner.bundle"),
       let bundle = Bundle(url: url) {
        return bundle
    }
    return .module
}()

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
    @State private var appState: AppState?

    init() {
        _ = _installSIGPIPEHandler
        let context = RelayInstallerContext.current()
        _appState = State(initialValue: context == nil ? AppState() : nil)

        if let context {
            NSApp.setActivationPolicy(.regular)
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
                Button("Quit") { NSApp.terminate(nil) }
            }
        } label: {
            if let appState {
                // Red dot badge signals a missing permission — per PRD this is a
                // passive indicator, not a nag. The menu dropdown has the "Fix"
                // actions; this just makes the user notice something's wrong.
                Image(appState.hasActiveSession ? "TrayIconActive" : "TrayIcon", bundle: resourceBundle)
                    .renderingMode(.original)
                    .overlay(alignment: .topTrailing) {
                        if !appState.permissions.allGranted {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -2)
                        }
                    }
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
