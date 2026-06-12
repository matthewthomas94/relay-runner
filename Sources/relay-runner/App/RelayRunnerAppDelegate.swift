import AppKit

final class RelayRunnerAppDelegate: NSObject, NSApplicationDelegate {
    var handlesDockReopenWithSettings = true
    var settingsOpener: () -> Void = {
        SettingsPresenter.open()
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
