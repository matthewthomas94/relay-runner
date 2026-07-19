import AppKit
import Foundation
import QuartzCore
import SwiftUI

struct OnboardingFlagURLs {
    let onboarded: URL
    let started: URL
    let sessionRun: URL
    let agentChoice: URL

    static var live: OnboardingFlagURLs {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("relay-runner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        return OnboardingFlagURLs(
            onboarded: support.appendingPathComponent(".onboarded"),
            started: support.appendingPathComponent(".onboarding-started"),
            sessionRun: support.appendingPathComponent(".session-run"),
            agentChoice: support.appendingPathComponent(".agent-choice-v1")
        )
    }
}

/// Owns the notch-hosted onboarding surface and the first-launch flag file.
///
/// Lifecycle:
///  * First launch ever → full walkthrough (welcome → agent choice → setup → ready).
///  * Subsequent launches with all required setup complete and an agent choice
///    recorded → nothing shows…
///    *unless* the user has never started a session yet, in which case
///    the simplified flow lands on Ready ("All Set") so they pick a
///    workspace folder before their first session.
///  * Subsequent launches with missing required setup → simplified flow
///    that starts at the first missing step.
///  * Relaunch after the app was killed mid-flow → simplified flow.
///
/// All methods must be called from the main thread — the class uses AppKit
/// APIs (NSWindow, NSWorkspace, NSApp) that require main-thread access.
final class OnboardingController {

    private var surfaceController: OnboardingSurfaceControlling?
    private var introController: (any OnboardingIntroPresenting)?
    private let flagURLs: OnboardingFlagURLs
    private let permissions: PermissionsManager
    /// Closure the Ready step calls to render live setup progress
    /// (e.g. "Loading speech model…") — nil means "finished".
    private let setupStatus: () -> String?
    /// Closure that returns the current configured workspace folder
    /// (empty string = "use the user's home folder"). Read at the moment
    /// the window opens so the Ready-step picker can preload the
    /// previously-chosen value.
    private let getWorkingDirectory: () -> String
    /// Current primary agent provider and mutation hook. First-launch
    /// onboarding asks for this before login/permission guidance so Codex and
    /// Claude users get the right path.
    private let getAgentProvider: () -> GeneralConfig.AgentProvider
    private let setAgentProvider: (GeneralConfig.AgentProvider) -> Void
    private let getModel: () -> String
    private let setModel: (String) -> Void
    private let getCodexReasoningEffort: () -> String
    private let setCodexReasoningEffort: (String) -> Void
    /// Closure that persists the user's chosen workspace folder back
    /// into AppConfig + ConfigManager. Called from the Ready step's Done
    /// button so a fresh path applies to the next voice session.
    private let setWorkingDirectory: (String) -> Void
    /// Starts a new voice session (wired to `AppState.newSession`).
    /// The Ready step's "Start Session" CTA hands off to this so the
    /// user can launch their first session without a detour back to
    /// the menu bar.
    private let startSession: () -> Void
    private let setOnboardingNotchOverrideActive: (Bool) -> Void
    private let requestPermissionSetup: (PermissionKind, PermissionSetupSource, String) -> Void
    private let cancelPermissionSetup: (PermissionSetupSource?) -> Void
    private let shouldDeferPermissionAdvance: (PermissionKind) -> Bool
    private let makeIntroController: () -> any OnboardingIntroPresenting
    private let makeSurfaceController: () -> OnboardingSurfaceControlling
    private let reduceMotion: () -> Bool

