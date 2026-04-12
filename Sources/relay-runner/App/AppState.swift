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

    init() {
        self.config = ConfigManager.shared.load()
    }

    func startListening() {
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
        statusText = "Listening"

        startOverlay()
    }

    func stopServices() {
        guard isRunning else { return }
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
            if engine.wasCancelled {
                engine.wasCancelled = false
                self.stateMachine.setCancelled()
            } else {
                self.stateMachine.updateSTT(isRecording: engine.isRecording, partial: engine.partialTranscription)
            }
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
