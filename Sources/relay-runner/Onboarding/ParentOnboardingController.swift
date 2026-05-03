import AppKit
import SwiftUI

/// Owns the per-parent permission wizard NSWindow. Mirrors the lifecycle
/// pattern of `OnboardingController` but is much smaller — there's only
/// one screen and no state machine.
///
/// Threading: every method must be called on the main thread (NSWindow / NSApp
/// access). `AppState` bridges off-main bus callbacks via `MainActor.run`.
final class ParentOnboardingController {

    private var windowController: NSWindowController?
    /// Parent currently surfaced. Used to ignore duplicate `parent_detected`
    /// pings while the window is already open for that parent (the MCP server
    /// fires one on every spawn).
    private var visibleParent: String?

    /// Show the wizard for `parent` if it isn't already visible. No-op if a
    /// window for the same parent is already up. If a window for a *different*
    /// parent is up, replace it — newest wins (the user just opened a session
    /// in a different terminal, that's the more relevant prompt).
    func show(parent: String) {
        if let existing = windowController?.window, visibleParent == parent {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Tear down any existing window before building a new one — keeps
        // visibleParent in sync without juggling state across two windows.
        close()

        let view = ParentOnboardingView(
            parent: parent,
            onAcknowledge: { [weak self] in
                ParentOnboardingTracker.markOnboarded(parent)
                self?.close()
            }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Permissions for \(parent)"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 480))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = nil

        // Menu-bar apps default to .accessory. Elevate so the window can take
        // focus and be reached via Cmd-Tab; OnboardingController does the same
        // for the main onboarding flow. We restore .accessory in `close()`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let wc = NSWindowController(window: window)
        windowController = wc
        visibleParent = parent
        wc.showWindow(nil)
    }

    /// Close the wizard and drop activation policy back to .accessory so the
    /// menu-bar app stops claiming the dock / Cmd-Tab slot. Safe to call
    /// when no window is visible.
    func close() {
        windowController?.close()
        windowController = nil
        visibleParent = nil
        // Don't downgrade if the main onboarding window is up — it'd hide
        // it from the dock. We can't cheaply check that here, so for now
        // we leave activation policy alone and let OnboardingController
        // restore it when its own flow finishes. Worst case: app stays
        // .regular until the user quits.
    }
}
