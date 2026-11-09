import AppKit

/// RR-472: Command-T and Command-W on the Workspace Terminal tab. Routing is
/// pure so the rules are testable; the board overlay's key monitor applies it
/// before SwiftTerm sees the key, so neither shortcut reaches the PTY.
enum PMTabShortcut: Equatable {
    case open, close

    enum Action: Equatable {
        /// Not ours: the key behaves as it does today.
        case passThrough
        /// Same path as "+"; at the nine-tab limit that path shows the limit message.
        case openTab
        case closeTab
        /// Closing the last live tab ends the session, so ask first.
        case confirmEndSession
    }

    /// Plain Command-T / Command-W only.
    init?(event: NSEvent) {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              !event.isARepeat else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t": self = .open
        case "w": self = .close
        default: return nil
        }
    }

    static func route(
        _ shortcut: PMTabShortcut,
        terminalTabShowing: Bool,
        sessionRunning: Bool,
        liveTabCount: Int
    ) -> Action {
        guard terminalTabShowing, sessionRunning else { return .passThrough }
        switch shortcut {
        case .open: return .openTab
        case .close: return liveTabCount <= 1 ? .confirmEndSession : .closeTab
        }
    }
}

extension AppState {
    /// Apply a routed shortcut; true when the key was consumed.
    @MainActor
    func performPMTabShortcut(_ shortcut: PMTabShortcut, terminalTabShowing: Bool) -> Bool {
        let action = PMTabShortcut.route(
            shortcut,
            terminalTabShowing: terminalTabShowing,
            sessionRunning: sessionRegistry.hasLiveSessions,
            liveTabCount: sessionRegistry.liveContextIDs.count
        )
        switch action {
        case .passThrough:
            return false
        case .openTab:
            openPMTab()
        case .closeTab:
            removePMTab(activeContext.id)
        case .confirmEndSession:
            // Not inside the key monitor: a modal alert needs a clean event turn.
            DispatchQueue.main.async { [weak self] in
                let alert = NSAlert()
                alert.messageText = "End the session?"
                alert.informativeText = "Closing the last tab ends the session."
                alert.addButton(withTitle: "End Session")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn, let self {
                    self.removePMTab(self.activeContext.id)
                }
            }
        }
        return true
    }
}
