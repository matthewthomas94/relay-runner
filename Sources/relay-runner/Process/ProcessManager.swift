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

    /// Check if the relay consumer (Claude's bash polling loop) is alive.
    /// Uses two signals: stale heartbeat file and unconsumed voice command.
    func bridgeConsumerAlive() -> Bool {
        let fm = FileManager.default

        // Fast check: if a voice command has been pending for >10s, consumer is dead
        // (in normal flow, Claude reads voice_cmd_ready within ~1s)
        if fm.fileExists(atPath: "/tmp/voice_cmd_ready"),
           let attrs = try? fm.attributesOfItem(atPath: "/tmp/voice_cmd_ready"),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 10 {
            return false
        }

        // Slow check: if heartbeat is stale for >30s, consumer is likely dead
        // (the bash polling loop touches this file every 200ms; it goes stale
        // during normal Claude processing, so we use a generous threshold)
        let heartbeatPath = "/tmp/voice_bridge_heartbeat"
        guard fm.fileExists(atPath: heartbeatPath) else { return true } // no file = old skill version, benefit of doubt
        guard let attrs = try? fm.attributesOfItem(atPath: heartbeatPath),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) < 30
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
        // Clean up all IPC files so the next session starts fresh
        for path in ["/tmp/voice_bridge.sock", "/tmp/voice_cmd_ready", "/tmp/tts_in.fifo", "/tmp/voice_bridge_heartbeat"] {
            try? FileManager.default.removeItem(atPath: path)
        }
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
        let cdLine = Self.cdLine(config.general.working_directory)
        let python = Self.venvPython(servicesDir: sdir)
        let script = """
        #!/bin/bash
        \(Self.shellProfileSource())
        \(Self.venvSetupScript(servicesDir: sdir))
        \(cdLine)
        '\(python)' '\(bridgeScript)' --config '\(configPath)'
        echo ''
        echo '[Relay Runner] Session ended.'
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

    // MARK: - Claude Code skill install

    private static let skillDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands")
    }()

    private static let bridgeSkillPath: URL = skillDir.appendingPathComponent("relay-bridge.md")
    private static let stopSkillPath: URL = skillDir.appendingPathComponent("relay-stop.md")

    var isSkillInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.bridgeSkillPath.path)
            && FileManager.default.fileExists(atPath: Self.stopSkillPath.path)
    }

    @discardableResult
    func installSkill() -> Bool {
        let sdir = servicesDir.path
        let bridgeScript = servicesDir.appendingPathComponent("voice_bridge.py").path
        let configPath = ConfigManager.shared.configPath.path
        let python = Self.venvPython(servicesDir: sdir)
        let reqs = servicesDir.appendingPathComponent("requirements.txt").path

        let content = """
        Connect voice I/O to this Claude session. You become a voice-interactive assistant: listen for spoken input, respond, and speak the response aloud via TTS.

        ## Setup

        1. Verify the Relay Runner app is running:

        ```bash
        pgrep -f 'relay-runner' > /dev/null 2>&1 && echo "app: ok" || echo "app: NOT RUNNING"
        ```

        If not running, tell the user to start the Relay Runner menu bar app, then try `/relay-bridge` again. Do not proceed.

        2. Kill any existing voice bridge and start a new one in relay mode:

        ```bash
        pkill -f 'voice_bridge.py' 2>/dev/null; rm -f /tmp/voice_bridge.sock /tmp/voice_cmd_ready /tmp/voice_bridge_heartbeat
        RELAY_PYTHON='\(python)'
        if [ ! -x "$RELAY_PYTHON" ]; then
            echo "venv: creating..."
            VENV_PYTHON=python3
            for p in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
                if [ -x "$p" ] && "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
                    VENV_PYTHON="$p"
                    break
                fi
            done
            "$VENV_PYTHON" -m venv '\(sdir)/.venv' && '\(sdir)/.venv/bin/pip' install --quiet -r '\(reqs)' && echo "venv: ok" || { echo "venv: FAILED"; exit 1; }
        fi
        nohup "$RELAY_PYTHON" '\(bridgeScript)' --config '\(configPath)' --relay > /tmp/voice_bridge.log 2>&1 &
        ```

        3. Wait for the relay bridge to come up:

        ```bash
        for i in $(seq 1 20); do [ -S /tmp/voice_bridge.sock ] && echo "bridge: ok" && break; sleep 0.5; done; [ -S /tmp/voice_bridge.sock ] || echo "bridge: FAILED"
        ```

        If the bridge failed to start, tell the user to check `/tmp/voice_bridge.log` and stop here.

        ## Voice Interaction Loop

        Now enter a continuous loop. Repeat these steps until the user says "stop listening" or you receive `__INTERRUPT__`:

        ### Step 1: Wait for voice input

        ```bash
        while [ ! -f /tmp/voice_cmd_ready ]; do sleep 0.2; touch /tmp/voice_bridge_heartbeat; [ -S /tmp/voice_bridge.sock ] || { echo "__BRIDGE_DIED__"; exit 0; }; done; cat /tmp/voice_cmd_ready; rm -f /tmp/voice_cmd_ready
        ```

        This blocks until the user speaks via Caps Lock. If the voice bridge is killed (e.g. a new session was started), the loop exits.

        ### Step 2: Process the input

        - If the text is `__BRIDGE_DIED__`, the voice session was ended (another session was started, or the bridge was stopped). Say "Voice session ended." and stop the loop — do NOT go back to Step 1. Clean up and return to normal operation.
        - If the text is `__INTERRUPT__`, acknowledge briefly and go back to Step 1.
        - Otherwise, treat the text as a normal user message. Respond naturally and helpfully, as you would to any typed message.

        ### Step 3: Speak your response

        After generating your response, ensure the bridge is still alive (the app's watchdog may have killed an orphaned bridge during long processing). If it died, restart it so the user still receives your response:

        ```bash
        touch /tmp/voice_bridge_heartbeat
        if ! pgrep -f 'voice_bridge.py' > /dev/null 2>&1; then
            rm -f /tmp/voice_bridge.sock
            nohup '\(python)' '\(bridgeScript)' --config '\(configPath)' --relay > /tmp/voice_bridge.log 2>&1 &
            for i in $(seq 1 20); do [ -S /tmp/voice_bridge.sock ] && break; sleep 0.5; done
        fi
        ```

        Then send the TTS response. Keep it concise and conversational (strip markdown formatting, code blocks, and verbose explanations — speak the key points):

        ```bash
        echo 'YOUR_SPOKEN_RESPONSE' > /tmp/tts_in.fifo
        ```

        Important: Use single quotes and escape any single quotes in your response (`'` becomes `'\\''`). Only send the spoken summary, not the full detailed response.

        ### Step 4: Loop

        Go back to Step 1 and wait for the next voice command.

        ## Cleanup

        When the session ends (user says "stop listening", "exit voice", or similar), clean up:

        ```bash
        pkill -f 'voice_bridge.py' 2>/dev/null; rm -f /tmp/voice_bridge.sock /tmp/voice_cmd_ready /tmp/voice_bridge_heartbeat
        ```

        ## Important Notes

        - You are in a normal Claude session with full tool access. Voice input is just another way for the user to send messages.
        - Speak concisely. TTS responses should be 1-3 sentences summarizing what you did or what you found. The user can read the full detail in the conversation.
        - If the user asks you to run commands, edit files, or do anything you'd normally do, do it. Then speak a brief summary of what happened.
        - The relay daemon handles Caps Lock detection, STT, and TTS playback. You just read commands and write responses.
        """

        let stopContent = """
        Stop the voice I/O bridge for this Claude session. Use this to end a `/relay-bridge` voice session cleanly without exiting Claude Code.

        ## Steps

        1. Kill the voice bridge process and remove its runtime files:

        ```bash
        pkill -f 'voice_bridge.py' 2>/dev/null; rm -f /tmp/voice_bridge.sock /tmp/voice_cmd_ready /tmp/voice_bridge_heartbeat
        ```

        2. Confirm it's stopped:

        ```bash
        pgrep -f 'voice_bridge.py' > /dev/null 2>&1 && echo "bridge: STILL RUNNING" || echo "bridge: stopped"
        ```

        If the bridge is still running, tell the user to check `/tmp/voice_bridge.log` and try again. Otherwise, tell the user the voice session has ended.

        ## Notes

        - This only stops the voice bridge. The Relay Runner menu bar app keeps running.
        - Any active `/relay-bridge` voice loop in another Claude session will detect the dead socket on its next heartbeat and exit on its own.
        - To start voice again, run `/relay-bridge`.
        """

        do {
            try FileManager.default.createDirectory(at: Self.skillDir, withIntermediateDirectories: true)
            try content.write(to: Self.bridgeSkillPath, atomically: true, encoding: .utf8)
            try stopContent.write(to: Self.stopSkillPath, atomically: true, encoding: .utf8)
            NSLog("[ProcessManager] Installed Claude Code skills at \(Self.bridgeSkillPath.path) and \(Self.stopSkillPath.path)")
            return true
        } catch {
            NSLog("[ProcessManager] Failed to install skill: \(error)")
            return false
        }
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
            # Prefer a pinned minor version with broad wheel coverage
            # for kokoro-onnx and its transitive deps. Bare `python3`
            # may be 3.14+, where some transitive wheels are still
            # missing; fall back to it only if no 3.11 – 3.13 is
            # installed, rather than refusing to run.
            find_python() {
                for p in \\
                    /opt/homebrew/bin/python3.13 /usr/local/bin/python3.13 python3.13 \\
                    /opt/homebrew/bin/python3.12 /usr/local/bin/python3.12 python3.12 \\
                    /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11 python3.11 \\
                    /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
                    if command -v "$p" >/dev/null 2>&1 && \\
                       "$p" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3,10) else 1)' 2>/dev/null; then
                        echo "$p"
                        return 0
                    fi
                done
                return 1
            }
            find_brew() {
                for b in brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
                    if command -v "$b" >/dev/null 2>&1; then
                        echo "$b"
                        return 0
                    fi
                done
                return 1
            }
            install_homebrew() {
                if ! command -v curl >/dev/null 2>&1; then
                    echo "[Relay Runner] curl not available — cannot bootstrap Homebrew."
                    return 1
                fi
                echo "[Relay Runner] Homebrew not found. Installing Homebrew..."
                echo "(This may prompt for your macOS password.)"
                NONINTERACTIVE=1 /bin/bash -c \\
                    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 1
                for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                    if [ -x "$b" ]; then
                        eval "$("$b" shellenv)"
                        return 0
                    fi
                done
                return 1
            }
            VENV_PYTHON="$(find_python || true)"
            if [ -z "$VENV_PYTHON" ]; then
                BREW="$(find_brew || true)"
                if [ -z "$BREW" ]; then
                    if ! install_homebrew; then
                        echo "[Relay Runner] Could not install Homebrew automatically."
                        echo "Install it from https://brew.sh then re-run."
                        exit 1
                    fi
                    BREW="$(find_brew || true)"
                fi
                echo "[Relay Runner] No Python 3.10+ found. Installing python@3.13 via Homebrew..."
                echo "(This can take a few minutes on first run.)"
                if ! "$BREW" install python@3.13; then
                    echo "[Relay Runner] brew install python@3.13 failed. See errors above."
                    exit 1
                fi
                VENV_PYTHON="$(find_python || true)"
                if [ -z "$VENV_PYTHON" ]; then
                    echo "[Relay Runner] python@3.13 installed but not found on disk."
                    echo "Try opening a new terminal and re-running."
                    exit 1
                fi
            fi
            echo "Using $("$VENV_PYTHON" --version) at $VENV_PYTHON"
            "$VENV_PYTHON" -m venv '\(venv)' && \\
            '\(venv)/bin/python3' -m pip install --upgrade pip && \\
            '\(venv)/bin/pip' install -r '\(reqs)' && \\
            echo '' && echo '[Relay Runner] Setup complete.' || \\
            { echo ''; echo '[Relay Runner] Setup failed. Check errors above.'; exit 1; }
            echo ''
        fi
        """
    }

    /// Returns a `cd` line for the launcher script, or a comment if empty.
    private static func cdLine(_ workingDirectory: String) -> String {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "# no working directory configured" }
        return "cd '\(trimmed)'"
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
