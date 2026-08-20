import AppKit
import Foundation
import QuartzCore
import SwiftUI

@Observable
final class AppState {
    enum ContinuityRecoveryComponentAction: Equatable {
        case restartSpeechCapture
        case restartTranscriptionDelivery
        case recoverBridge
        case restartDaemon
        case releaseForegroundProviderOwnership
        case launchForegroundProvider
    }

    enum ContinuityRecoveryDecision: Equatable {
        case apply(ContinuityRecoveryComponentAction)
        case reject(String)
    }

    struct ContinuityRecoveryBoundary: Equatable {
        let currentSessionID: String
        let currentRecoveryGeneration: String
        let currentCommandID: String?
        let provider: String
        let liveWorkActive: Bool
        let providerProcessRunning: Bool
        let bridgeAlive: Bool
        let idempotencyAlreadyApplied: Bool
        let cooldownActive: Bool
    }

    enum SessionLaunchDestination: Equatable {
        case embedded
        case externalTerminal
    }

    struct SessionLaunchRequest: Equatable {
        let config: AppConfig
        let destination: SessionLaunchDestination
    }

    struct LaunchPlan: Equatable {
        let startsOverlay: Bool
        let startsAwareness: Bool
        let statusText: String?
    }

    struct NotchPresentation: Equatable {
        let status: NotchSessionStatus
        let activityLabels: [String]
        let workingProgressLabel: String?
    }

    struct BridgeRecoveryFailurePresentation: Equatable {
        let statusText: String
        let title: String
        let body: String
    }

    struct ProgramStatusPresentation: Equatable {
        let statusText: String
        let title: String
        let body: String
    }

    private struct BridgeWatchdogSample {
        let daemonAlive: Bool
        let consumerAlive: Bool
        let hasSessionContext: Bool
        let pendingDeliveryState: ProcessManager.PendingVoiceCommandDeliveryState
        let stopRequested: Bool
    }

    var config: AppConfig
    var isRunning = false
    var statusText = "Idle"
    private(set) var isFirstRunExperienceActive = false

    private(set) var sttEngine: STTEngine?
    @ObservationIgnored private let checkForUpdatesAction: @MainActor () -> Void
    @ObservationIgnored private let refreshBundledOrchestratorDaemon: () async -> OrchestratorDaemonRefreshResult
    @ObservationIgnored private let refreshBundledServicesOnLaunch: Bool
    @ObservationIgnored private let sleepPreventionController = SleepPreventionController()
    @ObservationIgnored private let workspaceActivityStore = WorkspaceActivitySnapshotStore()
    @ObservationIgnored private var workspaceActivityTimer: Timer?
    @ObservationIgnored private var workspaceActivityTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceActivityRefreshID = 0
    @ObservationIgnored private var workspaceDiscoveryTask: Task<Void, Never>?
    @ObservationIgnored private var sleepPreventionMonitoringActive = false
    @ObservationIgnored private var appTerminationObserver: NSObjectProtocol?

    var serviceLifecycleMessage: String?

    /// Populated when STTEngine.start() throws — surfaces a human-readable
    /// failure in the menu bar with a Retry Setup action. Nil when STT is
    /// healthy or still loading.
    private(set) var sttEngineError: String?
    private var sttSetupStartedAt: Date?
    private var sttSetupSucceeded = false

    /// Shared finite STT setup state for Settings and onboarding. Preparing
    /// status is allowed to be temporary only; success becomes Loaded and
    /// listening, while errors and timeouts become retryable failures.
    var setupRuntimeReadiness: SetupRuntimeReadiness {
        Self.setupRuntimeReadiness(
            engineStatusMessage: sttEngine?.statusMessage,
            engineError: sttEngineError,
            setupSucceeded: sttSetupSucceeded,
            startedAt: sttSetupStartedAt
        )
    }

    /// Translated version of `sttEngineError`, suitable for direct display.
    var sttEngineErrorTranslation: ErrorTranslator.Translation? {
        sttEngineError.map { ErrorTranslator.translate($0) }
    }

    let configManager = ConfigManager.shared
    let processManager = ProcessManager()
    let embeddedTerminal = EmbeddedTerminalSession()
    let permissions = PermissionsManager()
    // @ObservationIgnored: @Observable's macro expansion doesn't compose with
    // `lazy`. The controller is stateless from the UI's perspective — views
    // observe PermissionsManager directly — so hiding it from observation
    // costs nothing.
    @ObservationIgnored lazy var onboarding: OnboardingController = {
        OnboardingController(
            permissions: permissions,
            getWorkingDirectory: { [weak self] in self?.config.general.working_directory ?? "" },
            getAgentProvider: { [weak self] in self?.config.general.provider ?? .codex },
            setAgentProvider: { [weak self] provider in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.selectProvider(provider)
                self.saveConfig(newConfig)
            },
            setWorkingDirectory: { [weak self] path in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.working_directory = path
                self.saveConfig(newConfig, forceWorkspaceDiscovery: true)
            },
            usesProjectRegistryV2: ProjectRegistryV2Rollout.isEnabled(),
            setOnboardingNotchOverrideActive: { [weak self] active in
                self?.setOnboardingNotchOverrideActive(active)
            },
            setFirstRunExperienceActive: { [weak self] active in
                self?.setFirstRunExperienceActive(active)
            },
            requestPermissionSetup: { [weak self] kind, source, purpose in
                self?.requestPermissionSetup(kind, source: source, purpose: purpose)
            },
            cancelPermissionSetup: { [weak self] source in
                self?.cancelPermissionSetup(source: source)
            },
            shouldDeferPermissionAdvance: { [weak self] kind in
                self?.permissionSetupCoordinator.shouldDeferAutoAdvance(for: kind) ?? false
            },
            onOpenExternalWindow: { [weak self] in
                self?.suspendWorkspaceForExternalWindow()
            },
            prepareTutorialSpeech: { [weak self] in
                self?.prepareOnboardingTutorialSpeech() ?? false
            },
            stopTutorialSpeech: { [weak self] in
                self?.stopOnboardingTutorialSpeech()
            },
            openWorkspaceAfterCompletion: { [weak self] in
                self?.showWorkspaceWork()
            }
        )
    }()
    @ObservationIgnored private let permissionNotifier = PermissionNotifier()
    @ObservationIgnored private let permissionRelaunchGuard = PermissionRelaunchGuard()
    @ObservationIgnored private lazy var permissionSetupCoordinator = PermissionSetupCoordinator(
        permissions: permissions,
        setSetupNotchState: { [weak self] state in
            self?.setPermissionSetupNotchState(state)
        },
        prepareForExternalWindow: { [weak self] permission in
            self?.prepareForPermissionExternalWindow(permission)
        }
    )

    /// One-shot wizard that fires when MCP detects a not-yet-onboarded
    /// parent terminal/IDE. AppState owns the controller; the bus calls into
    /// it via the closures wired in `startOverlay`. @ObservationIgnored
    /// because the controller's window lifecycle is imperative — UI doesn't
    /// observe it directly.
    @ObservationIgnored private let parentOnboardingController = ParentOnboardingController()

    // Phase 2: Awareness overlay
    let stateMachine = StateMachine()
    private var overlayController: OverlayController?
    @ObservationIgnored private let programBoardOverlay = ProgramBoardOverlayController()
    @ObservationIgnored private let notchStatusController = NotchStatusController()
    private var perimeterOverlay: PerimeterOverlayManager?
    private var eventBus: StateEventBus?
    private var actionsBus: ActionsConfirmBus?
    private var sttPollTimer: Timer?
    private var notchActivityPollingActive = false
    private var notchActivityRunStates: [RunState] = []
    private var notchActivityTickets: [Ticket] = []
    private var notchActivityTicketsByRunKey: [String: Ticket] = [:]
    private var workspaceActivitySnapshot = WorkspaceActivitySnapshot.empty
    private var onboardingNotchOverrideActive = false
    private var permissionSetupNotchState: PermissionSetupNotchState?
    private var bridgeWatchdog: Timer?
    private var bridgeWatchdogTask: Task<Void, Never>?
    private var programStatusTask: Task<Void, Never>?
    /// True while a menu-started terminal session owns the bridge.
    private var menuSessionActive = false {
        didSet { syncNotchStatusSurface() }
    }
    @ObservationIgnored private var activeSessionLaunchConfig: AppConfig?
    @ObservationIgnored private var continuityRecoveryGenerationBySession: [String: String] = [:]
    @ObservationIgnored private var appliedContinuityRecoveryKeys: Set<String> = []
    @ObservationIgnored private var continuityRecoveryCooldowns: [String: CFTimeInterval] = [:]
    @ObservationIgnored private let projectRegistryV2 = ProjectRegistryV2Service.makeIfEnabled()
    @ObservationIgnored private let projectScopeCoordinator = ProjectScopeCoordinator()
    @ObservationIgnored private var activeSessionProjectScopeToken: ConfirmedProjectScopeToken?
    /// Cached by the watchdog so the 20fps poll timer avoids spawning pgrep.
    private var bridgeAliveCache = false {
        didSet { syncNotchStatusSurface() }
    }
    private var wasRecording = false
    private var observedRecordingStartedSerial = 0
    private var observedSpeechDetectedSerial = 0
    private var observedDeliveredTranscriptSerial = 0
    private var observedTutorialTranscriptSerial = 0
    /// Caps Lock state when the session prompt was shown — any toggle dismisses it.
    private var sessionPromptCapsState = false
    private var sessionPromptGate = SessionPromptGate()
    /// Grace period: don't let the watchdog revert a session before the bridge has time to start.
    private var sessionStartTime: Date = .distantPast
    /// Has the bridge for the current menu-started session been observed alive at least once?
    /// Used to distinguish "still starting up" from "came up and then died".
    private var sessionBridgeSeen = false {
        didSet {
            guard oldValue != sessionBridgeSeen else { return }
            syncNotchStatusSurface()
        }
    }
    private var sessionReadyShownForCurrentBridgeSession = false
    /// Session-level contract shared by the bridge and app overlay. Tutorial
    /// sessions suppress both greeting sources, including after recovery.
    private var activeSessionSuppressesStartupGreeting = false
    private var bridgeRecoveryInFlight = false {
        didSet { syncNotchStatusSurface() }
    }
    private var programBoardLoading = false
    private var lastBridgeRecoveryAt: Date = .distantPast
    private static let bridgeRecoveryCooldown: TimeInterval = 15
    private var bridgeRecoverySuppressedForUpdate = false
    @ObservationIgnored private var updateRelaunchObserver: NSObjectProtocol?
    /// Per-bridge-session flag for the per-parent permissions wizard. False at
    /// startup and after any bridge death; flipped true once the watchdog has
    /// either surfaced the wizard for this session or confirmed the parent is
    /// already onboarded. Without this, the watchdog's per-tick retry (needed
    /// to handle MCP's `parent_detected` arriving after the bridge transition)
    /// would re-open the wizard window every 3s while it's dismissed.
    private var wizardShownForCurrentBridgeSession = false

    /// Whether any voice session is active (for menu bar UI). Covers both
    /// menu-started Start Session terminals and externally-started bridges
    /// (the /relay-bridge slash command). The watchdog flips bridgeAliveCache
    /// within ~3 seconds of an external bridge coming up, so /relay-bridge
    /// users see the menu reflect their session promptly.
    var hasActiveSession: Bool { menuSessionActive || bridgeAliveCache || bridgeRecoveryInFlight }

    private var bridgeStartingUp: Bool {
        menuSessionActive && !sessionBridgeSeen && !bridgeRecoveryInFlight
    }

    private func syncNotchStatusSurface() {
        notchStatusController.setActive(overlayController != nil)
        syncNotchActivitySurface()
    }

    private func setOnboardingNotchOverrideActive(_ active: Bool) {
        guard onboardingNotchOverrideActive != active else { return }
        onboardingNotchOverrideActive = active
        syncNotchStatusSurface()
    }

