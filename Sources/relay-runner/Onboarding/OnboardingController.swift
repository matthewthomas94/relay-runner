import AppKit
import Foundation
import SwiftUI

/// Owns the onboarding NSWindow and the first-launch flag file.
///
/// Lifecycle:
///  * First launch ever → full walkthrough (welcome → agent choice → setup → ready).
///  * Subsequent launches with all required setup complete and an agent choice
///    recorded → nothing shows…
///    *unless* the user has never started a session yet, in which case
///    the simplified flow lands on Ready ("All Set") so they pick a
///    working directory before their first session.
///  * Subsequent launches with missing required setup → simplified flow
///    that starts at the first missing step.
///  * Relaunch after the app was killed mid-flow → simplified flow.
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
    /// Current primary agent provider and mutation hook. First-launch
    /// onboarding asks for this before login/permission guidance so Codex and
    /// Claude users get the right path.
    private let getAgentProvider: () -> GeneralConfig.AgentProvider
    private let setAgentProvider: (GeneralConfig.AgentProvider) -> Void
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
    /// If the process exits before `finish()` runs, `.onboarded` never gets
    /// written and the next launch would otherwise repeat the whole welcome
    /// flow. Looking at this flag lets `showIfNeeded()` resume into the
    /// simplified flow, which lands directly on Ready ("All Set") when setup
    /// is complete.
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

    /// Written once the user explicitly confirms Codex or Claude as the
    /// primary agent. This is separate from `.onboarded` so users who completed
    /// the older permission-only flow still see the new provider-choice step
    /// exactly once after upgrading.
    private static let agentChoiceFlagURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("relay-runner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        return support.appendingPathComponent(".agent-choice-v1")
    }()

    init(permissions: PermissionsManager,
         setupStatus: @escaping () -> String? = { nil },
         getWorkingDirectory: @escaping () -> String = { "" },
         getAgentProvider: @escaping () -> GeneralConfig.AgentProvider = { .codex },
         setAgentProvider: @escaping (GeneralConfig.AgentProvider) -> Void = { _ in },
         setWorkingDirectory: @escaping (String) -> Void = { _ in },
         startSession: @escaping () -> Void = {}) {
        self.permissions = permissions
        self.setupStatus = setupStatus
        self.getWorkingDirectory = getWorkingDirectory
        self.getAgentProvider = getAgentProvider
        self.setAgentProvider = setAgentProvider
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

    /// True iff the user has explicitly confirmed the primary coding agent in
    /// the versioned onboarding flow.
    var hasChosenAgent: Bool {
        FileManager.default.fileExists(atPath: Self.agentChoiceFlagURL.path)
    }

    /// Mark a session as having been run. Idempotent — safe to call from
    /// both `AppState.newSession()` and the bridge watchdog when an
    /// externally-started relay-bridge is detected.
    func markSessionRun() {
        try? Data().write(to: Self.sessionRunFlagURL)
    }

    private func markAgentChoiceComplete() {
        try? Data().write(to: Self.agentChoiceFlagURL)
    }

    /// True iff onboarding was opened previously but never reached `finish()`.
    /// Indicates a kill-mid-flow before the user reached the final step.
    private var wasInterrupted: Bool {
        !hasOnboarded && FileManager.default.fileExists(atPath: Self.startedFlagURL.path)
    }

    /// Show the onboarding window if it's needed — first launch, kill-
    /// mid-flow recovery, required setup missing on a later launch, no
    /// recorded agent choice after upgrade, or
    /// a returning user who hasn't started their first session yet.
    ///
    /// The simplified flow is used in three cases:
    ///   * `hasOnboarded` and required setup is missing or the agent-choice
    ///     flag is absent — focused setup prompt, no need to show
    ///     welcome/explanations again.
    ///   * `hasOnboarded` and `!hasRunSession` — the user got through
    ///     setup but never ran a session, so we land them on Ready
    ///     so they pick a working directory before their first run.
    ///   * `wasInterrupted` — the user already saw the welcome flow,
    ///     the app exited mid-way, and on relaunch they should resume into a
    ///     focused flow that lands on Ready immediately when setup is complete.
    func showIfNeeded() {
        if hasOnboarded {
            if !hasChosenAgent || !permissions.allGranted || !hasRunSession {
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

        // Mark "started" before the window is even constructed, so any
        // mid-flow exit leaves enough state for the next launch to resume
        // into the simplified flow rather than the full walkthrough.
        try? Data().write(to: Self.startedFlagURL)

        let view = OnboardingView(
            permissions: permissions,
            simplified: simplified,
            setupStatus: setupStatus,
            initialWorkingDirectory: getWorkingDirectory(),
            initialAgentProvider: getAgentProvider(),
            requiresAgentChoice: !hasChosenAgent,
            onSetAgentProvider: { [weak self] provider in
                self?.setAgentProvider(provider)
                self?.markAgentChoiceComplete()
            },
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
        // Started flag is no longer meaningful once onboarding has completed.
        // Clear it so a future focused setup prompt doesn't get treated as a
        // resumed mid-flow exit.
        try? FileManager.default.removeItem(at: Self.startedFlagURL)
        windowController?.close()
        windowController = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
