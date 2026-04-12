import Foundation

final class ProcessManager {

    private var bridgeProcess: Process?

    // Paths resolved relative to the app bundle or dev environment
    private var servicesDir: URL {
        // App bundle: Contents/SharedSupport/services
        let bundledServices = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/services")
        if FileManager.default.fileExists(atPath: bundledServices.path) {
            return bundledServices
        }

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
        NSLog("[ProcessManager] launchNewSession: servicesDir=\(servicesDir.path) bridgeScript=\(bridgeScript) configPath=\(configPath)")

        let launcher = "/tmp/voice_bridge_launch.command"
        let sdir = servicesDir.path
        let script = """
        #!/bin/bash
        \(Self.shellProfileSource())
        \(Self.venvSetupScript(servicesDir: sdir))
        exec '\(Self.venvPython(servicesDir: sdir))' '\(bridgeScript)' --config '\(configPath)'
        """
        try? script.write(toFile: launcher, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", launcher]
        try? chmod.run()
        chmod.waitUntilExit()

        // Create FIFO before bridge starts
        ensureFifo()

        launchInTerminal(command: launcher)
    }

    // MARK: - Terminal launch

    private func launchBridgeTerminal(config: AppConfig) {
        let configPath = ConfigManager.shared.configPath.path
        let bridgeScript = servicesDir.appendingPathComponent("voice_bridge.py").path

        // Create launcher script — relay mode (connects to existing Claude session)
        let launcher = "/tmp/voice_bridge_launch.command"
        let sdir = servicesDir.path
        let script = """
        #!/bin/bash
        \(Self.shellProfileSource())
        \(Self.venvSetupScript(servicesDir: sdir))
        exec '\(Self.venvPython(servicesDir: sdir))' '\(bridgeScript)' --config '\(configPath)' --relay
        """
        try? script.write(toFile: launcher, atomically: true, encoding: .utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", launcher]
        try? chmod.run()
        chmod.waitUntilExit()

        // Create FIFO before bridge starts
        ensureFifo()

        launchInTerminal(command: launcher)
    }

    /// Returns the venv python path for a services directory.
    private static func venvPython(servicesDir: String) -> String {
        "\(servicesDir)/.venv/bin/python3"
    }

    /// Returns shell commands to create a venv and install dependencies if missing.
    private static func venvSetupScript(servicesDir: String) -> String {
        let venv = "\(servicesDir)/.venv"
        let reqs = "\(servicesDir)/requirements.txt"
        return """
        if [ ! -x '\(venv)/bin/python3' ]; then
            echo ''
            echo '╔══════════════════════════════════════════╗'
            echo '║  Relay Runner — First-time setup         ║'
            echo '║  Installing Python dependencies...       ║'
            echo '╚══════════════════════════════════════════╝'
            echo ''
            VENV_PYTHON=python3
            for p in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
                if [ -x "$p" ] && "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
                    VENV_PYTHON="$p"
                    break
                fi
            done
            echo "Using $("$VENV_PYTHON" --version)"
            "$VENV_PYTHON" -m venv '\(venv)' && \\
            '\(venv)/bin/python3' -m pip install --upgrade pip && \\
            '\(venv)/bin/pip' install -r '\(reqs)' && \\
            echo '' && echo '[Relay Runner] Setup complete.' || \\
            { echo ''; echo '[Relay Runner] Setup failed. Check errors above.'; exit 1; }
            echo ''
        fi
        """
    }

    /// Returns shell commands to source the user's profile so PATH includes
    /// tools like claude, python, etc. that aren't on the default app PATH.
    private static func shellProfileSource() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Try zprofile/zshrc first (macOS default), then bash
        let candidates = [
            "\(home)/.zprofile",
            "\(home)/.zshrc",
            "\(home)/.bash_profile",
            "\(home)/.profile",
        ]
        let sources = candidates
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { "source '\($0)' 2>/dev/null" }
            .joined(separator: "\n")
        return sources.isEmpty ? "# no shell profile found" : sources
    }

    private func ensureFifo() {
        let mkfifo = Process()
        mkfifo.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        mkfifo.arguments = ["/tmp/voice_in.fifo"]
        mkfifo.standardError = FileHandle.nullDevice
        try? mkfifo.run()
        mkfifo.waitUntilExit()
    }

    /// Launch a command in Terminal.app via AppleScript `do script`.
    private func launchInTerminal(command: String) {
        let appleScript = """
        tell application "Terminal"
            activate
            do script "bash '\(command)'"
        end tell
        """
        runAppleScript(appleScript)
    }

    private func runAppleScript(_ script: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            if proc.terminationStatus != 0, let errStr = String(data: errData, encoding: .utf8) {
                NSLog("[ProcessManager] osascript failed (\(proc.terminationStatus)): \(errStr)")
            }
        } catch {
            NSLog("[ProcessManager] osascript launch error: \(error)")
        }
    }
}
