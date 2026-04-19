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

@main
struct RelayRunnerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(appState.hasActiveSession ? "TrayIconActive" : "TrayIcon", bundle: resourceBundle)
                .renderingMode(.original)
        }

        Settings {
            SettingsWindow(appState: appState)
        }
    }
}
