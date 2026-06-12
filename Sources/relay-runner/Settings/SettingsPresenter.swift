import AppKit

enum SettingsPresenter {
    static func open(openSettings: (() -> Void)? = nil) {
        if let openSettings {
            openSettings()
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            activateAndFrontVisibleWindows()
        }
    }

    private static func activateAndFrontVisibleWindows() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible && !window.ignoresMouseEvents {
            window.orderFrontRegardless()
        }
    }
}
