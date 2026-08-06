import AppKit
import Foundation

struct OnboardingFlagURLs {
    let onboarded: URL
    let architectureVersion: URL
    let started: URL
    let sessionRun: URL
    let agentChoice: URL
    let manualRedo: URL

    static var live: OnboardingFlagURLs {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("relay-runner", isDirectory: true)
        try? FileManager.default.createDirectory(at: support,
                                                 withIntermediateDirectories: true)
        return OnboardingFlagURLs(
            onboarded: support.appendingPathComponent(".onboarded"),
            architectureVersion: support.appendingPathComponent(".onboarding-architecture-version"),
            started: support.appendingPathComponent(".onboarding-started"),
            sessionRun: support.appendingPathComponent(".session-run"),
            agentChoice: support.appendingPathComponent(".agent-choice-v1"),
            manualRedo: support.appendingPathComponent(".onboarding-manual-redo")
        )
    }
}

protocol OnboardingRuntimeInstalling: AnyObject {
    var status: VenvInstaller.Status { get }
    func install(for provider: GeneralConfig.AgentProvider?)
}

extension VenvInstaller: OnboardingRuntimeInstalling {}

/// Owns the intro onboarding presentation and the first-launch flag file.
///
/// Lifecycle:
///  * First launch ever → cinematic, live permissions, agent choice, setup, login, workspace.
///  * Subsequent launches with all required setup complete and an agent choice
///    recorded → nothing shows.
///  * Previously-onboarded upgrades without the versioned agent-choice flag
///    receive a focused provider/runtime/login prompt.
///  * Relaunch after the app was killed mid-flow resumes from live state.
///
/// All methods must be called from the main thread — the class coordinates
/// SwiftUI presentation and AppKit launch state that require main-thread access.
final class OnboardingController {

    static let currentArchitectureVersion = "2"

    private var introController: (any OnboardingIntroPresenting)?
    private var dismissingIntroController: (any OnboardingIntroPresenting)?
    let presentation: OnboardingPresentationState
    private let flagURLs: OnboardingFlagURLs
    private let permissions: PermissionsManager
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
    /// Closure that persists the user's chosen workspace folder back
    /// into AppConfig + ConfigManager. Called from the Ready step's Done
    /// button so a fresh path applies to the next voice session.
    private let setWorkingDirectory: (String) -> Void
    private let usesProjectRegistryV2: Bool
    private let setOnboardingNotchOverrideActive: (Bool) -> Void
    private let setFirstRunExperienceActive: (Bool) -> Void
    private let requestPermissionSetup: (PermissionKind, PermissionSetupSource, String) -> Void
    private let cancelPermissionSetup: (PermissionSetupSource?) -> Void
    private let shouldDeferPermissionAdvance: (PermissionKind) -> Bool
    private let permissionStatus: (PermissionKind) -> PermissionStatus
    private let permissionLikelyRestricted: (PermissionKind) -> Bool
    private let makeIntroController: () -> any OnboardingIntroPresenting
    private let makeVenvInstaller: () -> any OnboardingRuntimeInstalling
    private let runtimeAlreadyInstalled: (GeneralConfig.AgentProvider) -> Bool
    private let isAgentAuthenticated: (GeneralConfig.AgentProvider) -> Bool
    private let openAgentLoginInTerminal: (GeneralConfig.AgentProvider) -> Bool
    private let onOpenExternalWindow: () -> Void
    private let runtimePollInterval: TimeInterval
    private let authPollInterval: TimeInterval
    private let introAdvanceDelay: TimeInterval
    private let pickWorkspaceDirectory: (
        _ onPrepareExternalWindow: @escaping (@escaping () -> Void) -> Void,
        _ completion: @escaping (String?) -> Void
    ) -> Void
    private let reduceMotion: () -> Bool
    private let prepareTutorialSpeech: () -> Bool
    private let stopTutorialSpeech: () -> Void
    private let openWorkspaceAfterCompletion: () -> Void
    private var freshPermissionState: FreshPermissionState?
    private var freshWorkspaceSelectionInFlight = false
    private var permissionGrantObserver: NSObjectProtocol?
    private var permissionEndedObserver: NSObjectProtocol?
    private var agentSetupState: AgentSetupState?
    private var venvInstaller: any OnboardingRuntimeInstalling
    private var runtimePollTimer: Timer?
    private var authPollTimer: Timer?
    private var appActivationObserver: NSObjectProtocol?
    private var forceWorkspaceSelectionAfterIntro = false
    private var tutorialState: TutorialState?
    private var tutorialIntroAdvance: DispatchWorkItem?

