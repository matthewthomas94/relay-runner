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
            setWorkingDirectory: { [weak self] path in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.working_directory = path
                self.saveConfig(newConfig)
            },
            startSession: { [weak self] in self?.newSession() }
        )
    }()
    @ObservationIgnored private let permissionNotifier = PermissionNotifier()

    // Phase 2: Awareness overlay
    let stateMachine = StateMachine()
    private var overlayController: OverlayController?
    private var perimeterOverlay: PerimeterOverlayManager?
    private var eventBus: StateEventBus?
    private var actionsBus: ActionsConfirmBus?
    private var sttPollTimer: Timer?
    private var bridgeWatchdog: Timer?
    /// True while a direct-mode terminal session owns the bridge.
    private var directSessionActive = false
    /// Cached by the watchdog so the 20fps poll timer avoids spawning pgrep.
    private var bridgeAliveCache = false
    private var wasRecording = false
    /// Caps Lock state when the session prompt was shown — any toggle dismisses it.
    private var sessionPromptCapsState = false
    /// Grace period: don't let the watchdog revert a session before the bridge has time to start.
    private var sessionStartTime: Date = .distantPast
    /// Has the bridge for the current direct session been observed alive at least once?
    /// Used to distinguish "still starting up" from "came up and then died".
    private var sessionBridgeSeen = false

    /// Whether any voice session is active (for menu bar UI). Covers both
    /// direct-mode (menu's Start Session) and externally-started bridges
    /// (the /relay-bridge slash command). The watchdog flips bridgeAliveCache
    /// within ~3 seconds of an external bridge coming up, so /relay-bridge
    /// users see the menu reflect their session promptly.
    var hasActiveSession: Bool { directSessionActive || bridgeAliveCache }

    init() {
        self.config = ConfigManager.shared.load()
        // Watch privacy permissions continuously — macOS doesn't notify us
        // when the user grants/revokes in Settings, so we poll.
        permissions.startMonitoring()
        // Pre-register for Input Monitoring TCC so the app appears in the
        // System Settings list with a toggle when the user lands on that
        // onboarding step — instead of forcing them through the "+" button
        // + Finder dialog. Cheap to call on every launch.
        permissions.registerForInputMonitoringList()
        // Hook permission transitions: notify on revoke, auto-recover STT
        // when mic/input-monitoring comes back (the STT engine binds to the
        // mic + installs NSEvent monitors at start, so neither recovers
        // without a restart).
        permissions.onChange = { [weak self] kind, old, new in
            guard let self else { return }
            self.permissionNotifier.recordChange(kind, from: old, to: new)
            if new == .granted && old != .granted {
                if kind == .microphone || kind == .inputMonitoring {
                    self.restartSTTForRecovery()
                }
            }
        }
        // Start awareness on next run loop tick (after app finishes launching)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Services start regardless — STTEngine etc. handle denied perms
            // gracefully so the app is still usable while onboarding runs.
            self.startAwareness()
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

    /// End the active direct session and revert to awareness mode.
    func endSession() {
        processManager.killBridge()
        directSessionActive = false
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
        directSessionActive = false
        stopOverlay()
        sttEngine?.stop()
        sttEngine = nil
        processManager.stopServices()
        isRunning = false
        statusText = "Idle"
    }

    func saveConfig(_ newConfig: AppConfig) {
        let oldConfig = config
        config = newConfig

        do {
            try configManager.save(newConfig)
        } catch {
            NSLog("[RelayRunner] Failed to save config: \(error)")
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

    func newSession() {
        // Mark first-session-run before we do anything else — the
        // onboarding controller uses this flag to decide whether to
        // re-show the All Set screen on next launch. Marking on
        // attempt is fine: if the launch fails the user still
        // initiated a session, and the kill-bridge step below cleans
        // up so they can retry without onboarding nagging them again.
        onboarding.markSessionRun()
        // Kill any existing voice bridge so only one session is active
        processManager.killBridge()
        directSessionActive = true
        sessionStartTime = Date()
        sessionBridgeSeen = false
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

        // Launch voice_bridge in direct mode (own Claude session) in a terminal
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
        sttEngine?.toggleRecording()
    }

    // MARK: - Bridge watchdog

    private func startBridgeWatchdog() {
        stopBridgeWatchdog()
        bridgeAliveCache = processManager.bridgeAlive()
        bridgeWatchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let alive = self.processManager.bridgeAlive()
            let wasAlive = self.bridgeAliveCache
            self.bridgeAliveCache = alive

            // Track externally-started bridges (e.g. /relay-bridge)
            if alive && !self.directSessionActive && self.statusText != "Session" {
                self.statusText = "Session"
                // External /relay-bridge counts as the first session run
                // for onboarding purposes — same as the menu Start Session
                // path. Without this, a user who only ever uses the slash
                // command would keep seeing the All Set re-prompt.
                self.onboarding.markSessionRun()
            }

            // Detect orphaned relay bridge (process alive but consumer dead).
            // Reap the orphan but don't pop the session-prompt overlay — the
            // user gets the prompt when they actually press Caps Lock with no
            // session, not while Claude is mid-processing on a long task.
            if alive && !self.directSessionActive && !self.processManager.bridgeConsumerAlive() {
                NSLog("[AppState] Relay bridge orphaned (consumer heartbeat stale), killing")
                self.processManager.killBridge()
                self.bridgeAliveCache = false
                self.statusText = "Ready"
                return
            }

            if self.directSessionActive && alive {
                self.sessionBridgeSeen = true
            }

            if self.directSessionActive && !alive {
                // Only declare dead once we've actually seen the bridge alive
                // (real death), or after a generous absolute timeout (true
                // launch failure — covers cold starts where Kokoro load +
                // venv setup can easily exceed the old 15s grace).
                let elapsed = Date().timeIntervalSince(self.sessionStartTime)
                if self.sessionBridgeSeen || elapsed > 90 {
                    NSLog("[AppState] Direct session bridge died, reverting to awareness")
                    self.directSessionActive = false
                    self.sessionBridgeSeen = false
                    self.statusText = "Ready"
                    // Don't auto-show the session prompt overlay — wait until
                    // the user actually tries to record (Caps Lock path in
                    // sttPollTimer fires it then).
                }
            } else if wasAlive && !alive && !self.directSessionActive {
                // Relay-bridge session ended externally — same idea: update
                // status quietly, let the prompt fire on next Caps Lock.
                NSLog("[AppState] Relay bridge died, reverting to awareness")
                self.statusText = "Ready"
            }
        }
    }

    private func stopBridgeWatchdog() {
        bridgeWatchdog?.invalidate()
        bridgeWatchdog = nil
    }

    // MARK: - Overlay management

    private func startOverlay() {
        // State event bus (listens for Python service state)
        let bus = StateEventBus(stateMachine: stateMachine)
        eventBus = bus
        Task { await bus.start() }

        // Computer-action confirmation bus (request/reply socket between the
        // RelayActionsMCP helper and the menu-bar app — drives perimeter
        // glow + double-tap confirmation for propose_action).
        let actions = ActionsConfirmBus(stateMachine: stateMachine)
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

        // Perimeter overlay (purple band on every screen while
        // .computerVision is active; pulses while a confirmation is pending).
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
                let bridgeUp = bridgeProcessUp && (self.directSessionActive || self.processManager.bridgeConsumerAlive())
                self.bridgeAliveCache = bridgeUp
                if !bridgeUp {
                    if bridgeProcessUp {
                        self.processManager.killBridge()
                    }
                    engine.cancelRecording()
                    self.sessionPromptCapsState = CapsLockGesture.isCapsLockOn()
                    self.stateMachine.showSessionPrompt()
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
