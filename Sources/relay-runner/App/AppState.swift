import Foundation
import SwiftUI

@Observable
final class AppState {
    struct LaunchPlan: Equatable {
        let startsOverlay: Bool
        let startsAwareness: Bool
        let statusText: String?
    }

    var config: AppConfig
    var isRunning = false
    var statusText = "Idle"

    private(set) var sttEngine: STTEngine?
    @ObservationIgnored private let checkForUpdatesAction: @MainActor () -> Void
    @ObservationIgnored private let refreshBundledOrchestratorDaemon: () async -> OrchestratorDaemonRefreshResult
    @ObservationIgnored private let refreshBundledServicesOnLaunch: Bool

    var serviceLifecycleMessage: String?

    /// Populated when STTEngine.start() throws — surfaces a human-readable
    /// failure in the menu bar with a Retry Setup action. Nil when STT is
    /// healthy or still loading.
    private(set) var sttEngineError: String?

    /// Non-nil while STT is still preparing (loading model, compiling, etc.).
    /// The onboarding Ready step and menu bar both show this in place of
    /// "Ready" so the user knows the app isn't actually idle.
    var setupStatusMessage: String? {
        guard let engine = sttEngine else { return nil }
        let msg = engine.statusMessage
        if msg.isEmpty || msg == "Listening" { return nil }
        return msg
    }

    /// Translated version of `sttEngineError`, suitable for direct display.
    var sttEngineErrorTranslation: ErrorTranslator.Translation? {
        sttEngineError.map { ErrorTranslator.translate($0) }
    }

    let configManager = ConfigManager.shared
    let processManager = ProcessManager()
    let permissions = PermissionsManager()
    // @ObservationIgnored: @Observable's macro expansion doesn't compose with
    // `lazy`. The controller is stateless from the UI's perspective — views
    // observe PermissionsManager directly — so hiding it from observation
    // costs nothing.
    @ObservationIgnored lazy var onboarding: OnboardingController = {
        OnboardingController(
            permissions: permissions,
            setupStatus: { [weak self] in self?.setupStatusMessage },
            getWorkingDirectory: { [weak self] in self?.config.general.working_directory ?? "" },
            getAgentProvider: { [weak self] in self?.config.general.provider ?? .codex },
            getModel: { [weak self] in self?.config.general.model ?? GeneralConfig.defaultModel },
            getCodexReasoningEffort: { [weak self] in
                self?.config.general.codex_reasoning_effort ?? GeneralConfig.defaultCodexReasoningEffort
            },
            setAgentProvider: { [weak self] provider in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.selectProvider(provider)
                self.saveConfig(newConfig)
            },
            setModel: { [weak self] model in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.model = GeneralConfig.isModel(model, validFor: newConfig.general.provider)
                    ? model
                    : GeneralConfig.defaultModel
                self.saveConfig(newConfig)
            },
            setCodexReasoningEffort: { [weak self] effort in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.codex_reasoning_effort = GeneralConfig.normalizedCodexReasoningEffort(effort)
                self.saveConfig(newConfig)
            },
            setWorkingDirectory: { [weak self] path in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.working_directory = path
                self.saveConfig(newConfig, forceWorkspaceDiscovery: true)
            },
            startSession: { [weak self] in self?.newSession() }
        )
    }()
    @ObservationIgnored private let permissionNotifier = PermissionNotifier()

    /// One-shot wizard that fires when MCP detects a not-yet-onboarded
    /// parent terminal/IDE. AppState owns the controller; the bus calls into
    /// it via the closures wired in `startOverlay`. @ObservationIgnored
    /// because the controller's window lifecycle is imperative — UI doesn't
    /// observe it directly.
    @ObservationIgnored private let parentOnboardingController = ParentOnboardingController()

