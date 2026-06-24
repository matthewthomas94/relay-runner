import Foundation

enum RelayRunnerResources {
    static let bundle: Bundle = {
        // When running from a .app bundle, resources live at Contents/Resources/.
        // SPM's default Bundle.module looks next to the executable, which doesn't
        // match the macOS .app layout, so fall through to that only in dev builds.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("relay-runner_relay-runner.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
