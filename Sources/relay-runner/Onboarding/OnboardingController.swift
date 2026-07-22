import AppKit
import Foundation
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

/// Owns the embedded Settings onboarding presentation and the first-launch flag file.
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
/// All methods must be called from the main thread — the class coordinates
/// SwiftUI presentation and AppKit launch state that require main-thread access.
final class OnboardingController {

    private var introController: (any OnboardingIntroPresenting)?
    let presentation: OnboardingPresentationState
    private let flagURLs: OnboardingFlagURLs
    private let permissions: PermissionsManager
    /// Closure the Ready step calls to render finite live setup status.
    /// `.ready` means the shared runtime is finished and listening.
    private let setupStatus: () -> SetupRuntimeReadiness
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
    private let retrySetup: () -> Void
    private let setOnboardingNotchOverrideActive: (Bool) -> Void
    private let requestPermissionSetup: (PermissionKind, PermissionSetupSource, String) -> Void
    private let cancelPermissionSetup: (PermissionSetupSource?) -> Void
    private let shouldDeferPermissionAdvance: (PermissionKind) -> Bool
    private let permissionStatus: (PermissionKind) -> PermissionStatus
    private let permissionLikelyRestricted: (PermissionKind) -> Bool
    private let makeIntroController: () -> any OnboardingIntroPresenting
    private let openSettingsHost: () -> Void
    private let onOpenExternalWindow: () -> Void
    private let pickWorkspaceDirectory: (
        _ onPrepareExternalWindow: @escaping (@escaping () -> Void) -> Void,
        _ completion: @escaping (String?) -> Void
    ) -> Void
    private let reduceMotion: () -> Bool
    private var freshPermissionState: FreshPermissionState?
    private var freshWorkspaceSelectionInFlight = false
    private var permissionGrantObserver: NSObjectProtocol?
    private var permissionEndedObserver: NSObjectProtocol?

    private struct FreshPermissionState {
        var activePermission: PermissionKind?
        var requestInFlight = false
    }

    init(permissions: PermissionsManager,
         flagURLs: OnboardingFlagURLs = .live,
         presentation: OnboardingPresentationState = OnboardingPresentationState(),
         setupStatus: @escaping () -> SetupRuntimeReadiness = { .ready },
         getWorkingDirectory: @escaping () -> String = { "" },
         getAgentProvider: @escaping () -> GeneralConfig.AgentProvider = { .codex },
         getModel: @escaping () -> String = { GeneralConfig.defaultModel },
         getCodexReasoningEffort: @escaping () -> String = { GeneralConfig.defaultCodexReasoningEffort },
         setAgentProvider: @escaping (GeneralConfig.AgentProvider) -> Void = { _ in },
         setModel: @escaping (String) -> Void = { _ in },
         setCodexReasoningEffort: @escaping (String) -> Void = { _ in },
         setWorkingDirectory: @escaping (String) -> Void = { _ in },
         startSession: @escaping () -> Void = {},
         retrySetup: @escaping () -> Void = {},
         setOnboardingNotchOverrideActive: @escaping (Bool) -> Void = { _ in },
         requestPermissionSetup: @escaping (PermissionKind, PermissionSetupSource, String) -> Void = { _, _, _ in },
         cancelPermissionSetup: @escaping (PermissionSetupSource?) -> Void = { _ in },
         shouldDeferPermissionAdvance: @escaping (PermissionKind) -> Bool = { _ in false },
         permissionStatus: ((PermissionKind) -> PermissionStatus)? = nil,
         permissionLikelyRestricted: ((PermissionKind) -> Bool)? = nil,
         makeIntroController: @escaping () -> any OnboardingIntroPresenting = { OnboardingIntroController() },
         openSettingsHost: @escaping () -> Void = { SettingsPresenter.open() },
         onOpenExternalWindow: @escaping () -> Void = {},
         pickWorkspaceDirectory: @escaping (
            _ onPrepareExternalWindow: @escaping (@escaping () -> Void) -> Void,
            _ completion: @escaping (String?) -> Void
         ) -> Void = { onPrepareExternalWindow, completion in
            WorkspaceDirectoryPicker.pick(
                message: GeneralSettingsTab.workspaceFolderPanelMessage,
                onPrepareExternalWindow: onPrepareExternalWindow,
                chooseDirectory: {
                    WorkspaceDirectoryPicker.runAppKitDirectoryPanel(
                        message: GeneralSettingsTab.workspaceFolderPanelMessage
                    )
                },
                completion: completion
            )
         },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.presentation = presentation
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
        self.retrySetup = retrySetup
        self.setOnboardingNotchOverrideActive = setOnboardingNotchOverrideActive
        self.requestPermissionSetup = requestPermissionSetup
        self.cancelPermissionSetup = cancelPermissionSetup
        self.shouldDeferPermissionAdvance = shouldDeferPermissionAdvance
        self.permissionStatus = permissionStatus ?? { permissions.status(for: $0) }
        self.permissionLikelyRestricted = permissionLikelyRestricted ?? { permissions.likelyRestricted.contains($0) }
        self.makeIntroController = makeIntroController
        self.openSettingsHost = openSettingsHost
        self.onOpenExternalWindow = onOpenExternalWindow
        self.pickWorkspaceDirectory = pickWorkspaceDirectory
        self.reduceMotion = reduceMotion
    }

