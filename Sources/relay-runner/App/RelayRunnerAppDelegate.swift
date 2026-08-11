import AppKit

final class RelayRunnerAppDelegate: NSObject, NSApplicationDelegate {
    var handlesDockReopenWithSettings = true
    var settingsOpener: () -> Void = {
        SettingsPresenter.open()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        RelayMetricKitSubscriber.shared.start()
        RelayDiagnostics.shared.record(
            process: "app",
            phase: "app_launch",
            outcome: "ready"
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        RelayDiagnostics.shared.record(
            process: "app",
            phase: "app_launch",
            outcome: "stopped"
        )
        RelayMetricKitSubscriber.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return handleDockReopen(activationPolicy: sender.activationPolicy())
    }

    func handleDockReopen(activationPolicy: NSApplication.ActivationPolicy) -> Bool {
        guard handlesDockReopenWithSettings else { return true }
        guard activationPolicy == .regular else { return true }

        settingsOpener()
        return false
    }
}