    private struct FreshPermissionState {
        var activePermission: PermissionKind?
        var requestInFlight = false
    }

    private struct AgentSetupState {
        var provider: GeneralConfig.AgentProvider
        var requiresWorkspaceSelection: Bool
        var requiresProjectlessTutorial: Bool
        var providerPersisted = false
    }

    private struct TutorialState {
        var provider: GeneralConfig.AgentProvider
        var recordingGate: OnboardingSessionControlsTutorial.RecordingGate = .waitingForStart
        var playbackGate: OnboardingSessionControlsTutorial.PlaybackGate = .waitingForPlayback
        var responseText: String?
    }

    init(permissions: PermissionsManager,
         flagURLs: OnboardingFlagURLs = .live,
         presentation: OnboardingPresentationState = OnboardingPresentationState(),
         getWorkingDirectory: @escaping () -> String = { "" },
         getAgentProvider: @escaping () -> GeneralConfig.AgentProvider = { .codex },
         setAgentProvider: @escaping (GeneralConfig.AgentProvider) -> Void = { _ in },
         setWorkingDirectory: @escaping (String) -> Void = { _ in },
         usesProjectRegistryV2: Bool = false,
         setOnboardingNotchOverrideActive: @escaping (Bool) -> Void = { _ in },
         setFirstRunExperienceActive: @escaping (Bool) -> Void = { _ in },
         requestPermissionSetup: @escaping (PermissionKind, PermissionSetupSource, String) -> Void = { _, _, _ in },
         cancelPermissionSetup: @escaping (PermissionSetupSource?) -> Void = { _ in },
         shouldDeferPermissionAdvance: @escaping (PermissionKind) -> Bool = { _ in false },
         permissionStatus: ((PermissionKind) -> PermissionStatus)? = nil,
         permissionLikelyRestricted: ((PermissionKind) -> Bool)? = nil,
         makeIntroController: @escaping () -> any OnboardingIntroPresenting = { OnboardingIntroController() },
         makeVenvInstaller: @escaping () -> any OnboardingRuntimeInstalling = { VenvInstaller() },
         runtimeAlreadyInstalled: @escaping (GeneralConfig.AgentProvider) -> Bool = { VenvInstaller.alreadyInstalled(for: $0) },
         isAgentAuthenticated: @escaping (GeneralConfig.AgentProvider) -> Bool = { AgentAuth.isAuthenticated(for: $0) },
         openAgentLoginInTerminal: @escaping (GeneralConfig.AgentProvider) -> Bool = { AgentAuth.openLoginInTerminal(for: $0) },
         onOpenExternalWindow: @escaping () -> Void = {},
         runtimePollInterval: TimeInterval = 0.5,
         authPollInterval: TimeInterval = 1.0,
         introAdvanceDelay: TimeInterval = 0.4,
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
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         prepareTutorialSpeech: @escaping () -> Bool = { true },
         stopTutorialSpeech: @escaping () -> Void = {},
         openWorkspaceAfterCompletion: @escaping () -> Void = {}) {
        self.presentation = presentation
        self.flagURLs = flagURLs
        self.permissions = permissions
        self.getWorkingDirectory = getWorkingDirectory
        self.getAgentProvider = getAgentProvider
        self.setAgentProvider = setAgentProvider
        self.setWorkingDirectory = setWorkingDirectory
        self.usesProjectRegistryV2 = usesProjectRegistryV2
        self.setOnboardingNotchOverrideActive = setOnboardingNotchOverrideActive
        self.setFirstRunExperienceActive = setFirstRunExperienceActive
        self.requestPermissionSetup = requestPermissionSetup
        self.cancelPermissionSetup = cancelPermissionSetup
        self.shouldDeferPermissionAdvance = shouldDeferPermissionAdvance
        self.permissionStatus = permissionStatus ?? { permissions.status(for: $0) }
        self.permissionLikelyRestricted = permissionLikelyRestricted ?? { permissions.likelyRestricted.contains($0) }
        self.makeIntroController = makeIntroController
        self.makeVenvInstaller = makeVenvInstaller
        self.venvInstaller = makeVenvInstaller()
        self.runtimeAlreadyInstalled = runtimeAlreadyInstalled
        self.isAgentAuthenticated = isAgentAuthenticated
        self.openAgentLoginInTerminal = openAgentLoginInTerminal
        self.onOpenExternalWindow = onOpenExternalWindow
        self.runtimePollInterval = runtimePollInterval
        self.authPollInterval = authPollInterval
        self.introAdvanceDelay = introAdvanceDelay
        self.pickWorkspaceDirectory = pickWorkspaceDirectory
        self.reduceMotion = reduceMotion
        self.prepareTutorialSpeech = prepareTutorialSpeech
        self.stopTutorialSpeech = stopTutorialSpeech
        self.openWorkspaceAfterCompletion = openWorkspaceAfterCompletion
    }

