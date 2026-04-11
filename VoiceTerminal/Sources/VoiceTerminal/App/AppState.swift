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
    let hotkeyManager = HotkeyManager()

    init() {
        self.config = ConfigManager.shared.load()
        registerHotkeys()
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
    }

    func stopServices() {
        guard isRunning else { return }
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
            NSLog("[VoiceTerminal] Failed to save config: \(error)")
        }

        // Hot-reload running services
        guard isRunning else { return }

        // Always tell bridge to reload TTS settings
        SocketClient.bridgeSend("reload")

        // Re-register hotkeys if controls changed
        if oldConfig.controls != newConfig.controls {
            registerHotkeys()
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
    }

    func ttsCommand(_ cmd: String) {
        SocketClient.ttsSend(cmd)
    }

    private func registerHotkeys() {
        hotkeyManager.register(
            config: config.controls,
            onPlayPause: { [weak self] in self?.ttsCommand("toggle") },
            onSkip: { [weak self] in self?.ttsCommand("skip") }
        )
    }
}
