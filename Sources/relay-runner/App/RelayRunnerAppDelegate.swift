import AppKit

final class RelayRunnerAppDelegate: NSObject, NSApplicationDelegate {
    var handlesDockReopenWithSettings = true

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard handlesDockReopenWithSettings else { return true }
        guard sender.activationPolicy() == .regular else { return true }

        SettingsPresenter.open()
        return false
    }
}