    // Phase 2: Awareness overlay
    let stateMachine = StateMachine()
    private var overlayController: OverlayController?
    @ObservationIgnored private let boardOverlay = BoardOverlayController()
    @ObservationIgnored private let programBoardOverlay = ProgramBoardOverlayController()
    @ObservationIgnored private let notchStatusController = NotchStatusController()
    private var perimeterOverlay: PerimeterOverlayManager?
    private var eventBus: StateEventBus?
    private var actionsBus: ActionsConfirmBus?
    private var sttPollTimer: Timer?
    private var notchActivityTimer: Timer?
    private var notchActivityRunStates: [RunState] = []
    private var notchActivityTickets: [Ticket] = []
    private var bridgeWatchdog: Timer?
    private var programStatusTask: Task<Void, Never>?
    /// True while a menu-started terminal session owns the bridge.
    private var menuSessionActive = false {
        didSet { syncNotchStatusSurface() }
    }
    /// Cached by the watchdog so the 20fps poll timer avoids spawning pgrep.
    private var bridgeAliveCache = false {
        didSet { syncNotchStatusSurface() }
    }
    private var wasRecording = false
    /// Caps Lock state when the session prompt was shown — any toggle dismisses it.
    private var sessionPromptCapsState = false
    private var sessionPromptGate = SessionPromptGate()
    /// Grace period: don't let the watchdog revert a session before the bridge has time to start.
    private var sessionStartTime: Date = .distantPast
    /// Has the bridge for the current menu-started session been observed alive at least once?
    /// Used to distinguish "still starting up" from "came up and then died".
    private var sessionBridgeSeen = false
    private var bridgeRecoveryInFlight = false {
        didSet { syncNotchStatusSurface() }
    }
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

    private func syncNotchStatusSurface() {
        notchStatusController.setActive(hasActiveSession)
        syncNotchActivitySurface()
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
        notchActivityRunStates = []
        notchActivityTickets = []
        notchStatusController.setActivityLabels([])
    }

    private func syncNotchActivityProjectState() {
        guard hasActiveSession,
              let project = ProjectResolver.resolve() else {
            notchActivityRunStates = []
            notchActivityTickets = []
            syncNotchActivitySurface()
            return
        }

        notchActivityRunStates = Array(RunStateStore.load(forRepo: project.repoPath).values)
        notchActivityTickets = ProjectResolver.scanTickets(in: project)
        syncNotchActivitySurface()
    }

    private func syncNotchActivitySurface() {
        guard hasActiveSession else {
            notchStatusController.setActivityLabels([])
            return
        }

        let labels = NotchActivityLabelPlanner.labels(
            for: stateMachine.state,
            activeRuns: notchActivityRunStates,
            tickets: notchActivityTickets,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight
        )
        notchStatusController.setActivityLabels(labels)
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
            if new == .granted && old != .granted {
                if kind == .microphone {
                    if self.sttEngine == nil {
                        self.startAwareness()
                    } else {
                        self.restartSTTForRecovery()
                    }
                } else if kind == .inputMonitoring {
                    self.boardOverlay.installGlobalHotkeys()
                    self.restartSTTForRecovery()
                }
            }
        }
        // Start awareness on next run loop tick (after app finishes launching)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let launchPlan = Self.launchPlan(for: self.permissions.microphone)
            if launchPlan.startsOverlay {
                // Keep board routing and the no-session/program-board surfaces
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
        let engine = STTEngine(config: config.stt)
        sttEngine = engine
        Task { [weak self] in
            do {
                try await engine.start()
                await MainActor.run { [weak self] in self?.sttEngineError = nil }
            } catch {
                await MainActor.run { [weak self] in
                    self?.sttEngineError = "\(error)"
                }
                NSLog("[AppState] STT restart (\(reason)) failed: \(error)")
            }
        }
    }

    /// Start STT + overlay for gesture detection. No bridge — user must
    /// start a session or run /relay-bridge manually.
    private func startAwareness() {
        guard sttEngine == nil else { return }

        let engine = STTEngine(config: config.stt)
        sttEngine = engine
        Task { [weak self] in
            do {
                try await engine.start()
                await MainActor.run { [weak self] in self?.sttEngineError = nil }
            } catch {
                await MainActor.run { [weak self] in
                    self?.sttEngineError = "\(error)"
                }
                NSLog("[AppState] STT engine failed to start: \(error)")
            }
        }
        isRunning = true
        statusText = "Ready"

        startBridgeWatchdog()
        bridgeAliveCache = false

        startOverlay()
    }

