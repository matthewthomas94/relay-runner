import Foundation
import Observation

/// Drives first-run service bootstrap from inside the app by invoking
/// `relay-orchestrator --install` and streaming its output. That launcher
/// delegates Python setup to relay-bridge, then installs and health-checks
/// the launchd daemon and provider tools before reporting success.
@Observable
final class VenvInstaller {

    enum Status: Equatable {
        /// Not started yet — entered when the onboarding step is reached.
        case idle
        /// Installer is running. `message` is the most recent line
        /// emitted by relay-bridge; surface it as live status text.
        /// `progress` is 0.0–1.0 when relay-bridge has emitted a
        /// `RELAY_PROGRESS:` marker, or nil if the bar should stay
        /// indeterminate (we haven't seen one yet).
        case running(message: String, progress: Double?)
        /// Bootstrap finished cleanly; venv exists and deps import.
        case succeeded
        /// Bootstrap exited non-zero or failed to launch. The message
        /// is human-readable; relay-bridge logs the underlying detail
        /// to stdout/stderr (visible in Console).
        case failed(message: String)
    }

    private(set) var status: Status = .idle

    @ObservationIgnored
    private var process: Process?

    @ObservationIgnored
    private var outputPipe: Pipe?

    @ObservationIgnored
    private var diagnosticTail: [String] = []

    /// Last progress fraction we surfaced to the UI. Tracked separately
    /// from `status` so out-of-order or repeated pip "Collecting" lines
    /// can never make the bar go backwards (jittery progress is worse
    /// than no progress).
    @ObservationIgnored
    private var lastProgress: Double = 0

    /// Each pip "Collecting <pkg>" line during the dep install phase
    /// bumps the bar by this much, capped at `collectingCapPercent`.
    /// That's where the perceived "hang" lives — pip goes silent for
    /// 5–15s per wheel download, so making the bar tick per package
    /// is what keeps the install feeling alive. Cap stops short of
    /// the 80% phase marker for the speech-model download so the bar
    /// has somewhere to go when that next phase starts.
    private let collectingTickPercent: Double = 0.02
    private let collectingCapPercent: Double = 0.78

    /// True when every runtime dependency a session needs is on disk:
    /// the venv interpreter, the Kokoro speech-model files, an agent CLI,
    /// AND the relay voice command/skill files. relay-bridge
    /// runs the install path if any one is missing, so the SwiftUI must
    /// check the same union — otherwise onboarding's pythonSetup would
    /// short-circuit to .succeeded while a missing piece still needed
    /// installing, and the user would discover it only when starting a
    /// session (or starting relay-bridge inside an agent session).
    static var alreadyInstalled: Bool {
        commonRuntimeInstalled && anyAgentCLIInstalled
    }

    static func alreadyInstalled(for provider: GeneralConfig.AgentProvider) -> Bool {
        commonRuntimeInstalled && cliInstalled(for: provider)
    }

    static func cliInstalled(for provider: GeneralConfig.AgentProvider) -> Bool {
        let fm = FileManager.default
        switch provider {
        case .codex:
            return codexCLIPaths.contains { fm.isExecutableFile(atPath: $0) }
        case .claude:
            return fm.isExecutableFile(atPath: claudeCLIPath)
        }
    }