    deinit {
        removeFreshPermissionObservers()
        stopRuntimePolling()
        stopAuthPolling()
        cancelTutorialIntroAdvance()
        stopTutorialSpeech()
    }

    /// True iff the user has completed (or skipped past) onboarding before.
    var hasOnboarded: Bool {
        FileManager.default.fileExists(atPath: flagURLs.onboarded.path)
    }

    private var hasCompletedCurrentArchitectureOnboarding: Bool {
        Self.hasCompletedCurrentArchitectureOnboarding(flagURLs: flagURLs)
    }

    private static func hasCompletedCurrentArchitectureOnboarding(
        flagURLs: OnboardingFlagURLs
    ) -> Bool {
        guard let value = try? String(contentsOf: flagURLs.architectureVersion, encoding: .utf8) else {
            return false
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == currentArchitectureVersion
    }

    /// True iff the user has started at least one voice session (direct
    /// or via `/relay-bridge`). Kept for compatibility with existing
    /// launch/session bookkeeping; onboarding completion no longer depends on it.
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

    static func sharedOnboardingInProgress(
        flagURLs: OnboardingFlagURLs = .live,
        usesProjectRegistryV2: Bool = ProjectRegistryV2Rollout.isEnabled()
    ) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: flagURLs.manualRedo.path) {
            return true
        }
        if !fileManager.fileExists(atPath: flagURLs.onboarded.path) {
            return fileManager.fileExists(atPath: flagURLs.started.path)
        }
        guard usesProjectRegistryV2 else { return false }
        return !hasCompletedCurrentArchitectureOnboarding(flagURLs: flagURLs)
    }

    private var manualRedoInProgress: Bool {
        FileManager.default.fileExists(atPath: flagURLs.manualRedo.path)
    }

    /// Show onboarding if it's needed — first launch, kill-mid-flow recovery,
    /// or a previously-onboarded upgrade without the versioned agent flag.
    func showIfNeeded() {
        forceWorkspaceSelectionAfterIntro = false
        if manualRedoInProgress {
            resumeManualRedo()
            return
        }
        if usesProjectRegistryV2,
           hasOnboarded,
           !hasCompletedCurrentArchitectureOnboarding {
            showArchitectureMigration()
            return
        }
        if hasOnboarded {
            if !hasChosenAgent {
                beginIntroAgentSetup(
                    requiresWorkspaceSelection: false,
                    resumeState: OnboardingResumeState.load()
                )
            }
        } else {
            showFreshAutomatic()
        }
    }

    private func showArchitectureMigration() {
        guard !presentation.isPresented, introController == nil else { return }
        let fileManager = FileManager.default
        let wasInterrupted = fileManager.fileExists(atPath: flagURLs.started.path)
        if !wasInterrupted {
            OnboardingResumeState.clear()
        }
        forceWorkspaceSelectionAfterIntro = true
        setFirstRunExperienceActive(true)
        try? Data().write(to: flagURLs.started)

        guard OnboardingIntroPolicy.shouldPlayAutomaticIntro(
            hasOnboarded: false,
            wasInterrupted: wasInterrupted,
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

    /// Force-show onboarding (e.g. from a menu item). Uses the intro overlay,
    /// with the cinematic reserved for pristine automatic launches.
    func showAlways() {
        showIntro(forceWorkspaceSelectionAfterIntro: false)
    }

    /// Manual redo mirrors a pristine first launch: cinematic first, then the
    /// complete live setup sequence with workspace selection last.
    func showManualRedo() {
        guard introController == nil else { return }
        cancelPermissionSetup(.onboarding)
        OnboardingResumeState.clear()
        forceWorkspaceSelectionAfterIntro = true
        setFirstRunExperienceActive(true)
        try? Data().write(to: flagURLs.started)
        try? Data().write(to: flagURLs.manualRedo)

        let intro = makeIntroController()
        introController = intro
        setOnboardingNotchOverrideActive(true)
        intro.present { [weak self, weak intro] in
            guard let self else { return }
            guard let intro, self.introController === intro else { return }
            self.beginFreshPermissionSequence(intro: intro)
        }
    }

    private func resumeManualRedo() {
        forceWorkspaceSelectionAfterIntro = true
        setFirstRunExperienceActive(true)
        try? Data().write(to: flagURLs.started)
        beginFreshPermissionSequence(intro: makeIntroController())
    }

    private func showIntro(forceWorkspaceSelectionAfterIntro: Bool) {
        guard introController == nil else { return }
        self.forceWorkspaceSelectionAfterIntro = forceWorkspaceSelectionAfterIntro
        try? Data().write(to: flagURLs.started)
        beginFreshPermissionSequence(intro: makeIntroController())
    }

    private func showFreshAutomatic() {
        guard !presentation.isPresented, introController == nil else {
            return
        }

        setFirstRunExperienceActive(true)
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
        let isFreshSetup = forceWorkspaceSelectionAfterIntro || !hasOnboarded
        let requiresWorkspaceSelection = isFreshSetup && !usesProjectRegistryV2
        forceWorkspaceSelectionAfterIntro = false
        beginIntroAgentSetup(
            requiresWorkspaceSelection: requiresWorkspaceSelection,
            requiresProjectlessTutorial: isFreshSetup && usesProjectRegistryV2,
            resumeState: OnboardingResumeState.load()
        )
    }

    private func showFreshWorkspaceSelection() {
        let intro = introController ?? makeIntroController()
        introController = intro
        setOnboardingNotchOverrideActive(true)
        intro.presentWorkspacePrompt(
            currentPath: Self.workspacePromptDisplayPath(getWorkingDirectory()),
            continueAction: { [weak self] in
                self?.completeFreshWorkspaceSelection(
                    Self.workspacePromptDisplayPath(self?.getWorkingDirectory() ?? "")
                )
            },
            browseAction: { [weak self, weak intro] in
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
        beginSessionControlsTutorial(screen: .intro)
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

    private func beginIntroAgentSetup(
        requiresWorkspaceSelection: Bool,
        requiresProjectlessTutorial: Bool = false,
        resumeState: OnboardingResumeState.Snapshot? = nil
    ) {
        guard !presentation.isPresented else { return }
        let provider = resumeState?.provider ?? getAgentProvider()
        let intro = introController ?? makeIntroController()
        let isContinuingExistingIntro = introController === intro
        introController = intro
        agentSetupState = AgentSetupState(
            provider: provider,
            requiresWorkspaceSelection: requiresWorkspaceSelection,
            requiresProjectlessTutorial: requiresProjectlessTutorial
        )
        if !isContinuingExistingIntro {
            setOnboardingNotchOverrideActive(true)
        }

        switch resumeState?.step {
        case .tutorialIntro,
             .tutorialRecording,
             .tutorialRecordingActive,
             .tutorialPlayback,
             .tutorialCancellation,
             .tutorialWorkspace,
             .tutorialSessionRetry:
            if let step = resumeState?.step,
               let screen = OnboardingSessionControlsTutorial.screen(for: step) {
                beginSessionControlsTutorial(screen: screen)
            } else {
                beginSessionControlsTutorial(screen: .intro)
            }
        case .pythonSetup:
            showIntroRuntimePreparation()
        case .agentLogin:
            if runtimeAlreadyInstalled(provider) {
                showIntroAgentLogin(message: nil)
            } else {
                showIntroRuntimePreparation()
            }
        case .ready:
            if requiresWorkspaceSelection {
                showFreshWorkspaceSelection()
            } else if requiresProjectlessTutorial {
                beginSessionControlsTutorial(screen: .intro)
            } else {
                finish()
            }
        default:
            showIntroAgentChoice()
        }
    }

    private func showIntroAgentChoice() {
        guard let state = agentSetupState,
              let intro = introController else { return }
        stopRuntimePolling()
        stopAuthPolling()
        OnboardingResumeState.save(
            step: .agentChoice,
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        intro.presentAgentChoicePrompt(
            selectedProvider: state.provider,
            codexAction: { [weak self] in self?.selectIntroAgentProvider(.codex) },
            claudeAction: { [weak self] in self?.selectIntroAgentProvider(.claude) }
        )
    }

    private func selectIntroAgentProvider(_ provider: GeneralConfig.AgentProvider) {
        guard var state = agentSetupState else { return }
        state.provider = provider
        if !state.providerPersisted {
            setAgentProvider(provider)
            state.providerPersisted = true
        }
        agentSetupState = state
        venvInstaller = makeVenvInstaller()
        OnboardingResumeState.save(
            step: .agentChoice,
            provider: provider,
            parentPermissionsReviewed: true
        )
        showIntroRuntimePreparation()
    }

    private func showIntroRuntimePreparation() {
        guard let state = agentSetupState,
              let intro = introController else { return }
        stopAuthPolling()
        OnboardingResumeState.save(
            step: .pythonSetup,
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        venvInstaller.install(for: state.provider)
        intro.presentRuntimePrompt(
            OnboardingRuntimePromptPresentation(
                provider: state.provider,
                status: venvInstaller.status
            ),
            retryAction: { [weak self] in self?.retryIntroRuntimePreparation() }
        )
        startRuntimePolling(provider: state.provider)
    }

    private func retryIntroRuntimePreparation() {
        venvInstaller = makeVenvInstaller()
        showIntroRuntimePreparation()
    }

    private func startRuntimePolling(provider: GeneralConfig.AgentProvider) {
        stopRuntimePolling()
        let timer = Timer(timeInterval: runtimePollInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.runtimePollTick(provider: provider)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        runtimePollTimer = timer
        runtimePollTick(provider: provider)
    }

    private func runtimePollTick(provider: GeneralConfig.AgentProvider) {
        guard agentSetupState?.provider == provider,
              let intro = introController else { return }
        intro.presentRuntimePrompt(
            OnboardingRuntimePromptPresentation(
                provider: provider,
                status: venvInstaller.status
            ),
            retryAction: { [weak self] in self?.retryIntroRuntimePreparation() }
        )
        switch venvInstaller.status {
        case .succeeded:
            stopRuntimePolling()
            DispatchQueue.main.asyncAfter(deadline: .now() + introAdvanceDelay) { [weak self] in
                guard self?.agentSetupState?.provider == provider else { return }
                self?.showIntroAgentLogin(message: nil)
            }
        case .failed:
            stopRuntimePolling()
        case .idle, .running:
            break
        }
    }

    private func stopRuntimePolling() {
        runtimePollTimer?.invalidate()
        runtimePollTimer = nil
    }

    private func showIntroAgentLogin(message: String?) {
        guard let state = agentSetupState,
              let intro = introController else { return }
        stopRuntimePolling()
        OnboardingResumeState.save(
            step: .agentLogin,
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        let signedIn = isAgentAuthenticated(state.provider)
        intro.presentAgentLoginPrompt(
            OnboardingAgentLoginPromptPresentation(
                provider: state.provider,
                signedIn: signedIn,
                message: message
            ),
            signInAction: { [weak self] in self?.startIntroAgentLogin() }
        )
        guard signedIn else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + introAdvanceDelay) { [weak self] in
            guard let self,
                  self.agentSetupState?.provider == state.provider,
                  self.isAgentAuthenticated(state.provider) else { return }
            self.completeAuthenticatedProvider(state.provider, introDismissed: false)
        }
    }

    private func startIntroAgentLogin() {
        guard let state = agentSetupState,
              let intro = introController else { return }
        OnboardingResumeState.save(
            step: .agentLogin,
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        intro.dismiss { [weak self] in
            guard let self else { return }
            self.setOnboardingNotchOverrideActive(false)
            self.onOpenExternalWindow()
            guard self.openAgentLoginInTerminal(state.provider) else {
                self.restoreIntroAgentLogin(
                    provider: state.provider,
                    message: "Could not open Terminal for \(state.provider.displayName) sign-in."
                )
                return
            }
            self.startAuthPolling(provider: state.provider)
        }
    }

    private func startAuthPolling(provider: GeneralConfig.AgentProvider) {
        stopAuthPolling()
        let timer = Timer(timeInterval: authPollInterval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.authPollTick(provider: provider)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        authPollTimer = timer
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.restoreLoginIfAuthenticationDidNotComplete(provider: provider)
            }
        }
        authPollTick(provider: provider)
    }

    private func authPollTick(provider: GeneralConfig.AgentProvider) {
        guard agentSetupState?.provider == provider else {
            stopAuthPolling()
            return
        }
        guard isAgentAuthenticated(provider) else { return }
        stopAuthPolling()
        completeAuthenticatedProvider(provider, introDismissed: true)
    }

    private func restoreLoginIfAuthenticationDidNotComplete(provider: GeneralConfig.AgentProvider) {
        guard agentSetupState?.provider == provider,
              !isAgentAuthenticated(provider) else { return }
        stopAuthPolling()
        restoreIntroAgentLogin(
            provider: provider,
            message: "\(provider.displayName) sign-in did not complete. Try again when you are ready."
        )
    }

    private func restoreIntroAgentLogin(provider: GeneralConfig.AgentProvider, message: String) {
        guard agentSetupState?.provider == provider else { return }
        setOnboardingNotchOverrideActive(true)
        if introController == nil {
            introController = makeIntroController()
        }
        showIntroAgentLogin(message: message)
    }

    private func stopAuthPolling() {
        authPollTimer?.invalidate()
        authPollTimer = nil
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func completeAuthenticatedProvider(
        _ provider: GeneralConfig.AgentProvider,
        introDismissed: Bool
    ) {
        guard let state = agentSetupState,
              state.provider == provider else { return }
        markAgentChoiceComplete()
        if state.requiresWorkspaceSelection {
            OnboardingResumeState.save(
                step: .ready,
                provider: provider,
                parentPermissionsReviewed: true
            )
            showFreshWorkspaceSelection()
        } else if state.requiresProjectlessTutorial {
            beginSessionControlsTutorial(screen: .intro)
        } else {
            if introDismissed {
                introController = nil
            }
            finish()
        }
    }

    private func beginSessionControlsTutorial(screen: OnboardingTutorialScreen) {
        let intro = introController ?? makeIntroController()
        introController = intro
        setOnboardingNotchOverrideActive(true)

        let provider = agentSetupState?.provider ?? getAgentProvider()
        if tutorialState?.provider != provider || screen == .intro {
            tutorialState = TutorialState(provider: provider)
        }

        guard prepareTutorialSpeech() else {
            presentTutorial(
                screen: .sessionRetry,
                message: "Relay Runner could not prepare local tutorial speech. Retry when voice setup is available."
            )
            return
        }

        let transientScreens: [OnboardingTutorialScreen] = [
            .recordingActive,
            .playback,
            .cancellation,
        ]
        let safeScreen: OnboardingTutorialScreen = transientScreens.contains(screen)
            ? .recording
            : screen
        if transientScreens.contains(screen) {
            tutorialState?.recordingGate = .waitingForStart
            tutorialState?.playbackGate = .waitingForPlayback
            tutorialState?.responseText = nil
        }

        presentTutorial(screen: safeScreen)
        if safeScreen == .intro {
            scheduleTutorialIntroAdvance(provider: provider)
        }
    }

    private func presentTutorial(screen: OnboardingTutorialScreen, message: String? = nil) {
        guard let state = tutorialState,
              let intro = introController else { return }
        cancelTutorialIntroAdvance()
        OnboardingResumeState.save(
            step: OnboardingSessionControlsTutorial.resumeID(for: screen),
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        intro.presentTutorial(
            OnboardingTutorialPresentation(
                screen: screen,
                reduceMotion: reduceMotion(),
                message: message
            ),
            retryAction: { [weak self] in
                self?.beginSessionControlsTutorial(screen: .intro)
            }
        )
    }

    private func scheduleTutorialIntroAdvance(provider: GeneralConfig.AgentProvider) {
        let delay = reduceMotion() ? 0 : introAdvanceDelay
        scheduleTutorialIntroAdvance(provider: provider, after: delay)
    }

    private func scheduleTutorialIntroAdvance(
        provider: GeneralConfig.AgentProvider,
        after delay: TimeInterval
    ) {
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.tutorialState?.provider == provider,
                  OnboardingResumeState.load()?.step == .tutorialIntro else { return }
            self.presentTutorial(screen: .recording)
        }
        tutorialIntroAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelTutorialIntroAdvance() {
        tutorialIntroAdvance?.cancel()
        tutorialIntroAdvance = nil
    }

    var isAwaitingTutorialWorkspaceToggle: Bool {
        OnboardingResumeState.load()?.step == .tutorialWorkspace
    }

    var isSessionControlsTutorialActive: Bool {
        tutorialState != nil
    }

    func noteTutorialRecordingStarted() {
        advanceRecordingTutorial(with: .recordingStarted)
    }

    func noteTutorialSpeechDetected() {
        advanceRecordingTutorial(with: .speechDetected)
    }

    @discardableResult
    func noteTutorialRecordingSent() -> String? {
        let previousGate = tutorialState?.recordingGate
        advanceRecordingTutorial(with: .recordingSent)
        guard previousGate == .waitingForSend,
              tutorialState?.recordingGate == .waitingForResponse else { return nil }
        return OnboardingSessionControlsTutorial.deterministicReply
    }

    func noteTutorialResponseReady(_ text: String?) {
        guard var state = tutorialState,
              OnboardingResumeState.load()?.step == .tutorialPlayback,
              state.recordingGate == .waitingForResponse,
              let response = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              response == OnboardingSessionControlsTutorial.deterministicReply else { return }
        state.responseText = response
        state.recordingGate = OnboardingSessionControlsTutorial.nextRecordingGate(
            state.recordingGate,
            event: .responseReady
        )
        tutorialState = state
    }

    @discardableResult
    func noteTutorialPlaybackRequested(
        playbackActive: Bool = false
    ) -> OnboardingSessionControlsTutorial.PlaybackCommand? {
        guard var state = tutorialState,
              let step = OnboardingResumeState.load()?.step,
              step == .tutorialPlayback || step == .tutorialCancellation,
              state.recordingGate == .complete,
              state.responseText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return nil }
        let previousGate = state.playbackGate
        state.playbackGate = OnboardingSessionControlsTutorial.nextPlaybackGate(
            state.playbackGate,
            event: .playbackRequested
        )
        if playbackActive {
            state.playbackGate = OnboardingSessionControlsTutorial.nextPlaybackGate(
                state.playbackGate,
                event: .playbackStarted
            )
        }
        tutorialState = state
        guard state.playbackGate != previousGate else { return nil }
        return step == .tutorialPlayback ? .play : .replay
    }

    func noteTutorialPlaybackStarted() {
        guard var state = tutorialState,
              let step = OnboardingResumeState.load()?.step,
              step == .tutorialPlayback || step == .tutorialCancellation else { return }
        state.playbackGate = OnboardingSessionControlsTutorial.nextPlaybackGate(
            state.playbackGate,
            event: .playbackStarted
        )
        tutorialState = state
    }

    @discardableResult
    func noteTutorialPlaybackFinished() -> String? {
        guard var state = tutorialState,
              OnboardingResumeState.load()?.step == .tutorialPlayback else {
            return persistentTutorialReplayResponse
        }
        let previousGate = state.playbackGate
        state.playbackGate = OnboardingSessionControlsTutorial.nextPlaybackGate(
            state.playbackGate,
            event: .playbackFinished
        )
        tutorialState = state
        guard previousGate == .waitingForInitialPlaybackEnd,
              state.playbackGate == .waitingForReplayStart else { return nil }

        presentTutorial(screen: .cancellation)
        return persistentTutorialReplayResponse
    }

    private var persistentTutorialReplayResponse: String? {
        guard OnboardingResumeState.load()?.step == .tutorialCancellation,
              let response = tutorialState?.responseText?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !response.isEmpty else { return nil }
        return response
    }

    func noteTutorialCancelRequested() {
        guard var state = tutorialState,
              OnboardingResumeState.load()?.step == .tutorialCancellation else { return }
        state.playbackGate = OnboardingSessionControlsTutorial.nextPlaybackGate(
            state.playbackGate,
            event: .cancelRequested
        )
        tutorialState = state
        if state.playbackGate == .complete {
            stopTutorialSpeech()
            presentTutorial(screen: .workspace)
        }
    }

    func noteTutorialWorkspaceToggled() {
        guard OnboardingResumeState.load()?.step == .tutorialWorkspace else { return }
        finish {
            self.openWorkspaceAfterCompletion()
        }
    }

    private func advanceRecordingTutorial(with event: OnboardingSessionControlsTutorial.Event) {
        guard var state = tutorialState,
              let step = OnboardingResumeState.load()?.step,
              step == .tutorialRecording || step == .tutorialRecordingActive else { return }
        let previousGate = state.recordingGate
        state.recordingGate = OnboardingSessionControlsTutorial.nextRecordingGate(
            state.recordingGate,
            event: event
        )
        tutorialState = state
        if previousGate == .waitingForStart,
           state.recordingGate == .waitingForSpeech {
            presentTutorial(screen: .recordingActive)
        } else if previousGate == .waitingForSend,
                  state.recordingGate == .waitingForResponse {
            presentTutorial(screen: .playback)
        }
    }

    /// Mark the flag file and clear the embedded presentation. Called when the user
    /// completes or skips past the final step.
    private func finish(completion: @escaping () -> Void = {}) {
        stopRuntimePolling()
        stopAuthPolling()
        cancelTutorialIntroAdvance()
        stopTutorialSpeech()
        cancelPermissionSetup(.onboarding)
        try? Data().write(to: flagURLs.onboarded)
        if usesProjectRegistryV2 {
            try? Data(Self.currentArchitectureVersion.utf8).write(to: flagURLs.architectureVersion)
        }
        OnboardingResumeState.clear()
        try? FileManager.default.removeItem(at: flagURLs.manualRedo)
        // Started flag is no longer meaningful once onboarding has completed.
        // Clear it so a future focused setup prompt doesn't get treated as a
        // resumed mid-flow exit.
        try? FileManager.default.removeItem(at: flagURLs.started)
        presentation.clear()
        agentSetupState = nil
        tutorialState = nil
        let intro = introController
        introController = nil
        let complete: () -> Void = { [weak self] in
            self?.dismissingIntroController = nil
            self?.setOnboardingNotchOverrideActive(false)
            self?.setFirstRunExperienceActive(false)
            completion()
        }
        if let intro {
            dismissingIntroController = intro
            intro.dismiss(completion: complete)
        } else {
            complete()
        }
    }

    private func hostDismissed() {
        guard presentation.isPresented else { return }
        cancelPermissionSetup(.onboarding)
        cancelTutorialIntroAdvance()
        stopTutorialSpeech()
        presentation.clear()
        setOnboardingNotchOverrideActive(false)
    }
}
