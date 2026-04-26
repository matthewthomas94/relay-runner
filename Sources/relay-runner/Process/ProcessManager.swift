import Foundation

final class ProcessManager {

    private var bridgeProcess: Process?

    /// The read-only services directory that ships in the .app bundle (or
    /// repo, for dev). Holds voice_bridge.py, tts_worker.py, requirements.txt,
    /// etc. Crucially does NOT hold the venv anymore — the venv lives at a
    /// user-writable path so non-admin users (or admin-installed bundles
    /// owned by root) can write to it. Match SERVICES_BUNDLE in
    /// scripts/relay-bridge.
    private var bundledServicesDir: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/services")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Dev mode: look for services/ relative to the working directory or project root
        for base in [URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                     Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()] {
            let candidate = base.appendingPathComponent("services")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
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

    /// Path to the venv python the install creates. Match SERVICES_DIR/.venv
    /// in scripts/relay-bridge and `userVenvPython` in VenvInstaller.swift —
    /// all three must agree or the SwiftUI thinks setup is incomplete while
    /// the bash side has actually finished it.
    private static var userVenvPython: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("relay-runner/services/.venv/bin/python3")
            .path
    }

    /// Path to the bundled relay-bridge script — the single source of truth
    /// for venv install + voice-bridge launch logic. ProcessManager defers
    /// to it instead of duplicating the install bash inline.
    private var bundledRelayBridge: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/scripts/relay-bridge")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        // Dev mode: relay-bridge in repo's scripts/
        let repoLocal = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/relay-bridge")
        return repoLocal
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
    /// The launcher script defers to the bundled `relay-bridge` for the venv
    /// install (single source of truth — relay-bridge handles relocatable
    /// Python download, pip deps, and Kokoro model pre-download), then
    /// exec's voice_bridge.py against the user-Library venv it set up.
    func launchNewSession(config: AppConfig) {
        let configPath = ConfigManager.shared.configPath.path
        let bridgeScript = bundledServicesDir.appendingPathComponent("voice_bridge.py").path
        let relayBridge = bundledRelayBridge.path
        let python = Self.userVenvPython
        NSLog("[ProcessManager] launchNewSession: relayBridge=\(relayBridge) bridgeScript=\(bridgeScript) configPath=\(configPath)")

        let launcher = "/tmp/voice_bridge_launch.command"
        let cdLine = Self.cdLine(config.general.working_directory)
        let script = """
        #!/bin/bash
        \(Self.shellProfileSource())
        # Ensure venv + deps + speech-model + Claude CLI are installed.
        # relay-bridge short-circuits in well under a second when everything's
        # already in place; on first run it does the full no-admin install.
        # Either way, the user sees its progress in the Terminal that just
        # opened.
        '\(relayBridge)' --venv-only || { echo '[Relay Runner] Setup failed.'; exit 1; }
        # claude.ai/install.sh symlinks the Claude Code binary at
        # ~/.local/bin/claude. Make sure that's on PATH for python's
        # shutil.which("claude") lookup downstream — the user's shell
        # profile sourced above usually adds it, but on fresh installs
        # the relay-bridge install just dropped the binary moments ago
        # and the profile isn't aware of it yet.
        export PATH="$HOME/.local/bin:$PATH"
        \(cdLine)
        '\(python)' '\(bridgeScript)' --config '\(configPath)'
        echo ''
        echo '[Relay Runner] Session ended.'
        """
        try? script.write(toFile: launcher, atomically: true, encoding: String.Encoding.utf8)

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

    /// Force-install the /relay-bridge and /relay-stop slash command files
    /// by shelling out to `relay-bridge --install-skills`. The .md content
    /// itself lives in the bash script (single source of truth — the
    /// onboarding bootstrap and this Settings action both read from the
    /// same place). Always overwrites — Settings shows an explicit
    /// confirmation alert before this is reached.
    @discardableResult
    func installSkill() -> Bool {
        let proc = Process()
        proc.executableURL = bundledRelayBridge
        proc.arguments = ["--install-skills"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                NSLog("[ProcessManager] Installed Claude Code skills via \(bundledRelayBridge.path)")
                return true
            }
            NSLog("[ProcessManager] relay-bridge --install-skills exited with code \(proc.terminationStatus)")
            return false
        } catch {
            NSLog("[ProcessManager] Failed to launch relay-bridge --install-skills: \(error)")
            return false
        }
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
