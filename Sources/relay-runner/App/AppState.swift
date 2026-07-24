import Foundation
import SwiftUI

private struct NotchActivitySnapshot {
    let runStates: [RunState]
    let tickets: [Ticket]
    let ticketsByRunKey: [String: Ticket]
}

@Observable
final class AppState {
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

    var config: AppConfig
    var isRunning = false
    var statusText = "Idle"
    private(set) var isFirstRunExperienceActive = false

    private(set) var sttEngine: STTEngine?
    @ObservationIgnored private let checkForUpdatesAction: @MainActor () -> Void
    @ObservationIgnored private let refreshBundledOrchestratorDaemon: () async -> OrchestratorDaemonRefreshResult
    @ObservationIgnored private let refreshBundledServicesOnLaunch: Bool

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
            startSessionForTutorial: { [weak self] in
                self?.startOnboardingTutorialSession() ?? false
            },
            openWorkspaceAfterCompletion: { [weak self] in
                self?.showWorkspaceWork()
            }
        )
    }()
    @ObservationIgnored private let permissionNotifier = PermissionNotifier()
    @ObservationIgnored private lazy var permissionSetupCoordinator = PermissionSetupCoordinator(
        permissions: permissions,
        setSetupNotchState: { [weak self] state in
            self?.setPermissionSetupNotchState(state)
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
    private var notchActivityTimer: Timer?
    private var notchActivityRunStates: [RunState] = []
    private var notchActivityTickets: [Ticket] = []
    private var notchActivityTicketsByRunKey: [String: Ticket] = [:]
    private var notchActivityTask: Task<Void, Never>?
    private var onboardingNotchOverrideActive = false
    private var permissionSetupNotchState: PermissionSetupNotchState?
    private var bridgeWatchdog: Timer?
    private var programStatusTask: Task<Void, Never>?
    /// True while a menu-started terminal session owns the bridge.
    private var menuSessionActive = false {
        didSet { syncNotchStatusSurface() }
    }
    @ObservationIgnored private var activeSessionLaunchConfig: AppConfig?
    /// Cached by the watchdog so the 20fps poll timer avoids spawning pgrep.
    private var bridgeAliveCache = false {
        didSet { syncNotchStatusSurface() }
    }
    private var wasRecording = false
    private var observedRecordingStartedSerial = 0
    private var observedSpeechDetectedSerial = 0
    private var observedDeliveredTranscriptSerial = 0
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

    static func allowsAppShellAccess(firstRunExperienceActive: Bool) -> Bool {
        !firstRunExperienceActive
    }

    private var allowsAppShellAccess: Bool {
        Self.allowsAppShellAccess(firstRunExperienceActive: isFirstRunExperienceActive)
    }

    func requestPermissionSetup(_ kind: PermissionKind,
                                source: PermissionSetupSource,
                                purpose: String = "") {
        permissionSetupCoordinator.request(kind, source: source, purpose: purpose)
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
        stopNotchActivityPolling()
        syncNotchActivityProjectState()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.syncNotchActivityProjectState()
        }
        RunLoop.main.add(timer, forMode: .common)
        notchActivityTimer = timer
    }

    private func stopNotchActivityPolling() {
        notchActivityTimer?.invalidate()
        notchActivityTimer = nil
        notchActivityTask?.cancel()
        notchActivityTask = nil
        notchActivityRunStates = []
        notchActivityTickets = []
        notchActivityTicketsByRunKey = [:]
        notchStatusController.clearWorkingActivity()
    }

    private func syncNotchActivityProjectState() {
        guard hasActiveSession else {
            clearNotchActivityProjectState()
            return
        }

        guard notchActivityTask == nil else { return }
        notchActivityTask = Task { @MainActor [weak self] in
            let snapshot = await Self.loadNotchActivitySnapshot()
            guard let self else { return }
            self.notchActivityTask = nil
            guard !Task.isCancelled else { return }
            guard self.hasActiveSession else {
                self.clearNotchActivityProjectState()
                return
            }
            self.notchActivityRunStates = snapshot.runStates
            self.notchActivityTickets = snapshot.tickets
            self.notchActivityTicketsByRunKey = snapshot.ticketsByRunKey
            self.syncNotchActivitySurface()
        }
    }

    private func clearNotchActivityProjectState() {
        notchActivityTask?.cancel()
        notchActivityTask = nil
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
        let workingProgressLabel = foregroundActivityLabel
            ?? (boardIsLoading ? BoardUpdateStatus.workingLabel : hoverActivityLabel)
        notchStatusController.setPresentation(
            status: NotchSessionStatus.resolve(
                for: stateMachine.state,
                hasActivityLabels: !labels.isEmpty || workingProgressLabel != nil,
                boardIsLoading: boardIsLoading
            ),
            activityLabels: labels,
            workingProgressLabel: workingProgressLabel
        )
    }

    static func setupNotchPresentation(onboardingActive: Bool,
                                       permissionState: PermissionSetupNotchState?) -> NotchPresentation? {
        let label: String?
        if let permissionState {
            label = permissionState.label
        } else if onboardingActive {
            label = PermissionSetupNotchState.gettingStarted.label
        } else {
            label = nil
        }
        guard let label else { return nil }
        let status: NotchSessionStatus
        if let permissionState, case .granted = permissionState {
            status = .working
        } else {
            status = .notWorking
        }
        return NotchPresentation(
            status: status,
            activityLabels: [label],
            workingProgressLabel: nil
        )
    }

    static func onboardingNotchPresentation(active: Bool) -> NotchPresentation? {
        setupNotchPresentation(onboardingActive: active, permissionState: nil)
    }

    private static func notchActivityRunKey(repoPath: String, ticketId: String) -> String {
        "\(repoPath)|\(ticketId)"
    }

    private static func loadNotchActivitySnapshot() async -> NotchActivitySnapshot {
        await Task.detached(priority: .utility) {
            let projects = ProjectResolver.resolveActivityProjects()
            var runStates: [RunState] = []
            var tickets: [Ticket] = []
            var ticketsByRunKey: [String: Ticket] = [:]

            for project in projects {
                runStates.append(contentsOf: Array(RunStateStore.load(forRepo: project.repoPath).values))
                let projectTickets = ProjectResolver.scanTickets(in: project)
                tickets.append(contentsOf: projectTickets)
                let repoPath = project.repoPath.resolvingSymlinksInPath().path
                for ticket in projectTickets {
                    ticketsByRunKey[notchActivityRunKey(repoPath: repoPath, ticketId: ticket.id)] = ticket
                }
            }

            return NotchActivitySnapshot(
                runStates: runStates,
                tickets: tickets,
                ticketsByRunKey: ticketsByRunKey
            )
        }.value
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
        programBoardOverlay.setProjectScopeProvider {
            ProjectResolver.resolveActivityProjects().map(\.repoPath.path)
        }
        embeddedTerminal.setExitHandler { [weak self] _ in
            self?.embeddedTerminalDidExit()
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
        refreshConfiguredWorkspaceDiscoveryIfNeeded(
            oldConfig: nil,
            newConfig: config,
            force: false
        )
        // Watch privacy permissions continuously — macOS doesn't notify us
        // when the user grants/revokes in Settings, so we poll.
        permissions.startMonitoring()
        // Hook permission transitions: notify on revoke, auto-recover STT
        // when mic/input-monitoring comes back (the STT engine binds to the
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
                } else if kind == .inputMonitoring {
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

    private func embeddedTerminalDidExit() {
        resetActiveSessionState()
    }

    private func resetActiveSessionState() {
        processManager.killBridge(stopRequested: true)
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        bridgeAliveCache = false
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        sessionReadyShownForCurrentBridgeSession = false
        sessionStartTime = .distantPast
        wizardShownForCurrentBridgeSession = false
        statusText = "Ready"
        // Bridge events (processing/speaking/messageWaiting) are sticky on the
        // state machine — without an explicit reset, killing the bridge mid-
        // response leaves the overlay parked on the last state forever.
        // Cancel any in-flight recording too, so the mic indicator clears.
        sttEngine?.cancelRecording()
        stateMachine.reset()
    }

    /// Full shutdown (for app quit).
    func stopServices() {
        guard isRunning else { return }
        stopBridgeWatchdog()
        embeddedTerminal.shutdown()
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        sessionReadyShownForCurrentBridgeSession = false
        stopOverlay()
        sttEngine?.stop()
        sttEngine = nil
        sttSetupStartedAt = nil
        sttSetupSucceeded = false
        sttEngineError = nil
        processManager.stopServices()
        isRunning = false
        statusText = "Idle"
    }

    func prepareForSparkleRelaunch() {
        bridgeRecoverySuppressedForUpdate = true
        stopBridgeWatchdog()
        embeddedTerminal.shutdown()
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        bridgeAliveCache = false
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        sessionReadyShownForCurrentBridgeSession = false
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
        do {
            _ = try WorkspaceFolder.refreshDiscovery(for: newConfig.general)
        } catch {
            NSLog("[RelayRunner] Workspace folder discovery skipped for \(url.path): \(error)")
        }
    }

    private func shouldRefreshWorkspaceDiscovery(
        oldGeneral: GeneralConfig?,
        newGeneral: GeneralConfig,
        force: Bool
    ) -> Bool {
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
        showsWorkspaceOnLaunch: Bool = true
    ) -> Bool {
        guard allowsAppShellAccess || allowDuringFirstRun else { return false }
        guard permissions.microphone == .granted else {
            onboarding.showAlways()
            return false
        }
        let request = Self.sessionLaunchRequest(
            from: config,
            workingDirectory: workingDirectory,
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
        // Kill any existing voice bridge so only one session is active
        processManager.clearBridgeStopRequested()
        processManager.killBridge()
        if embeddedTerminal.phase.isActive || embeddedTerminal.isEmbeddedProcessRunning {
            embeddedTerminal.end()
        }
        menuSessionActive = true
        sessionStartTime = Date()
        sessionBridgeSeen = false
        sessionReadyShownForCurrentBridgeSession = false
        sessionPromptGate.reset()
        activeSessionLaunchConfig = launchConfig
        // Bridge is about to launch — assume alive until watchdog says otherwise
        bridgeAliveCache = true

        // Start STT if not already running
        if sttEngine == nil {
            startConfiguredSTT(reason: "session-start", failureLogPrefix: "STT engine session start failed")
        }

        let sessionDirectory = WorkspaceFolder.url(from: launchConfig.general.working_directory).path
        do {
            try embeddedTerminal.beginPreparing(
                providerName: launchConfig.general.provider.displayName,
                workingDirectory: sessionDirectory
            )
            let voiceDelivery: ProcessManager.SessionVoiceDelivery =
                (request.destination == .embedded) ? .appOwned : .agentSkill
            let prepared = try processManager.prepareNewSession(
                config: launchConfig,
                voiceDelivery: voiceDelivery
            )
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
            embeddedTerminal.markFailed(error)
            menuSessionActive = false
            activeSessionLaunchConfig = nil
            bridgeAliveCache = false
            sessionBridgeSeen = false
            sessionReadyShownForCurrentBridgeSession = false
            sessionStartTime = .distantPast
            statusText = "Ready"
            NSLog("[AppState] Failed to start session: \(error)")
            return false
        }
        isRunning = true
        if menuSessionActive {
            statusText = "Session"
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

    private func startOnboardingTutorialSession() -> Bool {
        if hasActiveSession {
            return true
        }
        return newSession(
            allowDuringFirstRun: true,
            showsWorkspaceOnLaunch: false
        )
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
    func toggleBoard(allowDuringFirstRun: Bool = false) -> Bool {
        guard allowsAppShellAccess || allowDuringFirstRun else { return false }
        return programBoardOverlay.toggle()
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

    func activateProject(pathOrAlias: String, provider: String?) -> ProjectActivationReply {
        do {
            let project = try ProjectResolver.activateProject(
                matching: pathOrAlias,
                provider: provider
            )
            return .activated(repoPath: project.repoPath.path)
        } catch {
            return .failed(message: "\(error)")
        }
    }

    // MARK: - Bridge watchdog

    private var bridgeRecoveryFallbackConfig: AppConfig? {
        guard menuSessionActive else { return nil }
        return activeSessionLaunchConfig ?? config
    }

    private func startBridgeWatchdog() {
        stopBridgeWatchdog()
        let daemonAlive = processManager.bridgeAlive()
        let consumerAlive = daemonAlive && processManager.bridgeConsumerAlive()
        let hasSessionContext = processManager.bridgeRecoveryContext(
            fallbackConfig: bridgeRecoveryFallbackConfig
        ) != nil
        bridgeAliveCache = ProcessManager.relaySessionAlive(
            daemonAlive: daemonAlive,
            consumerAlive: consumerAlive,
            hasSessionContext: hasSessionContext
        )
        bridgeWatchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let daemonAlive = self.processManager.bridgeAlive()
            let consumerAlive = daemonAlive && self.processManager.bridgeConsumerAlive()
            let hasSessionContext = self.processManager.bridgeRecoveryContext(
                fallbackConfig: self.bridgeRecoveryFallbackConfig
            ) != nil
            let pendingDeliveryState = self.processManager.pendingVoiceCommandDeliveryState()
            let pendingDeliveryTimedOut = pendingDeliveryState == .timedOut
            let alive = ProcessManager.relaySessionAlive(
                daemonAlive: daemonAlive,
                consumerAlive: consumerAlive,
                hasSessionContext: hasSessionContext
            )
            let wasAlive = self.bridgeAliveCache
            let elapsed = Date().timeIntervalSince(self.sessionStartTime)
            let action = Self.bridgeWatchdogAction(
                menuSessionActive: self.menuSessionActive,
                daemonAlive: daemonAlive,
                consumerAlive: consumerAlive,
                hasSessionContext: hasSessionContext,
                wasAlive: wasAlive,
                sessionBridgeSeen: self.sessionBridgeSeen,
                elapsedSinceSessionStart: elapsed,
                pendingDeliveryTimedOut: pendingDeliveryTimedOut,
                stopRequested: self.processManager.bridgeStopRequested(),
                recoverySuppressed: self.bridgeRecoverySuppressedForUpdate
            )

            if daemonAlive {
                self.programBoardOverlay.refreshRouteIfNeeded()
            }

            switch action {
            case .reapOrphan:
                NSLog("[AppState] Relay bridge orphaned before any active session, killing")
                self.processManager.killBridge()
                self.bridgeAliveCache = false
                self.menuSessionActive = false
                self.activeSessionLaunchConfig = nil
                self.sessionBridgeSeen = false
                self.sessionReadyShownForCurrentBridgeSession = false
                self.statusText = "Ready"
                return
            case .keepDaemon:
                // A busy Codex/Claude turn can stop touching the consumer
                // heartbeat while git/build work continues. A completed Codex
                // App turn can also leave a valid context-backed daemon idle.
                // Keep that session alive so TTS, the board, and queued voice
                // input can recover.
                self.bridgeAliveCache = true
                if self.statusText != "Session" {
                    self.statusText = "Session"
                }
                return
            case .waitForConsumer:
                self.bridgeAliveCache = true
                if self.statusText != "Voice command waiting" {
                    self.surfaceVoiceCommandWaiting()
                }
                return
            case .waitForLaunch:
                self.bridgeAliveCache = true
                return
            case .recoverDaemon:
                self.bridgeAliveCache = false
                let reason = pendingDeliveryTimedOut
                    ? "voice-delivery-timeout"
                    : (wasAlive ? "bridge-lost" : "menu-session-lost")
                if self.startBridgeRecovery(reason: reason) {
                    return
                }
                NSLog("[AppState] Bridge died but no recovery context was available")
                self.menuSessionActive = false
                self.activeSessionLaunchConfig = nil
                self.sessionBridgeSeen = false
                self.sessionReadyShownForCurrentBridgeSession = false
                self.surfaceBridgeRecoveryFailure(reason: reason)
                return
            case .markDead:
                self.bridgeAliveCache = false
            case .alive:
                self.bridgeAliveCache = true
            }

            // Track externally-started bridges (e.g. /relay-bridge)
            if alive && !self.menuSessionActive && self.statusText != "Session" {
                self.statusText = "Session"
                // External /relay-bridge counts as the first session run
                // for onboarding purposes — same as the menu Start Session
                // path. Without this, a user who only ever uses the slash
                // command would keep seeing the All Set re-prompt.
                self.onboarding.markSessionRun()
            }

            if alive {
                self.sweepReadyTicketsForActiveProject(
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

            if self.menuSessionActive && alive {
                self.surfaceSessionReadyIfNeeded(daemonAlive: daemonAlive, consumerAlive: consumerAlive)
                self.sessionBridgeSeen = true
            }

            if wasAlive && !alive && !self.menuSessionActive {
                // Relay-bridge session ended externally — same idea: update
                // status quietly, let the prompt fire on next Caps Lock.
                NSLog("[AppState] Relay bridge died, reverting to awareness")
                self.statusText = "Ready"
            }
        }
    }

    private func surfaceSessionReadyIfNeeded(daemonAlive: Bool, consumerAlive: Bool) {
        guard Self.shouldSurfaceSessionReady(
            menuSessionActive: menuSessionActive,
            sessionBridgeSeen: sessionBridgeSeen,
            sessionReadyShownForCurrentBridgeSession: sessionReadyShownForCurrentBridgeSession,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            daemonAlive: daemonAlive,
            consumerAlive: consumerAlive
        ) else {
            return
        }
        sessionReadyShownForCurrentBridgeSession = true
        stateMachine.showSessionReady()
        syncNotchActivitySurface()
    }

    static func shouldSurfaceSessionReady(
        menuSessionActive: Bool,
        sessionBridgeSeen: Bool,
        sessionReadyShownForCurrentBridgeSession: Bool,
        bridgeRecoveryInFlight: Bool,
        daemonAlive: Bool,
        consumerAlive: Bool
    ) -> Bool {
        menuSessionActive
            && !sessionBridgeSeen
            && !sessionReadyShownForCurrentBridgeSession
            && !bridgeRecoveryInFlight
            && daemonAlive
            && consumerAlive
    }

    enum BridgeWatchdogAction: Equatable {
        case alive
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
            return .alive
        }
        if daemonAlive && !consumerAlive {
            if pendingDeliveryTimedOut {
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
        if pendingDeliveryState == .waiting || pendingDeliveryState == .timedOut {
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
        guard let context = processManager.bridgeRecoveryContext(fallbackConfig: bridgeRecoveryFallbackConfig) else {
            return false
        }
        let now = Date()
        if now.timeIntervalSince(lastBridgeRecoveryAt) < Self.bridgeRecoveryCooldown {
            return true
        }

        bridgeRecoveryInFlight = true
        lastBridgeRecoveryAt = now
        statusText = "Session reconnecting"
        NSLog("[AppState] Relaunching voice bridge daemon for \(context.workingDirectory) reason=\(reason)")

        let processManager = self.processManager
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recovered = processManager.relaunchBridgeDaemon(context: context)
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
                    self.sessionBridgeSeen = false
                    self.sessionReadyShownForCurrentBridgeSession = false
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
                    self.sessionBridgeSeen = false
                    self.sessionReadyShownForCurrentBridgeSession = false
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
    }

    private func sweepReadyTicketsForActiveProject(trigger: String) {
        guard let project = ProjectResolver.resolve() else { return }
        OrchestratorClient.sweepReadyTickets(repoPath: project.repoPath.path, trigger: trigger)
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
            onServiceEvent: { [weak self] source, state, text in
                self?.handleOnboardingTutorialServiceEvent(source: source, state: state, text: text)
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
                    _ = self.toggleBoard()
                }
            },
            onActivateProject: { [weak self] pathOrAlias, provider in
                guard let self else {
                    return .failed(message: "Relay Runner app state is unavailable.")
                }
                return await MainActor.run {
                    self.activateProject(pathOrAlias: pathOrAlias, provider: provider)
                }
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

        // Workspace overlay — install Esc dismissal only once macOS has already
        // granted Input Monitoring. The double-tap Shift board trigger is
        // emitted by the STT gesture monitor so it shares the same recovery
        // path as Option/Control activation gestures.
        if permissions.inputMonitoring == .granted {
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
                engine.boardToggleRequested = false
                let allowDuringOnboarding = self.onboarding.isAwaitingTutorialWorkspaceToggle
                if self.toggleBoard(allowDuringFirstRun: allowDuringOnboarding),
                   allowDuringOnboarding {
                    self.onboarding.noteTutorialWorkspaceToggled()
                }
            }

            // Session prompt: handle responses
            if case .sessionPrompt = self.stateMachine.state {
                if engine.playRequested {
                    // Double-tap Alt → start new session
                    engine.playRequested = false
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
            if justStartedRecording {
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
                        self.showSessionPromptIfAllowed()
                    }
                    engine.cancelRecording()
                    self.wasRecording = false
                    return
                case .promptForSession:
                    self.bridgeAliveCache = false
                    self.menuSessionActive = false
                    self.showSessionPromptIfAllowed()
                    engine.cancelRecording()
                    self.wasRecording = false
                    return
                }
            }

            // Clear stale play requests
            if engine.playRequested {
                engine.playRequested = false
                self.onboarding.noteTutorialPlaybackRequested()
            }

            if engine.wasCancelled {
                engine.wasCancelled = false
                let playbackActive: Bool
                if case .speaking = self.stateMachine.state {
                    playbackActive = true
                } else {
                    playbackActive = false
                }
                self.onboarding.noteTutorialCancelRequested(playbackActive: playbackActive)
                self.stateMachine.setCancelled()
            } else {
                self.stateMachine.updateSTT(isRecording: nowRecording, partial: engine.partialTranscription)
            }
            self.wasRecording = nowRecording
            self.syncNotchActivitySurface()
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
            onboarding.noteTutorialRecordingSent()
        }
    }

    private func handleOnboardingTutorialServiceEvent(source: String, state: String, text: String?) {
        guard source == "tts", state == "message_waiting" else { return }
        onboarding.noteTutorialResponseReady(text)
    }

    private func suspendWorkspaceForExternalWindow() {
        programBoardOverlay.suspendForExternalWindow()
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