    private func setFirstRunExperienceActive(_ active: Bool) {
        guard isFirstRunExperienceActive != active else { return }
        isFirstRunExperienceActive = active
        if active {
            programBoardOverlay.hide()
        }
    }

    static func allowsAppShellAccess(
        firstRunExperienceActive: Bool,
        sharedOnboardingInProgress: Bool = false
    ) -> Bool {
        !firstRunExperienceActive && !sharedOnboardingInProgress
    }

    static func routeWorkspaceToggleRequest(
        consumeForTutorial: Bool,
        toggleWorkspace: () -> Void,
        completeTutorial: () -> Void
    ) {
        if consumeForTutorial {
            completeTutorial()
        } else {
            toggleWorkspace()
        }
    }

    private var allowsAppShellAccess: Bool {
        Self.allowsAppShellAccess(
            firstRunExperienceActive: isFirstRunExperienceActive,
            sharedOnboardingInProgress: OnboardingController.sharedOnboardingInProgress()
        )
    }

    func requestPermissionSetup(_ kind: PermissionKind,
                                source: PermissionSetupSource,
                                purpose: String = "") {
        permissionSetupCoordinator.request(kind, source: source, purpose: purpose)
    }

    private func prepareForPermissionExternalWindow(_ kind: PermissionKind) {
        guard kind.opensSystemSettingsDuringSetup else { return }
        suspendWorkspaceForExternalWindow()
        permissionRelaunchGuard.armIfNeeded(for: kind)
    }

    func cancelPermissionSetup(source: PermissionSetupSource? = nil) {
        permissionSetupCoordinator.cancel(source: source)
    }

    private func setPermissionSetupNotchState(_ state: PermissionSetupNotchState?) {
        guard permissionSetupNotchState != state else { return }
        permissionSetupNotchState = state
        syncNotchStatusSurface()
    }

    private func startNotchActivityPolling() {
        notchActivityPollingActive = true
        updateWorkspaceActivityPolling()
        refreshWorkspaceActivity()
    }

    private func stopNotchActivityPolling() {
        notchActivityPollingActive = false
        updateWorkspaceActivityPolling()
        notchActivityRunStates = []
        notchActivityTickets = []
        notchActivityTicketsByRunKey = [:]
        notchStatusController.clearWorkingActivity()
    }

    private func refreshWorkspaceActivity(
        invalidateRoute: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        if invalidateRoute {
            workspaceActivityRefreshID += 1
            workspaceActivityTask?.cancel()
            workspaceActivityTask = nil
            workspaceActivitySnapshot = .empty
        }
        guard workspaceActivityTask == nil else { return }
        let bridgeSessionAlive = hasActiveSession
        workspaceActivityRefreshID += 1
        let refreshID = workspaceActivityRefreshID
        workspaceActivityTask = Task { @MainActor [weak self, workspaceActivityStore] in
            if invalidateRoute {
                await workspaceActivityStore.cancel(invalidate: true)
            }
            let snapshot = await workspaceActivityStore.refresh(
                bridgeSessionAlive: bridgeSessionAlive
            )
            guard let self, self.workspaceActivityRefreshID == refreshID else { return }
            self.workspaceActivityTask = nil
            guard !Task.isCancelled else { return }
            self.workspaceActivitySnapshot = snapshot
            if self.hasActiveSession {
                self.notchActivityRunStates = snapshot.runStates
                self.notchActivityTickets = snapshot.tickets
                self.notchActivityTicketsByRunKey = snapshot.ticketsByRunKey
            } else {
                self.clearNotchActivityProjectState(cancelRefresh: false)
            }
            self.syncNotchActivitySurface()
            self.syncSleepPreventionController(with: snapshot)
            if invalidateRoute {
                self.programBoardOverlay.refreshProjectScopeAfterRegistryChange()
            } else {
                self.programBoardOverlay.refreshRouteIfNeeded()
            }
            completion?()
        }
    }

    private func cancelWorkspaceActivityRefresh(invalidate: Bool) {
        workspaceActivityRefreshID += 1
        workspaceActivityTask?.cancel()
        workspaceActivityTask = nil
        Task { [workspaceActivityStore] in
            await workspaceActivityStore.cancel(invalidate: invalidate)
        }
        if invalidate {
            workspaceActivitySnapshot = .empty
        }
    }

    private func clearNotchActivityProjectState(cancelRefresh: Bool = true) {
        if cancelRefresh {
            cancelWorkspaceActivityRefresh(invalidate: false)
        }
        notchActivityRunStates = []
        notchActivityTickets = []
        notchActivityTicketsByRunKey = [:]
        syncNotchActivitySurface()
    }

    private func syncNotchActivitySurface() {
        if let presentation = Self.setupNotchPresentation(
            onboardingActive: onboardingNotchOverrideActive,
            permissionState: permissionSetupNotchState
        ) {
            notchStatusController.setPresentation(
                status: presentation.status,
                activityLabels: presentation.activityLabels,
                workingProgressLabel: presentation.workingProgressLabel
            )
            return
        }

        let boardIsLoading = programBoardLoading
        guard hasActiveSession || boardIsLoading else {
            notchStatusController.setPresentation(
                status: .notWorking,
                activityLabels: [],
                workingProgressLabel: nil
            )
            return
        }

        let foregroundActivityLabel =
            NotchActivityLabelPlanner.label(forWorkingProgress: stateMachine.currentWorkingProgress())
        let labels = NotchActivityLabelPlanner.labels(
            for: stateMachine.state,
            foregroundActivity: foregroundActivityLabel,
            activeRuns: notchActivityRunStates,
            tickets: notchActivityTickets,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            bridgeStartingUp: bridgeStartingUp
        )
        let hoverActivityLabel = NotchActivityLabelPlanner.hoverLabel(
            for: stateMachine.state,
            foregroundActivity: foregroundActivityLabel,
            activeRuns: notchActivityRunStates,
            tickets: notchActivityTickets,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            bridgeStartingUp: bridgeStartingUp,
            ticketForRun: { [notchActivityTicketsByRunKey] run in
                let repoPath = URL(fileURLWithPath: run.repoPath).resolvingSymlinksInPath().path
                return notchActivityTicketsByRunKey[
                    Self.notchActivityRunKey(repoPath: repoPath, ticketId: run.ticketId)
                ]
            }
        )
        let hasActiveWork = NotchActivityLabelPlanner.hasActiveWork(
            state: stateMachine.state,
            foregroundActivity: foregroundActivityLabel,
            activeRuns: notchActivityRunStates,
            tickets: notchActivityTickets,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            bridgeStartingUp: bridgeStartingUp,
            boardIsLoading: boardIsLoading
        )
        notchStatusController.setPresentation(
            status: NotchSessionStatus.resolve(
                for: stateMachine.state,
                hasActivityLabels: hasActiveWork,
                boardIsLoading: boardIsLoading
            ),
            activityLabels: labels,
            workingProgressLabel: hoverActivityLabel
        )
    }

    static func setupNotchPresentation(onboardingActive: Bool,
                                       permissionState: PermissionSetupNotchState?) -> NotchPresentation? {
        guard onboardingActive || permissionState != nil else { return nil }
        return NotchPresentation(
            status: .working,
            activityLabels: [],
            workingProgressLabel: nil
        )
    }

    static func onboardingNotchPresentation(active: Bool) -> NotchPresentation? {
        setupNotchPresentation(onboardingActive: active, permissionState: nil)
    }

    private static func notchActivityRunKey(repoPath: String, ticketId: String) -> String {
        "\(repoPath)|\(ticketId)"
    }