    init(permissions: PermissionsManager,
         flagURLs: OnboardingFlagURLs = .live,
         setupStatus: @escaping () -> String? = { nil },
         getWorkingDirectory: @escaping () -> String = { "" },
         getAgentProvider: @escaping () -> GeneralConfig.AgentProvider = { .codex },
         getModel: @escaping () -> String = { GeneralConfig.defaultModel },
         getCodexReasoningEffort: @escaping () -> String = { GeneralConfig.defaultCodexReasoningEffort },
         setAgentProvider: @escaping (GeneralConfig.AgentProvider) -> Void = { _ in },
         setModel: @escaping (String) -> Void = { _ in },
         setCodexReasoningEffort: @escaping (String) -> Void = { _ in },
         setWorkingDirectory: @escaping (String) -> Void = { _ in },
         startSession: @escaping () -> Void = {},
         setOnboardingNotchOverrideActive: @escaping (Bool) -> Void = { _ in },
         requestPermissionSetup: @escaping (PermissionKind, PermissionSetupSource, String) -> Void = { _, _, _ in },
         cancelPermissionSetup: @escaping (PermissionSetupSource?) -> Void = { _ in },
         shouldDeferPermissionAdvance: @escaping (PermissionKind) -> Bool = { _ in false },
         makeIntroController: @escaping () -> any OnboardingIntroPresenting = { OnboardingIntroController() },
         makeSurfaceController: @escaping () -> OnboardingSurfaceControlling = { OnboardingNotchSurfaceController() },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.flagURLs = flagURLs
        self.permissions = permissions
        self.setupStatus = setupStatus
        self.getWorkingDirectory = getWorkingDirectory
        self.getAgentProvider = getAgentProvider
        self.getModel = getModel
        self.getCodexReasoningEffort = getCodexReasoningEffort
        self.setAgentProvider = setAgentProvider
        self.setModel = setModel
        self.setCodexReasoningEffort = setCodexReasoningEffort
        self.setWorkingDirectory = setWorkingDirectory
        self.startSession = startSession
        self.setOnboardingNotchOverrideActive = setOnboardingNotchOverrideActive
        self.requestPermissionSetup = requestPermissionSetup
        self.cancelPermissionSetup = cancelPermissionSetup
        self.shouldDeferPermissionAdvance = shouldDeferPermissionAdvance
        self.makeIntroController = makeIntroController
        self.makeSurfaceController = makeSurfaceController
        self.reduceMotion = reduceMotion
    }

    /// True iff the user has completed (or skipped past) onboarding before.
    var hasOnboarded: Bool {
        FileManager.default.fileExists(atPath: flagURLs.onboarded.path)
    }

    /// True iff the user has started at least one voice session (direct
    /// or via `/relay-bridge`). Drives the "always re-show All Set until
    /// they've started" rule — see `showIfNeeded`.
    var hasRunSession: Bool {
        FileManager.default.fileExists(atPath: flagURLs.sessionRun.path)
    }

    /// True iff the user has explicitly confirmed the primary coding agent in
    /// the versioned onboarding flow.
    var hasChosenAgent: Bool {
        FileManager.default.fileExists(atPath: flagURLs.agentChoice.path)
    }

    /// Mark a session as having been run. Idempotent — safe to call from
    /// both `AppState.newSession()` and the bridge watchdog when an
    /// externally-started relay-bridge is detected.
    func markSessionRun() {
        try? Data().write(to: flagURLs.sessionRun)
    }

    private func markAgentChoiceComplete() {
        try? Data().write(to: flagURLs.agentChoice)
    }

    /// True iff onboarding was opened previously but never reached `finish()`.
    /// Indicates a kill-mid-flow before the user reached the final step.
    private var wasInterrupted: Bool {
        !hasOnboarded && FileManager.default.fileExists(atPath: flagURLs.started.path)
    }

