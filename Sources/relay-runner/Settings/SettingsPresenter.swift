import AppKit

enum SettingsPresenter {
    private static var registeredOpenSettings: (() -> Void)?

    static func register(openSettings: (() -> Void)?) {
        registeredOpenSettings = openSettings
    }

    static func open(openSettings: (() -> Void)? = nil) {
        open(
            openSettings: openSettings,
            sendAction: { selector in
                NSApp.sendAction(selector, to: nil, from: nil)
            },
            activateWindows: activateAndFrontVisibleWindows,
            scheduleActivation: { activation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: activation)
            }
        )
    }

    static func open(
        openSettings: (() -> Void)? = nil,
        sendAction: (Selector) -> Bool,
        activateWindows: @escaping () -> Void,
        scheduleActivation: (@escaping () -> Void) -> Void
    ) {
        if let openSettings {
            openSettings()
        } else if let registeredOpenSettings {
            registeredOpenSettings()
        } else if !sendAction(Selector(("showSettingsWindow:"))) {
            _ = sendAction(Selector(("showPreferencesWindow:")))
        }

        scheduleActivation {
            activateWindows()
        }
    }

    private static func activateAndFrontVisibleWindows() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.isVisible && !window.ignoresMouseEvents {
            window.orderFrontRegardless()
        }
    }
}