    deinit {
        removeFreshPermissionObservers()
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
    /// mid-flow recovery, no recorded agent choice after upgrade, or
    /// a returning user who hasn't started their first session yet.
    ///
    /// The simplified flow is used in three cases:
    ///   * `hasOnboarded` and the agent-choice flag is absent — focused setup
    ///     prompt, no need to show welcome/explanations again.
    ///   * `hasOnboarded` and `!hasRunSession` — the user got through
    ///     setup but never ran a session, so we land them on Ready
    ///     so they pick a working directory before their first run.
    ///   * `wasInterrupted` — the user already saw the welcome flow,
    ///     the app exited mid-way, and on relaunch they should resume into a
    ///     focused flow that lands on Ready immediately when setup is complete.
    func showIfNeeded() {
        if hasOnboarded {
            if !hasChosenAgent || !hasRunSession {
                show(simplified: true)
            }
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
        guard !presentation.isPresented, introController == nil else {
            openSettingsHost()
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
            beginFreshPermissionSequence(intro: makeIntroController())
            return
        }

        let intro = makeIntroController()
        introController = intro
        setOnboardingNotchOverrideActive(true)
        intro.present { [weak self, weak intro] in
            guard let self else { return }
            guard let intro, self.introController === intro else { return }
            self.beginFreshPermissionSequence(intro: intro)
        }
    }

    private func beginFreshPermissionSequence(intro: any OnboardingIntroPresenting) {
        let isContinuingExistingIntro = introController === intro
        introController = intro
        freshPermissionState = FreshPermissionState()
        if !isContinuingExistingIntro {
            setOnboardingNotchOverrideActive(true)
        }
        installFreshPermissionObservers()
        showNextFreshPermission()
    }

    private func showNextFreshPermission() {
        guard let intro = introController else { return }
        guard let permission = firstMissingFreshPermission() else {
            completeFreshPermissionSequence()
            return
        }
        freshPermissionState = FreshPermissionState(activePermission: permission)
        let prompt = OnboardingPermissionTreatment.presentation(
            permission: permission,
            status: permissionStatus(permission),
            explanation: OnboardingPermissionTreatment.explanation(for: permission),
            likelyRestricted: permissionLikelyRestricted(permission)
        )
        intro.presentPermissionPrompt(prompt) { [weak self] in
            self?.startFreshPermissionSetup(permission)
        }
    }

    private func startFreshPermissionSetup(_ permission: PermissionKind) {
        guard freshPermissionState?.activePermission == permission,
              freshPermissionState?.requestInFlight != true else { return }
        freshPermissionState?.requestInFlight = true
        let purpose = OnboardingPermissionTreatment.explanation(for: permission)
        let request: () -> Void = { [weak self] in
            self?.requestPermissionSetup(permission, .onboarding, purpose)
        }
        guard permission != .microphone else {
            request()
            return
        }
        introController?.dismiss(completion: request)
    }

    private func firstMissingFreshPermission() -> PermissionKind? {
        PermissionKind.guidedSetupOrder.first { permissionStatus($0) != .granted }
    }

    private func freshPermissionGranted(_ permission: PermissionKind) {
        guard freshPermissionState?.activePermission == permission else { return }
        freshPermissionState?.requestInFlight = false
        freshPermissionState?.activePermission = nil
        showNextFreshPermission()
    }

    private func freshPermissionEndedWithoutGrant(_ event: PermissionSetupLifecycleEvent) {
        guard event.source == .onboarding,
              freshPermissionState?.activePermission == event.permission else { return }
        freshPermissionState?.requestInFlight = false
        showNextFreshPermission()
    }

    private func completeFreshPermissionSequence() {
        removeFreshPermissionObservers()
        freshPermissionState = nil
        showFreshWorkspaceSelection()
    }

    private func showFreshWorkspaceSelection() {
        let intro = introController ?? makeIntroController()
        introController = intro
        setOnboardingNotchOverrideActive(true)
        intro.presentWorkspacePrompt(
            currentPath: Self.workspacePromptDisplayPath(getWorkingDirectory()),
            action: { [weak self, weak intro] in
                self?.pickFreshWorkspace(intro: intro)
            }
        )
    }

    private func pickFreshWorkspace(intro: (any OnboardingIntroPresenting)?) {
        guard !freshWorkspaceSelectionInFlight else { return }
        freshWorkspaceSelectionInFlight = true
        pickWorkspaceDirectory(
            { [weak self, weak intro] ready in
                guard let self else {
                    ready()
                    return
                }
                guard let intro, self.introController === intro else {
                    ready()
                    return
                }
                intro.dismiss { [weak self] in
                    self?.setOnboardingNotchOverrideActive(false)
                    ready()
                }
            },
            { [weak self, weak intro] path in
                guard let self else { return }
                self.freshWorkspaceSelectionInFlight = false
                guard let path else {
                    if let intro, self.introController === intro {
                        self.showFreshWorkspaceSelection()
                    }
                    return
                }
                self.completeFreshWorkspaceSelection(path)
            }
        )
    }

    private func completeFreshWorkspaceSelection(_ path: String) {
        setWorkingDirectory(path)
        introController = nil
        let handoff = { [weak self] in
            guard let self else { return }
            self.show(
                simplified: false,
                initialStepOverride: .agentChoice,
                markStarted: false,
                workspaceAlreadyConfirmed: true
            )
        }
        handoff()
    }

    private static func workspacePromptDisplayPath(_ path: String) -> String {
        path.isEmpty ? NSHomeDirectory() : path
    }

    private func installFreshPermissionObservers() {
        guard permissionGrantObserver == nil, permissionEndedObserver == nil else { return }
        permissionGrantObserver = NotificationCenter.default.addObserver(
            forName: .relayPermissionSetupGrantReady,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let raw = notification.object as? String,
                  let permission = PermissionKind(rawValue: raw) else { return }
            DispatchQueue.main.async {
                self?.freshPermissionGranted(permission)
            }
        }
        permissionEndedObserver = NotificationCenter.default.addObserver(
            forName: .relayPermissionSetupEndedWithoutGrant,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let event = notification.object as? PermissionSetupLifecycleEvent else { return }
            DispatchQueue.main.async {
                self?.freshPermissionEndedWithoutGrant(event)
            }
        }
    }

    private func removeFreshPermissionObservers() {
        if let permissionGrantObserver {
            NotificationCenter.default.removeObserver(permissionGrantObserver)
            self.permissionGrantObserver = nil
        }
        if let permissionEndedObserver {
            NotificationCenter.default.removeObserver(permissionEndedObserver)
            self.permissionEndedObserver = nil
        }
    }

    private func show(
        simplified: Bool,
        initialStepOverride: OnboardingView.Step? = nil,
        markStarted: Bool = true,
        workspaceAlreadyConfirmed: Bool = false
    ) {
        if presentation.isPresented {
            openSettingsHost()
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

        // Mark "started" before the embedded walkthrough is even constructed, so any
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
            showsWorkingDirectoryPicker: !workspaceAlreadyConfirmed,
            initialWorkingDirectoryConfirmed: workspaceAlreadyConfirmed,
            persistsWorkingDirectorySelection: !workspaceAlreadyConfirmed,
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
            onRetrySetup: { [weak self] in self?.retrySetup() },
            requestPermissionSetup: { [weak self] kind, source, purpose in
                self?.requestPermissionSetup(kind, source, purpose)
            },
            cancelPermissionSetup: { [weak self] source in
                self?.cancelPermissionSetup(source)
            },
            shouldDeferPermissionAdvance: { [weak self] kind in
                self?.shouldDeferPermissionAdvance(kind) ?? false
            },
            onOpenExternalWindow: onOpenExternalWindow,
            presentation: presentation,
            onSurfaceVisibilityChanged: { [weak self] visible in
                self?.presentation.setContentVisible(visible)
            },
            onFinish: { [weak self] in self?.finish() },
            onHostDismissed: { [weak self] in self?.hostDismissed() }
        )

        setOnboardingNotchOverrideActive(true)
        presentation.present(
            rootView: AnyView(view),
            initialDetail: OnboardingDetailPresentation(
                title: OnboardingView.headerTitle(for: initialStep, provider: startingProvider),
                subtitle: OnboardingView.headerSubtitle(for: initialStep),
                progress: OnboardingView.progressLabel(
                    for: initialStep,
                    simplified: simplified,
                    requiresAgentChoice: !hasChosenAgent,
                    requiresParentPermissionGuidance: requiresParentPermissionGuidance,
                    permissionStatus: { permissions.status(for: $0) },
                    venvInstalled: VenvInstaller.alreadyInstalled,
                    agentSignedIn: AgentAuth.isAuthenticated(for: startingProvider),
                    parentPermissionsReviewed: startingParentReviewed
                )
            )
        )
        presentation.setContentVisible(OnboardingView.initialSurfaceVisible(for: initialStep))
        openSettingsHost()
    }

    /// Mark the flag file and clear the embedded presentation. Called when the user
    /// completes or skips past the final step.
    private func finish() {
        cancelPermissionSetup(.onboarding)
        try? Data().write(to: flagURLs.onboarded)
        OnboardingResumeState.clear()
        // Started flag is no longer meaningful once onboarding has completed.
        // Clear it so a future focused setup prompt doesn't get treated as a
        // resumed mid-flow exit.
        try? FileManager.default.removeItem(at: flagURLs.started)
        presentation.clear()
        setOnboardingNotchOverrideActive(false)
    }

    private func hostDismissed() {
        guard presentation.isPresented else { return }
        cancelPermissionSetup(.onboarding)
        presentation.clear()
        setOnboardingNotchOverrideActive(false)
    }
}
