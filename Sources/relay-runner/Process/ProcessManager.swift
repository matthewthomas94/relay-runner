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

        // Slow check: if heartbeat is stale for >5 minutes, consumer is likely
        // dead. The skill's bash polling loop touches the file every 200ms
        // while waiting for voice input — but during Claude processing
        // (multi-tool tasks, long agent spawns, builds) nothing is touching
        // it. The threshold has to be generous enough to outlast realistic
        // background work; 5 minutes is comfortably above typical processing
        // and still small enough that a truly closed terminal gets reaped
        // before the user notices the leak.
        let heartbeatPath = "/tmp/voice_bridge_heartbeat"
        guard fm.fileExists(atPath: heartbeatPath) else { return true } // no file = old skill version, benefit of doubt
        guard let attrs = try? fm.attributesOfItem(atPath: heartbeatPath),
              let modified = attrs[.modificationDate] as? Date else { return true }
        return Date().timeIntervalSince(modified) < 300
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

    /// Launch interactive Claude Code in a new terminal tab and have it
    /// auto-fire `/relay-bridge` on startup. That slash command is the
    /// single source of truth for spinning up the voice bridge daemon and
    /// running the polling loop inside the live Claude session — so the
    /// user gets the full Claude Code TUI (model picker, /commands,
    /// thinking stream) and voice in the same window.
    ///
    /// The launcher still calls `relay-bridge --venv-only` first so the
    /// Python venv, Kokoro model, and Claude CLI are all in place before
    /// the slash command runs (which spawns the daemon that needs them).
    /// The skill `.md` files have to exist on disk before launch too,
    /// otherwise `/relay-bridge` is silently treated as a literal prompt;
    /// we self-heal by reinstalling them if they've gone missing.
    func launchNewSession(config: AppConfig) {
        let configPath = ConfigManager.shared.configPath.path
        let relayBridge = bundledRelayBridge.path
        let claudeBinary = Self.resolveClaudeBinary()
        NSLog("[ProcessManager] launchNewSession: relayBridge=\(relayBridge) claudeBinary=\(claudeBinary) configPath=\(configPath)")

        // /relay-bridge is delivered as the prompt arg; if its .md file is
        // missing OR stale, Claude would treat the string as literal user
        // input or follow obsolete instructions. The skill content lives in
        // the relay-bridge bash script as the source of truth, so we
        // unconditionally reinstall on every launch — cheap (single file
        // write, ~10ms) and ensures the user always runs against the
        // shipped version of the skill text. Onboarding already gave consent.
        NSLog("[ProcessManager] Refreshing slash command files before launch.")
        installSkill()

        let bypassFlag = config.general.bypass_permissions ? "--dangerously-skip-permissions " : ""
        let modelFlag = Self.modelFlag(config.general.model)
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
        # ~/.local/bin/claude. Make sure that's on PATH so anything Claude
        # spawns downstream finds it — the user's shell profile sourced
        # above usually adds it, but on fresh installs the relay-bridge
        # install just dropped the binary moments ago and the profile
        # isn't aware of it yet.
        export PATH="$HOME/.local/bin:$PATH"
        \(cdLine)
        # Interactive Claude Code with the /relay-bridge slash command
        # pre-fired. The slash command (installed at
        # ~/.claude/commands/relay-bridge.md by `relay-bridge --install-skills`)
        # boots the voice_bridge daemon and drives the polling loop from
        # inside this session.
        '\(claudeBinary)' \(modelFlag)\(bypassFlag)"/relay-bridge"
        echo ''
        echo '[Relay Runner] Session ended.'
        """
        try? script.write(toFile: launcher, atomically: true, encoding: String.Encoding.utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", launcher]
        try? chmod.run()
        chmod.waitUntilExit()

        // Pre-create the legacy voice_in fifo for any old-path consumers;
        // the new --relay daemon manages /tmp/voice_bridge.sock,
        // /tmp/voice_cmd_ready, /tmp/tts_in.fifo, and the heartbeat itself.
        ensureFifo()

        launchInTerminal(command: launcher)
    }

    /// Resolve the Claude Code binary. Prefers `~/.local/bin/claude` (where
    /// claude.ai/install.sh symlinks the CLI), falling back to bare `claude`
    /// so the user's $PATH is consulted at run time.
    private static func resolveClaudeBinary() -> String {
        let local = ClaudeAuth.claudeBinaryPath
        if FileManager.default.isExecutableFile(atPath: local) {
            return local
        }
        return "claude"
    }

    /// Render the `--model <name>` flag for the launcher script, or empty
    /// string when the user wants Claude's default. Single-quotes the name
    /// so a TOML-edited custom model id (e.g. `claude-sonnet-4-6`) can't
    /// break shell parsing.
    private static func modelFlag(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if v.isEmpty || v == "default" { return "" }
        return "--model '\(raw.trimmingCharacters(in: .whitespaces))' "
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

    // MARK: - Voice preview

    /// Run a one-shot voice preview using the bundled preview_voice.py.
    /// Blocks until afplay returns or the script exits with an error. Throws
    /// if the venv or model isn't ready (caller surfaces that to the user).
    func previewVoice(name: String, text: String) throws {
        let python = Self.userVenvPython
        let script = bundledServicesDir.appendingPathComponent("preview_voice.py").path

        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw NSError(domain: "ProcessManager.previewVoice", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Voice preview unavailable — finish onboarding to install Python first."
            ])
        }
        guard FileManager.default.fileExists(atPath: script) else {
            throw NSError(domain: "ProcessManager.previewVoice", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Voice preview script not found in app bundle."
            ])
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script, "--voice", name, "--text", text]
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "(no stderr)"
            throw NSError(domain: "ProcessManager.previewVoice", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Voice preview failed: \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))"
            ])
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
