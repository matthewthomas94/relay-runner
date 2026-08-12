import Foundation
import Observation

/// Incrementally decodes installer output and owns the progress shown while the
/// outer `relay-orchestrator --install` process is active. Shell phases may
/// report 100% for their own work, but the final fraction remains reserved for
/// the outer process result.
struct VenvInstallProgressState {
    static let maximumRunningProgress = 0.98

    private(set) var message = "Starting setup…"
    private(set) var progress: Double?
    private(set) var diagnosticLines: [String] = []

    private var pendingOutput = Data()
    private var lastProgress: Double = 0
    private let collectingTickPercent: Double = 0.02
    private let collectingCapPercent: Double = 0.78

    mutating func reset() {
        message = "Starting setup…"
        progress = nil
        diagnosticLines = []
        pendingOutput = Data()
        lastProgress = 0
    }

    /// Consume arbitrary pipe chunks. A progress marker may be split across
    /// reads, so only complete lines are parsed until `flush` is requested.
    @discardableResult
    mutating func consume(_ data: Data, flush: Bool = false) -> [String] {
        pendingOutput.append(data)
        var lines: [String] = []

        while let delimiter = pendingOutput.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let lineData = pendingOutput.prefix(upTo: delimiter)
            pendingOutput.removeSubrange(...delimiter)
            if let line = decodedLine(lineData), !line.isEmpty {
                lines.append(line)
            }
        }

        if flush, !pendingOutput.isEmpty {
            if let line = decodedLine(pendingOutput), !line.isEmpty {
                lines.append(line)
            }
            pendingOutput.removeAll(keepingCapacity: false)
        }