    /// End the active voice session and revert to awareness mode.
    func endSession() {
        processManager.killBridge(stopRequested: true)
        menuSessionActive = false
        bridgeAliveCache = false
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
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
        menuSessionActive = false
        bridgeRecoveryInFlight = false
        stopOverlay()
        sttEngine?.stop()
        sttEngine = nil
        processManager.stopServices()
        isRunning = false
        statusText = "Idle"
    }

    func prepareForSparkleRelaunch() {
        bridgeRecoverySuppressedForUpdate = true
        stopBridgeWatchdog()
        menuSessionActive = false
        bridgeAliveCache = false
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        statusText = "Updating"
        sttEngine?.cancelRecording()
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
            let engine = STTEngine(config: newConfig.stt)
            sttEngine = engine
            Task {
                do {
                    try await engine.start()
                } catch {
                    NSLog("[AppState] STT engine restart failed: \(error)")
                }
            }
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

    func newSession() {
        guard permissions.microphone == .granted else {
            onboarding.showAlways()
            return
        }
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
        menuSessionActive = true
        sessionStartTime = Date()
        sessionBridgeSeen = false
        sessionPromptGate.reset()
        // Bridge is about to launch — assume alive until watchdog says otherwise
        bridgeAliveCache = true

        // Start STT if not already running
        if sttEngine == nil {
            let engine = STTEngine(config: config.stt)
            sttEngine = engine
            Task {
                try? await engine.start()
            }
        }

        // Launch a normal agent terminal and pre-fire relay-bridge voice mode.
        processManager.launchNewSession(config: config)
        isRunning = true
        statusText = "Session"

        // Ensure overlay is running
        if overlayController == nil { startOverlay() }
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

    /// Show or hide the routed board overlay. Single-project sessions read
    /// tickets from that repo's `.orchestrator/`; workspace sessions open the
    /// read-only Program Board.
    func toggleBoard() {
        boardOverlay.toggle()
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

    private func startBridgeWatchdog() {
        stopBridgeWatchdog()
        let daemonAlive = processManager.bridgeAlive()
        bridgeAliveCache = daemonAlive && processManager.bridgeConsumerAlive()
        bridgeWatchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let daemonAlive = self.processManager.bridgeAlive()
            let consumerAlive = daemonAlive && self.processManager.bridgeConsumerAlive()
            let alive = daemonAlive && consumerAlive
            let wasAlive = self.bridgeAliveCache
            let elapsed = Date().timeIntervalSince(self.sessionStartTime)
            let action = Self.bridgeWatchdogAction(
                menuSessionActive: self.menuSessionActive,
                daemonAlive: daemonAlive,
                consumerAlive: consumerAlive,
                wasAlive: wasAlive,
                sessionBridgeSeen: self.sessionBridgeSeen,
                elapsedSinceSessionStart: elapsed,
                stopRequested: self.processManager.bridgeStopRequested(),
                recoverySuppressed: self.bridgeRecoverySuppressedForUpdate
            )

            switch action {
            case .reapOrphan:
                NSLog("[AppState] Relay bridge orphaned before any active session, killing")
                self.processManager.killBridge()
                self.bridgeAliveCache = false
                self.menuSessionActive = false
                self.sessionBridgeSeen = false
                self.statusText = "Ready"
                return
            case .keepDaemon:
                // A busy Codex/Claude turn can stop touching the consumer
                // heartbeat while git/build work continues. Keep an already
                // observed session daemon alive so TTS and queued voice input
                // can recover.
                self.bridgeAliveCache = true
                if self.statusText != "Session" {
                    self.statusText = "Session"
                }
                return
            case .waitForLaunch:
                self.bridgeAliveCache = true
                return
            case .recoverDaemon:
                self.bridgeAliveCache = false
                if self.startBridgeRecovery(reason: wasAlive ? "bridge-lost" : "menu-session-lost") {
                    return
                }
                NSLog("[AppState] Bridge died but no recovery context was available")
                self.menuSessionActive = false
                self.sessionBridgeSeen = false
                self.statusText = "Ready"
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

            // Per-parent permissions wizard. Bridge alive = user has actively
            // engaged voice from a particular terminal/IDE. That's the
            // contextual moment for the wizard.
            //
            // We retry on every alive tick (not just the dead→alive transition)
            // until the wizard either surfaces or the parent is confirmed
            // already onboarded. Reason: MCP's `parent_detected` and the
            // bridge process can come up in either order; on a cold start the
            // bridge often appears first and `currentParent()` returns nil
            // until the MCP server's startup message arrives ~1-2s later.
            // The session-scoped flag prevents re-opening the wizard window
            // every tick while the user has it dismissed.
            if alive {
                if !wasAlive { wizardShownForCurrentBridgeSession = false }
                if !wizardShownForCurrentBridgeSession {
                    self.surfaceParentWizardIfNeeded()
                }
            } else if wasAlive {
                // Bridge died — reset so the next /relay-bridge re-evaluates.
                wizardShownForCurrentBridgeSession = false
            }

            if self.menuSessionActive && alive {
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

    enum BridgeWatchdogAction: Equatable {
        case alive
        case keepDaemon
        case waitForLaunch
        case recoverDaemon
        case reapOrphan
        case markDead
    }

    static func bridgeWatchdogAction(
        menuSessionActive: Bool,
        daemonAlive: Bool,
        consumerAlive: Bool,
        wasAlive: Bool,
        sessionBridgeSeen: Bool,
        elapsedSinceSessionStart: TimeInterval,
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
            return (menuSessionActive || wasAlive) ? .keepDaemon : .reapOrphan
        }
        if menuSessionActive {
            if sessionBridgeSeen || elapsedSinceSessionStart > 90 {
                return .recoverDaemon
            }
            return .waitForLaunch
        }
        return .markDead
    }

    @discardableResult
    private func startBridgeRecovery(reason: String) -> Bool {
        if bridgeRecoverySuppressedForUpdate { return false }
        if processManager.bridgeStopRequested() { return false }
        if bridgeRecoveryInFlight { return true }
        guard let context = processManager.bridgeRecoveryContext(fallbackConfig: menuSessionActive ? config : nil) else {
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
                    self.sessionBridgeSeen = false
                    self.statusText = "Ready"
                    NSLog("[AppState] Voice bridge recovery ignored because session stop was requested")
                    return
                }
                if recovered {
                    self.bridgeAliveCache = true
                    self.sessionStartTime = Date()
                    self.sessionBridgeSeen = false
                    self.statusText = "Session"
                    NSLog("[AppState] Voice bridge daemon recovery succeeded")
                } else {
                    self.bridgeAliveCache = false
                    self.menuSessionActive = false
                    self.sessionBridgeSeen = false
                    self.statusText = "Ready"
                    NSLog("[AppState] Voice bridge daemon recovery failed")
                }
            }
        }
        return true
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
        let bus = StateEventBus(stateMachine: stateMachine)
        eventBus = bus
        Task { await bus.start() }

        // Relay Actions confirmation bus (request/reply socket between the
        // RelayActionsMCP helper and the menu-bar app — drives perimeter
        // glow + double-tap confirmation for propose_action).
        //
        // Wires one parent-onboarding callback for the revocation case:
        // pre-flight discovered a missing permission for an already-onboarded
        // parent → reset and re-surface so the user can re-grant. Proactive
        // first-time wizard surfacing is driven by the bridge watchdog (see
        // `surfaceParentWizardIfNeeded`), tied to "voice just started from
        // this app" rather than "MCP server happened to spawn."
        let onboardingController = parentOnboardingController
        let actions = ActionsConfirmBus(
            stateMachine: stateMachine,
            onParentPermissionRevoked: { parent, _ in
                guard parent != "unknown" else { return }
                ParentOnboardingTracker.resetOnboarded(parent)
                await MainActor.run { onboardingController.show(parent: parent) }
            },
            onToggleBoard: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.toggleBoard()
                }
            },
            onActivateProject: { [weak self] pathOrAlias, provider in
                guard let self else {
                    return .failed(message: "Relay Runner app state is unavailable.")
                }
                return await MainActor.run {
                    self.activateProject(pathOrAlias: pathOrAlias, provider: provider)
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

        // Board overlay — install global double-tap Shift / Esc hotkeys only
        // once macOS has already granted Input Monitoring. The menu and MCP
        // toggle still work without that optional permission, and deferring
        // avoids a TCC prompt during first launch.
        if permissions.inputMonitoring == .granted {
            boardOverlay.installGlobalHotkeys()
        }
        boardOverlay.setThemeResolver { [weak self] in
            guard let state = self?.stateMachine.state else { return nil }
            // ActionGlow intentionally returns nil from `particleTheme` so
            // the bottom particle field stays hidden — but the board has its
            // own glow that should reflect "agent is reading the screen".
            // Map it to .stt so the board glow matches the perimeter dots.
            if case .actionGlow = state { return .stt }
            return state.particleTheme
        }
        // Reuse the existing "no session" pill when the user tries to open
        // the board before any bridge or explicit project activation can
        // resolve a project.
        boardOverlay.setNoSessionHandler { [weak self] in
            self?.showSessionPromptIfAllowed()
        }
        boardOverlay.setProgramBoardHandler { [weak self] in
            self?.programBoardOverlay.toggle()
        }
        programBoardOverlay.setThemeResolver { [weak self] in
            guard let state = self?.stateMachine.state else { return nil }
            if case .actionGlow = state { return .stt }
            return state.particleTheme
        }
        programBoardOverlay.setOpenProjectHandler { [weak self] repoPath in
            guard let self else { return }
            let project = ProjectResolver.LinkedProject(
                repoPath: URL(fileURLWithPath: repoPath)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            )
            self.programBoardOverlay.hide()
            self.boardOverlay.show(project: project)
        }
        // Perimeter overlay (purple band on every screen while
        // .actionGlow is active; pulses while a confirmation is pending).
        let perimeter = PerimeterOverlayManager()
        perimeter.start(stateMachine: stateMachine)
        perimeterOverlay = perimeter
        startNotchActivityPolling()

        // Poll STT engine state → state machine (STT is in-process, no socket needed)
        sttPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, let engine = self.sttEngine else { return }

            let nowRecording = engine.isRecording
            let justStartedRecording = nowRecording && !self.wasRecording

            // Session prompt: handle responses
            if case .sessionPrompt = self.stateMachine.state {
                if engine.playRequested {
                    // Double-tap Alt → start new session
                    engine.playRequested = false
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
                let bridgeProcessUp = self.processManager.bridgeAlive()
                if bridgeProcessUp {
                    self.bridgeAliveCache = true
                } else {
                    self.bridgeAliveCache = false
                    let recovering = self.menuSessionActive
                        && self.startBridgeRecovery(reason: "recording-start")
                    if !recovering {
                        self.menuSessionActive = false
                        self.showSessionPromptIfAllowed()
                    }
                    engine.cancelRecording()
                    self.wasRecording = false
                    return
                }
            }

            // Clear stale play requests
            if engine.playRequested { engine.playRequested = false }

            if engine.wasCancelled {
                engine.wasCancelled = false
                self.stateMachine.setCancelled()
            } else {
                self.stateMachine.updateSTT(isRecording: nowRecording, partial: engine.partialTranscription)
            }
            self.wasRecording = nowRecording
            self.syncNotchActivitySurface()
        }
    }

    private func stopOverlay() {
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
        syncNotchActivitySurface()
    }

}