    /// Show onboarding if it's needed — first launch, kill-
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
            if !hasChosenAgent || !permissions.guidedSetupGranted || !hasRunSession {
                show(simplified: true)
            }
        } else if wasInterrupted {
            show(simplified: true)
        } else {
            showFreshAutomatic()
        }
    }

    /// Force-show onboarding (e.g. from a menu item). Always
    /// shows the full flow so the user can re-read the explanations.
    func showAlways() {
        show(simplified: false)
    }

    private func showFreshAutomatic() {
        guard surfaceController == nil, introController == nil else {
            surfaceController?.bringForward()
            Self.activateApp()
            return
        }

        let wasInterruptedBeforeStart = wasInterrupted
        // Mark before the cinematic begins so a termination during the
        // transient overlay resumes through the focused recovery flow.
        try? Data().write(to: flagURLs.started)

        guard OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: hasOnboarded,
            wasInterrupted: wasInterruptedBeforeStart,
            reduceMotion: reduceMotion()
        ) else {
            show(simplified: false, initialStepOverride: .agentChoice, markStarted: false)
            return
        }

        let intro = makeIntroController()
        introController = intro
        setOnboardingNotchOverrideActive(true)
        intro.present { [weak self, weak intro] in
            guard let self else { return }
            self.setOnboardingNotchOverrideActive(false)
            if self.introController === intro {
                self.introController = nil
            }
            self.show(simplified: false, initialStepOverride: .agentChoice, markStarted: false)
        }
    }

    private func show(
        simplified: Bool,
        initialStepOverride: OnboardingView.Step? = nil,
        markStarted: Bool = true
    ) {
        if let surfaceController {
            surfaceController.bringForward()
            Self.activateApp()
            return
        }
        let resumeState = simplified ? OnboardingResumeState.load() : nil
        let requiresParentPermissionGuidance = resumeState?.parentPermissionsReviewed == false
        let initialWorkingDirectory = getWorkingDirectory()
        let initialAgentProvider = getAgentProvider()
        let initialModel = getModel()
        let initialCodexReasoningEffort = getCodexReasoningEffort()
        let startingProvider = resumeState?.provider ?? initialAgentProvider
        let startingParentReviewed = resumeState?.parentPermissionsReviewed ?? false
        let initialStep = OnboardingView.initialStep(
            simplified: simplified,
            resumeStep: resumeState?.step,
            requiresAgentChoice: !hasChosenAgent,
            requiresParentPermissionGuidance: requiresParentPermissionGuidance,
            parentPermissionsReviewed: startingParentReviewed,
            permissionStatus: { permissions.status(for: $0) },
            venvInstalled: VenvInstaller.alreadyInstalled,
            agentSignedIn: AgentAuth.isAuthenticated(for: startingProvider),
            fullFlowInitialStep: initialStepOverride ?? .welcome
        )

        // Mark "started" before the surface is even constructed, so any
        // mid-flow exit leaves enough state for the next launch to resume
        // into the simplified flow rather than the full walkthrough.
        if markStarted {
            try? Data().write(to: flagURLs.started)
        }

        let view = OnboardingView(
            permissions: permissions,
            simplified: simplified,
            setupStatus: setupStatus,
            initialWorkingDirectory: initialWorkingDirectory,
            initialAgentProvider: initialAgentProvider,
            initialModel: initialModel,
            initialCodexReasoningEffort: initialCodexReasoningEffort,
            requiresAgentChoice: !hasChosenAgent,
            requiresParentPermissionGuidance: requiresParentPermissionGuidance,
            initialStepOverride: initialStepOverride,
            resumeState: resumeState,
            onSetAgentProvider: { [weak self] provider in
                self?.setAgentProvider(provider)
                self?.markAgentChoiceComplete()
            },
            onSetModel: { [weak self] model in self?.setModel(model) },
            onSetCodexReasoningEffort: { [weak self] effort in
                self?.setCodexReasoningEffort(effort)
            },
            onSetWorkingDirectory: { [weak self] path in self?.setWorkingDirectory(path) },
            onStartSession: { [weak self] in self?.startSession() },
            requestPermissionSetup: { [weak self] kind, source, purpose in
                self?.requestPermissionSetup(kind, source, purpose)
            },
            cancelPermissionSetup: { [weak self] source in
                self?.cancelPermissionSetup(source)
            },
            shouldDeferPermissionAdvance: { [weak self] kind in
                self?.shouldDeferPermissionAdvance(kind) ?? false
            },
            onSurfaceVisibilityChanged: { [weak self] visible in
                self?.surfaceController?.setContentVisible(visible)
            },
            onFinish: { [weak self] in self?.finish() }
        )

        setOnboardingNotchOverrideActive(true)

        let surface = makeSurfaceController()
        surfaceController = surface
        surface.show(
            rootView: AnyView(view),
            initiallyVisible: OnboardingView.initialSurfaceVisible(for: initialStep)
        ) { [weak self] in
            self?.cancelPermissionSetup(.onboarding)
            self?.surfaceController = nil
            self?.setOnboardingNotchOverrideActive(false)
            Self.setActivationPolicy(.accessory)
        }

        // Menu-bar apps default to .accessory. Temporarily elevate so the
        // onboarding surface takes focus and can be reached via Cmd-Tab; drop
        // back to .accessory when the user dismisses the surface.
        Self.setActivationPolicy(.regular)
        Self.activateApp()
        surface.bringForward()
    }

    /// Mark the flag file and close the surface. Called when the user
    /// completes or skips past the final step.
    private func finish() {
        cancelPermissionSetup(.onboarding)
        try? Data().write(to: flagURLs.onboarded)
        OnboardingResumeState.clear()
        // Started flag is no longer meaningful once onboarding has completed.
        // Clear it so a future focused setup prompt doesn't get treated as a
        // resumed mid-flow exit.
        try? FileManager.default.removeItem(at: flagURLs.started)
        surfaceController?.close()
        surfaceController = nil
        setOnboardingNotchOverrideActive(false)
        Self.setActivationPolicy(.accessory)
    }

    private static func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApplication.shared.setActivationPolicy(policy)
    }

    private static func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