    init(
        checkForUpdates: @escaping @MainActor () -> Void = {},
        bundleURL: URL = Bundle.main.bundleURL,
        refreshBundledOrchestratorDaemon: @escaping () async -> OrchestratorDaemonRefreshResult = {
            await OrchestratorClient.refreshBundledOrchestratorDaemonIfIdle()
        }
    ) {
        self.checkForUpdatesAction = checkForUpdates
        self.refreshBundledOrchestratorDaemon = refreshBundledOrchestratorDaemon
        self.refreshBundledServicesOnLaunch = RelayUpdaterController.shouldStartAutomatically(
            installerContext: nil,
            bundleURL: bundleURL
        )
        EmbeddedAgentDiagnostics.finalizeInterruptedSessionIfNeeded()
        self.config = ConfigManager.shared.load()
        programBoardOverlay.setWorkerSizingDefaultsProvider { [weak self] in
            guard let self else { return nil }
            return TicketWriter.WorkerSizingDefaults.from(self.config.general)
        }
        programBoardOverlay.setStartSessionHandler { [weak self] projectPath in
            self?.newSession(workingDirectory: projectPath)
        }
        programBoardOverlay.setEndSessionHandler { [weak self] in
            self?.endSession()
        }
        programBoardOverlay.setSessionActiveProvider { [weak self] in
            self?.hasActiveSession ?? false
        }
        programBoardOverlay.setBoardRouteResolver { [weak self] in
            self?.workspaceActivitySnapshot.route ?? .unavailable
        }
        programBoardOverlay.setProjectScopeProvider { [weak self] in
            self?.workspaceActivitySnapshot.projects.map(\.repoPath.path) ?? []
        }
        programBoardOverlay.setProjectManagementHandlers(
            addExisting: { [weak self] in self?.addExistingProject() },
            create: { [weak self] in self?.createProject() }
        )
        programBoardOverlay.setProjectSelectionHandler { [weak self] repoPath in
            guard let self, let projectRegistryV2 = self.projectRegistryV2 else { return }
            do {
                _ = try projectRegistryV2.confirmProject(matching: repoPath)
                self.refreshWorkspaceActivity(invalidateRoute: true)
            } catch {
                self.surfaceProjectScopeFailure(String(describing: error))
            }
        }
        programBoardOverlay.setRequiresConfirmedProjectProvider { [weak self] in
            self?.projectRegistryV2 != nil
        }
        programBoardOverlay.setProjectScopeTokenProvider { [weak self] repoPath in
            guard let registry = self?.projectRegistryV2 else { return nil }
            return try? registry.scopeToken(matching: repoPath).encodedValue
        }
        embeddedTerminal.setExitHandler { [weak self] exitCode in
            self?.embeddedTerminalDidExit(exitCode: exitCode)
        }
        notchStatusController.setGlyphClickHandler { [weak self] in
            self?.toggleBoard()
        }
        self.updateRelaunchObserver = NotificationCenter.default.addObserver(
            forName: .relayRunnerWillRelaunchForUpdate,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.prepareForSparkleRelaunch()
        }
        self.appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.stopSleepPreventionMonitoring(releaseReason: "app-termination")
        }
        refreshConfiguredWorkspaceDiscoveryIfNeeded(
            oldConfig: nil,
            newConfig: config,
            force: false
        )
        updateSleepPreventionMonitoring()
        // Watch privacy permissions continuously — macOS doesn't notify us
        // when the user grants/revokes in Settings, so we poll.
        permissions.startMonitoring()
        // Hook permission transitions: notify on revoke, auto-recover STT
        // when mic/global-event access comes back (the STT engine binds to the
        // mic + installs NSEvent monitors at start, so neither recovers
        // without a restart).
        permissions.onChange = { [weak self] kind, old, new in
            guard let self else { return }
            self.permissionNotifier.recordChange(kind, from: old, to: new)
            self.permissionSetupCoordinator.permissionStatusChanged(kind, status: new)
            if new == .granted && old != .granted {
                if kind == .microphone {
                    if self.sttEngine == nil {
                        self.startAwareness()
                    } else {
                        self.restartSTTForRecovery()
                    }
                } else if kind == .accessibility || kind == .inputMonitoring {
                    self.programBoardOverlay.installGlobalDismissHotkey()
                    self.restartSTTForRecovery()
                }
            }
        }
        // Start awareness on next run loop tick (after app finishes launching)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let launchPlan = Self.launchPlan(for: self.permissions.microphone)
            if launchPlan.startsOverlay {
                // Keep Workspace routing and the no-session/Work surfaces
                // available even before STT starts.
                self.startOverlay()
            }
            // Don't touch the microphone at install/open time. Onboarding owns
            // the permission ask, and STT starts only after the grant applies.
            if launchPlan.startsAwareness {
                self.startAwareness()
            } else {
                self.statusText = launchPlan.statusText ?? self.statusText
            }
            self.onboarding.showIfNeeded()
            if self.refreshBundledServicesOnLaunch {
                self.refreshBundledServicesAfterLaunch()
            }
        }
    }

    deinit {
        if let updateRelaunchObserver {
            NotificationCenter.default.removeObserver(updateRelaunchObserver)
        }
        if let appTerminationObserver {
            NotificationCenter.default.removeObserver(appTerminationObserver)
        }
        stopSleepPreventionMonitoring(releaseReason: "deinit")
    }

    func checkForUpdates() {
        Task { @MainActor [checkForUpdatesAction] in
            checkForUpdatesAction()
        }
    }

    static func launchPlan(for microphone: PermissionStatus) -> LaunchPlan {
        if microphone == .granted {
            return LaunchPlan(startsOverlay: true, startsAwareness: true, statusText: nil)
        }
        return LaunchPlan(
            startsOverlay: true,
            startsAwareness: false,
            statusText: "Microphone permission needed"
        )
    }

    static func serviceLifecycleMessage(for result: OrchestratorDaemonRefreshResult) -> String? {
        switch result {
        case .restarted:
            return nil
        case .notInstalled:
            return nil
        case .deferredActiveRuns:
            return (
                "Bundled service refresh deferred until active orchestrator workers finish. "
                + "Quit and reopen Relay Runner after they finish."
            )
        case .failed(let message):
            return message.isEmpty
                ? "Bundled service refresh failed. Quit and reopen Relay Runner to retry."
                : "Bundled service refresh failed: \(message)"
        }
    }

    private func refreshBundledServicesAfterLaunch() {
        Task { [weak self, refreshBundledOrchestratorDaemon] in
            let result = await refreshBundledOrchestratorDaemon()
            let message = Self.serviceLifecycleMessage(for: result)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.serviceLifecycleMessage = message
                switch result {
                case .restarted:
                    NSLog("[RelayRunner] Bundled orchestrator daemon refreshed after app launch.")
                case .notInstalled:
                    NSLog("[RelayRunner] Bundled orchestrator refresh skipped; launch agent is not installed.")
                case .deferredActiveRuns:
                    NSLog("[RelayRunner] Bundled orchestrator refresh deferred because active workers are running.")
                case .failed(let message):
                    NSLog("[RelayRunner] Bundled orchestrator refresh failed: \(message)")
                }
            }
        }
    }

    static func setupRuntimeReadiness(
        engineStatusMessage: String?,
        engineError: String?,
        setupSucceeded: Bool = false,
        startedAt: Date?,
        now: Date = Date(),
        timeout: TimeInterval = SetupRuntimeReadiness.defaultTimeout
    ) -> SetupRuntimeReadiness {
        SetupRuntimeReadiness.resolve(
            engineStatusMessage: engineStatusMessage,
            engineError: engineError,
            setupSucceeded: setupSucceeded,
            startedAt: startedAt,
            now: now,
            timeout: timeout
        )
    }

    /// Recreate the STT engine so it re-binds to the microphone and reinstalls
    /// global key monitors. Called from `permissions.onChange` when a
    /// previously-denied permission gets granted.
    private func restartSTTForRecovery() {
        guard isRunning else { return }
        NSLog("[AppState] Permission restored — restarting STT for recovery")
        restartSTT(reason: "permission-recovery")
    }

    /// User-facing retry, e.g. from the menu's "Retry Setup" item after
    /// setupStatusFailed fired. Clears the prior error and recreates the
    /// engine so the statusMessage pipeline re-runs from scratch.
    func retrySTTSetup() {
        sttEngineError = nil
        restartSTT(reason: "user-retry")
    }

    private func restartSTT(reason: String) {
        sttEngine?.stop()
        startConfiguredSTT(reason: reason, failureLogPrefix: "STT restart (\(reason)) failed")
    }

    private func startConfiguredSTT(reason: String, failureLogPrefix: String) {
        let engine = STTEngine(config: config.stt)
        engine.tutorialActive = onboarding.isSessionControlsTutorialActive
        sttEngine = engine
        resetObservedTutorialSTTSerials()
        sttSetupStartedAt = Date()
        sttSetupSucceeded = false
        sttEngineError = nil
        Task { [weak self, engine] in
            do {
                try await engine.start()
                await MainActor.run { [weak self, engine] in
                    self?.completeSTTSetupIfCurrent(engine)
                }
            } catch {
                await MainActor.run { [weak self, engine] in
                    self?.failSTTSetupIfCurrent(engine, error: error)
                }
                NSLog("[AppState] \(failureLogPrefix): \(error)")
            }
        }
        NSLog("[AppState] STT setup started: \(reason)")
    }

    private func completeSTTSetupIfCurrent(_ engine: STTEngine) {
        guard sttEngine === engine else { return }
        sttEngineError = nil
        sttSetupStartedAt = nil
        sttSetupSucceeded = true
    }

    private func failSTTSetupIfCurrent(_ engine: STTEngine, error: Error) {
        guard sttEngine === engine else { return }
        sttEngineError = "\(error)"
        sttSetupStartedAt = nil
        sttSetupSucceeded = false
    }

    /// Start STT + overlay for gesture detection. No bridge — user must
    /// start a session or run /relay-bridge manually.
    private func startAwareness() {
        guard sttEngine == nil else { return }

        startConfiguredSTT(reason: "awareness-start", failureLogPrefix: "STT engine failed to start")
        isRunning = true
        statusText = "Ready"

        startBridgeWatchdog()

        startOverlay()
    }

    /// End the active voice session and revert to awareness mode.
    func endSession() {
        embeddedTerminal.end()
        resetActiveSessionState()
    }

    private func embeddedTerminalDidExit(exitCode: Int32?) {
        let earlyFailureMessage: String?
        if case .failed(let message) = embeddedTerminal.phase {
            earlyFailureMessage = message
        } else {
            earlyFailureMessage = nil
        }
        resetActiveSessionState()
        if let earlyFailureMessage {
            statusText = "Session failed before provider readiness"
            stateMachine.showProgramStatus(
                title: "Session failed before provider readiness",
                body: earlyFailureMessage
            )
            syncNotchActivitySurface()
            NSLog("[AppState] Embedded provider exited before readiness code=\(exitCode.map(String.init) ?? "unknown")")
        }
    }

    private func resetActiveSessionState() {
        processManager.killBridge(stopRequested: true)
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        activeSessionProjectScopeToken = nil
        projectScopeCoordinator.cancel()
        bridgeAliveCache = false
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        sessionReadyShownForCurrentBridgeSession = false
        activeSessionSuppressesStartupGreeting = false
        sessionStartTime = .distantPast
        wizardShownForCurrentBridgeSession = false
        statusText = "Ready"
        // Bridge events (processing/speaking/messageWaiting) are sticky on the
        // state machine — without an explicit reset, killing the bridge mid-
        // response leaves the overlay parked on the last state forever.
        // Cancel any in-flight recording too, so the mic indicator clears.
        sttEngine?.cancelRecording()
        stateMachine.reset()
        refreshWorkspaceActivity(invalidateRoute: true)
    }

    /// Full shutdown (for app quit).
    func stopServices() {
        guard isRunning else {
            workspaceDiscoveryTask?.cancel()
            workspaceDiscoveryTask = nil
            cancelWorkspaceActivityRefresh(invalidate: true)
            stopSleepPreventionMonitoring(releaseReason: "services-stopped")
            return
        }
        stopBridgeWatchdog()
        embeddedTerminal.shutdown()
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        activeSessionProjectScopeToken = nil
        projectScopeCoordinator.cancel()
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        sessionReadyShownForCurrentBridgeSession = false
        activeSessionSuppressesStartupGreeting = false
        stopOverlay()
        sttEngine?.stop()
        sttEngine = nil
        sttSetupStartedAt = nil
        sttSetupSucceeded = false
        sttEngineError = nil
        processManager.stopServices()
        isRunning = false
        statusText = "Idle"
        workspaceDiscoveryTask?.cancel()
        workspaceDiscoveryTask = nil
        cancelWorkspaceActivityRefresh(invalidate: true)
        stopSleepPreventionMonitoring(releaseReason: "services-stopped")
    }

    func prepareForSparkleRelaunch() {
        workspaceDiscoveryTask?.cancel()
        workspaceDiscoveryTask = nil
        cancelWorkspaceActivityRefresh(invalidate: true)
        stopSleepPreventionMonitoring(releaseReason: "update-relaunch")
        bridgeRecoverySuppressedForUpdate = true
        stopBridgeWatchdog()
        embeddedTerminal.shutdown()
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        activeSessionProjectScopeToken = nil
        projectScopeCoordinator.cancel()
        bridgeAliveCache = false
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        sessionReadyShownForCurrentBridgeSession = false
        activeSessionSuppressesStartupGreeting = false
        statusText = "Updating"
        sttEngine?.cancelRecording()
        sttSetupStartedAt = nil
        sttSetupSucceeded = false
        processManager.stopServicesForBundleReplacement()
    }

    func saveConfig(_ newConfig: AppConfig, forceWorkspaceDiscovery: Bool = false) {
        let oldConfig = config
        config = newConfig

        do {
            try configManager.save(newConfig)
        } catch {
            NSLog("[RelayRunner] Failed to save config: \(error)")
        }

        refreshConfiguredWorkspaceDiscoveryIfNeeded(
            oldConfig: oldConfig,
            newConfig: newConfig,
            force: forceWorkspaceDiscovery
        )
        if oldConfig.general.prevent_sleep_while_running != newConfig.general.prevent_sleep_while_running {
            updateSleepPreventionMonitoring()
        }

        // Hot-reload running services
        guard isRunning else { return }

        // Always tell bridge to reload TTS settings
        SocketClient.bridgeSend("reload")

        // Update overlay config
        if oldConfig.awareness != newConfig.awareness {
            overlayController?.updateConfig(newConfig.awareness)
        }

        // Restart STT if settings changed
        if oldConfig.stt != newConfig.stt {
            sttEngine?.stop()
            startConfiguredSTT(reason: "settings-change", failureLogPrefix: "STT engine restart failed")
        }
    }

    private func refreshConfiguredWorkspaceDiscoveryIfNeeded(
        oldConfig: AppConfig?,
        newConfig: AppConfig,
        force: Bool
    ) {
        guard shouldRefreshWorkspaceDiscovery(
            oldGeneral: oldConfig?.general,
            newGeneral: newConfig.general,
            force: force
        ) else {
            return
        }

        let url = WorkspaceFolder.url(from: newConfig.general.working_directory)
        let general = newConfig.general
        workspaceDiscoveryTask?.cancel()
        workspaceDiscoveryTask = Task { @MainActor [weak self] in
            let errorMessage = await Task.detached(priority: .utility) {
                do {
                    _ = try WorkspaceFolder.refreshDiscovery(for: general)
                    return nil as String?
                } catch {
                    return "\(error)"
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.workspaceDiscoveryTask = nil
            if let errorMessage {
                NSLog(
                    "[RelayRunner] Workspace folder discovery skipped for \(url.path): \(errorMessage)"
                )
                return
            }
            self.refreshWorkspaceActivity(invalidateRoute: true)
        }
    }

    private func shouldRefreshWorkspaceDiscovery(
        oldGeneral: GeneralConfig?,
        newGeneral: GeneralConfig,
        force: Bool
    ) -> Bool {
        guard projectRegistryV2 == nil else { return false }
        if force { return true }

        let hasExplicitWorkspace = !newGeneral.working_directory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard let oldGeneral else {
            return hasExplicitWorkspace
        }
        if oldGeneral.working_directory != newGeneral.working_directory {
            return true
        }
        return hasExplicitWorkspace && oldGeneral.provider != newGeneral.provider
    }

    @discardableResult
    func newSession(
        workingDirectory: String? = nil,
        destination: SessionLaunchDestination = .embedded,
        allowDuringFirstRun: Bool = false,
        showsWorkspaceOnLaunch: Bool = true,
        suppressesStartupGreeting: Bool = false,
        recoveryGeneration: String? = nil,
        preservesVoiceBridge: Bool = false
    ) -> Bool {
        guard allowsAppShellAccess || allowDuringFirstRun else { return false }
        if preservesVoiceBridge {
            guard destination == .embedded,
                  recoveryGeneration != nil,
                  !processManager.bridgeStopRequested()
            else { return false }
        }
        guard permissions.microphone == .granted else {
            onboarding.showAlways()
            return false
        }
        let projectScopeToken: ConfirmedProjectScopeToken?
        if let projectRegistryV2 {
            let requestedProject = workingDirectory?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !requestedProject.isEmpty else {
                surfaceProjectScopeFailure("Select an available project in Workspace before starting a session.")
                return false
            }
            do {
                let token = try projectRegistryV2.confirmProject(matching: requestedProject)
                guard projectRegistryV2.validateScopeToken(token).isValid else {
                    throw ProjectRegistryV2Service.ServiceError.staleScope(token.projectID)
                }
                projectScopeCoordinator.confirm(token)
                projectScopeToken = token
            } catch {
                surfaceProjectScopeFailure(String(describing: error))
                return false
            }
        } else {
            projectScopeToken = nil
        }
        let request = Self.sessionLaunchRequest(
            from: config,
            workingDirectory: projectScopeToken?.repositoryPath ?? workingDirectory,
            destination: destination
        )
        let launchConfig = request.config
        // Mark first-session-run before we do anything else — the
        // onboarding controller uses this flag to decide whether to
        // re-show the All Set screen on next launch. Marking on
        // attempt is fine: if the launch fails the user still
        // initiated a session, and the kill-bridge step below cleans
        // up so they can retry without onboarding nagging them again.
        onboarding.markSessionRun()
        // A confirmed-dead provider can be replaced without interrupting the
        // detached bridge that still owns the active voice session.
        if !preservesVoiceBridge {
            processManager.clearBridgeStopRequested()
            processManager.killBridge()
        }
        if embeddedTerminal.phase.isActive || embeddedTerminal.isEmbeddedProcessRunning {
            embeddedTerminal.end()
        }
        menuSessionActive = true
        sessionStartTime = Date()
        sessionBridgeSeen = false
        sessionReadyShownForCurrentBridgeSession = false
        activeSessionSuppressesStartupGreeting = suppressesStartupGreeting
        sessionPromptGate.reset()
        activeSessionLaunchConfig = launchConfig
        activeSessionProjectScopeToken = projectScopeToken
        // Bridge is about to launch — assume alive until watchdog says otherwise
        bridgeAliveCache = true
        refreshWorkspaceActivity(invalidateRoute: true)

        // Start STT if not already running
        if sttEngine == nil {
            startConfiguredSTT(reason: "session-start", failureLogPrefix: "STT engine session start failed")
        }

        let sessionDirectory = WorkspaceFolder.url(from: launchConfig.general.working_directory).path
        do {
            try embeddedTerminal.beginPreparing(
                providerName: launchConfig.general.provider.displayName,
                providerKey: launchConfig.general.provider.rawValue,
                workingDirectory: sessionDirectory,
                recordDiagnostics: request.destination == .embedded
            )
            let voiceDelivery: ProcessManager.SessionVoiceDelivery =
                (request.destination == .embedded) ? .appOwned : .agentSkill
            let prepared = try processManager.prepareNewSession(
                config: launchConfig,
                voiceDelivery: voiceDelivery,
                suppressStartupGreeting: suppressesStartupGreeting,
                sessionEventPath: embeddedTerminal.diagnosticEventPath,
                projectScopeToken: projectScopeToken,
                recoveryGeneration: recoveryGeneration,
                startsVoiceBridge: !preservesVoiceBridge
            )
            if let generation = prepared.recoveryGeneration {
                let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
                    repositoryPath: prepared.workingDirectory
                )
                continuityRecoveryGenerationBySession[sessionID] = generation
            }
            switch request.destination {
            case .embedded:
                try embeddedTerminal.start(prepared)
            case .externalTerminal:
                guard processManager.launchPreparedSessionInTerminal(prepared) else {
                    throw ProcessManager.SessionLaunchPreparationError.externalTerminalLaunch
                }
                embeddedTerminal.markExternal(
                    providerName: launchConfig.general.provider.displayName,
                    workingDirectory: prepared.workingDirectory
                )
            }
        } catch {
            if !preservesVoiceBridge {
                continuityRecoveryGenerationBySession.removeValue(
                    forKey: ContinuityRecoveryRequest.projectSessionIdentifier(
                        repositoryPath: launchConfig.general.working_directory
                    )
                )
            }
            embeddedTerminal.markFailed(error)
            if preservesVoiceBridge {
                bridgeAliveCache = processManager.bridgeAlive()
                menuSessionActive = bridgeAliveCache
                statusText = bridgeAliveCache ? "Session reconnecting" : "Ready"
            } else {
                processManager.killBridge(stopRequested: true)
                menuSessionActive = false
                activeSessionLaunchConfig = nil
                activeSessionProjectScopeToken = nil
                projectScopeCoordinator.cancel()
                bridgeAliveCache = false
                sessionBridgeSeen = false
                sessionReadyShownForCurrentBridgeSession = false
                activeSessionSuppressesStartupGreeting = false
                sessionStartTime = .distantPast
                statusText = "Ready"
            }
            NSLog("[AppState] Failed to start session: \(error)")
            return false
        }
        isRunning = true
        if menuSessionActive {
            statusText = activeProviderInteractiveReady ? "Session" : "Starting session"
        }

        // Ensure overlay is running
        if overlayController == nil { startOverlay() }
        if !showsWorkspaceOnLaunch {
            return menuSessionActive
        }
        if request.destination == .externalTerminal && menuSessionActive {
            if programBoardOverlay.isVisible {
                programBoardOverlay.hide()
            }
        } else {
            programBoardOverlay.showTerminal()
        }
        return menuSessionActive
    }

    private func updateSleepPreventionMonitoring() {
        if config.general.prevent_sleep_while_running {
            startSleepPreventionMonitoring()
        } else {
            stopSleepPreventionMonitoring(releaseReason: "setting-disabled")
        }
    }

    private func startSleepPreventionMonitoring() {
        sleepPreventionMonitoringActive = true
        updateWorkspaceActivityPolling()
        syncSleepPreventionActivity()
    }

    private func updateWorkspaceActivityPolling() {
        let shouldPoll = notchActivityPollingActive || sleepPreventionMonitoringActive
        if shouldPoll, workspaceActivityTimer == nil {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshWorkspaceActivity()
            }
            RunLoop.main.add(timer, forMode: .common)
            workspaceActivityTimer = timer
        } else if !shouldPoll {
            workspaceActivityTimer?.invalidate()
            workspaceActivityTimer = nil
            cancelWorkspaceActivityRefresh(invalidate: false)
        }
    }

    private func stopSleepPreventionMonitoring(releaseReason: String) {
        sleepPreventionMonitoringActive = false
        sleepPreventionController.release(reason: releaseReason)
        updateWorkspaceActivityPolling()
    }

    private func syncSleepPreventionActivity() {
        refreshWorkspaceActivity()
    }

    private func syncSleepPreventionController(with snapshot: WorkspaceActivitySnapshot) {
        sleepPreventionController.sync(
            preferenceEnabled: config.general.prevent_sleep_while_running,
            activity: SleepPreventionActivity(
                foregroundProviderTurnActive: hasActiveSession
                    && snapshot.foregroundProviderTurnActive,
                activeWorkerRunCount: SleepPreventionActivity.activeWorkerRunCount(
                    in: snapshot.runStates
                )
            )
        )
    }

    private func prepareOnboardingTutorialSpeech() -> Bool {
        guard processManager.startTutorialTTS() else { return false }
        sttEngine?.tutorialActive = true
        stateMachine.dismissSessionPrompt()
        return true
    }

    private func surfaceProjectScopeFailure(_ detail: String) {
        statusText = "Select a project"
        if overlayController == nil { startOverlay() }
        stateMachine.showProgramStatus(
            title: "Project selection required",
            body: detail
        )
        syncNotchActivitySurface()
        showWorkspaceWork()
    }

    private func stopOnboardingTutorialSpeech() {
        sttEngine?.tutorialActive = false
        processManager.stopTutorialTTS()
    }

    static func sessionLaunchRequest(
        from config: AppConfig,
        workingDirectory: String?,
        destination: SessionLaunchDestination = .embedded
    ) -> SessionLaunchRequest {
        SessionLaunchRequest(
            config: sessionLaunchConfig(from: config, workingDirectory: workingDirectory),
            destination: destination
        )
    }

    static func sessionLaunchConfig(from config: AppConfig, workingDirectory: String?) -> AppConfig {
        var launchConfig = config
        let trimmed = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            launchConfig.general.working_directory = trimmed
        }
        return launchConfig
    }

    func ttsCommand(_ cmd: String) {
        SocketClient.ttsSend(cmd)
    }

    func showProgramStatus() {
        if overlayController == nil { startOverlay() }
        stateMachine.showProgramStatus(title: "Program Status", body: "Loading program status...")
        syncNotchActivitySurface()

        programStatusTask?.cancel()
        programStatusTask = Task { [weak self] in
            do {
                let message = try await OrchestratorClient.fetchProgramStatusOverlay()
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self, title = message.title, body = message.body] in
                    self?.stateMachine.showProgramStatus(title: title, body: body)
                    self?.syncNotchActivitySurface()
                }
            } catch {
                guard !Task.isCancelled else { return }
                let message = ProgramStatusOverlayFormatter.errorMessage(for: error)
                await MainActor.run { [weak self, title = message.title, body = message.body] in
                    self?.stateMachine.showProgramStatus(title: title, body: body)
                    self?.syncNotchActivitySurface()
                }
            }
        }
    }

    func showServiceLifecycleDetail(_ message: String) {
        if overlayController == nil { startOverlay() }
        stateMachine.showProgramStatus(title: "Service Status", body: message)
        syncNotchActivitySurface()
    }

    func toggleRecording() {
        guard permissions.microphone == .granted else {
            permissions.requestMicrophonePrompt { _ in }
            return
        }
        sttEngine?.toggleRecording()
    }

    /// Show or hide the unified Workspace overlay. Single-repo sessions scope
    /// Work to that repo; workspace sessions aggregate discovered child repos.
    @discardableResult
    func toggleBoard(recognizedAt: CFTimeInterval? = nil) -> Bool {
        guard allowsAppShellAccess else { return false }
        return programBoardOverlay.toggle(recognizedAt: recognizedAt)
    }

    func toggleWorkspace() {
        _ = toggleBoard()
    }

    func showWorkspaceSettings() {
        guard allowsAppShellAccess else { return }
        if overlayController == nil { startOverlay() }
        programBoardOverlay.showSettings()
    }

    private func showWorkspaceWork() {
        guard allowsAppShellAccess else { return }
        if overlayController == nil { startOverlay() }
        programBoardOverlay.showWork()
    }

    var usesProjectRegistryV2: Bool {
        projectRegistryV2 != nil
    }

    func registeredProjectsV2() -> [RegisteredProjectV2] {
        (try? projectRegistryV2?.projects()) ?? []
    }

    func refreshRegisteredProject(_ projectID: String) throws -> RegisteredProjectV2 {
        guard let projectRegistryV2 else {
            throw ProjectRegistryV2Service.ServiceError.projectNotFound(projectID)
        }
        let project = try projectRegistryV2.refreshAvailability(projectID: projectID)
        invalidateConfirmedProjectScopeIfNeeded()
        refreshWorkspaceActivity(invalidateRoute: true)
        return project
    }

    func removeRegisteredProject(_ projectID: String) throws {
        guard let projectRegistryV2 else {
            throw ProjectRegistryV2Service.ServiceError.projectNotFound(projectID)
        }
        try projectRegistryV2.removeProject(projectID: projectID, confirmed: true)
        if activeSessionProjectScopeToken?.projectID == projectID {
            projectScopeCoordinator.cancel(projectID: projectID)
            activeSessionProjectScopeToken = nil
        }
        invalidateConfirmedProjectScopeIfNeeded()
        refreshWorkspaceActivity(invalidateRoute: true)
    }

    func addExistingProject(
        resumeInSettings: Bool = false,
        completion: ((Result<RegisteredProjectV2, Error>) -> Void)? = nil
    ) {
        guard let projectRegistryV2 else { return }
        WorkspaceDirectoryPicker.pick(
            message: "Choose an existing project folder",
            onPrepareExternalWindow: { [weak self] ready in
                guard let self else {
                    ready()
                    return
                }
                self.suspendWorkspaceForProjectPicker(ready)
            },
            chooseDirectory: {
                WorkspaceDirectoryPicker.runAppKitDirectoryPanel(
                    message: "Choose an existing project folder"
                )
            },
            completion: { [weak self] path in
                guard let self else { return }
                guard let path else {
                    self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings)
                    return
                }
                self.performProjectRegistration(
                    resumeInSettings: resumeInSettings,
                    completion: completion
                ) {
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    return try projectRegistryV2.registerExistingProject(at: url)
                }
            }
        )
    }

    func createProject(
        resumeInSettings: Bool = false,
        completion: ((Result<RegisteredProjectV2, Error>) -> Void)? = nil
    ) {
        guard let projectRegistryV2 else { return }
        suspendWorkspaceForProjectPicker { [weak self] in
            guard let self else { return }
            let panel = NSSavePanel()
            panel.title = "Create Project"
            panel.message = "Choose a new folder for the Git repository."
            panel.nameFieldLabel = "Project name:"
            panel.nameFieldStringValue = "New Project"
            panel.canCreateDirectories = true
            let selectedURL = WorkspaceDirectoryPicker.runAppKitPanel(panel)
            guard let selectedURL else {
                self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings)
                return
            }
            self.performProjectRegistration(
                resumeInSettings: resumeInSettings,
                completion: completion
            ) {
                try projectRegistryV2.createProject(at: selectedURL)
            }
        }
    }

    private func performProjectRegistration(
        resumeInSettings: Bool,
        completion: ((Result<RegisteredProjectV2, Error>) -> Void)?,
        operation: @escaping () throws -> RegisteredProjectV2
    ) {
        Task { @MainActor [weak self] in
            let result = await Self.performProjectRegistrationWork(operation)
            guard let self else { return }
            switch result {
            case .success(let project):
                self.refreshWorkspaceActivity(invalidateRoute: true) {
                    self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings)
                    completion?(.success(project))
                }
            case .failure(let error):
                self.surfaceProjectManagementFailure(error)
                self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings)
                completion?(.failure(error))
            }
        }
    }

    static func performProjectRegistrationWork<T>(
        _ operation: @escaping () throws -> T
    ) async -> Result<T, Error> {
        await Task.detached(priority: .utility) {
            Result { try operation() }
        }.value
    }

    func locateRegisteredProject(
        _ projectID: String,
        resumeInSettings: Bool = true,
        completion: ((Result<RegisteredProjectV2, Error>) -> Void)? = nil
    ) {
        guard let projectRegistryV2 else { return }
        WorkspaceDirectoryPicker.pick(
            message: "Locate the registered Git repository",
            onPrepareExternalWindow: { [weak self] ready in
                guard let self else {
                    ready()
                    return
                }
                self.suspendWorkspaceForProjectPicker(ready)
            },
            chooseDirectory: {
                WorkspaceDirectoryPicker.runAppKitDirectoryPanel(
                    message: "Locate the registered Git repository"
                )
            },
            completion: { [weak self] path in
                guard let self else { return }
                defer { self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings) }
                guard let path else { return }
                do {
                    let project = try projectRegistryV2.locate(
                        projectID: projectID,
                        selectedURL: URL(fileURLWithPath: path, isDirectory: true)
                    )
                    self.invalidateConfirmedProjectScopeIfNeeded()
                    self.refreshWorkspaceActivity(invalidateRoute: true)
                    completion?(.success(project))
                } catch {
                    self.surfaceProjectManagementFailure(error)
                    completion?(.failure(error))
                }
            }
        )
    }

    private func resumeWorkspace(afterProjectManagementInSettings settings: Bool) {
        if settings {
            programBoardOverlay.showSettings()
        } else {
            programBoardOverlay.showWork()
        }
    }

    private func invalidateConfirmedProjectScopeIfNeeded() {
        guard let projectRegistryV2 else { return }
        projectScopeCoordinator.invalidateIfNeeded(using: projectRegistryV2.validateScopeToken)
        activeSessionProjectScopeToken = projectScopeCoordinator.inheritedToken()
    }

    private func surfaceProjectManagementFailure(_ error: Error) {
        statusText = "Project update failed"
        stateMachine.showProgramStatus(
            title: "Project update failed",
            body: String(describing: error)
        )
        syncNotchActivitySurface()
    }

    func activateProject(pathOrAlias: String, provider: String?) async -> ProjectActivationReply {
        let reply = await Task.detached(priority: .utility) {
            do {
                let project = try ProjectResolver.activateProject(
                    matching: pathOrAlias,
                    provider: provider
                )
                return ProjectActivationReply.activated(repoPath: project.repoPath.path)
            } catch {
                return ProjectActivationReply.failed(message: "\(error)")
            }
        }.value
        if case .activated = reply {
            refreshWorkspaceActivity(invalidateRoute: true)
        }
        return reply
    }

    // MARK: - Bridge watchdog

    private var bridgeRecoveryFallbackConfig: AppConfig? {
        guard menuSessionActive else { return nil }
        return activeSessionLaunchConfig ?? config
    }

    private func startBridgeWatchdog() {
        stopBridgeWatchdog()
        refreshBridgeWatchdog()
        bridgeWatchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshBridgeWatchdog()
        }
    }

    private func refreshBridgeWatchdog() {
        guard isRunning, bridgeWatchdogTask == nil else { return }
        let processManager = processManager
        let fallbackConfig = bridgeRecoveryFallbackConfig
        bridgeWatchdogTask = Task { @MainActor [weak self] in
            let sample = await Task.detached(priority: .utility) {
                let daemonAlive = processManager.bridgeAlive()
                let consumerAlive = daemonAlive && processManager.bridgeConsumerAlive()
                return BridgeWatchdogSample(
                    daemonAlive: daemonAlive,
                    consumerAlive: consumerAlive,
                    hasSessionContext: processManager.bridgeRecoveryContext(
                        fallbackConfig: fallbackConfig
                    ) != nil,
                    pendingDeliveryState: processManager.pendingVoiceCommandDeliveryState(),
                    stopRequested: processManager.bridgeStopRequested()
                )
            }.value
            guard let self else { return }
            self.bridgeWatchdogTask = nil
            guard !Task.isCancelled, self.isRunning else { return }
            self.applyBridgeWatchdogSample(sample)
        }
    }

    private func applyBridgeWatchdogSample(_ sample: BridgeWatchdogSample) {
        let daemonAlive = sample.daemonAlive
        let consumerAlive = sample.consumerAlive
        let hasSessionContext = sample.hasSessionContext
        let pendingDeliveryState = sample.pendingDeliveryState
        let pendingDeliveryTimedOut = pendingDeliveryState == .timedOut
        let alive = ProcessManager.relaySessionAlive(
            daemonAlive: daemonAlive,
            consumerAlive: consumerAlive,
            hasSessionContext: hasSessionContext
        )
        let wasAlive = bridgeAliveCache
        let elapsed = Date().timeIntervalSince(sessionStartTime)
        let action = Self.bridgeWatchdogAction(
            menuSessionActive: menuSessionActive,
            daemonAlive: daemonAlive,
            consumerAlive: consumerAlive,
            hasSessionContext: hasSessionContext,
            wasAlive: wasAlive,
            sessionBridgeSeen: sessionBridgeSeen,
            elapsedSinceSessionStart: elapsed,
            pendingDeliveryTimedOut: pendingDeliveryTimedOut,
            pendingDeliveryState: pendingDeliveryState,
            stopRequested: sample.stopRequested,
            recoverySuppressed: bridgeRecoverySuppressedForUpdate
        )

        if alive != wasAlive {
            refreshWorkspaceActivity(invalidateRoute: true)
        }

        switch action {
        case .reapOrphan:
            NSLog("[AppState] Relay bridge orphaned before any active session, killing")
            processManager.killBridge()
            bridgeAliveCache = false
            menuSessionActive = false
            activeSessionLaunchConfig = nil
            activeSessionProjectScopeToken = nil
            projectScopeCoordinator.cancel()
            sessionBridgeSeen = false
            sessionReadyShownForCurrentBridgeSession = false
            activeSessionSuppressesStartupGreeting = false
            statusText = "Ready"
            return
        case .keepDaemon:
            // A busy Codex/Claude turn can stop touching the consumer
            // heartbeat while git/build work continues. A completed Codex
            // App turn can also leave a valid context-backed daemon idle.
            // Keep that session alive so TTS, the board, and queued voice
            // input can recover.
            bridgeAliveCache = true
            if !menuSessionActive || activeProviderInteractiveReady {
                statusText = "Session"
            } else {
                statusText = "Starting session"
            }
            return
        case .voiceCommandQueued:
            bridgeAliveCache = true
            if statusText != Self.voiceCommandQueuedPresentation.statusText {
                surfaceVoiceCommandQueued()
            }
        case .waitForConsumer:
            bridgeAliveCache = true
            if statusText != "Voice command waiting" {
                surfaceVoiceCommandWaiting()
            }
            return
        case .waitForLaunch:
            bridgeAliveCache = true
            return
        case .recoverDaemon:
            bridgeAliveCache = false
            let reason = pendingDeliveryTimedOut
                ? "voice-delivery-timeout"
                : (wasAlive ? "bridge-lost" : "menu-session-lost")
            if startBridgeRecovery(reason: reason) {
                return
            }
            NSLog("[AppState] Bridge died but no recovery context was available")
            menuSessionActive = false
            activeSessionLaunchConfig = nil
            activeSessionProjectScopeToken = nil
            projectScopeCoordinator.cancel()
            sessionBridgeSeen = false
            sessionReadyShownForCurrentBridgeSession = false
            activeSessionSuppressesStartupGreeting = false
            surfaceBridgeRecoveryFailure(reason: reason)
            return
        case .markDead:
            bridgeAliveCache = false
        case .alive:
            bridgeAliveCache = true
            if menuSessionActive {
                statusText = activeProviderInteractiveReady ? "Session" : "Starting session"
            }
        }

        // Track externally-started bridges (e.g. /relay-bridge)
        if alive,
           action != .voiceCommandQueued,
           !menuSessionActive,
           statusText != "Session" {
            statusText = "Session"
            // External /relay-bridge counts as the first session run
            // for onboarding purposes — same as the menu Start Session
            // path. Without this, a user who only ever uses the slash
            // command would keep seeing the All Set re-prompt.
            onboarding.markSessionRun()
        }

        if alive {
            sweepReadyTicketsForActiveProject(
                trigger: wasAlive ? "bridge-watchdog" : "bridge-reconnect"
            )
        }

        if alive {
            // Legacy parent-permission metadata is ignored. Relay Runner
            // now hosts Relay Actions/Vision gated calls in the app
            // process, so Accessibility and Screen Recording belong to
            // Relay Runner rather than the agent parent.
            if !wasAlive { wizardShownForCurrentBridgeSession = true }
        } else if wasAlive {
            // Bridge died — reset the legacy session flag.
            wizardShownForCurrentBridgeSession = false
        }

        if menuSessionActive && alive {
            surfaceSessionReadyIfNeeded(daemonAlive: daemonAlive, consumerAlive: consumerAlive)
            sessionBridgeSeen = true
        }

        if wasAlive && !alive && !menuSessionActive {
            // Relay-bridge session ended externally — same idea: update
            // status quietly, let the prompt fire on next Caps Lock.
            NSLog("[AppState] Relay bridge died, reverting to awareness")
            statusText = "Ready"
        }
    }

    private func surfaceSessionReadyIfNeeded(daemonAlive: Bool, consumerAlive: Bool) {
        guard Self.shouldSurfaceSessionReady(
            menuSessionActive: menuSessionActive,
            sessionBridgeSeen: sessionBridgeSeen,
            sessionReadyShownForCurrentBridgeSession: sessionReadyShownForCurrentBridgeSession,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            daemonAlive: daemonAlive,
            consumerAlive: consumerAlive,
            providerInteractiveReady: activeProviderInteractiveReady,
            sessionControlsTutorialActive: onboarding.isSessionControlsTutorialActive,
            suppressesStartupGreeting: activeSessionSuppressesStartupGreeting
        ) else {
            return
        }
        sessionReadyShownForCurrentBridgeSession = true
        stateMachine.showSessionReady()
        syncNotchActivitySurface()
    }

    static func shouldSurfaceSessionReady(
        menuSessionActive: Bool,
        sessionBridgeSeen _: Bool,
        sessionReadyShownForCurrentBridgeSession: Bool,
        bridgeRecoveryInFlight: Bool,
        daemonAlive: Bool,
        consumerAlive: Bool,
        providerInteractiveReady: Bool = true,
        sessionControlsTutorialActive: Bool = false,
        suppressesStartupGreeting: Bool = false
    ) -> Bool {
        menuSessionActive
            && !sessionReadyShownForCurrentBridgeSession
            && !bridgeRecoveryInFlight
            && daemonAlive
            && consumerAlive
            && providerInteractiveReady
            && !sessionControlsTutorialActive
            && !suppressesStartupGreeting
    }

    private var activeProviderInteractiveReady: Bool {
        switch embeddedTerminal.phase {
        case .running, .external:
            return true
        default:
            return false
        }
    }

    enum BridgeWatchdogAction: Equatable {
        case alive
        case voiceCommandQueued
        case keepDaemon
        case waitForConsumer
        case waitForLaunch
        case recoverDaemon
        case reapOrphan
        case markDead
    }

    static func bridgeWatchdogAction(
        menuSessionActive: Bool,
        daemonAlive: Bool,
        consumerAlive: Bool,
        hasSessionContext: Bool = false,
        wasAlive: Bool,
        sessionBridgeSeen: Bool,
        elapsedSinceSessionStart: TimeInterval,
        pendingDeliveryTimedOut: Bool = false,
        pendingDeliveryState: ProcessManager.PendingVoiceCommandDeliveryState = .none,
        stopRequested: Bool = false,
        recoverySuppressed: Bool = false
    ) -> BridgeWatchdogAction {
        if stopRequested {
            return daemonAlive ? .reapOrphan : .markDead
        }
        if recoverySuppressed {
            return .markDead
        }
        if daemonAlive && consumerAlive {
            if pendingDeliveryState == .waiting {
                return .voiceCommandQueued
            }
            return .alive
        }
        let deliveryTimedOut = pendingDeliveryTimedOut || pendingDeliveryState == .timedOut
        if daemonAlive && !consumerAlive {
            if deliveryTimedOut {
                return (menuSessionActive || wasAlive || hasSessionContext) ? .waitForConsumer : .reapOrphan
            }
            return (menuSessionActive || wasAlive || hasSessionContext) ? .keepDaemon : .reapOrphan
        }
        if menuSessionActive {
            if sessionBridgeSeen || elapsedSinceSessionStart > 90 {
                return .recoverDaemon
            }
            return .waitForLaunch
        }
        if hasSessionContext {
            return .recoverDaemon
        }
        return .markDead
    }

    enum RecordingStartBridgeAction: Equatable {
        case allowRecording
        case waitForBridgeRecovery
        case recoverBridge
        case promptForSession
        case waitForPendingCommand
        case waitForConsumer
    }

    static func recordingStartBridgeAction(
        bridgeRecoveryInFlight: Bool,
        daemonAlive: Bool,
        consumerAlive: Bool,
        hasSessionContext: Bool,
        pendingDeliveryState: ProcessManager.PendingVoiceCommandDeliveryState
    ) -> RecordingStartBridgeAction {
        if bridgeRecoveryInFlight {
            return .waitForBridgeRecovery
        }
        if !daemonAlive {
            return hasSessionContext ? .recoverBridge : .promptForSession
        }
        if pendingDeliveryState == .timedOut {
            return .waitForPendingCommand
        }
        if !consumerAlive {
            return hasSessionContext ? .waitForConsumer : .promptForSession
        }
        return .allowRecording
    }

    @discardableResult
    private func startBridgeRecovery(reason: String) -> Bool {
        if bridgeRecoverySuppressedForUpdate { return false }
        if processManager.bridgeStopRequested() { return false }
        if bridgeRecoveryInFlight { return true }
        guard let baseContext = processManager.bridgeRecoveryContext(fallbackConfig: bridgeRecoveryFallbackConfig) else {
            return false
        }
        let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
            repositoryPath: baseContext.workingDirectory
        )
        let context = ProcessManager.BridgeRecoveryContext(
            workingDirectory: baseContext.workingDirectory,
            provider: baseContext.provider,
            recoveryGeneration: continuityRecoveryGenerationBySession[sessionID],
            continuityRecoveryPending: reason.hasPrefix("continuity-")
        )
        let now = Date()
        if now.timeIntervalSince(lastBridgeRecoveryAt) < Self.bridgeRecoveryCooldown {
            return true
        }

        bridgeRecoveryInFlight = true
        lastBridgeRecoveryAt = now
        statusText = "Session reconnecting"
        NSLog("[AppState] Relaunching voice bridge daemon for \(context.workingDirectory) reason=\(reason)")

        let processManager = self.processManager
        let suppressStartupGreeting = activeSessionSuppressesStartupGreeting
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recovered = processManager.relaunchBridgeDaemon(
                context: context,
                suppressStartupGreeting: suppressStartupGreeting
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bridgeRecoveryInFlight = false
                if self.processManager.bridgeStopRequested() {
                    if recovered {
                        self.processManager.killBridge(stopRequested: true)
                    }
                    self.bridgeAliveCache = false
                    self.menuSessionActive = false
                    self.activeSessionLaunchConfig = nil
                    self.activeSessionProjectScopeToken = nil
                    self.projectScopeCoordinator.cancel()
                    self.sessionBridgeSeen = false
                    self.sessionReadyShownForCurrentBridgeSession = false
                    self.activeSessionSuppressesStartupGreeting = false
                    self.statusText = "Ready"
                    NSLog("[AppState] Voice bridge recovery ignored because session stop was requested")
                    return
                }
                if recovered {
                    self.bridgeAliveCache = true
                    self.sessionStartTime = Date()
                    self.sessionBridgeSeen = false
                    self.sessionReadyShownForCurrentBridgeSession = false
                    self.statusText = "Session"
                    NSLog("[AppState] Voice bridge daemon recovery succeeded")
                } else {
                    self.bridgeAliveCache = false
                    self.menuSessionActive = false
                    self.activeSessionLaunchConfig = nil
                    self.activeSessionProjectScopeToken = nil
                    self.projectScopeCoordinator.cancel()
                    self.sessionBridgeSeen = false
                    self.sessionReadyShownForCurrentBridgeSession = false
                    self.activeSessionSuppressesStartupGreeting = false
                    self.surfaceBridgeRecoveryFailure(reason: reason)
                    NSLog("[AppState] Voice bridge daemon recovery failed")
                }
            }
        }
        return true
    }

    static func bridgeRecoveryFailurePresentation(reason: String) -> BridgeRecoveryFailurePresentation {
        let detail = reason == "voice-delivery-timeout"
            ? "a voice delivery timeout"
            : "the bridge stopped responding"
        return BridgeRecoveryFailurePresentation(
            statusText: "Voice bridge recovery failed",
            title: "Voice command not delivered",
            body: (
                "Relay Runner could not recover the active voice bridge after \(detail). "
                + "Start a new session before speaking again."
            )
        )
    }

    private func surfaceBridgeRecoveryFailure(reason: String) {
        if embeddedTerminal.phase == .running {
            embeddedTerminal.end()
        }
        let presentation = Self.bridgeRecoveryFailurePresentation(reason: reason)
        statusText = presentation.statusText
        stateMachine.showProgramStatus(title: presentation.title, body: presentation.body)
        syncNotchActivitySurface()
    }

    private func surfaceVoiceCommandWaiting() {
        statusText = "Voice command waiting"
        stateMachine.showProgramStatus(
            title: "Voice command waiting",
            body: "Relay Runner recorded a voice command, but the active Codex or Claude listener has not claimed it yet. Keep the agent turn running, or start a new session before speaking again."
        )
        syncNotchActivitySurface()
    }

    static let voiceCommandQueuedPresentation = ProgramStatusPresentation(
        statusText: "Command queued",
        title: "Command queued",
        body: "Relay Runner is holding the latest voice command until the active Codex or Claude turn can take it. Speak again to replace the queued command."
    )

    private func surfaceVoiceCommandQueued() {
        let presentation = Self.voiceCommandQueuedPresentation
        statusText = presentation.statusText
        stateMachine.showProgramStatus(title: presentation.title, body: presentation.body)
        syncNotchActivitySurface()
    }

    private func surfaceVoiceListenerIdle() {
        statusText = "Voice listener idle"
        stateMachine.showProgramStatus(
            title: "Voice listener idle",
            body: "The Relay bridge is still running, but the active Codex or Claude turn is not listening for new voice commands. Start a new session before speaking again."
        )
        syncNotchActivitySurface()
    }

    private func showSessionPromptIfAllowed(now: Date = Date()) {
        if case .sessionPrompt = stateMachine.state {
            return
        }
        guard sessionPromptGate.shouldShow(now: now) else {
            return
        }
        sessionPromptCapsState = CapsLockGesture.isCapsLockOn()
        stateMachine.showSessionPrompt()
    }

    private func stopBridgeWatchdog() {
        bridgeWatchdog?.invalidate()
        bridgeWatchdog = nil
        bridgeWatchdogTask?.cancel()
        bridgeWatchdogTask = nil
    }

    private func sweepReadyTicketsForActiveProject(trigger: String) {
        guard case .project(let project) = workspaceActivitySnapshot.route else { return }
        let token = activeSessionProjectScopeToken
        OrchestratorClient.sweepReadyTickets(
            repoPath: project.repoPath.path,
            trigger: trigger,
            projectScopeToken: token?.repositoryPath == project.repoPath.path ? token?.encodedValue : nil
        )
    }

    /// Read the bus's most-recently-detected parent and open the wizard if
    /// this parent hasn't been onboarded yet. Called from the bridge
    /// watchdog on every tick the bridge is alive (until the per-session flag
    /// flips true). Skips when the bus hasn't yet received a
    /// `parent_detected` (MCP server still booting — the next tick retries),
    /// when the parent was unclassifiable (the wizard has nothing useful to
    /// say — flag set so we don't keep checking), and when the tracker has
    /// recorded an acknowledgement (flag set to stop polling).
    private func surfaceParentWizardIfNeeded() {
        guard let bus = actionsBus else { return }
        let controller = parentOnboardingController
        Task { [weak self] in
            guard let self else { return }
            // Parent unknown yet — leave the flag false so the next tick retries.
            guard let parent = await bus.currentParent() else { return }
            await MainActor.run {
                // We have a parent. Settle this session one way or another
                // so the watchdog stops polling.
                self.wizardShownForCurrentBridgeSession = true
                if parent == "unknown" { return }
                if ParentOnboardingTracker.isOnboarded(parent) { return }
                controller.show(parent: parent)
            }
        }
    }

    // MARK: - Overlay management

    private func startOverlay() {
        guard overlayController == nil else { return }

        // State event bus (listens for Python service state)
        let bus = StateEventBus(
            stateMachine: stateMachine,
            shouldHandleServiceEvent: { [weak self] source, tutorial in
                guard let self else { return false }
                return Self.shouldHandleServiceEvent(
                    source: source,
                    tutorial: tutorial,
                    tutorialActive: self.onboarding.isSessionControlsTutorialActive
                )
            },
            onServiceEvent: { [weak self] source, state, text, tutorial in
                self?.handleOnboardingTutorialServiceEvent(
                    source: source,
                    state: state,
                    text: text,
                    tutorial: tutorial
                )
            },
            onRecoveryAction: { [weak self] request in
                self?.performContinuityRecoveryAction(request)
                    ?? .failed("component_action_unavailable")
            }
        )
        eventBus = bus
        Task { await bus.start() }

        // Relay Actions confirmation bus (request/reply socket between the
        // RelayActionsMCP helper and the menu-bar app — drives perimeter
        // glow + double-tap confirmation for propose_action).
        //
        let actions = ActionsConfirmBus(
            stateMachine: stateMachine,
            onParentPermissionRevoked: { _, _ in
                // Compatibility with older helper binaries. Current helpers
                // forward gated work to the app, so parent revocation is not
                // actionable.
            },
            onToggleBoard: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    _ = self.toggleBoard(recognizedAt: CACurrentMediaTime())
                }
            },
            onActivateProject: { [weak self] pathOrAlias, provider in
                guard let self else {
                    return .failed(message: "Relay Runner app state is unavailable.")
                }
                return await self.activateProject(pathOrAlias: pathOrAlias, provider: provider)
            },
            onHostedToolPermissionMissing: { [weak self] kind, purpose in
                guard let appState = self else { return }
                await MainActor.run {
                    appState.requestPermissionSetup(kind, source: .hostedTool, purpose: purpose)
                }
            }
        )
        actionsBus = actions
        Task { await actions.start() }
        // Wire CapsLockGesture's modal yes/no resolution back to the bus.
        // Gesture handler runs on the main thread; bridge to the actor via Task.
        sttEngine?.wireConfirmationGate(stateMachine: stateMachine) { [weak actions] confirmed in
            Task { _ = await actions?.resolveLatest(confirmed: confirmed) }
        }

        // Overlay controller (panel + glow + pill)
        let oc = OverlayController(config: config.awareness)
        oc.start(stateMachine: stateMachine)
        overlayController = oc

        // Workspace overlay — install Esc dismissal once macOS has granted
        // either global-event permission. Accessibility is the normal setup
        // path; an existing Input Monitoring grant remains compatible. The
        // double-tap Shift board trigger is
        // emitted by the STT gesture monitor so it shares the same recovery
        // path as Option/Control activation gestures.
        if permissions.accessibility == .granted || permissions.inputMonitoring == .granted {
            programBoardOverlay.installGlobalDismissHotkey()
        }
        programBoardOverlay.setThemeResolver { [weak self] in
            guard let state = self?.stateMachine.state else { return nil }
            if case .actionGlow = state { return .stt }
            return state.particleTheme
        }
        programBoardOverlay.setNoSessionHandler { [weak self] in
            self?.showSessionPromptIfAllowed()
        }
        programBoardOverlay.setLoadingStateHandler { [weak self] isLoading in
            self?.setProgramBoardLoading(isLoading)
        }
        programBoardOverlay.setSettingsContentProvider { [weak self] in
            guard let self else { return nil }
            return AnyView(WorkspaceSettingsPanel(
                appState: self,
                onOpenExternalWindow: { [weak self] in
                    self?.suspendWorkspaceForExternalWindow()
                }
            ))
        }
        programBoardOverlay.setTerminalContentProvider { [weak self] workingDirectory in
            guard let self else { return nil }
            return AnyView(
                WorkspaceTerminalPanel(
                    appState: self,
                    workingDirectory: workingDirectory
                )
            )
        }
        programBoardOverlay.setTerminalFocusProvider(
            hasFocus: { [weak self] in self?.embeddedTerminal.hasTerminalFocus ?? false },
            focus: { [weak self] in self?.embeddedTerminal.focus() }
        )
        // Perimeter overlay (purple band on every screen while
        // .actionGlow is active; pulses while a confirmation is pending).
        let perimeter = PerimeterOverlayManager()
        perimeter.start(stateMachine: stateMachine)
        perimeterOverlay = perimeter
        startNotchActivityPolling()
        syncNotchStatusSurface()

        // Poll STT engine state → state machine (STT is in-process, no socket needed)
        sttPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, let engine = self.sttEngine else { return }

            let nowRecording = engine.isRecording
            let justStartedRecording = nowRecording && !self.wasRecording
            self.publishOnboardingTutorialSTTEvents(from: engine, includeRecordingStart: false)

            if engine.boardToggleRequested {
                let recognizedAt = engine.boardToggleRequestedAt ?? CACurrentMediaTime()
                engine.boardToggleRequested = false
                engine.boardToggleRequestedAt = nil
                Self.routeWorkspaceToggleRequest(
                    consumeForTutorial: self.onboarding.shouldConsumeWorkspaceToggleRequest,
                    toggleWorkspace: {
                        _ = self.toggleBoard(recognizedAt: recognizedAt)
                    },
                    completeTutorial: {
                        self.onboarding.noteTutorialWorkspaceToggled()
                    }
                )
            }

            // Session prompt: handle responses
            if case .sessionPrompt = self.stateMachine.state,
               !self.onboarding.isSessionControlsTutorialActive {
                if engine.playRequested {
                    // Double-tap Alt → start new session
                    engine.playRequested = false
                    engine.playRequestedAt = nil
                    engine.playDetectedAt = nil
                    self.onboarding.noteTutorialPlaybackRequested()
                    self.stateMachine.dismissSessionPrompt()
                    self.newSession()
                } else if CapsLockGesture.isCapsLockOn() != self.sessionPromptCapsState {
                    // Any Caps Lock toggle → dismiss prompt immediately
                    if engine.isRecording { engine.cancelRecording() }
                    self.stateMachine.dismissSessionPrompt()
                }
                self.wasRecording = nowRecording
                self.syncNotchActivitySurface()
                return
            }

            // No bridge alive: intercept recording and show prompt.
            // Real-time check on each recording start — the cached value
            // can be stale for up to 3s after a bridge dies.
            // Also detect orphaned relay bridges (process alive but no consumer).
            if justStartedRecording && self.onboarding.isSessionControlsTutorialActive {
                self.publishOnboardingTutorialSTTEvents(
                    from: engine,
                    includeRecordingStart: true
                )
            } else if justStartedRecording {
                let daemonAlive = self.processManager.bridgeAlive()
                let pendingDeliveryState = self.processManager.pendingVoiceCommandDeliveryState()
                let consumerAlive = daemonAlive && self.processManager.bridgeConsumerAlive()
                let hasSessionContext = self.processManager.bridgeRecoveryContext(
                    fallbackConfig: self.bridgeRecoveryFallbackConfig
                ) != nil
                let bridgeAction = Self.recordingStartBridgeAction(
                    bridgeRecoveryInFlight: self.bridgeRecoveryInFlight,
                    daemonAlive: daemonAlive,
                    consumerAlive: consumerAlive,
                    hasSessionContext: hasSessionContext,
                    pendingDeliveryState: pendingDeliveryState
                )

                switch bridgeAction {
                case .allowRecording:
                    self.bridgeAliveCache = true
                    self.publishOnboardingTutorialSTTEvents(from: engine, includeRecordingStart: true)
                case .waitForBridgeRecovery:
                    engine.cancelRecording()
                    self.wasRecording = false
                    self.stateMachine.showProgramStatus(
                        title: "Voice session reconnecting",
                        body: "Relay Runner is recovering the active voice bridge. Try again in a moment."
                    )
                    self.syncNotchActivitySurface()
                    return
                case .waitForPendingCommand:
                    self.bridgeAliveCache = true
                    engine.cancelRecording()
                    self.wasRecording = false
                    self.surfaceVoiceCommandWaiting()
                    return
                case .waitForConsumer:
                    self.bridgeAliveCache = true
                    engine.cancelRecording()
                    self.wasRecording = false
                    self.surfaceVoiceListenerIdle()
                    return
                case .recoverBridge:
                    self.bridgeAliveCache = false
                    let recovering = self.startBridgeRecovery(reason: "recording-start")
                    if !recovering {
                        self.menuSessionActive = false
                        self.activeSessionSuppressesStartupGreeting = false
                        self.showSessionPromptIfAllowed()
                    }
                    engine.cancelRecording()
                    self.wasRecording = false
                    return
                case .promptForSession:
                    self.bridgeAliveCache = false
                    self.menuSessionActive = false
                    self.activeSessionSuppressesStartupGreeting = false
                    self.showSessionPromptIfAllowed()
                    engine.cancelRecording()
                    self.wasRecording = false
                    return
                }
            }

            // Clear stale play requests
            if engine.playRequested {
                engine.playRequested = false
                let recognizedAt = engine.playRequestedAt
                let detectedAt = engine.playDetectedAt
                engine.playRequestedAt = nil
                engine.playDetectedAt = nil
                self.stateMachine.setPlaybackRequested()
                if let detectedAt {
                    engine.recordPlaybackAcknowledgement(
                        detectedAt: detectedAt,
                        acknowledgedAt: Date()
                    )
                }
                if let recognizedAt {
                    let acknowledgementMs = (CACurrentMediaTime() - recognizedAt) * 1_000
                    NSLog("[AppState] Option playback acknowledged in %.1fms", acknowledgementMs)
                }
                let playbackActive: Bool
                switch self.stateMachine.state {
                case .preparing, .speaking:
                    playbackActive = true
                default:
                    playbackActive = false
                }
                if let command = self.onboarding.noteTutorialPlaybackRequested(
                    playbackActive: playbackActive
                ) {
                    switch command {
                    case .play:
                        self.processManager.tutorialTTSCommand("play")
                    case .replay:
                        self.processManager.tutorialTTSCommand("replay")
                    }
                }
            }

            if engine.wasCancelled {
                engine.wasCancelled = false
                self.stateMachine.setCancelled()
                self.onboarding.noteTutorialCancelRequested()
            } else {
                self.stateMachine.updateSTT(isRecording: nowRecording, partial: engine.partialTranscription)
            }
            self.wasRecording = nowRecording
            self.syncNotchActivitySurface()
        }
    }

    static func continuityRecoveryDecision(
        for request: ContinuityRecoveryRequest,
        boundary: ContinuityRecoveryBoundary,
        nowMonotonic: Double,
        nowEpoch: Double
    ) -> ContinuityRecoveryDecision {
        typealias Contract = (
            action: ContinuityRecoveryComponentAction,
            incidentPhases: Set<String>,
            commandPhases: Set<String>,
            liveness: Set<String>,
            postcondition: String,
            maxAttempts: Int,
            disruptive: Bool
        )
        let contract: Contract? = switch (request.capability, request.component) {
        case ("reinitialize_speech_capture", "speech_capture"):
            (
                .restartSpeechCapture, ["capture"], ["before_command"],
                ["unhealthy", "confirmed_dead"], "capture_progress_observed", 2, false
            )
        case ("reinitialize_transcription_delivery", "transcription"):
            (
                .restartTranscriptionDelivery, ["transcription", "delivery"],
                ["before_command", "captured", "undelivered"],
                ["unhealthy", "confirmed_dead"], "transcription_completed", 2, false
            )
        case ("restart_bridge", "bridge"):
            (
                .recoverBridge, ["delivery", "component_liveness"], ["none", "undelivered"],
                ["unhealthy", "confirmed_dead"], "bridge_process_alive", 2, true
            )
        case ("reconnect_ipc", "bridge"):
            (
                .recoverBridge, ["delivery", "component_liveness"], ["none", "undelivered"],
                ["unhealthy", "confirmed_dead"], "ipc_connection_restored", 2, true
            )
        case ("restart_daemon", "daemon"):
            (
                .restartDaemon, ["component_liveness"], ["none"],
                ["confirmed_dead"], "daemon_process_alive", 1, true
            )
        case ("reconnect_ipc", "daemon"):
            (
                .restartDaemon, ["component_liveness"], ["none"],
                ["unhealthy", "confirmed_dead"], "ipc_connection_restored", 2, true
            )
        case ("release_dead_ownership", "foreground_provider"):
            (
                .releaseForegroundProviderOwnership, ["provider_turn"], ["in_flight"],
                ["confirmed_dead"], "dead_ownership_released", 1, true
            )
        case ("launch_foreground_provider", "foreground_provider"):
            (
                .launchForegroundProvider, ["provider_turn"], ["in_flight"],
                ["confirmed_dead"], "provider_process_alive", 1, true
            )
        case ("launch_foreground_provider", "session"):
            (
                .launchForegroundProvider, ["session_liveness"], ["none"],
                ["confirmed_dead"], "provider_process_alive", 1, true
            )
        default:
            nil
        }

        guard let contract else { return .reject("unsupported_component_action") }
        guard request.validationToken == "live_continuity_watch",
              request.exactTargetOwned,
              request.incidentActive,
              request.generationMatches,
              request.commandPhaseMatches
        else { return .reject("stale_recovery_context") }
        guard request.sessionID == boundary.currentSessionID,
              request.recoveryGeneration == boundary.currentRecoveryGeneration
        else { return .reject("stale_recovery_generation") }
        guard contract.incidentPhases.contains(request.incidentPhase),
              contract.commandPhases.contains(request.commandPhase),
              contract.liveness.contains(request.liveness),
              request.expectedPostcondition == contract.postcondition,
              request.attempt <= contract.maxAttempts
        else { return .reject("recovery_contract_mismatch") }
        guard request.idempotencyState == "new",
              !boundary.idempotencyAlreadyApplied
        else { return .reject("idempotency_already_applied") }
        guard request.idempotencyKey == ContinuityRecoveryRequest.idempotencyKey(
                  incidentID: request.incidentID,
                  recoveryGeneration: request.recoveryGeneration,
                  capability: request.capability,
                  component: request.component,
                  sessionID: request.sessionID,
                  commandID: request.commandID
              ) else { return .reject("idempotency_context_mismatch") }
        guard request.cooldownRemaining == 0, !boundary.cooldownActive else {
            return .reject("component_cooldown_active")
        }
        guard request.provider == "none" || request.provider == boundary.provider else {
            return .reject("provider_target_mismatch")
        }
        guard nowMonotonic < request.deadline,
              request.incidentObservedAt <= nowEpoch + 5,
              nowEpoch - request.incidentObservedAt <= 300
        else { return .reject("stale_recovery_deadline") }
        if let commandID = request.commandID {
            guard boundary.currentCommandID == commandID else {
                return .reject("unrelated_command_target")
            }
        }
        if contract.disruptive && boundary.liveWorkActive {
            return .reject("live_work_active")
        }
        if contract.action == .releaseForegroundProviderOwnership,
           boundary.providerProcessRunning {
            return .reject("live_provider_must_not_be_killed")
        }
        if contract.action == .launchForegroundProvider,
           boundary.providerProcessRunning {
            return .reject("live_session_must_not_be_replaced")
        }
        return .apply(contract.action)
    }

    private func performContinuityRecoveryAction(
        _ request: ContinuityRecoveryRequest
    ) -> ContinuityRecoveryResponse {
        let now = CACurrentMediaTime()
        let repositoryPath = activeSessionLaunchConfig?.general.working_directory
            ?? config.general.working_directory
        let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
            repositoryPath: repositoryPath
        )
        guard let currentGeneration = continuityRecoveryGenerationBySession[sessionID]
        else { return .failed("recovery_generation_unavailable") }
        let currentCommandID = ProcessManager.currentRelayCommandID().map {
            ContinuityRecoveryRequest.opaqueIdentifier(kind: "command", nativeValue: $0)
        }
        let pendingDelivery = processManager.pendingVoiceCommandDeliveryState()
        let providerTurnActive = ProcessManager.foregroundProviderTurnActive()
        let liveWorkActive = providerTurnActive
            || pendingDelivery == .waiting
            || pendingDelivery == .claimed
        let cooldownKey = continuityRecoveryCooldownKey(request)
        let boundary = ContinuityRecoveryBoundary(
            currentSessionID: sessionID,
            currentRecoveryGeneration: currentGeneration,
            currentCommandID: currentCommandID,
            provider: activeSessionLaunchConfig?.general.provider.rawValue
                ?? config.general.provider.rawValue,
            liveWorkActive: liveWorkActive,
            providerProcessRunning: embeddedTerminal.phase.isActive
                || embeddedTerminal.isEmbeddedProcessRunning,
            bridgeAlive: processManager.bridgeAlive(),
            idempotencyAlreadyApplied: appliedContinuityRecoveryKeys.contains(
                request.idempotencyKey
            ),
            cooldownActive: now < (continuityRecoveryCooldowns[cooldownKey] ?? 0)
        )
        let decision = Self.continuityRecoveryDecision(
            for: request,
            boundary: boundary,
            nowMonotonic: now,
            nowEpoch: Date().timeIntervalSince1970
        )
        guard case let .apply(action) = decision else {
            if case let .reject(code) = decision { return .failed(code) }
            return .failed("component_action_unavailable")
        }

        continuityRecoveryGenerationBySession[sessionID] = request.recoveryGeneration
        let applied: Bool
        switch action {
        case .restartSpeechCapture, .restartTranscriptionDelivery:
            guard isRunning, sttEngine?.isRecording != true else {
                return .failed("live_capture_must_not_be_interrupted")
            }
            restartSTT(reason: "continuity-\(request.capability)")
            applied = true
        case .recoverBridge:
            guard !ProcessManager.foregroundProviderTurnActive() else {
                return .failed("live_work_active")
            }
            applied = startBridgeRecovery(reason: "continuity-\(request.capability)")
        case .restartDaemon:
            Task { [refreshBundledOrchestratorDaemon] in
                _ = await refreshBundledOrchestratorDaemon()
            }
            applied = true
        case .releaseForegroundProviderOwnership:
            guard activeSessionLaunchConfig != nil,
                  !embeddedTerminal.phase.isActive,
                  !ProcessManager.foregroundProviderTurnActive()
            else { return .failed("live_provider_must_not_be_killed") }
            embeddedTerminal.end()
            applied = true
        case .launchForegroundProvider:
            let delivery = processManager.pendingVoiceCommandDeliveryState()
            guard let launch = activeSessionLaunchConfig,
                  !embeddedTerminal.phase.isActive,
                  !embeddedTerminal.isEmbeddedProcessRunning,
                  !ProcessManager.foregroundProviderTurnActive()
            else { return .failed("live_session_must_not_be_replaced") }
            guard delivery != .waiting, delivery != .claimed else {
                return .failed("live_work_active")
            }
            let preservesVoiceBridge = processManager.bridgeAlive()
            applied = newSession(
                workingDirectory: launch.general.working_directory,
                suppressesStartupGreeting: true,
                recoveryGeneration: request.recoveryGeneration,
                preservesVoiceBridge: preservesVoiceBridge
            )
        }
        guard applied else { return .failed("component_action_unavailable") }
        appliedContinuityRecoveryKeys.insert(request.idempotencyKey)
        continuityRecoveryCooldowns[cooldownKey] = now + continuityRecoveryCooldown(request)
        return .applied()
    }

    private func continuityRecoveryCooldownKey(_ request: ContinuityRecoveryRequest) -> String {
        "\(request.sessionID)|\(request.component)|\(request.capability)"
    }

    private func continuityRecoveryCooldown(_ request: ContinuityRecoveryRequest) -> Double {
        switch request.capability {
        case "restart_daemon", "launch_foreground_provider": 15
        default: 5
        }
    }

    private func setProgramBoardLoading(_ isLoading: Bool) {
        guard programBoardLoading != isLoading else { return }
        programBoardLoading = isLoading
        syncNotchActivitySurface()
    }

    private func resetObservedTutorialSTTSerials() {
        observedRecordingStartedSerial = 0
        observedSpeechDetectedSerial = 0
        observedDeliveredTranscriptSerial = 0
        observedTutorialTranscriptSerial = 0
    }

    private func publishOnboardingTutorialSTTEvents(from engine: STTEngine,
                                                   includeRecordingStart: Bool) {
        if includeRecordingStart && engine.recordingStartedSerial > observedRecordingStartedSerial {
            observedRecordingStartedSerial = engine.recordingStartedSerial
            onboarding.noteTutorialRecordingStarted()
        }
        if engine.speechDetectedSerial > observedSpeechDetectedSerial {
            observedSpeechDetectedSerial = engine.speechDetectedSerial
            onboarding.noteTutorialSpeechDetected()
        }
        if engine.deliveredTranscriptSerial > observedDeliveredTranscriptSerial {
            observedDeliveredTranscriptSerial = engine.deliveredTranscriptSerial
            _ = onboarding.noteTutorialRecordingSent()
        }
        if engine.tutorialTranscriptSerial > observedTutorialTranscriptSerial {
            observedTutorialTranscriptSerial = engine.tutorialTranscriptSerial
            if let reply = onboarding.noteTutorialRecordingSent() {
                if processManager.queueTutorialTTS(reply) {
                    onboarding.noteTutorialResponseReady(reply)
                    stateMachine.handleServiceEvent(
                        source: "tts",
                        newState: "message_waiting",
                        text: reply
                    )
                }
            }
        }
    }

    static func shouldHandleServiceEvent(
        source: String,
        tutorial: Bool,
        tutorialActive: Bool
    ) -> Bool {
        guard source == "tts" else { return true }
        return tutorial ? tutorialActive : !tutorialActive
    }

    private func handleOnboardingTutorialServiceEvent(
        source: String,
        state: String,
        text: String?,
        tutorial: Bool
    ) {
        guard source == "tts", tutorial else { return }
        switch state {
        case "message_waiting":
            onboarding.noteTutorialResponseReady(text)
        case "preparing", "speaking":
            onboarding.noteTutorialPlaybackStarted()
        case "idle":
            if let response = onboarding.noteTutorialPlaybackFinished() {
                stateMachine.handleServiceEvent(
                    source: "tts",
                    newState: "message_waiting",
                    text: response
                )
            }
        default:
            break
        }
    }

    private func suspendWorkspaceForExternalWindow() {
        programBoardOverlay.suspendForExternalWindow()
    }

    private func suspendWorkspaceForProjectPicker(_ completion: @escaping () -> Void) {
        programBoardOverlay.suspendForExternalWindowAnimated(completion: completion)
    }

    private func stopOverlay() {
        cancelPermissionSetup()

        programStatusTask?.cancel()
        programStatusTask = nil

        sttPollTimer?.invalidate()
        sttPollTimer = nil
        stopNotchActivityPolling()

        overlayController?.stop()
        overlayController = nil

        perimeterOverlay?.stop()
        perimeterOverlay = nil

        Task { await eventBus?.stop() }
        eventBus = nil

        Task { await actionsBus?.stop() }
        actionsBus = nil

        stateMachine.reset()
        syncNotchStatusSurface()
    }

}
