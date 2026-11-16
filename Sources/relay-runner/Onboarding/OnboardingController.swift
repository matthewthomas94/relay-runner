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
    var status: RelaySetupInstaller.Status { get }
    func install(for provider: GeneralConfig.AgentProvider?)
}

extension RelaySetupInstaller: OnboardingRuntimeInstalling {}

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
    private let makeSetupInstaller: () -> any OnboardingRuntimeInstalling
    private let runtimeAlreadyInstalled: (GeneralConfig.AgentProvider) -> Bool
    private let isAgentAuthenticated: (GeneralConfig.AgentProvider) -> Bool
    /// Rechecks readiness before `isAgentAuthenticated` is read and reports
    /// why the provider isn't ready. Claude's subscription gate is slow, so it
    /// answers asynchronously; the default answers at once with no detail.
    private let refreshAgentReadiness: (GeneralConfig.AgentProvider, @escaping (String?) -> Void) -> Void
    /// RR-513: sign-in runs in Relay Runner's embedded terminal. Terminal.app
    /// (`openAgentLoginInTerminal`) is only the fallback when that cannot start.
    private let makeProviderLogin: (GeneralConfig.AgentProvider) -> any ProviderLoginRunning
    private let openAgentLoginInTerminal: (GeneralConfig.AgentProvider) -> Bool
    private let onOpenExternalWindow: () -> Void
    private let runtimePollInterval: TimeInterval
    private let authPollInterval: TimeInterval
    private let introAdvanceDelay: TimeInterval
    private let loginPromptDwell: TimeInterval
    private let pickWorkspaceDirectory: (
        _ onPrepareExternalWindow: @escaping (@escaping () -> Void) -> Void,
        _ completion: @escaping (String?) -> Void
    ) -> Void
    private let reduceMotion: () -> Bool
    private let prepareTutorialSpeech: () -> Bool
    private let stopTutorialSpeech: () -> Void
    private let openWorkspaceAfterCompletion: () -> Void
    private let scheduleWorkspaceOpenAfterTutorialDismissal: (@escaping () -> Void) -> Void
    /// Speech-to-text model readiness. The Caps Lock loop runs only once the
    /// model has loaded, so the tutorial's intro waits for it.
    private let tutorialSpeechReadiness: () -> SetupRuntimeReadiness
    /// Nil turns the recording step's Caps Lock diagnostics off.
    private let tutorialRecordingProbe: (() -> OnboardingTutorialRecordingProbe)?
    private let toggleTutorialRecording: () -> Void
    private let retryTutorialSpeechSetup: () -> Void
    private let openTutorialSettings: (URL) -> Void
    private let tutorialRecordingCheckInterval: TimeInterval
    private let now: () -> Date
    private let diagnosticLog: (String) -> Void
    private let copyToPasteboard: (String) -> Void
    private var tutorialRecordingWatch: OnboardingTutorialRecordingWatch?
    private var tutorialRecordingHelp: OnboardingTutorialRecordingHelp?
    private var tutorialRecordingTimer: Timer?
    private var tutorialIntroSpeechWaitLogged = false
    private var freshPermissionState: FreshPermissionState?
    private var freshWorkspaceSelectionInFlight = false
    private var permissionGrantObserver: NSObjectProtocol?
    private var permissionEndedObserver: NSObjectProtocol?
    private var agentSetupState: AgentSetupState?
    private var setupInstaller: any OnboardingRuntimeInstalling
    private var runtimePollTimer: Timer?
    private var authPollTimer: Timer?
    private var appActivationObserver: NSObjectProtocol?
    private var providerLogin: (any ProviderLoginRunning)?
    private var forceWorkspaceSelectionAfterIntro = false
    private var tutorialState: TutorialState?
    private var tutorialIntroAdvance: DispatchWorkItem?
    private var workspaceOpenScheduled = false
    private var workspaceOpenedAfterTutorial = false
    private var tutorialWorkspaceHandoffInProgress = false
    private var externalHandoff: ExternalHandoff?
    private var externalHandoffObservers: [NSObjectProtocol] = []

    /// RR-514: onboarding has stepped aside for another app.
    private struct ExternalHandoff {
        /// Shows the step again when the person comes back. Nil when the
        /// step's own lifecycle decides what shows next (permission setup,
        /// the Terminal.app sign-in fallback).
        var restore: (() -> Void)?
        var surfaceHidden = false
        /// A return that arrived while the surface was still hiding.
        var pendingReturn: (() -> Void)?
        /// Relay Runner has been inactive since the hand-off began, so its
        /// next activation means the person came back.
        var leftApp = false
    }

    private struct FreshPermissionState {
        var activePermission: PermissionKind?
        var requestInFlight = false
        /// Attempts that came back without a grant. The next prompt for the
        /// same permission explains a managed Mac and offers to continue.
        var endedWithoutGrant: Set<PermissionKind> = []
        /// Optional permissions the user chose to continue without.
        var skipped: Set<PermissionKind> = []
        var itRequestCopied = false
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
         makeSetupInstaller: @escaping () -> any OnboardingRuntimeInstalling = { RelaySetupInstaller() },
         runtimeAlreadyInstalled: @escaping (GeneralConfig.AgentProvider) -> Bool = { RelaySetupInstaller.alreadyInstalled(for: $0) },
         isAgentAuthenticated: @escaping (GeneralConfig.AgentProvider) -> Bool = { AgentAuth.isAuthenticated(for: $0) },
         refreshAgentReadiness: @escaping (GeneralConfig.AgentProvider, @escaping (String?) -> Void) -> Void = { _, done in done(nil) },
         makeProviderLogin: @escaping (GeneralConfig.AgentProvider) -> any ProviderLoginRunning = { ProviderLoginTerminal(provider: $0) },
         openAgentLoginInTerminal: @escaping (GeneralConfig.AgentProvider) -> Bool = { AgentAuth.openLoginInTerminal(for: $0) },
         onOpenExternalWindow: @escaping () -> Void = {},
         runtimePollInterval: TimeInterval = 0.5,
         authPollInterval: TimeInterval = 1.0,
         introAdvanceDelay: TimeInterval = OnboardingFlowMotion.completedStepHold,
         loginPromptDwell: TimeInterval = OnboardingPromptTiming.agentLoginDwell,
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
         scheduleWorkspaceOpenAfterTutorialDismissal: @escaping (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: action)
         },
         openWorkspaceAfterCompletion: @escaping () -> Void = {},
         tutorialSpeechReadiness: @escaping () -> SetupRuntimeReadiness = { .ready },
         tutorialRecordingProbe: (() -> OnboardingTutorialRecordingProbe)? = nil,
         toggleTutorialRecording: @escaping () -> Void = {},
         retryTutorialSpeechSetup: @escaping () -> Void = {},
         openTutorialSettings: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         tutorialRecordingCheckInterval: TimeInterval = 0.5,
         now: @escaping () -> Date = Date.init,
         diagnosticLog: @escaping (String) -> Void = RelayUnifiedLog.sink(category: "Onboarding"),
         copyToPasteboard: @escaping (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
         }) {
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
        self.makeSetupInstaller = makeSetupInstaller
        self.setupInstaller = makeSetupInstaller()
        self.runtimeAlreadyInstalled = runtimeAlreadyInstalled
        self.isAgentAuthenticated = isAgentAuthenticated
        self.refreshAgentReadiness = refreshAgentReadiness
        self.makeProviderLogin = makeProviderLogin
        self.openAgentLoginInTerminal = openAgentLoginInTerminal
        self.onOpenExternalWindow = onOpenExternalWindow
        self.runtimePollInterval = runtimePollInterval
        self.authPollInterval = authPollInterval
        self.introAdvanceDelay = introAdvanceDelay
        self.loginPromptDwell = loginPromptDwell
        self.pickWorkspaceDirectory = pickWorkspaceDirectory
        self.reduceMotion = reduceMotion
        self.prepareTutorialSpeech = prepareTutorialSpeech
        self.stopTutorialSpeech = stopTutorialSpeech
        self.scheduleWorkspaceOpenAfterTutorialDismissal = scheduleWorkspaceOpenAfterTutorialDismissal
        self.openWorkspaceAfterCompletion = openWorkspaceAfterCompletion
        self.tutorialSpeechReadiness = tutorialSpeechReadiness
        self.tutorialRecordingProbe = tutorialRecordingProbe
        self.toggleTutorialRecording = toggleTutorialRecording
        self.retryTutorialSpeechSetup = retryTutorialSpeechSetup
        self.openTutorialSettings = openTutorialSettings
        self.tutorialRecordingCheckInterval = tutorialRecordingCheckInterval
        self.now = now
        self.diagnosticLog = diagnosticLog
        self.copyToPasteboard = copyToPasteboard
    }

    deinit {
        removeExternalHandoffObservers()
        removeFreshPermissionObservers()
        stopRuntimePolling()
        stopAuthPolling()
        providerLogin?.cancel()
        cancelTutorialIntroAdvance()
        stopTutorialRecordingWatch()
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
        if !wasInterruptedBeforeStart {
            // A resume step without the started flag belongs to an earlier
            // install whose app files were reset (RR-517). Honouring it skipped
            // voice setup and opened the tutorial at "Turn Caps Lock on".
            OnboardingResumeState.clear()
        }
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
        guard !OnboardingResumeState.permissionsSkipped else {
            completeFreshPermissionSequence()
            return
        }
        installFreshPermissionObservers()
        showNextFreshPermission()
    }

    private func showNextFreshPermission() {
        guard let intro = introController else { return }
        // Showing a permission step means any earlier hand-off is over.
        cancelExternalHandoff()
        guard let permission = firstMissingFreshPermission() else {
            completeFreshPermissionSequence()
            return
        }
        var state = freshPermissionState ?? FreshPermissionState()
        if state.activePermission != permission { state.itRequestCopied = false }
        state.activePermission = permission
        state.requestInFlight = false
        freshPermissionState = state
        var prompt = OnboardingPermissionTreatment.presentation(
            permission: permission,
            status: permissionStatus(permission),
            explanation: OnboardingPermissionTreatment.explanation(for: permission),
            likelyRestricted: permissionLikelyRestricted(permission)
        )
        var managedActions: OnboardingPermissionManagedActions?
        if OnboardingPermissionTreatment.canContinueWithout(permission),
           state.endedWithoutGrant.contains(permission) {
            prompt.managedNotice = OnboardingPermissionTreatment.managedNotice(
                for: permission,
                itRequestCopied: state.itRequestCopied
            )
            prompt.continueTitle = OnboardingPermissionTreatment.continueWithoutTitle(for: permission)
            managedActions = OnboardingPermissionManagedActions(
                copyITRequest: { [weak self] in self?.copyManagedPermissionRequest(permission) },
                continueWithout: { [weak self] in self?.continueWithoutFreshPermission(permission) }
            )
        }
        intro.presentPermissionPrompt(
            prompt,
            action: { [weak self] in self?.startFreshPermissionSetup(permission) },
            skipAction: { [weak self] in self?.skipFreshPermissions() },
            managedActions: managedActions
        )
    }

    /// RR-514: Skip on a permission step moves past every permission. The
    /// skip is kept in the resume state so a relaunch does not bring them
    /// back; each one can still be granted later from Settings.
    private func skipFreshPermissions() {
        guard freshPermissionState != nil else { return }
        diagnosticLog("[Onboarding] permissions skipped")
        cancelPermissionSetup(.onboarding)
        cancelExternalHandoff()
        OnboardingResumeState.markPermissionsSkipped()
        completeFreshPermissionSequence()
    }

    private func copyManagedPermissionRequest(_ permission: PermissionKind) {
        guard freshPermissionState?.activePermission == permission else { return }
        copyToPasteboard(ManagedPermissionRequest.text())
        freshPermissionState?.itRequestCopied = true
        diagnosticLog("[OnboardingPermissions] copied IT request permission=\(permission.rawValue)")
        showNextFreshPermission()
    }

    private func continueWithoutFreshPermission(_ permission: PermissionKind) {
        guard freshPermissionState?.activePermission == permission,
              OnboardingPermissionTreatment.canContinueWithout(permission) else { return }
        freshPermissionState?.skipped.insert(permission)
        diagnosticLog("[OnboardingPermissions] continued without permission=\(permission.rawValue)")
        showNextFreshPermission()
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
        // Permission setup brings the step back itself: a grant shows the
        // next permission, and setup that ends without one shows this again.
        handOffToExternalApp(restore: nil, open: request)
    }

    private func firstMissingFreshPermission() -> PermissionKind? {
        let skipped = freshPermissionState?.skipped ?? []
        return PermissionKind.guidedSetupOrder.first {
            permissionStatus($0) != .granted && !skipped.contains($0)
        }
    }

    private func freshPermissionGranted(_ permission: PermissionKind) {
        guard freshPermissionState?.activePermission == permission else { return }
        freshPermissionState?.requestInFlight = false
        freshPermissionState?.activePermission = nil
        endExternalHandoff { [weak self] in self?.showNextFreshPermission() }
    }

    private func freshPermissionEndedWithoutGrant(_ event: PermissionSetupLifecycleEvent) {
        guard event.source == .onboarding,
              freshPermissionState?.activePermission == event.permission else { return }
        freshPermissionState?.requestInFlight = false
        freshPermissionState?.endedWithoutGrant.insert(event.permission)
        diagnosticLog(
            "[OnboardingPermissions] setup ended without grant permission=\(event.permission.rawValue) " +
            "status=\(permissionStatus(event.permission))"
        )
        endExternalHandoff { [weak self] in self?.showNextFreshPermission() }
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

    // MARK: - External hand-offs (RR-514)

    /// The one way onboarding sends the person to another app or the browser:
    /// sign-in, a permission's System Settings pane, a tutorial fix in System
    /// Settings and the Terminal.app sign-in fallback all come through here.
    /// The onboarding surface and the Workspace step aside first (Relay Runner
    /// keeps running), then `open` runs. The same step comes back when the
    /// person returns: `restore` runs on Relay Runner's next activation or a
    /// Dock click. With no `restore`, the step's own lifecycle brings it back
    /// through `endExternalHandoff`.
    private func handOffToExternalApp(restore: (() -> Void)?, open: @escaping () -> Void) {
        guard externalHandoff == nil else {
            // Already stepped aside; another link from the same step.
            open()
            return
        }
        externalHandoff = ExternalHandoff(restore: restore, leftApp: !(NSApp?.isActive ?? false))
        if restore != nil {
            installExternalHandoffObservers()
        }
        let proceed: () -> Void = { [weak self] in
            guard let self else { return }
            self.externalHandoff?.surfaceHidden = true
            self.onOpenExternalWindow()
            open()
            if let pending = self.externalHandoff?.pendingReturn {
                self.endExternalHandoff(then: pending)
            }
        }
        if let intro = introController {
            intro.dismiss(completion: proceed)
        } else {
            proceed()
        }
    }

    /// The person is back, or the step's lifecycle has moved on. Runs `next`
    /// (by default the hand-off's `restore`) once the surface has finished
    /// stepping aside; with no hand-off it runs `next` at once.
    private func endExternalHandoff(then next: (() -> Void)? = nil) {
        guard let handoff = externalHandoff else {
            next?()
            return
        }
        let action = next ?? handoff.restore ?? {}
        guard handoff.surfaceHidden else {
            externalHandoff?.pendingReturn = action
            return
        }
        cancelExternalHandoff()
        action()
    }

    private func cancelExternalHandoff() {
        externalHandoff = nil
        removeExternalHandoffObservers()
    }

    private func installExternalHandoffObservers() {
        removeExternalHandoffObservers()
        let center = NotificationCenter.default
        externalHandoffObservers = [
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: NSApp,
                queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.externalHandoff?.leftApp = true }
            },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApp,
                queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.externalHandoff?.leftApp == true else { return }
                    self.endExternalHandoff()
                }
            },
        ]
    }

    private func removeExternalHandoffObservers() {
        externalHandoffObservers.forEach(NotificationCenter.default.removeObserver)
        externalHandoffObservers = []
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
        case .voiceSetup:
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
        setupInstaller = makeSetupInstaller()
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
            step: .voiceSetup,
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        setupInstaller.install(for: state.provider)
        intro.presentRuntimePrompt(
            OnboardingRuntimePromptPresentation(
                provider: state.provider,
                status: setupInstaller.status
            ),
            retryAction: { [weak self] in self?.retryIntroRuntimePreparation() }
        )
        startRuntimePolling(provider: state.provider)
    }

    private func retryIntroRuntimePreparation() {
        setupInstaller = makeSetupInstaller()
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
                status: setupInstaller.status
            ),
            retryAction: { [weak self] in self?.retryIntroRuntimePreparation() }
        )
        switch setupInstaller.status {
        case .succeeded:
            stopRuntimePolling()
            let delay = reduceMotion() ? 0 : introAdvanceDelay
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
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

    private func showIntroAgentLogin(message: String?, retry: Bool = false) {
        guard let state = agentSetupState,
              introController != nil else { return }
        stopRuntimePolling()
        OnboardingResumeState.save(
            step: .agentLogin,
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        refreshAgentReadiness(state.provider) { [weak self] detail in
            self?.presentIntroAgentLogin(provider: state.provider, message: message ?? detail, retry: retry)
        }
    }

    private func presentIntroAgentLogin(
        provider: GeneralConfig.AgentProvider,
        message: String?,
        retry: Bool = false
    ) {
        guard let state = agentSetupState,
              state.provider == provider,
              providerLogin == nil,
              let intro = introController else { return }
        let signedIn = isAgentAuthenticated(state.provider)
        // RR-514: a reason shows only after an attempt fails; the first
        // view of the step is just its title, subtitle and actions.
        intro.presentAgentLoginPrompt(
            OnboardingAgentLoginPromptPresentation(
                provider: state.provider,
                signedIn: signedIn,
                message: signedIn || !retry ? nil : message,
                retry: !signedIn && retry
            ),
            fullyRendered: { [weak self] in
                guard signedIn else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + (self?.loginPromptDwell ?? 0)) {
                    guard let self,
                          self.agentSetupState?.provider == state.provider,
                          self.isAgentAuthenticated(state.provider) else { return }
                    self.completeAuthenticatedProvider(state.provider, introDismissed: false)
                }
            },
            signInAction: { [weak self] in self?.startIntroAgentLogin() },
            continueWithoutSignInAction: Self.allowsContinueWithoutSignIn(state.provider)
                ? { [weak self] in self?.continueIntroWithoutSignIn() }
                : nil
        )
    }

    /// "Sign in later" (RR-514) finishes app setup unsigned for either
    /// provider. Claude sessions stay unavailable until the subscription gate
    /// verifies the account; Codex asks for its sign-in when a session starts.
    static func allowsContinueWithoutSignIn(_ provider: GeneralConfig.AgentProvider) -> Bool {
        true
    }

    private func continueIntroWithoutSignIn() {
        guard let state = agentSetupState else { return }
        stopAuthPolling()
        completeAuthenticatedProvider(state.provider, introDismissed: false)
    }

    private func startIntroAgentLogin() {
        guard let state = agentSetupState,
              providerLogin == nil,
              introController != nil else { return }
        OnboardingResumeState.save(
            step: .agentLogin,
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        let login = makeProviderLogin(state.provider)
        providerLogin = login
        login.onBrowserHandoff = { [weak self, weak login] open in
            guard let self, let login, self.providerLogin === login else {
                open?()
                return
            }
            self.handOffToExternalApp(
                restore: { [weak self, weak login] in
                    guard let self, let login, self.providerLogin === login else { return }
                    self.presentLoginTerminal(login)
                },
                open: open ?? {}
            )
        }
        do {
            try login.start { [weak self, weak login] outcome in
                guard let self, let login, self.providerLogin === login else { return }
                self.providerLogin = nil
                self.finishInAppLogin(provider: state.provider, outcome: outcome)
            }
        } catch {
            providerLogin = nil
            startTerminalAppLogin(provider: state.provider)
            return
        }
        // A login that already ended has shown its own result.
        guard providerLogin === login else { return }
        presentLoginTerminal(login)
    }

    private func presentLoginTerminal(_ login: any ProviderLoginRunning) {
        introController?.presentAgentLoginTerminal(login) { [weak self, weak login] in
            guard let login, self?.providerLogin === login else { return }
            login.cancel()
        }
    }

    /// The login process has exited: recheck readiness at once and continue,
    /// or say why not and offer Try again.
    private func finishInAppLogin(provider: GeneralConfig.AgentProvider, outcome: ProviderLoginOutcome) {
        guard agentSetupState?.provider == provider else { return }
        refreshAgentReadiness(provider) { [weak self] detail in
            guard let self,
                  self.providerLogin == nil,
                  self.agentSetupState?.provider == provider else { return }
            // The login has ended, so the step comes back with its result.
            self.endExternalHandoff { [weak self] in
                self?.showInAppLoginResult(provider: provider, outcome: outcome, detail: detail)
            }
        }
    }

    private func showInAppLoginResult(
        provider: GeneralConfig.AgentProvider,
        outcome: ProviderLoginOutcome,
        detail: String?
    ) {
        guard agentSetupState?.provider == provider else { return }
        if outcome != .cancelled, isAgentAuthenticated(provider) {
            completeAuthenticatedProvider(provider, introDismissed: false)
            return
        }
        presentIntroAgentLogin(
            provider: provider,
            message: Self.inAppLoginFailureMessage(provider: provider, outcome: outcome, detail: detail),
            retry: true
        )
    }

    static func inAppLoginFailureMessage(
        provider: GeneralConfig.AgentProvider,
        outcome: ProviderLoginOutcome,
        detail: String?
    ) -> String {
        let name = provider.displayName
        let reason: String?
        switch outcome {
        case .cancelled:
            reason = "\(name) sign-in was canceled."
        case .exited(0):
            reason = nil
        case .exited(let status?):
            reason = "\(name) sign-in exited with code \(status)."
        case .exited(nil):
            reason = "\(name) sign-in stopped before it finished."
        }
        let fallback = "\(name) sign-in finished, but Relay Runner could not confirm that you are signed in."
        return [reason, detail ?? (reason == nil ? fallback : nil)]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Fallback for when the embedded terminal cannot start: the earlier
    /// Terminal.app sign-in, which brings Relay Runner back when it exits.
    private func startTerminalAppLogin(provider: GeneralConfig.AgentProvider) {
        // Auth polling and Terminal's own return bring the step back.
        handOffToExternalApp(restore: nil) { [weak self] in
            guard let self else { return }
            self.setOnboardingNotchOverrideActive(false)
            guard self.openAgentLoginInTerminal(provider) else {
                self.restoreIntroAgentLogin(
                    provider: provider,
                    message: "Could not open Terminal for \(provider.displayName) sign-in."
                )
                return
            }
            self.startAuthPolling(provider: provider)
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
        refreshAgentReadiness(provider) { [weak self] _ in
            guard let self,
                  self.authPollTimer != nil,
                  self.agentSetupState?.provider == provider,
                  self.isAgentAuthenticated(provider) else { return }
            self.stopAuthPolling()
            self.endExternalHandoff { [weak self] in
                self?.completeAuthenticatedProvider(provider, introDismissed: true)
            }
        }
    }

    /// A Dock click while onboarding waits on another app: sign-in, or a
    /// tutorial fix in System Settings. When Relay Runner is already active no
    /// activation notification fires, so this is the other way back to the
    /// step. Returns false when onboarding isn't waiting.
    @discardableResult
    func resumeAgentLoginIfWaiting() -> Bool {
        if externalHandoff?.restore != nil {
            endExternalHandoff()
            return true
        }
        guard authPollTimer != nil, let provider = agentSetupState?.provider else { return false }
        restoreLoginIfAuthenticationDidNotComplete(provider: provider)
        return true
    }

    private func restoreLoginIfAuthenticationDidNotComplete(provider: GeneralConfig.AgentProvider) {
        refreshAgentReadiness(provider) { [weak self] detail in
            guard let self,
                  self.authPollTimer != nil,
                  self.agentSetupState?.provider == provider,
                  !self.isAgentAuthenticated(provider) else { return }
            self.stopAuthPolling()
            self.restoreIntroAgentLogin(
                provider: provider,
                message: detail
                    ?? "\(provider.displayName) sign-in did not complete. Try again when you are ready."
            )
        }
    }

    private func restoreIntroAgentLogin(provider: GeneralConfig.AgentProvider, message: String) {
        guard agentSetupState?.provider == provider else { return }
        endExternalHandoff { [weak self] in
            guard let self else { return }
            self.setOnboardingNotchOverrideActive(true)
            if self.introController == nil {
                self.introController = self.makeIntroController()
            }
            self.showIntroAgentLogin(message: message, retry: true)
        }
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
        if screen == .intro {
            workspaceOpenScheduled = false
            workspaceOpenedAfterTutorial = false
            tutorialWorkspaceHandoffInProgress = false
        }
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

        if safeScreen == .recording, !tutorialSpeechReadiness().isReady {
            // A relaunch resumes here while the model is still loading, and
            // Caps Lock does nothing until it has. Wait like the intro does.
            diagnosticLog("[OnboardingTutorial] resumed recording step waits for speech")
            tutorialIntroSpeechWaitLogged = false
            advanceTutorialIntroWhenSpeechReady(provider: provider)
            return
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
        if screen != .recording {
            stopTutorialRecordingWatch()
        }
        OnboardingResumeState.save(
            step: OnboardingSessionControlsTutorial.resumeID(for: screen),
            provider: state.provider,
            parentPermissionsReviewed: true
        )
        diagnosticLog("[OnboardingTutorial] screen=\(screen.rawValue)")
        let help = screen == .recording ? tutorialRecordingHelp : nil
        intro.presentTutorial(
            OnboardingTutorialPresentation(
                screen: screen,
                reduceMotion: reduceMotion(),
                message: message,
                recordingHelp: help
            ),
            retryAction: { [weak self] in
                guard let self else { return }
                if case .failed = self.tutorialSpeechReadiness() {
                    self.diagnosticLog("[OnboardingTutorial] retrying speech setup")
                    self.retryTutorialSpeechSetup()
                }
                self.beginSessionControlsTutorial(screen: .intro)
            },
            recordingActions: recordingActions(for: screen, help: help),
            skipAction: { [weak self] in self?.skipSessionControlsTutorial() }
        )
        if screen == .recording {
            startTutorialRecordingWatchIfNeeded()
        }
    }

    private func recordingActions(
        for screen: OnboardingTutorialScreen,
        help: OnboardingTutorialRecordingHelp?
    ) -> OnboardingTutorialRecordingActions? {
        guard screen == .recording || screen == .recordingActive else { return nil }
        let fixAction: (() -> Void)? = help?.fix.map { fix in
            { [weak self] in self?.performTutorialRecordingFix(fix) }
        }
        return OnboardingTutorialRecordingActions(
            toggleRecording: { [weak self] in
                self?.diagnosticLog("[OnboardingTutorial] click fallback toggled recording screen=\(screen.rawValue)")
                self?.toggleTutorialRecording()
            },
            fix: fixAction
        )
    }

    private func performTutorialRecordingFix(_ fix: OnboardingTutorialRecordingHelp.Fix) {
        diagnosticLog("[OnboardingTutorial] recording fix=\(fix.title)")
        switch fix {
        case .retrySpeechSetup:
            retryTutorialSpeechSetup()
        case .openSettings(let pane):
            handOffToExternalApp(
                restore: { [weak self] in self?.restoreTutorialScreen() },
                open: { [weak self] in self?.openTutorialSettings(pane.url) }
            )
        }
    }

    /// Shows the tutorial screen the person left from (or has since reached).
    private func restoreTutorialScreen() {
        guard tutorialState != nil,
              let step = OnboardingResumeState.load()?.step,
              let screen = OnboardingSessionControlsTutorial.screen(for: step) else { return }
        presentTutorial(screen: screen)
    }

    /// RR-514: Skip on a tutorial step ends the tutorial and opens the
    /// Workspace, the same way finishing its last step does. Finishing marks
    /// onboarding complete, so a relaunch does not return to the tutorial.
    private func skipSessionControlsTutorial() {
        guard tutorialState != nil, !tutorialWorkspaceHandoffInProgress else { return }
        diagnosticLog("[OnboardingTutorial] skipped")
        tutorialWorkspaceHandoffInProgress = true
        finish { [weak self] in
            self?.scheduleWorkspaceOpenAfterTutorialDismissalOnce()
        }
    }

    private func startTutorialRecordingWatchIfNeeded() {
        guard tutorialRecordingWatch == nil,
              let probe = tutorialRecordingProbe?() else { return }
        tutorialRecordingWatch = OnboardingTutorialRecordingWatch(startedAt: now(), baseline: probe)
        diagnosticLog("[OnboardingTutorial] recording watch started \(probe.logSummary)")
        let timer = Timer(timeInterval: tutorialRecordingCheckInterval, repeats: true) { [weak self] _ in
            self?.checkTutorialRecording()
        }
        RunLoop.main.add(timer, forMode: .common)
        tutorialRecordingTimer = timer
    }

    private func stopTutorialRecordingWatch() {
        tutorialRecordingTimer?.invalidate()
        tutorialRecordingTimer = nil
        tutorialRecordingWatch = nil
        tutorialRecordingHelp = nil
    }

    /// One diagnostic tick on the recording step; the timer drives it.
    func checkTutorialRecording() {
        guard var watch = tutorialRecordingWatch,
              OnboardingResumeState.load()?.step == .tutorialRecording,
              let probe = tutorialRecordingProbe?() else { return }
        let hadPress = watch.firstPressAt != nil
        let symptom = watch.observe(probe, now: now())
        tutorialRecordingWatch = watch
        if !hadPress, watch.firstPressAt != nil {
            diagnosticLog("[OnboardingTutorial] Caps Lock activity seen; waiting for recording to start")
        }
        guard let symptom else { return }
        let help = OnboardingTutorialRecordingHelp.diagnose(symptom, probe: probe)
        guard help != tutorialRecordingHelp else { return }
        tutorialRecordingHelp = help
        diagnosticLog(
            "[OnboardingTutorial] recording help symptom=\(symptom.rawValue) " +
            "reason=\(help.reason.rawValue) \(probe.logSummary)"
        )
        // Away in System Settings, the new help shows when the step returns.
        guard externalHandoff == nil else { return }
        presentTutorial(screen: .recording)
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
            self.advanceTutorialIntroWhenSpeechReady(provider: provider)
        }
        tutorialIntroAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Caps Lock does nothing until the speech model has loaded, which on a
    /// fresh install includes downloading it, so hold the intro until then.
    private func advanceTutorialIntroWhenSpeechReady(provider: GeneralConfig.AgentProvider) {
        switch tutorialSpeechReadiness() {
        case .ready:
            tutorialIntroSpeechWaitLogged = false
            presentTutorial(screen: .recording)
        case .failed:
            tutorialIntroSpeechWaitLogged = false
            diagnosticLog("[OnboardingTutorial] speech setup failed before the recording step")
            presentTutorial(
                screen: .sessionRetry,
                message: "Speech recognition couldn't start, so Caps Lock can't record yet. Retry to set it up again."
            )
        case .preparing, .notStarted:
            if !tutorialIntroSpeechWaitLogged {
                tutorialIntroSpeechWaitLogged = true
                diagnosticLog("[OnboardingTutorial] waiting for speech model before the recording step")
                presentTutorial(screen: .intro, message: Self.tutorialSpeechPreparingMessage)
            }
            scheduleTutorialIntroAdvance(provider: provider, after: tutorialRecordingCheckInterval)
        }
    }

    static let tutorialSpeechPreparingMessage =
        "Getting speech recognition ready. The first time can take a few minutes."

    private func cancelTutorialIntroAdvance() {
        tutorialIntroAdvance?.cancel()
        tutorialIntroAdvance = nil
    }

    var isAwaitingTutorialWorkspaceToggle: Bool {
        OnboardingResumeState.load()?.step == .tutorialWorkspace
    }

    var shouldConsumeWorkspaceToggleRequest: Bool {
        isAwaitingTutorialWorkspaceToggle || tutorialWorkspaceHandoffInProgress
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
        guard OnboardingResumeState.load()?.step == .tutorialWorkspace,
              !tutorialWorkspaceHandoffInProgress else { return }
        tutorialWorkspaceHandoffInProgress = true
        finish { [weak self] in
            self?.scheduleWorkspaceOpenAfterTutorialDismissalOnce()
        }
    }

    private func scheduleWorkspaceOpenAfterTutorialDismissalOnce() {
        guard !workspaceOpenScheduled else { return }
        workspaceOpenScheduled = true
        scheduleWorkspaceOpenAfterTutorialDismissal { [self] in
            guard !workspaceOpenedAfterTutorial else { return }
            self.workspaceOpenedAfterTutorial = true
            self.openWorkspaceAfterCompletion()
            self.tutorialWorkspaceHandoffInProgress = false
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
        if previousGate != state.recordingGate {
            diagnosticLog(
                "[OnboardingTutorial] recording gate \(previousGate) -> \(state.recordingGate) event=\(event)"
            )
        }
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
        cancelExternalHandoff()
        stopRuntimePolling()
        stopAuthPolling()
        providerLogin?.cancel()
        cancelTutorialIntroAdvance()
        stopTutorialRecordingWatch()
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
        cancelExternalHandoff()
        cancelPermissionSetup(.onboarding)
        cancelTutorialIntroAdvance()
        stopTutorialRecordingWatch()
        stopTutorialSpeech()
        presentation.clear()
        setOnboardingNotchOverrideActive(false)
    }
}
