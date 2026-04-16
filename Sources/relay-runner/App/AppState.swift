import Foundation
import SwiftUI

@Observable
final class AppState {
    var config: AppConfig
    var isRunning = false
    var statusText = "Idle"

    private(set) var sttEngine: STTEngine?

    let configManager = ConfigManager.shared
    let processManager = ProcessManager()

    // Phase 2: Awareness overlay
    let stateMachine = StateMachine()
    private var overlayController: OverlayController?
    private var eventBus: StateEventBus?
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

    /// Whether a direct-mode session is active (for menu bar UI).
    var hasActiveSession: Bool { directSessionActive }

    init() {
        self.config = ConfigManager.shared.load()
        // Start awareness on next run loop tick (after app finishes launching)
        DispatchQueue.main.async { [weak self] in
            self?.startAwareness()
        }
    }

    /// Start STT + overlay for gesture detection. No bridge — user must
    /// start a session or run /relay-bridge manually.
    private func startAwareness() {
        guard sttEngine == nil else { return }

        let engine = STTEngine(config: config.stt)
        sttEngine = engine
        Task {
            do {
                try await engine.start()
            } catch {
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
        // Kill any existing voice bridge so only one session is active
        processManager.killBridge()
        directSessionActive = true
        sessionStartTime = Date()
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
            }

            // Detect orphaned relay bridge (process alive but consumer dead)
            if alive && !self.directSessionActive && !self.processManager.bridgeConsumerAlive() {
                NSLog("[AppState] Relay bridge orphaned (consumer heartbeat stale), killing")
                self.processManager.killBridge()
                self.bridgeAliveCache = false
                self.statusText = "Ready"
                self.stateMachine.showSessionPrompt()
                return
            }

            if self.directSessionActive && !alive {
                // Give the bridge 15s to start before declaring it dead
                let elapsed = Date().timeIntervalSince(self.sessionStartTime)
                if elapsed > 15 {
                    NSLog("[AppState] Direct session bridge died, reverting to awareness")
                    self.directSessionActive = false
                    self.statusText = "Ready"
                    self.stateMachine.showSessionPrompt()
                }
            } else if wasAlive && !alive && !self.directSessionActive {
                // Relay-bridge session ended externally
                NSLog("[AppState] Relay bridge died, reverting to awareness")
                self.statusText = "Ready"
                self.stateMachine.showSessionPrompt()
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

        // Overlay controller (panel + glow + pill)
        let oc = OverlayController(config: config.awareness)
        oc.start(stateMachine: stateMachine)
        overlayController = oc

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

        Task { await eventBus?.stop() }
        eventBus = nil

        stateMachine.reset()
    }

}