protocol OnboardingSurfaceControlling: AnyObject {
    func show(rootView: AnyView, initiallyVisible: Bool, onClose: @escaping () -> Void)
    func setContentVisible(_ visible: Bool)
    func bringForward()
    func close()
}

enum OnboardingNotchSurfaceMetrics {
    static let contentSize = CGSize(width: 520, height: 620)
    static let cornerRadius: CGFloat = 22
    static let topInset: CGFloat = 0
    static let screenEdgeGap: CGFloat = 14
    static let retractedVisibleSliver: CGFloat = 2
    static let styleMask: NSWindow.StyleMask = [.borderless]
}

struct OnboardingNotchSurfacePlacement: Equatable {
    let visibleFrame: CGRect
    let retractedFrame: CGRect
}

enum OnboardingNotchSurfacePlacementPlanner {
    static func placement(
        for geometry: NotchStatusDisplayGeometry,
        contentSize: CGSize = OnboardingNotchSurfaceMetrics.contentSize
    ) -> OnboardingNotchSurfacePlacement {
        let statusPlacement = NotchStatusPlacementPlanner.placement(for: geometry)
        let anchorX = statusPlacement?.visibleFrame.midX ?? geometry.frame.midX
        let minX = geometry.visibleFrame.minX + OnboardingNotchSurfaceMetrics.screenEdgeGap
        let maxX = geometry.visibleFrame.maxX - contentSize.width - OnboardingNotchSurfaceMetrics.screenEdgeGap
        let proposedX = anchorX - contentSize.width / 2
        let x = maxX >= minX
            ? min(max(proposedX, minX), maxX)
            : geometry.visibleFrame.midX - contentSize.width / 2
        let y = max(
            geometry.visibleFrame.minY + OnboardingNotchSurfaceMetrics.screenEdgeGap,
            geometry.frame.maxY - OnboardingNotchSurfaceMetrics.topInset - contentSize.height
        )
        let visibleFrame = CGRect(origin: CGPoint(x: x, y: y), size: contentSize)
        let retractedFrame = CGRect(
            x: x,
            y: geometry.frame.maxY - OnboardingNotchSurfaceMetrics.retractedVisibleSliver,
            width: contentSize.width,
            height: contentSize.height
        )
        return OnboardingNotchSurfacePlacement(
            visibleFrame: visibleFrame,
            retractedFrame: retractedFrame
        )
    }
}