    private static var commonRuntimeInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: userVenvPython)
            && fm.fileExists(atPath: kokoroModelPath)
            && fm.fileExists(atPath: kokoroVoicesPath)
            && fm.fileExists(atPath: bridgeSkillPath)
            && fm.fileExists(atPath: stopSkillPath)
            && fm.fileExists(atPath: codexBridgeSkillPath)
            && fm.fileExists(atPath: codexStopSkillPath)
            && orchestratorReady
    }

    private static var anyAgentCLIInstalled: Bool {
        cliInstalled(for: .codex) || cliInstalled(for: .claude)
    }

    /// Match what tts_worker.py:_find_kokoro_model() looks for and what
    /// relay-bridge writes into during the install.
    private static var kokoroModelPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/kokoro/kokoro-v1.0.onnx")
    }
    private static var kokoroVoicesPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/share/kokoro/voices-v1.0.bin")
    }
    /// claude.ai/install.sh symlinks the Claude Code binary here. Match
    /// the same path relay-bridge's CLAUDE_CLI_OK gate inspects.
    private static var claudeCLIPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".local/bin/claude")
    }
    static let codexCLIPaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
    ]
    /// Match relay-bridge's RELAY_SKILLS_OK gate — both command/skill files
    /// must exist for the install to be considered complete.
    private static var bridgeSkillPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/commands/relay-bridge.md")
    }
    private static var stopSkillPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/commands/relay-stop.md")
    }
    private static var codexBridgeSkillPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".codex/skills/relay-bridge/SKILL.md")
    }
    private static var codexStopSkillPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".codex/skills/relay-stop/SKILL.md")
    }

    private static var orchestratorReady: Bool {
        let fm = FileManager.default
        let plist = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/com.relay.orchestrator.plist")
        guard fm.fileExists(atPath: plist), launchdJobLoaded else { return false }

        let portFile = "/tmp/relay_orchestrator.port"
        guard let rawPort = try? String(contentsOfFile: portFile, encoding: .utf8),
              let port = Int(rawPort.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0,
              let url = URL(string: "http://127.0.0.1:\(port)/v1/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        let semaphore = DispatchSemaphore(value: 0)
        var healthy = false
        URLSession.shared.dataTask(with: request) { _, response, _ in
            healthy = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 0.75) == .success else { return false }
        return healthy
    }

    private static var launchdJobLoaded: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            "print",
            "gui/\(getuid())/com.relay.orchestrator",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Begin the bootstrap if it isn't already running. Idempotent —
    /// safe to call from `.onAppear` even if the user navigates back
    /// and forward across the step.
    func install(for provider: GeneralConfig.AgentProvider? = nil) {
        if case .running = status { return }
        if case .succeeded = status {
            guard let provider, !Self.alreadyInstalled(for: provider) else { return }
            status = .idle
        }
        // Venv is already healthy — short-circuit to succeeded so the
        // onboarding step's `onChange(of: status)` handler fires the
        // auto-advance, instead of leaving the UI parked on the idle
        // "Preparing…" spinner forever (the original bug: install() was
        // gated by the same alreadyInstalled check on the caller side,
        // so on a re-run with a healthy venv nothing ever advanced
        // status off .idle and the screen sat stuck).
        let alreadyReady = provider.map { Self.alreadyInstalled(for: $0) } ?? Self.alreadyInstalled
        if alreadyReady {
            status = .succeeded
            return
        }
        guard let scriptPath = relayOrchestratorScriptPath() else {
            status = .failed(message: "Couldn't locate relay-orchestrator in the app bundle.")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scriptPath)
        proc.arguments = ["--install"]
        // Inherit env (PATH for Homebrew etc.) but null stdin so any
        // stray prompts don't hang the install indefinitely.
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let chunk = String(data: data, encoding: .utf8) else { return }
            // relay-bridge can emit multi-line bursts (e.g. pip output).
            // Walk every line in order so structured `RELAY_PROGRESS:`
            // markers and informational lines both update state, then
            // pick the most recent non-empty informational line as the
            // visible message. The full transcript still goes to Console
            // via the inherited stdout/stderr fds when run from a terminal.
            let lines = chunk
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                self?.consume(lines: lines)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.process = nil
                if proc.terminationStatus == 0 {
                    if let provider, !Self.alreadyInstalled(for: provider) {
                        self.status = .failed(
                            message: "\(provider.displayName) setup finished, but the \(provider.displayName) command is still missing."
                        )
                        return
                    }
                    self.status = .succeeded
                } else {
                    let diagnostic = self.diagnosticTail.last.map { " Last step: \($0)" } ?? ""
                    self.status = .failed(
                        message: "Setup exited with code \(proc.terminationStatus).\(diagnostic) Retry setup or run relay-orchestrator --status."
                    )
                }
            }
        }

        process = proc
        // Retry must start from 0% even if a prior attempt got partway
        // through — reset before kicking off the new subprocess.
        lastProgress = 0
        diagnosticTail = []
        status = .running(message: "Starting setup…", progress: nil)

        do {
            try proc.run()
        } catch {
            self.process = nil
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.outputPipe = nil
            status = .failed(message: "Couldn't launch setup: \(error.localizedDescription)")
        }
    }

    // MARK: - Output parsing

    /// Apply a batch of output lines to `status`. Must run on the main
    /// queue — caller dispatches.
    ///
    /// Two kinds of lines drive the bar:
    ///   1. `RELAY_PROGRESS:<percent>:<label>` — explicit phase markers
    ///      emitted by relay-bridge. Set the bar to that percent (clamped
    ///      monotonic) and adopt the label as the visible message.
    ///   2. `Collecting <pkg>` — pip download phase signal. Each one
    ///      bumps the bar by `collectingTickPercent` so the user sees
    ///      motion during the otherwise-silent download. Capped so we
    ///      never overshoot the next phase marker.
    /// Anything else updates the visible message only.
    private func consume(lines: [String]) {
        guard case .running(let currentMessage, _) = status else { return }
        var message = currentMessage
        for line in lines {
            let boundedLine = String(line.prefix(300))
            diagnosticTail.append(boundedLine)
            if diagnosticTail.count > 12 {
                diagnosticTail.removeFirst(diagnosticTail.count - 12)
            }
            NSLog("[VenvInstaller] %@", boundedLine)
            if let marker = parseProgressMarker(line) {
                lastProgress = max(lastProgress, marker.percent / 100.0)
                message = marker.label
            } else if line.hasPrefix("Collecting ") {
                let next = min(
                    collectingCapPercent,
                    lastProgress + collectingTickPercent
                )
                lastProgress = max(lastProgress, next)
                message = line
            } else {
                message = line
            }
        }
        status = .running(message: message, progress: lastProgress > 0 ? lastProgress : nil)
    }

    /// Parse a `RELAY_PROGRESS:<percent>:<label>` marker, or nil if the
    /// line isn't one. Tolerant of malformed percent values (clamped
    /// 0–100) so a typo in the bash script can't crash the installer.
    private func parseProgressMarker(_ line: String) -> (percent: Double, label: String)? {
        let prefix = "RELAY_PROGRESS:"
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let percentStr = String(rest[..<colon])
        let label = String(rest[rest.index(after: colon)...])
        guard let raw = Double(percentStr) else { return nil }
        let clamped = min(100, max(0, raw))
        return (clamped, label)
    }

    // MARK: - Path resolution

    /// Path the venv-managed Python interpreter is expected to live at,
    /// kept in sync with `relay-bridge`'s `$SERVICES_DIR/.venv/bin/python3`.
    /// Lives under `~/Library/Application Support/relay-runner` (not in
    /// the .app bundle) so non-admin users — who can't write to a
    /// /Applications-installed bundle owned by root — can still get a
    /// working venv.
    private static var userVenvPython: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("relay-runner/services/.venv/bin/python3")
            .path
    }

    /// Resolve the orchestrator installer. Prefer the bundled copy at
    /// Contents/SharedSupport/scripts/relay-orchestrator; fall back to the
    /// repo's scripts/ dir for `swift run`-style local iteration.
    private func relayOrchestratorScriptPath() -> String? {
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/scripts/relay-orchestrator")
            .path
        if fm.isExecutableFile(atPath: bundled) { return bundled }
        let repoLocal = fm.currentDirectoryPath + "/scripts/relay-orchestrator"
        if fm.isExecutableFile(atPath: repoLocal) { return repoLocal }
        return nil
    }
}
