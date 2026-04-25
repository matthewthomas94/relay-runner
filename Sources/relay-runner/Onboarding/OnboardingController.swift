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
///  * Relaunch after macOS killed the app mid-flow (Accessibility /
///    Input Monitoring grants do this) → simplified flow, which lands
///    directly on Ready ("All Set") if every permission is now granted.
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

    /// Set the moment the onboarding window first opens; cleared by `finish()`.
    /// The point is to detect a kill-mid-flow on relaunch.
    ///
    /// Granting Accessibility or Input Monitoring in System Settings
    /// commonly causes macOS to terminate the running app so the new
    /// permission can take effect on next launch — which means
    /// `finish()` never runs, `.onboarded` never gets written, and the
    /// next launch repeats the full welcome → permissions → ready
    /// walkthrough even though the user is now done. Looking at this
    /// flag lets `showIfNeeded()` resume into the simplified flow,
    /// which lands directly on Ready ("All Set") when every permission
    /// is now granted.
    private static let startedFlagURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("relay-runner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        return support.appendingPathComponent(".onboarding-started")
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

    /// True iff onboarding was opened previously but never reached `finish()`.
    /// Indicates a kill-mid-flow (most often after a permission grant
    /// triggered macOS to terminate the app).
    private var wasInterrupted: Bool {
        !hasOnboarded && FileManager.default.fileExists(atPath: Self.startedFlagURL.path)
    }

    /// Show the onboarding window if it's needed — first launch, kill-
    /// mid-flow recovery, or a permission missing on a later launch.
    ///
    /// The simplified flow is used in two cases:
    ///   * `hasOnboarded` and a permission is now missing — focused
    ///     re-prompt, no need to show welcome/explanations again.
    ///   * `wasInterrupted` — the user already saw the welcome flow,
    ///     macOS killed the app mid-way (typically after granting
    ///     Accessibility or Input Monitoring), and on relaunch they
    ///     should resume into a focused flow that lands on Ready
    ///     immediately when every permission is now granted.
    func showIfNeeded() {
        if hasOnboarded {
            guard !permissions.allGranted else { return }
            show(simplified: true)
        } else if wasInterrupted {
            show(simplified: true)
        } else {
            show(simplified: false)
        }
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

        // Mark "started" before the window is even constructed, so a
        // macOS-induced kill at any later point in the flow leaves
        // behind enough state for the next launch to resume into the
        // simplified flow rather than the full walkthrough.
        try? Data().write(to: Self.startedFlagURL)

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
        // Started flag is no longer meaningful once onboarding has
        // completed — clear it so a future re-prompt (e.g. user
        // revoked a permission later) doesn't get treated as a
        // resumed kill-mid-flow.
        try? FileManager.default.removeItem(at: Self.startedFlagURL)
        windowController?.close()
        windowController = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
