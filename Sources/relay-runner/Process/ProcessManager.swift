import Darwin
import Foundation

final class ProcessManager {

    private var bridgeProcess: Process?
    private static let bridgeSocketPath = "/tmp/voice_bridge.sock"
    private static let voiceCommandPath = "/tmp/voice_cmd_ready"
    private static let heartbeatPath = "/tmp/voice_bridge_heartbeat"
    private static let bridgeCwdPath = "/tmp/voice_bridge.cwd"
    private static let pendingVoiceCommandTimeout: TimeInterval = 10
    private static let staleHeartbeatTimeout: TimeInterval = 30
    private static let missingHeartbeatGrace: TimeInterval = 30
    private static let bridgeRuntimePaths = [
        "/tmp/voice_in.fifo",
        bridgeSocketPath,
        voiceCommandPath,
        "/tmp/tts_in.fifo",
        "/tmp/tts_control.sock",
        heartbeatPath,
        "/tmp/voice_bridge_heartbeat.pid",
        bridgeCwdPath,
        "/tmp/relay_board_now.txt",
        "/tmp/relay_board_prev.txt",
    ]

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
        Self.bridgeDaemonAlive()
    }

    static func activeRelaySessionAlive() -> Bool {
        bridgeDaemonAlive() && relayConsumerAlive()
    }

    private static func bridgeDaemonAlive() -> Bool {
        guard FileManager.default.fileExists(atPath: bridgeSocketPath) else { return false }
        return Self.voiceBridgeProcessAlive()
    }

    private static func voiceBridgeProcessAlive() -> Bool {
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

    /// Check if the relay consumer (the agent skill's bash polling loop) is alive.
    /// Uses two signals: stale heartbeat file and unconsumed voice command.
    func bridgeConsumerAlive() -> Bool {
        Self.relayConsumerAlive()
    }

    static func relayConsumerAlive() -> Bool {
        relayConsumerAlive(
            voiceCommandPath: voiceCommandPath,
            heartbeatPath: heartbeatPath,
            sessionMarkerPaths: [bridgeSocketPath, bridgeCwdPath],
            now: Date()
        )
    }

    static func relayConsumerAlive(
        voiceCommandPath: String,
        heartbeatPath: String,
        sessionMarkerPaths: [String],
        now: Date,
        fileManager fm: FileManager = .default
    ) -> Bool {
        // Fast check: if a voice command has been pending for >10s, consumer is dead
        // (in normal flow, the agent reads voice_cmd_ready within ~1s)
        if let modified = modificationDate(of: voiceCommandPath, fileManager: fm),
           now.timeIntervalSince(modified) > pendingVoiceCommandTimeout {
            NSLog("[ProcessManager] relay consumer missing: voice command pending for \(Int(now.timeIntervalSince(modified)))s")
            return false
        }

        // Modern Codex and Claude relay-bridge sessions touch the heartbeat
        // every 200ms while waiting and every 2s while the agent is working.
        // A missing heartbeat gets only a bounded startup/old-skill grace
        // instead of indefinite benefit of doubt; after that, a live socket
        // without a consumer is treated as an orphaned session.
        if let modified = modificationDate(of: heartbeatPath, fileManager: fm) {
            let age = now.timeIntervalSince(modified)
            if age > staleHeartbeatTimeout {
                NSLog("[ProcessManager] relay consumer missing: heartbeat stale for \(Int(age))s")
                return false
            }
            return true
        }

        let newestMarker = sessionMarkerPaths
            .compactMap { modificationDate(of: $0, fileManager: fm) }
            .max()
        guard let markerModified = newestMarker else {
            NSLog("[ProcessManager] relay consumer missing: no heartbeat or session marker")
            return false
        }
        let missingAge = now.timeIntervalSince(markerModified)
        if missingAge > missingHeartbeatGrace {
            NSLog("[ProcessManager] relay consumer missing: heartbeat absent for \(Int(missingAge))s")
            return false
        }
        return true
    }

    private static func modificationDate(of path: String, fileManager fm: FileManager) -> Date? {
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return modified
    }

    /// Kill any running voice_bridge process (but leave the terminal window open).
    func killBridge() {
        if bridgeAlive() {
            SocketClient.bridgeSend("shutdown")
            Thread.sleep(forTimeInterval: 0.5)
        }
        if Self.voiceBridgeProcessAlive() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-f", "voice_bridge.py"]
            try? proc.run()
            proc.waitUntilExit()
        }
        Self.removeBridgeRuntimeFiles()
    }

    func stopServices() {
        // Ask bridge to shut down gracefully
        if bridgeAlive() {
            SocketClient.bridgeSend("shutdown")
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Force kill if still alive
        if Self.voiceBridgeProcessAlive() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-f", "voice_bridge.py"]
            try? proc.run()
            proc.waitUntilExit()
        }
        Self.removeBridgeRuntimeFiles()
    }

    /// Launch the configured agent in a new terminal tab and have it start
    /// Relay Runner voice mode on the first turn. Claude uses the
    /// `/relay-bridge` slash command; Codex uses the installed relay-bridge
    /// skill and a normal initial prompt.
    ///
    /// The launcher still calls `relay-bridge --venv-only` first so the
    /// Python venv, Kokoro model, and agent CLI are all in place before
    /// the command/skill runs (which spawns the daemon that needs them).
    /// The command/skill files have to exist on disk before launch too,
    /// otherwise relay startup is silently treated as a literal prompt;
    /// we self-heal by reinstalling them if they've gone missing.
    func launchNewSession(config: AppConfig) {
        let configPath = ConfigManager.shared.configPath.path
        let relayBridge = bundledRelayBridge.path
        let target = Self.target(for: config.general.provider)
        let agentBinary = Self.resolveAgentBinary(config.general.command, target: target)
        NSLog("[ProcessManager] launchNewSession: relayBridge=\(relayBridge) agentBinary=\(agentBinary) configPath=\(configPath)")

        // Relay startup is delivered as the prompt arg; if its command/skill
        // file is missing or stale, the agent would treat the string as literal
        // user input or follow obsolete instructions. The skill content lives in
        // the relay-bridge bash script as the source of truth, so we
        // unconditionally reinstall on every launch — cheap (single file
        // write, ~10ms) and ensures the user always runs against the
        // shipped version of the skill text. Onboarding already gave consent.
        NSLog("[ProcessManager] Refreshing Relay skill files before launch.")
        installSkill()

        let launcher = "/tmp/voice_bridge_launch.command"
        let script = Self.launchScript(
            relayBridge: relayBridge,
            target: target,
            agentBinary: agentBinary,
            config: config
        )
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

    enum AgentTarget {
        case codex
        case claude

        var providerMetadataValue: String {
            switch self {
            case .codex: return "codex"
            case .claude: return "claude"
            }
        }
    }

    static func launchScript(
        relayBridge: String,
        target: AgentTarget,
        agentBinary: String,
        config: AppConfig,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let bypassFlag = Self.bypassFlag(enabled: config.general.bypass_permissions, target: target)
        let modelFlag = Self.modelFlag(config.general.model, target: target)
        let cdLine = Self.cdLine(config.general.working_directory, homeDirectory: homeDirectory)
        let launchLine = Self.agentLaunchLine(
            binary: agentBinary,
            target: target,
            modelFlag: modelFlag,
            bypassFlag: bypassFlag
        )
        return """
        #!/bin/bash
        \(Self.shellProfileSource())
        # Ensure venv + deps + speech-model + relay skills are installed.
        # relay-bridge short-circuits in well under a second when everything's
        # already in place; on first run it does the full no-admin install.
        # Either way, the user sees its progress in the Terminal that just
        # opened.
        \(Self.shellQuoted(relayBridge)) --venv-only || { echo '[Relay Runner] Setup failed.'; exit 1; }
        # Keep common agent install locations on PATH for tools launched from
        # this session. On fresh installs the relay-bridge install may have
        # dropped a binary moments ago and the shell profile may not know yet.
        export PATH="$HOME/.local/bin:$PATH"
        export RELAY_RUNNER_PROVIDER=\(Self.shellQuoted(target.providerMetadataValue))
        \(cdLine)
        # Interactive agent session with Relay Runner voice mode pre-fired.
        \(launchLine)
        echo ''
        echo '[Relay Runner] Session ended.'
        """
    }

    private static func target(for provider: GeneralConfig.AgentProvider) -> AgentTarget {
        switch provider {
        case .codex: return .codex
        case .claude: return .claude
        }
    }

    /// Resolve the configured agent binary. For Codex, prefer the desktop
    /// app's bundled CLI; for Claude, prefer the installer symlink.
    private static func resolveAgentBinary(_ command: String, target: AgentTarget) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed.hasPrefix("/") {
            return trimmed
        }
        switch target {
        case .codex:
            let bundled = "/Applications/Codex.app/Contents/Resources/codex"
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
            return "codex"
        case .claude:
            let local = ClaudeAuth.claudeBinaryPath
            if FileManager.default.isExecutableFile(atPath: local) {
                return local
            }
            return "claude"
        }
    }

    /// Render the `--model <name>` flag for the launcher script, or empty
    /// string when the user wants the agent's default. Single-quotes the name
    /// so a TOML-edited custom model id (e.g. `claude-sonnet-4-6`) can't
    /// break shell parsing.
    private static func modelFlag(_ raw: String, target: AgentTarget) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if v.isEmpty || v == "default" { return "" }
        let provider: GeneralConfig.AgentProvider
        switch target {
        case .codex: provider = .codex
        case .claude: provider = .claude
        }
        guard GeneralConfig.isModel(v, validFor: provider) else { return "" }
        return "--model \(Self.shellQuoted(v)) "
    }

    private static func bypassFlag(enabled: Bool, target: AgentTarget) -> String {
        guard enabled else { return "" }
        switch target {
        case .codex:
            return "--dangerously-bypass-approvals-and-sandbox "
        case .claude:
            return "--dangerously-skip-permissions "
        }
    }

    private static func agentLaunchLine(
        binary: String,
        target: AgentTarget,
        modelFlag: String,
        bypassFlag: String
    ) -> String {
        switch target {
        case .codex:
            return "\(Self.shellQuoted(binary)) \(modelFlag)\(bypassFlag)\(Self.shellQuoted("Use the relay-bridge skill now."))"
        case .claude:
            return "\(Self.shellQuoted(binary)) \(modelFlag)\(bypassFlag)\"/relay-bridge\""
        }
    }

    // MARK: - Relay skill install

    private static let claudeSkillDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands")
    }()

    private static let codexSkillDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/skills")
    }()

    private static let claudeBridgeSkillPath: URL = claudeSkillDir.appendingPathComponent("relay-bridge.md")
    private static let claudeStopSkillPath: URL = claudeSkillDir.appendingPathComponent("relay-stop.md")
    private static let codexBridgeSkillPath: URL = codexSkillDir.appendingPathComponent("relay-bridge/SKILL.md")
    private static let codexStopSkillPath: URL = codexSkillDir.appendingPathComponent("relay-stop/SKILL.md")

    var isSkillInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Self.claudeBridgeSkillPath.path)
            && fm.fileExists(atPath: Self.claudeStopSkillPath.path)
            && fm.fileExists(atPath: Self.codexBridgeSkillPath.path)
            && fm.fileExists(atPath: Self.codexStopSkillPath.path)
    }

    /// Force-install the relay-bridge and relay-stop command/skill files by
    /// shelling out to `relay-bridge --install-skills`. The content itself
    /// lives in the bash script (single source of truth — the
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
                NSLog("[ProcessManager] Installed relay skills via \(bundledRelayBridge.path)")
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

    /// Returns the `cd` line for the launcher script using the configured
    /// workspace folder semantics, including the home directory fallback.
    static func cdLine(
        _ workingDirectory: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let url = WorkspaceFolder.url(from: workingDirectory, homeDirectory: homeDirectory)
        return "cd \(Self.shellQuoted(url.path))"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
        FIFOWriter.ensureFifo(FIFOWriter.voiceFifoPath)
    }

    private static func removeBridgeRuntimeFiles() {
        stopHeartbeatRefresher()
        let fm = FileManager.default
        for path in bridgeRuntimePaths {
            try? fm.removeItem(atPath: path)
        }
    }

    private static func stopHeartbeatRefresher() {
        let path = "/tmp/voice_bridge_heartbeat.pid"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        Darwin.kill(pid, SIGTERM)
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
