import AppKit
import Foundation
import SwiftUI

/// Owns the onboarding NSWindow and the first-launch flag file.
///
/// Lifecycle:
///  * First launch ever → full walkthrough (welcome → each permission → ready).
///  * Subsequent launches with all permissions granted → nothing shows.
///  * Subsequent launches with a missing permission → a simplified flow
///    that starts at the first missing step (no welcome/ready screens).
///
/// All methods must be called from the main thread — the class uses AppKit
/// APIs (NSWindow, NSWorkspace, NSApp) that require main-thread access.
final class OnboardingController {

    private var windowController: NSWindowController?
    private let permissions: PermissionsManager
    /// Closure the Ready step calls to render live setup progress
    /// (e.g. "Loading speech model…") — nil means "finished".
    private let setupStatus: () -> String?

    /// Persists across launches — a zero-byte sentinel next to the config file.
    private static let flagURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("relay-runner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        return support.appendingPathComponent(".onboarded")
    }()

    init(permissions: PermissionsManager,
         setupStatus: @escaping () -> String? = { nil }) {
        self.permissions = permissions
        self.setupStatus = setupStatus
    }

    /// True iff the user has completed (or skipped past) onboarding before.
    var hasOnboarded: Bool {
        FileManager.default.fileExists(atPath: Self.flagURL.path)
    }

    /// Show the onboarding window if it's needed — either on first launch,
    /// or when a required permission is missing on a later launch.
    func showIfNeeded() {
        guard !hasOnboarded || !permissions.allGranted else { return }
        show(simplified: hasOnboarded)
    }

    /// Force-show the onboarding window (e.g. from a menu item). Always
    /// shows the full flow so the user can re-read the explanations.
    func showAlways() {
        show(simplified: false)
    }

    private func show(simplified: Bool) {
        if let wc = windowController, let window = wc.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(
            permissions: permissions,
            simplified: simplified,
            setupStatus: setupStatus,
            onFinish: { [weak self] in self?.finish() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Relay Runner"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 440))
        window.center()
        window.isReleasedWhenClosed = false

        // Menu-bar apps default to .accessory. Temporarily elevate so the
        // onboarding window takes focus and can be reached via Cmd-Tab; drop
        // back to .accessory when the user dismisses the window.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let wc = NSWindowController(window: window)
        windowController = wc
        wc.showWindow(nil)
    }

    /// Mark the flag file and close the window. Called when the user
    /// completes or skips past the final step.
    private func finish() {
        try? Data().write(to: Self.flagURL)
        windowController?.close()
        windowController = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
