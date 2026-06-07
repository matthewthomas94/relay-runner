import Foundation
import SwiftUI

@Observable
final class AppState {
    var config: AppConfig
    var isRunning = false
    var statusText = "Idle"

    private(set) var sttEngine: STTEngine?

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
    private var perimeterOverlay: PerimeterOverlayManager?
    private var eventBus: StateEventBus?
    private var actionsBus: ActionsConfirmBus?
    private var sttPollTimer: Timer?
    private var bridgeWatchdog: Timer?
    /// True while a menu-started terminal session owns the bridge.
    private var menuSessionActive = false
    /// Cached by the watchdog so the 20fps poll timer avoids spawning pgrep.
    private var bridgeAliveCache = false
    private var wasRecording = false
    /// Caps Lock state when the session prompt was shown — any toggle dismisses it.
    private var sessionPromptCapsState = false
    private var sessionPromptGate = SessionPromptGate()
    /// Grace period: don't let the watchdog revert a session before the bridge has time to start.
    private var sessionStartTime: Date = .distantPast
    /// Has the bridge for the current menu-started session been observed alive at least once?
    /// Used to distinguish "still starting up" from "came up and then died".
    private var sessionBridgeSeen = false
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
    var hasActiveSession: Bool { menuSessionActive || bridgeAliveCache }

    init() {
        self.config = ConfigManager.shared.load()
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
            // Don't touch the microphone at install/open time. Onboarding owns
            // the permission ask, and STT starts only after the grant applies.
            if self.permissions.microphone == .granted {
                self.startAwareness()
            } else {
                self.statusText = "Microphone permission needed"
            }
            self.onboarding.showIfNeeded()
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
        processManager.killBridge()
        menuSessionActive = false
        bridgeAliveCache = false
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
        stopOverlay()
        sttEngine?.stop()
        sttEngine = nil
        processManager.stopServices()
        isRunning = false
        statusText = "Idle"
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
            let alive = daemonAlive && self.processManager.bridgeConsumerAlive()
            let wasAlive = self.bridgeAliveCache
            self.bridgeAliveCache = alive

            // Reap orphaned relay bridges quietly. A live daemon without a
            // consumer is not a usable session, but surfacing the no-session
            // pill from a polling path is noisy; wait for an explicit record
            // or board attempt before teaching the recovery action.
            if daemonAlive && !alive {
                NSLog("[AppState] Relay bridge orphaned (consumer heartbeat stale), killing")
                self.processManager.killBridge()
                self.bridgeAliveCache = false
                self.menuSessionActive = false
                self.sessionBridgeSeen = false
                self.statusText = "Ready"
                return
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

            if self.menuSessionActive && !alive {
                // Only declare dead once we've actually seen the bridge alive
                // (real death), or after a generous absolute timeout (true
                // launch failure — covers cold starts where Kokoro load +
                // venv setup can easily exceed the old 15s grace).
                let elapsed = Date().timeIntervalSince(self.sessionStartTime)
                if self.sessionBridgeSeen || elapsed > 90 {
                    NSLog("[AppState] Menu-started session bridge died, reverting to awareness")
                    self.menuSessionActive = false
                    self.sessionBridgeSeen = false
                    self.statusText = "Ready"
                    // Don't auto-show the session prompt overlay — wait until
                    // the user actually tries to record (Caps Lock path in
                    // sttPollTimer fires it then).
                }
            } else if wasAlive && !alive && !self.menuSessionActive {
                // Relay-bridge session ended externally — same idea: update
                // status quietly, let the prompt fire on next Caps Lock.
                NSLog("[AppState] Relay bridge died, reverting to awareness")
                self.statusText = "Ready"
            }
        }
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

        // Board overlay — install global ⌃⌥⌘ / Esc hotkeys only once macOS has
        // already granted Input Monitoring. The menu and MCP toggle still work
        // without that optional permission, and deferring avoids a TCC prompt
        // during first launch.
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
        // Perimeter overlay (purple band on every screen while
        // .actionGlow is active; pulses while a confirmation is pending).
        let perimeter = PerimeterOverlayManager()
        perimeter.start(stateMachine: stateMachine)
        perimeterOverlay = perimeter

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
                return
            }

            // No bridge alive: intercept recording and show prompt.
            // Real-time check on each recording start — the cached value
            // can be stale for up to 3s after a bridge dies.
            // Also detect orphaned relay bridges (process alive but no consumer).
            if justStartedRecording {
                let bridgeProcessUp = self.processManager.bridgeAlive()
                let bridgeUp = bridgeProcessUp && self.processManager.bridgeConsumerAlive()
                self.bridgeAliveCache = bridgeUp
                if !bridgeUp {
                    if bridgeProcessUp {
                        self.processManager.killBridge()
                    }
                    self.menuSessionActive = false
                    engine.cancelRecording()
                    self.showSessionPromptIfAllowed()
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
        }
    }

    private func stopOverlay() {
        sttPollTimer?.invalidate()
        sttPollTimer = nil

        overlayController?.stop()
        overlayController = nil

        perimeterOverlay?.stop()
        perimeterOverlay = nil

        Task { await eventBus?.stop() }
        eventBus = nil

        Task { await actionsBus?.stop() }
        actionsBus = nil

        stateMachine.reset()
    }

}