private final class OnboardingNotchSurfaceController: NSObject, OnboardingSurfaceControlling, NSWindowDelegate {
    private var panel: OnboardingNotchPanel?
    private var screenParametersObserver: NSObjectProtocol?
    private var onClose: (() -> Void)?
    private var contentVisible = true

    deinit {
        removeScreenParametersObserver()
    }

    func show(rootView: AnyView, initiallyVisible: Bool, onClose: @escaping () -> Void) {
        self.onClose = onClose
        installScreenParametersObserver()

        let hosting = NSHostingController(rootView: rootView)
        let panel = panel ?? OnboardingNotchPanel()
        self.panel = panel
        panel.contentViewController = hosting
        panel.delegate = self
        let placement = currentPlacement()
        panel.setFrame(placement.retractedFrame, display: false)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        contentVisible = false
        panel.orderFrontRegardless()
        if initiallyVisible {
            setContentVisible(true)
        }
    }

    func setContentVisible(_ visible: Bool) {
        guard contentVisible != visible || panel?.isVisible != true else { return }
        contentVisible = visible
        guard let panel else { return }

        let placement = currentPlacement()
        let targetFrame = visible ? placement.visibleFrame : placement.retractedFrame
        if visible {
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            panel.makeKey()
        } else {
            panel.ignoresMouseEvents = true
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration(visible ? 0.34 : 0.22)
            context.timingFunction = visible
                ? CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.28, 1.0)
                : CAMediaTimingFunction(controlPoints: 0.42, 0.0, 1.0, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = visible ? 1 : 0
        }
    }

    func bringForward() {
        guard let panel else { return }
        if contentVisible {
            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    func close() {
        removeScreenParametersObserver()
        panel?.delegate = nil
        panel?.close()
        panel = nil
        onClose = nil
    }

    func windowWillClose(_ notification: Notification) {
        removeScreenParametersObserver()
        panel = nil
        let handler = onClose
        onClose = nil
        handler?()
    }

    private func currentPlacement() -> OnboardingNotchSurfacePlacement {
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            return OnboardingNotchSurfacePlacementPlanner.placement(
                for: NotchStatusDisplayGeometry(screen: screen)
            )
        }
        return OnboardingNotchSurfacePlacement(
            visibleFrame: CGRect(origin: .zero, size: OnboardingNotchSurfaceMetrics.contentSize),
            retractedFrame: CGRect(
                x: 0,
                y: OnboardingNotchSurfaceMetrics.contentSize.height - OnboardingNotchSurfaceMetrics.retractedVisibleSliver,
                width: OnboardingNotchSurfaceMetrics.contentSize.width,
                height: OnboardingNotchSurfaceMetrics.contentSize.height
            )
        )
    }

    private func installScreenParametersObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            let placement = self.currentPlacement()
            panel.setFrame(self.contentVisible ? placement.visibleFrame : placement.retractedFrame, display: true)
        }
    }

    private func removeScreenParametersObserver() {
        guard let screenParametersObserver else { return }
        NotificationCenter.default.removeObserver(screenParametersObserver)
        self.screenParametersObserver = nil
    }

    private func animationDuration(_ defaultDuration: TimeInterval) -> TimeInterval {
        NotchStatusAnimationPolicy.duration(
            defaultDuration,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

private final class OnboardingNotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: OnboardingNotchSurfaceMetrics.contentSize),
            styleMask: OnboardingNotchSurfaceMetrics.styleMask,
            backing: .buffered,
            defer: false
        )

        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