        consume(lines: lines)
        return lines
    }

    private func decodedLine(_ data: Data.SubSequence) -> String? {
        String(data: Data(data), encoding: .utf8)?
            .trimmingCharacters(in: .whitespaces)
    }

    private mutating func consume(lines: [String]) {
        for line in lines {
            let boundedLine = String(line.prefix(300))
            diagnosticLines.append(boundedLine)
            if diagnosticLines.count > 12 {
                diagnosticLines.removeFirst(diagnosticLines.count - 12)
            }

            if let marker = Self.parseProgressMarker(line) {
                let runningProgress = min(
                    Self.maximumRunningProgress,
                    marker.percent / 100.0
                )
                lastProgress = max(lastProgress, runningProgress)
                progress = lastProgress
                message = marker.label
            } else if line.hasPrefix("Collecting ") {
                let next = min(
                    collectingCapPercent,
                    lastProgress + collectingTickPercent
                )
                lastProgress = max(lastProgress, next)
                progress = lastProgress
                message = line
            } else {
                message = line
            }
        }
    }

    /// Tolerate malformed percentages by rejecting non-numbers and clamping
    /// numeric values to the shell protocol's 0–100 range.
    private static func parseProgressMarker(_ line: String) -> (percent: Double, label: String)? {
        let prefix = "RELAY_PROGRESS:"
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let percentString = String(rest[..<colon])
        let label = String(rest[rest.index(after: colon)...])
        guard let raw = Double(percentString) else { return nil }
        return (min(100, max(0, raw)), label)
    }
}

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
        /// emitted by the outer workflow; surface it as live status text.
        /// `progress` is below 1.0 when a trustworthy `RELAY_PROGRESS:`
        /// marker has arrived, or nil while activity is indeterminate.
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
    private var progressState = VenvInstallProgressState()

    @ObservationIgnored
    private var setupIncidentID: String?

    @ObservationIgnored
    private var setupRetryAttempt = 0

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
        let incidentID = setupIncidentID ?? RelayDiagnostics.makeIncidentID()
        let retryAttempt = setupIncidentID == nil ? 1 : setupRetryAttempt + 1
        let correlationID = UUID().uuidString.lowercased()
        setupIncidentID = incidentID
        setupRetryAttempt = retryAttempt
        RelayDiagnostics.shared.record(
            process: "setup",
            phase: "setup",
            outcome: "started",
            incidentID: incidentID,
            retryAttempt: retryAttempt,
            correlationID: correlationID,
            provider: provider?.rawValue
        )
        let alreadyReady = provider.map { Self.alreadyInstalled(for: $0) } ?? Self.alreadyInstalled
        if alreadyReady {
            status = .succeeded
            RelayDiagnostics.shared.record(
                process: "setup",
                phase: "setup",
                outcome: "ready",
                incidentID: incidentID,
                retryAttempt: retryAttempt,
                correlationID: correlationID,
                provider: provider?.rawValue
            )
            setupIncidentID = nil
            setupRetryAttempt = 0
            return
        }
        guard let scriptPath = relayOrchestratorScriptPath() else {
            status = .failed(message: "Couldn't locate relay-orchestrator in the app bundle. Incident \(incidentID).")
            RelayDiagnostics.shared.record(
                process: "setup",
                phase: "setup",
                outcome: "failed",
                incidentID: incidentID,
                retryAttempt: retryAttempt,
                correlationID: correlationID,
                provider: provider?.rawValue,
                summary: "bundled launcher unavailable",
                attributes: ["error_code": "launcher_missing"]
            )
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: scriptPath)
        proc.arguments = ["--install"]
        var environment = ProcessInfo.processInfo.environment
        environment["RELAY_APP_SESSION_ID"] = RelayDiagnostics.shared.appSessionID
        environment["RELAY_CORRELATION_ID"] = correlationID
        environment["RELAY_INCIDENT_ID"] = incidentID
        environment["RELAY_RETRY_ATTEMPT"] = String(retryAttempt)
        proc.environment = environment
        // Inherit env (PATH for Homebrew etc.) but null stdin so any
        // stray prompts don't hang the install indefinitely.
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        outputPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { [weak self] in
                self?.consume(data: data, flush: data.isEmpty)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.process = nil
                self.consume(data: Data(), flush: true)
                let providerReady = provider.map { Self.alreadyInstalled(for: $0) } ?? true
                self.status = Self.terminalStatus(
                    terminationStatus: proc.terminationStatus,
                    provider: provider,
                    providerReady: providerReady,
                    diagnostic: self.progressState.diagnosticLines.last,
                    incidentID: incidentID
                )
                if proc.terminationStatus == 0 {
                    if let provider, !providerReady {
                        RelayDiagnostics.shared.record(
                            process: "setup",
                            phase: "provider_readiness",
                            outcome: "failed",
                            incidentID: incidentID,
                            retryAttempt: retryAttempt,
                            correlationID: correlationID,
                            provider: provider.rawValue,
                            summary: "provider command unavailable",
                            attributes: ["error_code": "provider_missing"]
                        )
                        return
                    }
                    RelayDiagnostics.shared.record(
                        process: "setup",
                        phase: "setup",
                        outcome: "ready",
                        incidentID: incidentID,
                        retryAttempt: retryAttempt,
                        correlationID: correlationID,
                        provider: provider?.rawValue
                    )
                    self.setupIncidentID = nil
                    self.setupRetryAttempt = 0
                } else {
                    RelayDiagnostics.shared.record(
                        process: "setup",
                        phase: "setup",
                        outcome: "failed",
                        incidentID: incidentID,
                        retryAttempt: retryAttempt,
                        correlationID: correlationID,
                        provider: provider?.rawValue,
                        summary: "setup process exited",
                        attributes: ["exit_code": String(proc.terminationStatus)]
                    )
                }
            }
        }

        process = proc
        // Retry must start indeterminate even if a prior attempt reached a
        // nested phase's terminal marker.
        progressState.reset()
        status = .running(message: "Starting setup…", progress: nil)

        do {
            try proc.run()
        } catch {
            self.process = nil
            self.outputPipe?.fileHandleForReading.readabilityHandler = nil
            self.outputPipe = nil
            status = .failed(message: "Couldn't launch setup. Incident \(incidentID).")
            RelayDiagnostics.shared.record(
                process: "setup",
                phase: "setup",
                outcome: "failed",
                incidentID: incidentID,
                retryAttempt: retryAttempt,
                correlationID: correlationID,
                provider: provider?.rawValue,
                summary: error.localizedDescription,
                attributes: ["error_code": "launch_failed"]
            )
        }
    }

    // MARK: - Output parsing

    static func terminalStatus(
        terminationStatus: Int32,
        provider: GeneralConfig.AgentProvider?,
        providerReady: Bool,
        diagnostic: String?,
        incidentID: String
    ) -> Status {
        guard terminationStatus == 0 else {
            let detail = diagnostic.map { " Last step: \($0)" } ?? ""
            return .failed(
                message: "Setup exited with code \(terminationStatus).\(detail) Incident \(incidentID). Retry setup or run relay-orchestrator --status."
            )
        }
        if let provider, !providerReady {
            return .failed(
                message: "\(provider.displayName) setup finished, but the \(provider.displayName) command is still missing. Incident \(incidentID)."
            )
        }
        return .succeeded
    }

    /// Apply a raw pipe chunk to the running status. Decoding lives in
    /// `VenvInstallProgressState` so chunk boundaries cannot corrupt markers.
    private func consume(data: Data, flush: Bool = false) {
        guard case .running = status else { return }
        let lines = progressState.consume(data, flush: flush)
        for line in lines {
            NSLog("[VenvInstaller] %@", String(line.prefix(300)))
        }
        guard !lines.isEmpty else { return }
        status = .running(
            message: progressState.message,
            progress: progressState.progress
        )
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
