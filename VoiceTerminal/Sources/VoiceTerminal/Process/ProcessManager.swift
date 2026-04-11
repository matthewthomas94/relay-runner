import Foundation

final class ProcessManager {

    private var bridgeProcess: Process?

    // Paths resolved relative to the app or dev environment
    private var servicesDir: URL {
        // Dev mode: look for services/ relative to the working directory or project root
        for base in [URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                     Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()] {
            let candidate = base.appendingPathComponent("services")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Walk up from the executable location
        if let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<5 {
                let candidate = dir.appendingPathComponent("services")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return URL(fileURLWithPath: "services")
    }

    private var pythonBin: String {
        let venvPython = servicesDir.appendingPathComponent(".venv/bin/python3").path
        if FileManager.default.isExecutableFile(atPath: venvPython) {
            return venvPython
        }
        return "python3"
    }

    // MARK: - Bridge lifecycle

    func bridgeAlive() -> Bool {
        guard FileManager.default.fileExists(atPath: "/tmp/voice_bridge.sock") else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "voice_bridge.py"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Kill any running voice_bridge process (but leave the terminal window open).
    func killBridge() {
        if bridgeAlive() {
            SocketClient.bridgeSend("shutdown")
            Thread.sleep(forTimeInterval: 0.5)
        }
        if bridgeAlive() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-f", "voice_bridge.py"]
            try? proc.run()
            proc.waitUntilExit()
        }
        // Clean up bridge socket so the next session can bind it
        try? FileManager.default.removeItem(atPath: "/tmp/voice_bridge.sock")
    }

    func startServices(config: AppConfig) {
        // Start bridge if not already running (relay-bridge may have started it)
        if !bridgeAlive() {
            launchBridgeTerminal(config: config)
        } else {
            NSLog("[ProcessManager] Bridge already running, skipping terminal launch")
        }
    }

    func stopServices() {
        // Ask bridge to shut down gracefully
        if bridgeAlive() {
            SocketClient.bridgeSend("shutdown")
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Force kill if still alive
        if bridgeAlive() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-f", "voice_bridge.py"]
            try? proc.run()
            proc.waitUntilExit()
        }
        // Clean up IPC files
        for path in ["/tmp/voice_in.fifo", "/tmp/tts_control.sock", "/tmp/voice_bridge.sock"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Launch voice_bridge.py in direct mode (its own Claude session) in a new terminal tab.
    func launchNewSession(config: AppConfig) {
        let configPath = ConfigManager.shared.configPath.path
        let bridgeScript = servicesDir.appendingPathComponent("voice_bridge.py").path

        let launcher = "/tmp/voice_bridge_launch.sh"
        let script = """
        #!/bin/bash
        exec '\(pythonBin)' '\(bridgeScript)' --config '\(configPath)'
        """
        try? script.write(toFile: launcher, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", launcher]
        try? chmod.run()
        chmod.waitUntilExit()

        // Create FIFO before bridge starts
        let mkfifo = Process()
        mkfifo.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        mkfifo.arguments = ["/tmp/voice_in.fifo"]
        mkfifo.standardError = FileHandle.nullDevice
        try? mkfifo.run()
        mkfifo.waitUntilExit()

        launchInTerminal(config: config, command: "bash \(launcher)")
    }

    // MARK: - Terminal launch (port of lib.rs:272-362)

    private func launchBridgeTerminal(config: AppConfig) {
        let configPath = ConfigManager.shared.configPath.path
        let bridgeScript = servicesDir.appendingPathComponent("voice_bridge.py").path

        // Create launcher script — relay mode (connects to existing Claude session)
        let launcher = "/tmp/voice_bridge_launch.sh"
        let script = """
        #!/bin/bash
        exec '\(pythonBin)' '\(bridgeScript)' --config '\(configPath)' --relay
        """
        try? script.write(toFile: launcher, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", launcher]
        try? chmod.run()
        chmod.waitUntilExit()

        // Create FIFO before bridge starts
        ensureFifo()

        launchInTerminal(config: config, command: "bash \(launcher)")
    }

    private func ensureFifo() {
        let mkfifo = Process()
        mkfifo.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        mkfifo.arguments = ["/tmp/voice_in.fifo"]
        mkfifo.standardError = FileHandle.nullDevice
        try? mkfifo.run()
        mkfifo.waitUntilExit()
    }

    private func launchInTerminal(config: AppConfig, command: String) {
        let terminal = config.general.terminal.lowercased()
        let appleScript: String

        switch terminal {
        case "warp":
            appleScript = """
            tell application "Warp" to activate
            delay 0.5
            tell application "System Events"
              tell process "Warp"
                keystroke "t" using command down
                delay 0.3
                keystroke "\(command)"
                keystroke return
              end tell
            end tell
            """
        case "iterm2", "iterm":
            appleScript = """
            tell application "iTerm2"
                activate
                tell current window
                    create tab with default profile command "\(command)"
                end tell
            end tell
            """
        default:
            appleScript = """
            tell application "Terminal"
                activate
                do script "\(command)"
            end tell
            """
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        try? proc.run()
    }
}
