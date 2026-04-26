import AppKit
import Foundation
import SwiftUI

/// Owns the onboarding NSWindow and the first-launch flag file.
///
/// Lifecycle:
///  * First launch ever → full walkthrough (welcome → each permission → ready).
///  * Subsequent launches with all permissions granted → nothing shows…
///    *unless* the user has never started a session yet, in which case
///    the simplified flow lands on Ready ("All Set") so they pick a
///    working directory before their first session.
///  * Subsequent launches with a missing permission → simplified flow
///    that starts at the first missing step.
///  * Relaunch after macOS killed the app mid-flow (Accessibility /
///    Input Monitoring grants do this) → simplified flow.
///
/// All methods must be called from the main thread — the class uses AppKit
/// APIs (NSWindow, NSWorkspace, NSApp) that require main-thread access.
final class OnboardingController {

    private var windowController: NSWindowController?
    private let permissions: PermissionsManager
    /// Closure the Ready step calls to render live setup progress
    /// (e.g. "Loading speech model…") — nil means "finished".
    private let setupStatus: () -> String?
    /// Closure that returns the current configured working directory
    /// (empty string = "use the user's home folder"). Read at the moment
    /// the window opens so the Ready-step picker can preload the
    /// previously-chosen value.
    private let getWorkingDirectory: () -> String
    /// Closure that persists the user's chosen working directory back
    /// into AppConfig + ConfigManager. Called from the Ready step's Done
    /// button so a fresh path applies to the next voice session.
    private let setWorkingDirectory: (String) -> Void
    /// Starts a new voice session (wired to `AppState.newSession`).
    /// The Ready step's "Start Session" CTA hands off to this so the
    /// user can launch their first session without a detour back to
    /// the menu bar.
    private let startSession: () -> Void

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

    /// Written the first time the user actually runs a voice session
    /// (either via the menu's Start Session, or by `/relay-bridge` from
    /// a Claude Code session). Until this exists, every launch re-shows
    /// the simplified onboarding so the user lands on the All Set screen
    /// and explicitly picks a working directory before kicking off.
    private static let sessionRunFlagURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("relay-runner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        return support.appendingPathComponent(".session-run")
    }()

    init(permissions: PermissionsManager,
         setupStatus: @escaping () -> String? = { nil },
         getWorkingDirectory: @escaping () -> String = { "" },
         setWorkingDirectory: @escaping (String) -> Void = { _ in },
         startSession: @escaping () -> Void = {}) {
        self.permissions = permissions
        self.setupStatus = setupStatus
        self.getWorkingDirectory = getWorkingDirectory
        self.setWorkingDirectory = setWorkingDirectory
        self.startSession = startSession
    }

    /// True iff the user has completed (or skipped past) onboarding before.
    var hasOnboarded: Bool {
        FileManager.default.fileExists(atPath: Self.flagURL.path)
    }

    /// True iff the user has started at least one voice session (direct
    /// or via `/relay-bridge`). Drives the "always re-show All Set until
    /// they've started" rule — see `showIfNeeded`.
    var hasRunSession: Bool {
        FileManager.default.fileExists(atPath: Self.sessionRunFlagURL.path)
    }

    /// Mark a session as having been run. Idempotent — safe to call from
    /// both `AppState.newSession()` and the bridge watchdog when an
    /// externally-started relay-bridge is detected.
    func markSessionRun() {
        try? Data().write(to: Self.sessionRunFlagURL)
    }

    /// True iff onboarding was opened previously but never reached `finish()`.
    /// Indicates a kill-mid-flow (most often after a permission grant
    /// triggered macOS to terminate the app).
    private var wasInterrupted: Bool {
        !hasOnboarded && FileManager.default.fileExists(atPath: Self.startedFlagURL.path)
    }

    /// Show the onboarding window if it's needed — first launch, kill-
    /// mid-flow recovery, a permission missing on a later launch, or
    /// a returning user who hasn't started their first session yet.
    ///
    /// The simplified flow is used in three cases:
    ///   * `hasOnboarded` and a permission is missing — focused
    ///     re-prompt, no need to show welcome/explanations again.
    ///   * `hasOnboarded` and `!hasRunSession` — the user got through
    ///     setup but never ran a session, so we land them on Ready
    ///     so they pick a working directory before their first run.
    ///   * `wasInterrupted` — the user already saw the welcome flow,
    ///     macOS killed the app mid-way (typically after granting
    ///     Accessibility or Input Monitoring), and on relaunch they
    ///     should resume into a focused flow that lands on Ready
    ///     immediately when every permission is now granted.
    func showIfNeeded() {
        if hasOnboarded {
            if !permissions.allGranted || !hasRunSession {
                show(simplified: true)
            }
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
            initialWorkingDirectory: getWorkingDirectory(),
            onSetWorkingDirectory: { [weak self] path in self?.setWorkingDirectory(path) },
            onStartSession: { [weak self] in self?.startSession() },
            onFinish: { [weak self] in self?.finish() }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Relay Runner"
        window.styleMask = [.titled, .closable]
        // Tall enough to fit the Ready step's full content (path
        // picker + two start-method rows + footer buttons) without
        // pushing the footer off-screen. Earlier 520pt builds clipped
        // the Dismiss / Start Session buttons.
        window.setContentSize(NSSize(width: 560, height: 640))
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
