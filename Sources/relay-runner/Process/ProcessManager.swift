import Darwin
import Foundation

final class ProcessManager {

    static let embeddedAutoCompactTokenThreshold = 150_000
    static let claudeAutoCompactWindow = 200_000
    static let claudeAutoCompactOutputReserve = 20_000
    // Claude caps the configured window to the model's native window, removes
    // its output reserve, then applies this percentage. Using Haiku's 200K
    // window for every alias makes 150K / (200K - 20K) the shared boundary.
    static let claudeAutoCompactPercentage =
        Double(embeddedAutoCompactTokenThreshold) * 100
        / Double(claudeAutoCompactWindow - claudeAutoCompactOutputReserve)

    private var bridgeProcess: Process?
    private var tutorialTTSProcess: Process?
    private var tutorialTTSInput: Pipe?
    private static let bridgeSocketPath = "/tmp/voice_bridge.sock"
    private static let voiceCommandPath = "/tmp/voice_cmd_ready"
    private static let voiceCommandMetaPath = "/tmp/voice_cmd_ready.meta"
    private static let voiceCommandStatePath = "/tmp/voice_command_state.json"
    private static let voiceCommandClaimedPath = "/tmp/voice_cmd_claimed.json"
    private static let legacyVoiceProviderTurnsPath = "/tmp/voice_provider_turns.json"
    private static let voiceProviderTurnsPath = "/tmp/voice_provider_turns_v2.json"
    private static let voiceProviderSessionPath = "/tmp/voice_provider_session_id"
    private static let terminalDeliveryEventsPath = "/tmp/relay_terminal_delivery_events.jsonl"
    private static let heartbeatPath = "/tmp/voice_bridge_heartbeat"
    private static let bridgeStopRequestedPath = "/tmp/voice_bridge_stop_requested"
    private static let bridgeCwdPath = "/tmp/voice_bridge.cwd"
    private static let bridgeProviderPath = "/tmp/voice_bridge.provider"
    private static let tutorialTTSControlPath = "/tmp/relay_tutorial_tts_control.sock"
    private static let bridgeLaunchdLabel = "com.relay.voicebridge"
    static let pendingVoiceCommandTimeout: TimeInterval = 10
    private static let staleHeartbeatTimeout: TimeInterval = 30
    private static let missingHeartbeatGrace: TimeInterval = 30
    private static let bridgeRuntimePaths = [
        "/tmp/voice_in.fifo",
        bridgeSocketPath,
        voiceCommandPath,
        voiceCommandMetaPath,
        voiceCommandStatePath,
        voiceCommandClaimedPath,
        legacyVoiceProviderTurnsPath,
        voiceProviderTurnsPath,
        voiceProviderSessionPath,
        terminalDeliveryEventsPath,
        "/tmp/tts_in.fifo",
        "/tmp/tts_control.sock",
        heartbeatPath,
        "/tmp/voice_bridge_heartbeat.pid",
        bridgeCwdPath,
        bridgeProviderPath,
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

    private static var servicePython: String {
        FileManager.default.isExecutableFile(atPath: userVenvPython)
            ? userVenvPython
            : "/usr/bin/python3"
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

    private var bundledRelayOrchestrator: URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/scripts/relay-orchestrator")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/relay-orchestrator")
    }

    // MARK: - Local onboarding speech

    func startTutorialTTS() -> Bool {
        if tutorialTTSProcess?.isRunning == true {
            return true
        }

        let script = bundledServicesDir.appendingPathComponent("tts_worker.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            NSLog("[ProcessManager] Tutorial TTS worker is missing: \(script.path)")
            return false
        }

        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.servicePython)
        process.arguments = [script.path]
        process.currentDirectoryURL = bundledServicesDir
        process.standardInput = input
        var environment = ProcessInfo.processInfo.environment
        environment["TTS_CONTROL_SOCK"] = Self.tutorialTTSControlPath
        environment["VOICE_STATE_SOCK"] = StateEventBus.socketPath
        environment["RELAY_TUTORIAL_TTS"] = "1"
        process.environment = environment

        do {
            try process.run()
        } catch {
            NSLog("[ProcessManager] Failed to start tutorial TTS: \(error)")
            return false
        }

        tutorialTTSProcess = process
        tutorialTTSInput = input
        return true
    }

    @discardableResult
    func queueTutorialTTS(_ text: String) -> Bool {
        writeTutorialTTSLine(text)
    }

    @discardableResult
    func tutorialTTSCommand(_ command: String) -> Bool {
        let control: String
        switch command {
        case "play":
            control = "__PLAY__"
        case "replay":
            control = "__REPLAY__"
        case "skip":
            control = "__CANCEL__"
        default:
            return false
        }
        return writeTutorialTTSLine(control)
    }

    @discardableResult
    private func writeTutorialTTSLine(_ text: String) -> Bool {
        guard tutorialTTSProcess?.isRunning == true,
              let input = tutorialTTSInput,
              let data = "\(text)\n".data(using: .utf8)
        else { return false }
        input.fileHandleForWriting.write(data)
        return true
    }

    func stopTutorialTTS() {
        guard tutorialTTSProcess != nil else { return }
        tutorialTTSCommand("skip")
        try? tutorialTTSInput?.fileHandleForWriting.close()
        tutorialTTSInput = nil
        tutorialTTSProcess = nil
    }

    // MARK: - Bridge lifecycle

    func bridgeAlive() -> Bool {
        Self.bridgeDaemonAlive()
    }

    static func activeRelaySessionAlive() -> Bool {
        let daemonAlive = bridgeDaemonAlive()
        let consumerAlive = daemonAlive && relayConsumerAlive()
        let hasSessionContext = bridgeRecoveryContext(
            cwdFile: URL(fileURLWithPath: bridgeCwdPath),
            providerFile: URL(fileURLWithPath: bridgeProviderPath)
        ) != nil
        return relaySessionAlive(
            daemonAlive: daemonAlive,
            consumerAlive: consumerAlive,
            hasSessionContext: hasSessionContext
        )
    }

    static func relaySessionAlive(
        daemonAlive: Bool,
        consumerAlive: Bool,
        hasSessionContext: Bool
    ) -> Bool {
        daemonAlive && (consumerAlive || hasSessionContext)
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
    /// This is watchdog input, not the whole session-liveness contract: a
    /// completed Codex App turn can stop touching the consumer heartbeat while
    /// the relay daemon and its cwd/provider metadata remain the active session.
    func bridgeConsumerAlive() -> Bool {
        Self.relayConsumerAlive()
    }

    func pendingVoiceCommandDeliveryState(now: Date = Date()) -> PendingVoiceCommandDeliveryState {
        Self.pendingVoiceCommandDeliveryState(
            commandURL: URL(fileURLWithPath: Self.voiceCommandPath),
            metaURL: URL(fileURLWithPath: Self.voiceCommandMetaPath),
            stateURL: URL(fileURLWithPath: Self.voiceCommandStatePath),
            claimedURL: URL(fileURLWithPath: Self.voiceCommandClaimedPath),
            now: now,
            providerTurnsURL: URL(fileURLWithPath: Self.voiceProviderTurnsPath),
            providerSessionID: Self.currentProviderSessionID()
        )
    }

    func bridgeStopRequested() -> Bool {
        Self.bridgeStopRequested()
    }

    func clearBridgeStopRequested() {
        Self.clearBridgeStopRequested()
    }

    static func relayConsumerAlive() -> Bool {
        relayConsumerAlive(
            voiceCommandPath: voiceCommandPath,
            voiceCommandMetaPath: voiceCommandMetaPath,
            voiceCommandStatePath: voiceCommandStatePath,
            voiceCommandClaimedPath: voiceCommandClaimedPath,
            voiceProviderTurnsPath: voiceProviderTurnsPath,
            voiceProviderSessionID: currentProviderSessionID(),
            heartbeatPath: heartbeatPath,
            sessionMarkerPaths: [bridgeSocketPath, bridgeCwdPath],
            now: Date()
        )
    }

    static func relayConsumerAlive(
        voiceCommandPath: String,
        voiceCommandMetaPath: String? = nil,
        voiceCommandStatePath: String? = nil,
        voiceCommandClaimedPath: String? = nil,
        voiceProviderTurnsPath: String? = nil,
        voiceProviderSessionID: String? = nil,
        heartbeatPath: String,
        sessionMarkerPaths: [String],
        now: Date,
        fileManager fm: FileManager = .default
    ) -> Bool {
        // Fast check: if a voice command has been pending for >10s with no
        // active provider turn, consumer delivery is stuck. While Codex or
        // Claude is actively running, newer commands may legitimately wait for
        // the next preemption checkpoint.
        if voiceCommandTimedOut(
            voiceCommandPath: voiceCommandPath,
            voiceCommandMetaPath: voiceCommandMetaPath,
            voiceCommandStatePath: voiceCommandStatePath,
            voiceCommandClaimedPath: voiceCommandClaimedPath,
            voiceProviderTurnsPath: voiceProviderTurnsPath,
            voiceProviderSessionID: voiceProviderSessionID,
            now: now,
            fileManager: fm
        ) {
            return false
        }

        // Modern Codex and Claude relay-bridge sessions touch the heartbeat
        // every 200ms while waiting and every 2s while the agent is working.
        // A missing heartbeat gets only a bounded startup/old-skill grace
        // instead of indefinite benefit of doubt. Callers combine this with
        // bridge session metadata before deciding whether to preserve or reap
        // the daemon.
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

    private static func voiceCommandTimedOut(
        voiceCommandPath: String,
        voiceCommandMetaPath: String?,
        voiceCommandStatePath: String?,
        voiceCommandClaimedPath: String?,
        voiceProviderTurnsPath: String?,
        voiceProviderSessionID: String?,
        now: Date,
        fileManager fm: FileManager
    ) -> Bool {
        guard let modified = modificationDate(of: voiceCommandPath, fileManager: fm) else {
            return false
        }

        if let metaPath = voiceCommandMetaPath,
           let statePath = voiceCommandStatePath,
           let claimedPath = voiceCommandClaimedPath {
            let state = pendingVoiceCommandDeliveryState(
                commandURL: URL(fileURLWithPath: voiceCommandPath),
                metaURL: URL(fileURLWithPath: metaPath),
                stateURL: URL(fileURLWithPath: statePath),
                claimedURL: URL(fileURLWithPath: claimedPath),
                now: now,
                providerTurnsURL: voiceProviderTurnsPath.map { URL(fileURLWithPath: $0) },
                providerSessionID: voiceProviderSessionID,
                fileManager: fm
            )
            switch state {
            case .timedOut:
                NSLog("[ProcessManager] relay consumer missing: voice command pending for \(Int(now.timeIntervalSince(modified)))s")
                return true
            case .waiting, .stale, .claimed:
                return false
            case .none:
                break
            }
        }

        if now.timeIntervalSince(modified) > pendingVoiceCommandTimeout {
            NSLog("[ProcessManager] relay consumer missing: voice command pending for \(Int(now.timeIntervalSince(modified)))s")
            return true
        }
        return false
    }

    enum PendingVoiceCommandDeliveryState: Equatable {
        case none
        case waiting
        case timedOut
        case stale
        case claimed
    }

    static func pendingVoiceCommandDeliveryState(
        commandURL: URL,
        metaURL: URL,
        stateURL: URL,
        claimedURL: URL,
        now: Date,
        timeout: TimeInterval = pendingVoiceCommandTimeout,
        providerTurnsURL: URL? = nil,
        providerSessionID: String? = nil,
        fileManager fm: FileManager = .default
    ) -> PendingVoiceCommandDeliveryState {
        guard fm.fileExists(atPath: commandURL.path),
              let attrs = try? fm.attributesOfItem(atPath: commandURL.path),
              let modified = attrs[.modificationDate] as? Date,
              let metadata = readJSONDictionary(from: metaURL) else {
            return .none
        }

        if let claimed = readJSONDictionary(from: claimedURL),
           relayMetadataMatches(metadata, claimed) {
            return .claimed
        }

        guard let state = readJSONDictionary(from: stateURL),
              relayMetadataMatches(metadata, state) else {
            return .stale
        }

        if now.timeIntervalSince(modified) > timeout {
            return providerTurnsURL.map {
                providerTurnActive(
                    providerTurnsURL: $0,
                    providerSessionID: providerSessionID
                )
            } == true
                ? .waiting
                : .timedOut
        }
        return .waiting
    }

    static func foregroundProviderTurnActive() -> Bool {
        return providerTurnActive(
            providerTurnsURL: URL(fileURLWithPath: voiceProviderTurnsPath),
            providerSessionID: currentProviderSessionID()
        )
    }

    private static func currentProviderSessionID() -> String? {
        (try? String(
            contentsOfFile: voiceProviderSessionPath,
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func modificationDate(of path: String, fileManager fm: FileManager) -> Date? {
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return modified
    }

    private static func readJSONDictionary(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func relayMetadataMatches(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let lhsSeq = relayCommandSeq(lhs["relay_command_seq"]),
              let rhsSeq = relayCommandSeq(rhs["relay_command_seq"]),
              let lhsId = relayCommandId(lhs["relay_command_id"]),
              let rhsId = relayCommandId(rhs["relay_command_id"]) else {
            return false
        }
        return lhsSeq == rhsSeq && lhsId == rhsId
    }

    private static func relayCommandSeq(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func relayCommandId(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func providerTurnActive(
        providerTurnsURL: URL,
        providerSessionID: String? = nil
    ) -> Bool {
        guard let data = try? Data(contentsOf: providerTurnsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schema_version"] as? NSNumber)?.intValue == 2,
              let records = object["records"] as? [[String: Any]] else {
            return false
        }
        return records.contains { record in
            let active = (record["state"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "active"
            guard active, let providerSessionID, !providerSessionID.isEmpty else {
                return active
            }
            return (record["provider_session_id"] as? String) == providerSessionID
        }
    }

    struct BridgeRecoveryContext: Equatable {
        let workingDirectory: String
        let provider: String?
    }

    func bridgeRecoveryContext(fallbackConfig: AppConfig? = nil) -> BridgeRecoveryContext? {
        if let context = Self.bridgeRecoveryContext(
            cwdFile: URL(fileURLWithPath: Self.bridgeCwdPath),
            providerFile: URL(fileURLWithPath: Self.bridgeProviderPath)
        ) {
            return context
        }

        guard let fallbackConfig else { return nil }
        return BridgeRecoveryContext(
            workingDirectory: WorkspaceFolder.url(from: fallbackConfig.general.working_directory).path,
            provider: fallbackConfig.general.provider.rawValue
        )
    }

    static func bridgeRecoveryContext(cwdFile: URL, providerFile: URL?) -> BridgeRecoveryContext? {
        guard let rawCwd = try? String(contentsOf: cwdFile, encoding: .utf8) else {
            return nil
        }
        let cwd = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cwd.isEmpty else { return nil }

        let provider = providerFile
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
        return BridgeRecoveryContext(workingDirectory: cwd, provider: provider)
    }

    @discardableResult
    func relaunchBridgeDaemon(
        context: BridgeRecoveryContext,
        suppressStartupGreeting: Bool = false
    ) -> Bool {
        guard !Self.bridgeStopRequested() else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [
            "-c",
            Self.bridgeRecoveryScript(
                relayBridge: bundledRelayBridge.path,
                context: context,
                suppressStartupGreeting: suppressStartupGreeting
            ),
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 && Self.bridgeDaemonAlive()
        } catch {
            NSLog("[ProcessManager] Failed to relaunch voice bridge: \(error)")
            return false
        }
    }

    static func bridgeRecoveryScript(
        relayBridge: String,
        context: BridgeRecoveryContext,
        suppressStartupGreeting: Bool = false
    ) -> String {
        let provider = context.provider ?? ""
        let greetingFlag = suppressStartupGreeting ? " --suppress-startup-greeting" : ""
        return """
        set +e
        RELAY_CWD=\(shellQuoted(context.workingDirectory))
        RELAY_BRIDGE=\(shellQuoted(relayBridge))
        RELAY_PROVIDER=\(shellQuoted(provider))
        RELAY_PROVIDER_SESSION_ID=$(cat /tmp/voice_provider_session_id 2>/dev/null || true)
        VOICE_BRIDGE_LOG=/tmp/voice_bridge.log
        REPLAY_DIR=$(mktemp -d /tmp/voice_bridge_replay.XXXXXX 2>/dev/null || true)
        REPLAY_READY=0
        cleanup_replay() {
            [ -n "$REPLAY_DIR" ] && rm -rf "$REPLAY_DIR"
        }
        trap cleanup_replay EXIT
        restore_replayed_command() {
            [ "$REPLAY_READY" = "1" ] || return 0
            [ -f /tmp/voice_bridge_stop_requested ] && return 1
            if [ -f /tmp/voice_cmd_ready ]; then
                echo "[relay-runner] app watchdog replay skipped; another voice command is already pending." >> "$VOICE_BRIDGE_LOG"
                return 0
            fi
            if [ -f /tmp/voice_command_state.json ] && ! cmp -s "$REPLAY_DIR/voice_cmd_ready.meta" /tmp/voice_command_state.json; then
                echo "[relay-runner] app watchdog replay skipped; Relay command state was superseded." >> "$VOICE_BRIDGE_LOG"
                return 0
            fi
            if [ -f /tmp/voice_cmd_ready.meta ] && ! cmp -s "$REPLAY_DIR/voice_cmd_ready.meta" /tmp/voice_cmd_ready.meta; then
                echo "[relay-runner] app watchdog replay skipped; newer ready metadata exists." >> "$VOICE_BRIDGE_LOG"
                return 0
            fi
            if [ -f /tmp/voice_cmd_claimed.json ] && cmp -s "$REPLAY_DIR/voice_cmd_ready.meta" /tmp/voice_cmd_claimed.json; then
                echo "[relay-runner] app watchdog replay skipped; Relay command was already claimed." >> "$VOICE_BRIDGE_LOG"
                return 0
            fi
            cp "$REPLAY_DIR/voice_cmd_ready.meta" /tmp/voice_cmd_ready.meta || return 1
            cp "$REPLAY_DIR/voice_command_state.json" /tmp/voice_command_state.json || return 1
            [ -f "$REPLAY_DIR/voice_command_authorizations.json" ] && cp "$REPLAY_DIR/voice_command_authorizations.json" /tmp/voice_command_authorizations.json
            cp "$REPLAY_DIR/voice_cmd_ready" /tmp/voice_cmd_ready.replay || return 1
            mv /tmp/voice_cmd_ready.replay /tmp/voice_cmd_ready || return 1
            echo "[relay-runner] app watchdog replayed pending voice command after bridge recovery." >> "$VOICE_BRIDGE_LOG"
        }
        if [ -n "$REPLAY_DIR" ] && mv /tmp/voice_cmd_ready "$REPLAY_DIR/voice_cmd_ready" 2>/dev/null; then
            if [ -f /tmp/voice_cmd_ready.meta ] && mv /tmp/voice_cmd_ready.meta "$REPLAY_DIR/voice_cmd_ready.meta" 2>/dev/null; then
                cp /tmp/voice_command_state.json "$REPLAY_DIR/voice_command_state.json" 2>/dev/null || cp "$REPLAY_DIR/voice_cmd_ready.meta" "$REPLAY_DIR/voice_command_state.json"
                cp /tmp/voice_command_authorizations.json "$REPLAY_DIR/voice_command_authorizations.json" 2>/dev/null || true
                if cmp -s "$REPLAY_DIR/voice_cmd_ready.meta" "$REPLAY_DIR/voice_command_state.json" \
                    && { [ ! -f /tmp/voice_cmd_claimed.json ] || ! cmp -s "$REPLAY_DIR/voice_cmd_ready.meta" /tmp/voice_cmd_claimed.json; }; then
                    REPLAY_READY=1
                    echo "[relay-runner] app watchdog captured pending voice command for replay." >> "$VOICE_BRIDGE_LOG"
                else
                    echo "[relay-runner] app watchdog skipped pending voice command replay; metadata was stale or already claimed." >> "$VOICE_BRIDGE_LOG"
                fi
            else
                echo "[relay-runner] app watchdog could not capture pending voice command metadata; replay disabled." >> "$VOICE_BRIDGE_LOG"
            fi
        fi
        launchctl remove com.relay.voicebridge 2>/dev/null || true
        [ -f /tmp/voice_bridge_heartbeat.pid ] && kill "$(cat /tmp/voice_bridge_heartbeat.pid)" 2>/dev/null || true
        [ -f /tmp/voice_bridge_stop_requested ] && exit 1
        pkill -f '[v]oice_bridge.py' 2>/dev/null || true
        rm -f /tmp/voice_in.fifo /tmp/voice_bridge.sock /tmp/voice_cmd_ready /tmp/voice_cmd_ready.meta /tmp/voice_command_state.json /tmp/voice_cmd_claimed.json /tmp/voice_command_authorizations.json /tmp/voice_provider_turns.json /tmp/voice_provider_turns_v2.json /tmp/voice_provider_session_id /tmp/relay_terminal_delivery_events.jsonl /tmp/tts_in.fifo /tmp/tts_control.sock /tmp/voice_bridge_heartbeat /tmp/voice_bridge_heartbeat.pid /tmp/voice_bridge.cwd /tmp/voice_bridge.provider /tmp/relay_board_now.txt /tmp/relay_board_prev.txt
        VOICE_BRIDGE_LOG_REASON=watchdog-recovery VOICE_BRIDGE_LOG_PROVIDER="${RELAY_PROVIDER:-none}" VOICE_BRIDGE_LOG_CWD="$RELAY_CWD" "$RELAY_BRIDGE" --rotate-log || : >> "$VOICE_BRIDGE_LOG"
        [ -f /tmp/voice_bridge_stop_requested ] && exit 1
        echo "[relay-runner] app watchdog recovery launching via launchctl provider=${RELAY_PROVIDER:-none} cwd=$RELAY_CWD bridge=$RELAY_BRIDGE" >> "$VOICE_BRIDGE_LOG"
        launchctl submit -l com.relay.voicebridge -- /bin/bash -lc 'cd "$1" || exit 1; if [ -n "$3" ]; then export RELAY_RUNNER_PROVIDER="$3"; else unset RELAY_RUNNER_PROVIDER; fi; if [ -n "$5" ]; then export RELAY_PROVIDER_SESSION_ID="$5"; else unset RELAY_PROVIDER_SESSION_ID; fi; export RELAY_ACTOR_ROLE=voice_bridge; unset RELAY_FOREGROUND_GATE_HANDLE RELAY_RECOVERY_GENERATION RELAY_REPLY_HELPER RELAY_SESSION_EVENTS RELAY_CONTEXT_COMPACTION_EVENTS; "$2" --relay\(greetingFlag) >> "$4" 2>&1; status=$?; echo "[relay-runner] launchctl bridge process exited status=$status at $(date -u "+%Y-%m-%dT%H:%M:%SZ") provider=${3:-none}" >> "$4"; exit "$status"' relay-voice "$RELAY_CWD" "$RELAY_BRIDGE" "$RELAY_PROVIDER" "$VOICE_BRIDGE_LOG" "$RELAY_PROVIDER_SESSION_ID" >> "$VOICE_BRIDGE_LOG" 2>&1
        submit_status=$?
        [ -n "$RELAY_PROVIDER_SESSION_ID" ] && printf '%s\n' "$RELAY_PROVIDER_SESSION_ID" > /tmp/voice_provider_session_id
        if [ "$submit_status" -eq 0 ]; then
            echo "[relay-runner] app watchdog launchctl job submission accepted exit_status=0 (submission only; bridge/provider outcome pending) provider=${RELAY_PROVIDER:-none}" >> "$VOICE_BRIDGE_LOG"
        else
            echo "[relay-runner] app watchdog launchctl job submission failed exit_status=$submit_status provider=${RELAY_PROVIDER:-none}" >> "$VOICE_BRIDGE_LOG"
        fi
        for _ in $(seq 1 20); do
            if [ -S /tmp/voice_bridge.sock ]; then
                echo "[relay-runner] app watchdog launchctl produced socket provider=${RELAY_PROVIDER:-none}" >> "$VOICE_BRIDGE_LOG"
                restore_replayed_command
                exit 0
            fi
            launchctl print "gui/$(id -u)/com.relay.voicebridge" >/dev/null 2>&1 || break
            sleep 0.5
        done
        if [ -S /tmp/voice_bridge.sock ]; then
            restore_replayed_command
            exit 0
        fi
        echo "[relay-runner] app watchdog launchctl recovery did not produce a socket; submit_status=$submit_status uid=$(id -u) provider=${RELAY_PROVIDER:-none} cwd=$RELAY_CWD; launchctl print follows." >> "$VOICE_BRIDGE_LOG"
        launchctl print "gui/$(id -u)/com.relay.voicebridge" >> "$VOICE_BRIDGE_LOG" 2>&1
        print_status=$?
        [ "$print_status" -eq 0 ] || echo "[relay-runner] app watchdog launchctl print exit_status=$print_status" >> "$VOICE_BRIDGE_LOG"
        echo "[relay-runner] app watchdog falling back to direct background launch." >> "$VOICE_BRIDGE_LOG"
        launchctl remove com.relay.voicebridge 2>/dev/null || true
        nohup /bin/bash -lc 'cd "$1" || exit 1; if [ -n "$3" ]; then export RELAY_RUNNER_PROVIDER="$3"; else unset RELAY_RUNNER_PROVIDER; fi; if [ -n "$5" ]; then export RELAY_PROVIDER_SESSION_ID="$5"; else unset RELAY_PROVIDER_SESSION_ID; fi; export RELAY_ACTOR_ROLE=voice_bridge; unset RELAY_FOREGROUND_GATE_HANDLE RELAY_RECOVERY_GENERATION RELAY_REPLY_HELPER RELAY_SESSION_EVENTS RELAY_CONTEXT_COMPACTION_EVENTS; "$2" --relay\(greetingFlag) >> "$4" 2>&1; status=$?; echo "[relay-runner] direct bridge process exited status=$status at $(date -u "+%Y-%m-%dT%H:%M:%SZ") provider=${3:-none}" >> "$4"; exit "$status"' relay-direct "$RELAY_CWD" "$RELAY_BRIDGE" "$RELAY_PROVIDER" "$VOICE_BRIDGE_LOG" "$RELAY_PROVIDER_SESSION_ID" >> "$VOICE_BRIDGE_LOG" 2>&1 &
        fallback_pid=$!
        echo "[relay-runner] app watchdog direct fallback launched pid=$fallback_pid provider=${RELAY_PROVIDER:-none}" >> "$VOICE_BRIDGE_LOG"
        for _ in $(seq 1 20); do
            if [ -S /tmp/voice_bridge.sock ]; then
                echo "[relay-runner] app watchdog direct fallback produced socket provider=${RELAY_PROVIDER:-none}" >> "$VOICE_BRIDGE_LOG"
                restore_replayed_command
                exit 0
            fi
            sleep 0.5
        done
        echo "[relay-runner] app watchdog direct fallback did not produce a socket provider=${RELAY_PROVIDER:-none}" >> "$VOICE_BRIDGE_LOG"
        exit 1
        """
    }

    /// Kill any running voice_bridge process (but leave the terminal window open).
    func killBridge(stopRequested: Bool = false) {
        if stopRequested {
            Self.markBridgeStopRequested()
        }

        Self.removeLaunchdBridgeJob()
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
        if stopRequested {
            Self.markBridgeStopRequested()
        }
    }

    func stopServices() {
        Self.markBridgeStopRequested()
        Self.removeLaunchdBridgeJob()
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
        Self.markBridgeStopRequested()
    }

    func stopServicesForBundleReplacement() {
        stopServices()
        stopBundledOrchestrator()
        Self.killProcesses(matching: bundledServicesDir.path)
        Self.removeBridgeRuntimeFiles()
    }

    private func stopBundledOrchestrator() {
        guard FileManager.default.isExecutableFile(atPath: bundledRelayOrchestrator.path) else { return }
        let proc = Process()
        proc.executableURL = bundledRelayOrchestrator
        proc.arguments = ["--stop"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("[ProcessManager] Failed to stop relay-orchestrator before bundle replacement: \(error)")
        }
    }

    private static func killProcesses(matching pattern: String) {
        guard !pattern.isEmpty else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", pattern]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("[ProcessManager] Failed to kill bundled service processes matching \(pattern): \(error)")
        }
    }

    enum SessionVoiceDelivery: Equatable {
        /// Relay Runner owns the bridge daemon and injects voice turns into the
        /// embedded PTY, leaving the provider at its normal interactive prompt.
        case appOwned
        /// The installed relay-bridge command/skill owns the foreground loop.
        /// This remains the transport for manual and external Terminal sessions.
        case agentSkill
    }

    struct PreparedSessionLaunch: Equatable {
        let executable: String
        let arguments: [String]
        let launcherPath: String
        let workingDirectory: String
        let target: AgentTarget
        let voiceDelivery: SessionVoiceDelivery
        let sessionEventPath: String?
        let providerSessionID: String?
        let appSessionID: String?
        let recoveryGeneration: String?
        let foregroundGateHandle: String?
        let diagnosticsCorrelationID: String

        init(
            executable: String,
            arguments: [String],
            launcherPath: String,
            workingDirectory: String,
            target: AgentTarget,
            voiceDelivery: SessionVoiceDelivery,
            sessionEventPath: String? = nil,
            providerSessionID: String? = nil,
            appSessionID: String? = nil,
            recoveryGeneration: String? = nil,
            foregroundGateHandle: String? = nil,
            diagnosticsCorrelationID: String = UUID().uuidString.lowercased()
        ) {
            self.executable = executable
            self.arguments = arguments
            self.launcherPath = launcherPath
            self.workingDirectory = workingDirectory
            self.target = target
            self.voiceDelivery = voiceDelivery
            self.sessionEventPath = sessionEventPath
            self.providerSessionID = providerSessionID
            self.appSessionID = appSessionID
            self.recoveryGeneration = recoveryGeneration
            self.foregroundGateHandle = foregroundGateHandle
            self.diagnosticsCorrelationID = diagnosticsCorrelationID
        }
    }

    enum SessionLaunchPreparationError: LocalizedError {
        case externalTerminalLaunch
        case launcherPermissions(Int32)
        case invalidWorkingDirectory(String)
        case codexModelResolution(String)
        case projectScopeRequired
        case invalidProjectScope(String)

        var errorDescription: String? {
            switch self {
            case .externalTerminalLaunch:
                return "Terminal.app could not open the Relay Runner session."
            case .launcherPermissions(let status):
                return "Could not prepare the Relay Runner session launcher (chmod exited with status \(status))."
            case .invalidWorkingDirectory(let path):
                return "The session workspace folder is unavailable: \(path)"
            case .codexModelResolution(let message):
                return "Could not resolve the selected Codex model family: \(message)"
            case .projectScopeRequired:
                return "Select an available registered project before starting a session."
            case .invalidProjectScope(let message):
                return "The selected project scope is no longer valid: \(message)"
            }
        }
    }

    /// Prepare the provider command shared by embedded and external terminal
    /// launches. Embedded Start Session uses app-owned PTY delivery so the
    /// terminal remains a normal interactive provider prompt; external/manual
    /// sessions still rely on the installed relay-bridge command/skill loop.
    ///
    /// The launcher calls `relay-bridge --venv-only` first so the Python venv,
    /// Kokoro model, and provider CLI are ready before the interactive agent
    /// starts. Refreshing the skill files here also keeps every launch path on
    /// the same shipped relay contract.
    func prepareNewSession(
        config: AppConfig,
        voiceDelivery: SessionVoiceDelivery = .agentSkill,
        suppressStartupGreeting: Bool = false,
        sessionEventPath: String? = nil,
        projectScopeToken: ConfirmedProjectScopeToken? = nil
    ) throws -> PreparedSessionLaunch {
        Self.clearBridgeStopRequested()

        let workingDirectory = WorkspaceFolder.url(from: config.general.working_directory).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionLaunchPreparationError.invalidWorkingDirectory(workingDirectory)
        }
        if let registryV2 = ProjectRegistryV2Service.makeIfEnabled() {
            guard let projectScopeToken else {
                throw SessionLaunchPreparationError.projectScopeRequired
            }
            guard case .valid(let project) = registryV2.validateScopeToken(projectScopeToken) else {
                throw SessionLaunchPreparationError.invalidProjectScope(projectScopeToken.projectID)
            }
            let confirmedPath = URL(fileURLWithPath: project.lastResolvedPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            let requestedPath = URL(fileURLWithPath: workingDirectory)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard confirmedPath == requestedPath else {
                throw SessionLaunchPreparationError.invalidProjectScope(
                    "requested cwd does not match \(projectScopeToken.projectID)"
                )
            }
        }

        let configPath = ConfigManager.shared.configPath.path
        let relayBridge = bundledRelayBridge.path
        let target = Self.target(for: config.general.provider)
        let agentBinary = Self.resolveAgentBinary(config.general.command, target: target)
        let codexSelection: CodexModelResolution?
        if target == .codex {
            do {
                codexSelection = try CodexModelResolver.resolveViaService(
                    family: config.general.model,
                    effort: config.general.effectiveOrchestratorEffort,
                    command: agentBinary,
                    servicesDir: bundledServicesDir,
                    pythonPath: Self.servicePython
                )
            } catch let error as CodexModelResolver.Error {
                throw SessionLaunchPreparationError.codexModelResolution(
                    error.errorDescription ?? String(describing: error)
                )
            } catch {
                throw SessionLaunchPreparationError.codexModelResolution(error.localizedDescription)
            }
        } else {
            codexSelection = nil
        }
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
        let providerSessionID = voiceDelivery == .appOwned
            ? UUID().uuidString.lowercased()
            : nil
        let appSessionID = voiceDelivery == .appOwned
            ? RelayDiagnostics.shared.appSessionID
            : nil
        let recoveryGeneration = voiceDelivery == .appOwned
            ? UUID().uuidString.lowercased()
            : nil
        let foregroundGateHandle = voiceDelivery == .appOwned
            ? UUID().uuidString.lowercased()
            : nil
        let script = Self.launchScript(
            relayBridge: relayBridge,
            target: target,
            agentBinary: agentBinary,
            config: config,
            voiceDelivery: voiceDelivery,
            suppressStartupGreeting: suppressStartupGreeting,
            sessionEventPath: sessionEventPath,
            providerSessionID: providerSessionID,
            appSessionID: appSessionID,
            recoveryGeneration: recoveryGeneration,
            foregroundGateHandle: foregroundGateHandle,
            resolvedCodexModel: codexSelection?.resolvedModel,
            resolvedCodexEffort: codexSelection?.resolvedEffort,
            projectScopeToken: projectScopeToken
        )
        try script.write(toFile: launcher, atomically: true, encoding: String.Encoding.utf8)

        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", launcher]
        try chmod.run()
        chmod.waitUntilExit()
        guard chmod.terminationStatus == 0 else {
            throw SessionLaunchPreparationError.launcherPermissions(chmod.terminationStatus)
        }

        // Pre-create the legacy voice_in fifo for any old-path consumers;
        // the new --relay daemon manages /tmp/voice_bridge.sock,
        // /tmp/voice_cmd_ready, /tmp/tts_in.fifo, and the heartbeat itself.
        ensureFifo()

        return PreparedSessionLaunch(
            executable: "/bin/bash",
            arguments: [launcher],
            launcherPath: launcher,
            workingDirectory: workingDirectory,
            target: target,
            voiceDelivery: voiceDelivery,
            sessionEventPath: sessionEventPath,
            providerSessionID: providerSessionID,
            appSessionID: appSessionID,
            recoveryGeneration: recoveryGeneration,
            foregroundGateHandle: foregroundGateHandle
        )
    }

    /// Launch the prepared session in Terminal.app. Kept as a compatibility
    /// path when the embedded terminal cannot be used or the user prefers a
    /// separate terminal window.
    @discardableResult
    func launchPreparedSessionInTerminal(_ launch: PreparedSessionLaunch) -> Bool {
        launchInTerminal(command: launch.launcherPath)
    }

    @discardableResult
    func launchNewSession(config: AppConfig) -> Bool {
        do {
            return launchPreparedSessionInTerminal(try prepareNewSession(config: config))
        } catch {
            NSLog("[ProcessManager] Failed to prepare new session: \(error)")
            return false
        }
    }

    enum AgentTarget: Equatable {
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
        voiceDelivery: SessionVoiceDelivery = .agentSkill,
        suppressStartupGreeting: Bool = false,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        sessionEventPath: String? = nil,
        providerSessionID: String? = nil,
        appSessionID: String? = nil,
        recoveryGeneration: String? = nil,
        foregroundGateHandle: String? = nil,
        resolvedCodexModel: String? = nil,
        resolvedCodexEffort: String? = nil,
        projectScopeToken: ConfirmedProjectScopeToken? = nil
    ) -> String {
        let effectiveProviderSessionID = voiceDelivery == .appOwned
            ? (providerSessionID ?? UUID().uuidString.lowercased())
            : nil
        let effectiveAppSessionID = voiceDelivery == .appOwned
            ? (appSessionID ?? RelayDiagnostics.shared.appSessionID)
            : nil
        let effectiveRecoveryGeneration = voiceDelivery == .appOwned
            ? (recoveryGeneration ?? UUID().uuidString.lowercased())
            : nil
        let effectiveForegroundGateHandle = voiceDelivery == .appOwned
            ? (foregroundGateHandle ?? UUID().uuidString.lowercased())
            : nil
        let bypassFlag = Self.bypassFlag(enabled: config.general.bypass_permissions, target: target)
        let modelFlag = Self.modelFlag(config.general.model, target: target, resolvedCodexModel: resolvedCodexModel)
        let reasoningEffortFlag = Self.orchestratorEffortFlag(
            config.general.effectiveOrchestratorEffort,
            target: target,
            model: config.general.model,
            resolvedCodexEffort: resolvedCodexEffort
        )
        let cdLine = Self.cdLine(config.general.working_directory, homeDirectory: homeDirectory)
        let bridgeStartLine = Self.bridgeStartLine(
            relayBridge: relayBridge,
            voiceDelivery: voiceDelivery,
            suppressStartupGreeting: suppressStartupGreeting
        )
        let launchLine = Self.agentLaunchLine(
            binary: agentBinary,
            target: target,
            modelFlag: modelFlag,
            reasoningEffortFlag: reasoningEffortFlag,
            automaticCompactionFlag: Self.appOwnedAutomaticCompactionFlag(
                target: target,
                voiceDelivery: voiceDelivery
            ),
            bypassFlag: bypassFlag,
            appOwnedInstructionFlag: Self.appOwnedInstructionFlag(
                target: target,
                voiceDelivery: voiceDelivery
            ),
            completionHookFlag: Self.appOwnedCompletionHookFlag(
                relayBridge: relayBridge,
                target: target,
                voiceDelivery: voiceDelivery
            ),
            voiceDelivery: voiceDelivery
        )
        return """
        #!/bin/bash
        \(Self.shellProfileSource())
        \(Self.sessionLifecyclePreamble(eventPath: sessionEventPath))
        \(Self.supportDiagnosticsPreamble())
        # Ensure venv + deps + speech-model + relay skills are installed. In
        # embedded sessions, also start the bridge daemon before the provider so
        # voice turns can be injected without a blocking bootstrap prompt.
        rm -f /tmp/voice_bridge_stop_requested
        # Keep common agent install locations on PATH for tools launched from
        # this session. On fresh installs the relay-bridge install may have
        # dropped a binary moments ago and the shell profile may not know yet.
        export PATH="$HOME/.local/bin:$PATH"
        export RELAY_RUNNER_PROVIDER=\(Self.shellQuoted(target.providerMetadataValue))
        \(Self.projectScopeEnvironment(projectScopeToken))
        # The agent can execute bootstrap checks inside its own sandbox, where
        # process enumeration may not see the Relay Runner host. This marker is
        # advisory session context, not a security boundary.
        export RELAY_RUNNER_APP_SESSION=1
        \(Self.appOwnedForegroundOwnershipEnvironment(
            appSessionID: effectiveAppSessionID,
            recoveryGeneration: effectiveRecoveryGeneration,
            foregroundGateHandle: effectiveForegroundGateHandle
        ))
        \(Self.appOwnedProviderSessionExport(effectiveProviderSessionID))
        \(Self.appOwnedAutomaticCompactionEnvironment(
            target: target,
            voiceDelivery: voiceDelivery,
            sessionEventPath: sessionEventPath
        ))
        \(Self.appOwnedReplyHelperExport(
            relayBridge: relayBridge,
            voiceDelivery: voiceDelivery
        ))
        \(cdLine)
        relay_record_session_event launcher_start started
        # relay-bridge owns bridge readiness. Agent-skill sessions only bootstrap
        # here; app-owned sessions wait for the Python bridge's socket.
        \(bridgeStartLine)
        \(Self.appOwnedProviderSessionPublish(effectiveProviderSessionID))
        relay_record_session_event provider_spawn started
        relay_record_support_event provider provider_readiness spawned
        # Interactive agent session with Relay Runner voice mode pre-fired.
        # Replacing this launcher process keeps the PTY child PID aligned with
        # the agent, so End Session terminates the interactive process cleanly.
        exec \(launchLine)
        """
    }

    private static func projectScopeEnvironment(_ token: ConfirmedProjectScopeToken?) -> String {
        guard let token, let encoded = token.encodedValue else {
            return "unset RELAY_PROJECT_SCOPE_TOKEN RELAY_PROJECT_ID RELAY_PROJECT_SCOPE_VERSION"
        }
        return """
        export RELAY_PROJECT_SCOPE_TOKEN=\(shellQuoted(encoded))
        export RELAY_PROJECT_ID=\(shellQuoted(token.projectID))
        export RELAY_PROJECT_SCOPE_VERSION=\(shellQuoted(String(token.version)))
        """
    }

    private static func sessionLifecyclePreamble(eventPath: String?) -> String {
        guard let eventPath, !eventPath.isEmpty else {
            return "relay_record_session_event() { :; }"
        }
        return """
        export RELAY_SESSION_EVENTS=\(shellQuoted(eventPath))
        relay_record_session_event() {
            printf '{"outcome":"%s","stage":"%s","timestamp":"%s"}\\n' \
                "$2" "$1" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
                >> "$RELAY_SESSION_EVENTS" 2>/dev/null || true
            chmod 600 "$RELAY_SESSION_EVENTS" 2>/dev/null || true
        }
        """
    }

    private static func supportDiagnosticsPreamble() -> String {
        """
        relay_support_file_mtime() {
            stat -f '%m' "$1" 2>/dev/null || stat --format='%Y' "$1" 2>/dev/null || echo 0
        }
        relay_support_file_size() {
            stat -f '%z' "$1" 2>/dev/null || stat --format='%s' "$1" 2>/dev/null || echo 0
        }
        relay_support_safe_id() {
            [ "${#1}" -le 64 ] && [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ \
                || "$1" =~ ^inc-[0-9a-f]{12}$ \
                || "$1" =~ ^(shell|orchestrator)-[0-9]{10,}-[0-9]+$ ]]
        }
        relay_acquire_support_journal_lock() {
            relay_lock="$1/.journal.lock"
            relay_lock_attempts=0
            while ! mkdir "$relay_lock" 2>/dev/null; do
                relay_now="$(date +%s)"
                relay_lock_mtime="$(relay_support_file_mtime "$relay_lock")"
                if [ "$relay_lock_mtime" -gt 0 ] && [ $((relay_now - relay_lock_mtime)) -ge 30 ]; then
                    relay_stale_lock="$1/.journal.lock.stale-$$-$relay_lock_attempts"
                    if mv "$relay_lock" "$relay_stale_lock" 2>/dev/null; then
                        rm -rf "$relay_stale_lock"
                        continue
                    fi
                fi
                relay_lock_attempts=$((relay_lock_attempts + 1))
                [ "$relay_lock_attempts" -lt 100 ] || return 1
                sleep 0.05
            done
        }
        relay_release_support_journal_lock() {
            rm -rf "$1/.journal.lock"
        }
        relay_prune_support_journals() {
            relay_diagnostics_dir="$1"
            relay_cutoff=$(($(date +%s) - 604800))
            for relay_file in "$relay_diagnostics_dir"/events-v1-*.jsonl; do
                [ -f "$relay_file" ] || continue
                relay_mtime="$(relay_support_file_mtime "$relay_file")"
                if [ "$relay_mtime" -lt "$relay_cutoff" ]; then rm -f "$relay_file"; fi
            done
            relay_total=0
            for relay_file in "$relay_diagnostics_dir"/events-v1-*.jsonl; do
                [ -f "$relay_file" ] || continue
                relay_size="$(relay_support_file_size "$relay_file")"
                relay_total=$((relay_total + relay_size))
            done
            while [ "$relay_total" -gt 5242880 ]; do
                relay_oldest=""
                relay_oldest_mtime=""
                for relay_file in "$relay_diagnostics_dir"/events-v1-*.jsonl; do
                    [ -f "$relay_file" ] || continue
                    relay_mtime="$(relay_support_file_mtime "$relay_file")"
                    if [ -z "$relay_oldest" ] || [ "$relay_mtime" -lt "$relay_oldest_mtime" ] \
                        || { [ "$relay_mtime" -eq "$relay_oldest_mtime" ] && [[ "$relay_file" < "$relay_oldest" ]]; }; then
                        relay_oldest="$relay_file"
                        relay_oldest_mtime="$relay_mtime"
                    fi
                done
                [ -n "$relay_oldest" ] || break
                relay_size="$(relay_support_file_size "$relay_oldest")"
                rm -f "$relay_oldest"
                relay_total=$((relay_total - relay_size))
            done
        }
        relay_record_support_event() {
            case "$1:$2:$3" in
                shell:bridge_readiness:started|shell:bridge_readiness:ready|shell:bridge_readiness:failed|shell:setup:failed|provider:provider_readiness:spawned) ;;
                *) return 0 ;;
            esac
            relay_diagnostics_dir="${RELAY_DIAGNOSTICS_DIR:-$HOME/Library/Application Support/relay-runner/support-diagnostics/v1}"
            relay_redaction_count=0
            relay_raw_id="${RELAY_APP_SESSION_ID:-shell-$(date +%s)-$$}"
            if relay_support_safe_id "$relay_raw_id"; then relay_app_session="$relay_raw_id"; else relay_app_session="redacted-id"; relay_redaction_count=$((relay_redaction_count + 1)); fi
            relay_raw_id="${RELAY_CORRELATION_ID:-shell-$(date +%s)-$$}"
            if relay_support_safe_id "$relay_raw_id"; then relay_correlation="$relay_raw_id"; else relay_correlation="redacted-id"; relay_redaction_count=$((relay_redaction_count + 1)); fi
            case "${RELAY_RUNNER_PROVIDER:-}" in
                codex|claude) relay_provider_json="\"$RELAY_RUNNER_PROVIDER\"" ;;
                *) relay_provider_json="null"; [ -z "${RELAY_RUNNER_PROVIDER:-}" ] || relay_redaction_count=$((relay_redaction_count + 1)) ;;
            esac
            mkdir -p "$relay_diagnostics_dir" 2>/dev/null || return 0
            chmod 700 "$relay_diagnostics_dir" 2>/dev/null || true
            relay_acquire_support_journal_lock "$relay_diagnostics_dir" || return 0
            printf '{"app_session_id":"%s","attributes":{},"correlation_id":"%s","incident_id":null,"outcome":"%s","phase":"%s","process":"%s","provider":%s,"redaction_count":%s,"retry_attempt":null,"schema_version":1,"summary":null,"timestamp":"%s"}\\n' \\
                "$relay_app_session" "$relay_correlation" "$3" "$2" "$1" "$relay_provider_json" "$relay_redaction_count" \\
                "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \\
                >> "$relay_diagnostics_dir/events-v1-$1-$$.jsonl" 2>/dev/null || true
            chmod 600 "$relay_diagnostics_dir/events-v1-$1-$$.jsonl" 2>/dev/null || true
            relay_prune_support_journals "$relay_diagnostics_dir"
            relay_release_support_journal_lock "$relay_diagnostics_dir"
        }
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
    static func resolveAgentBinary(
        _ command: String,
        target: AgentTarget,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed.hasPrefix("/") {
            return trimmed
        }
        switch target {
        case .codex:
            let bundledCandidates = [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
            ]
            if let bundled = bundledCandidates.first(where: isExecutable) {
                return bundled
            }
            return "codex"
        case .claude:
            let local = ClaudeAuth.claudeBinaryPath
            if isExecutable(local) {
                return local
            }
            return "claude"
        }
    }

    /// Render the `--model <name>` flag for the launcher script, or empty
    /// string when the user wants the agent's default. Single-quotes the name
    /// so a TOML-edited custom model id (e.g. `claude-sonnet-4-6`) can't
    /// break shell parsing.
    private static func modelFlag(_ raw: String, target: AgentTarget, resolvedCodexModel: String? = nil) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let provider: GeneralConfig.AgentProvider
        switch target {
        case .codex: provider = .codex
        case .claude: provider = .claude
        }
        switch target {
        case .codex:
            guard GeneralConfig.isModel(GeneralConfig.normalizeModel(v, for: provider), validFor: provider),
                  let resolved = resolvedCodexModel?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !resolved.isEmpty else { return "" }
            return "--model \(Self.shellQuoted(resolved)) "
        case .claude:
            guard GeneralConfig.isModel(v, validFor: provider) else { return "" }
            return "--model \(Self.shellQuoted(v)) "
        }
    }

    private static func orchestratorEffortFlag(
        _ raw: String,
        target: AgentTarget,
        model: String,
        resolvedCodexEffort: String? = nil
    ) -> String {
        let provider: GeneralConfig.AgentProvider
        switch target {
        case .codex: provider = .codex
        case .claude: provider = .claude
        }
        let effort: String
        if target == .codex,
           let resolvedCodexEffort,
           !resolvedCodexEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effort = resolvedCodexEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        } else {
            effort = GeneralConfig.normalizedOrchestratorEffort(raw, for: provider, model: model)
        }
        guard effort != GeneralConfig.defaultReasoningEffort else { return "" }
        switch target {
        case .codex:
            return "-c \(Self.shellQuoted("model_reasoning_effort=\"\(effort)\"")) "
        case .claude:
            return "--effort \(Self.shellQuoted(effort)) "
        }
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

    static let appOwnedRelayInstructions = """
    You are the app-owned foreground Relay orchestrator/PM in Relay Runner integrated terminal.
    Relay Runner has already started the voice bridge and injects each claimed voice turn into this provider prompt; do not invoke relay-bridge or start a polling loop.
    Dispatching a worker or sending a final response ends only the current provider turn. The Relay session remains active for later user turns and worker updates; never invoke relay-stop or end the session unless the user explicitly asks to stop it.
    A turn is voice-originated only when its prompt text exactly matches agent_prompt in /tmp/voice_cmd_claimed.json. For legacy metadata without agent_prompt, require an exact source_text match instead. Otherwise treat it as a normal typed turn and do not use claimed metadata or write messenger trace/reply events. One source turn may arrive as several ordered items; each claimed item has a stable intent_id and exactly one work_disposition: continue_current, run_sidecar, queue_project_work, clarify_priority, replace_current, or control_only. Queue conflicting work by default. A scoped replace_current cancels only its resolved item or ticket; only cancellation_scope=all_work may preempt unrelated accepted work. Sidecars must be bounded, read-only, independently verifiable, resource-safe, silent, and unable to bypass Relay tickets for project mutations.
    For a matching voice item, treat relay_command_seq, relay_command_id, and intent_id as two contracts. User-visible replies, traces, and TTS must still match the newest source command in /tmp/voice_command_state.json; if a newer command is present, stop stale work for output, do not answer or act on the newer command, and end this provider turn silently so Relay Runner can atomically claim and inject the ordered next item from the inbox. Ticket edits, dispatches, and orchestrator actions must pass the claimed seq/id and item identity when supported; an older bounded mutation may continue only when Relay Runner registered it and no scoped replacement, redirect, interrupt, or cancellation revoked that item. Acknowledgement, inspection/status, and additive items do not revoke unrelated prior authorizations.
    Resolve each command as non-work/control, direct action, ticket creation/refinement, ticket update, worker dispatch, or clarification. Raw Relay command captures are private metadata and must not appear in visible .orchestrator tickets. Do not implement substantial project work inline unless the user explicitly asks.
    Use mcp__relay-actions__* for screen manipulation and mcp__relay-vision__screenshot for screenshots; never use native computer-use fallbacks for those capabilities, and do not call propose_action.
    The messenger is tool-free and not authoritative. Mirror only bounded public provider-visible reasoning summaries/progress/lifecycle updates through __TRACE__ messages on /tmp/voice_in.fifo. A Relay-owned completion hook will recover a non-empty final provider message at turn Stop. Do not write reply JSON or reply envelopes to /tmp/voice_in.fifo directly. If an explicit current reply is needed, pipe only the final reply text to `/usr/bin/python3 "$RELAY_REPLY_HELPER"`; that shared helper binds and checks the claimed seq/id and is the sole app-owned __ORCHESTRATOR_REPLY__ encoder. Its accepted reply remains authoritative and deduplicates the later completion hook. Never expose hidden chain-of-thought, secrets, raw tool output, transcript dumps, or setup prose.
    Provider responses, reasoning summaries, tool calls, progress, and final output should remain visible in this terminal.
    """

    private static func appOwnedInstructionFlag(
        target: AgentTarget,
        voiceDelivery: SessionVoiceDelivery
    ) -> String {
        guard voiceDelivery == .appOwned else { return "" }
        let instructions = appOwnedRelayInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        switch target {
        case .codex:
            return "-c \(Self.shellQuoted("developer_instructions=\(tomlBasicStringLiteral(instructions))")) "
        case .claude:
            return "--append-system-prompt \(Self.shellQuoted(instructions)) "
        }
    }

    private static func tomlBasicStringLiteral(_ value: String) -> String {
        var escaped = "\""
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.append(character)
            }
        }
        escaped += "\""
        return escaped
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        var escaped = "\""
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.append(character)
            }
        }
        escaped += "\""
        return escaped
    }

    private static func completionHookScriptPath(relayBridge: String) -> String {
        URL(fileURLWithPath: relayBridge)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("services/relay_completion_hook.py")
            .path
    }

    private static func replyHelperScriptPath(relayBridge: String) -> String {
        URL(fileURLWithPath: relayBridge)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("services/relay_reply.py")
            .path
    }

    private static func appOwnedReplyHelperExport(
        relayBridge: String,
        voiceDelivery: SessionVoiceDelivery
    ) -> String {
        guard voiceDelivery == .appOwned else { return "" }
        return "export RELAY_REPLY_HELPER="
            + Self.shellQuoted(Self.replyHelperScriptPath(relayBridge: relayBridge))
    }

    private static func appOwnedProviderSessionExport(_ providerSessionID: String?) -> String {
        guard let providerSessionID else { return "" }
        return "export RELAY_PROVIDER_SESSION_ID=" + Self.shellQuoted(providerSessionID)
    }

    private static func appOwnedForegroundOwnershipEnvironment(
        appSessionID: String?,
        recoveryGeneration: String?,
        foregroundGateHandle: String?
    ) -> String {
        guard let appSessionID, let recoveryGeneration, let foregroundGateHandle else { return "" }
        return """
        export RELAY_APP_SESSION_ID=\(shellQuoted(appSessionID))
        export RELAY_RECOVERY_GENERATION=\(shellQuoted(recoveryGeneration))
        export RELAY_ACTOR_ROLE=foreground_pm
        export RELAY_FOREGROUND_GATE_HANDLE=\(shellQuoted(foregroundGateHandle))
        """
    }

    private static func appOwnedProviderSessionPublish(_ providerSessionID: String?) -> String {
        guard providerSessionID != nil else { return "" }
        return "printf '%s\\n' \"$RELAY_PROVIDER_SESSION_ID\" > /tmp/voice_provider_session_id"
    }

    private static func appOwnedAutomaticCompactionFlag(
        target: AgentTarget,
        voiceDelivery: SessionVoiceDelivery
    ) -> String {
        guard voiceDelivery == .appOwned, target == .codex else { return "" }
        let threshold = embeddedAutoCompactTokenThreshold
        return "-c \(Self.shellQuoted("model_auto_compact_token_limit=\(threshold)")) "
            + "-c \(Self.shellQuoted("model_auto_compact_token_limit_scope=\"total\"")) "
    }

    private static func appOwnedAutomaticCompactionEnvironment(
        target: AgentTarget,
        voiceDelivery: SessionVoiceDelivery,
        sessionEventPath: String?
    ) -> String {
        guard voiceDelivery == .appOwned else { return "" }
        var common = "export RELAY_AUTO_COMPACT_THRESHOLD_TOKENS=\(embeddedAutoCompactTokenThreshold)"
        if let sessionEventPath, !sessionEventPath.isEmpty {
            common += "\nexport RELAY_CONTEXT_COMPACTION_EVENTS="
                + shellQuoted(sessionEventPath + ".context-compaction.jsonl")
        }
        guard target == .claude else { return common }
        return """
        \(common)
        unset DISABLE_AUTO_COMPACT DISABLE_COMPACT
        export CLAUDE_CODE_AUTO_COMPACT_WINDOW=\(claudeAutoCompactWindow)
        export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=\(claudeAutoCompactPercentage)
        """
    }

    private static func completionHookCommand(relayBridge: String) -> String {
        "/usr/bin/python3 \(Self.shellQuoted(Self.completionHookScriptPath(relayBridge: relayBridge)))"
    }

    private static func codexCompletionHookFlag(event: String, command: String, statusMessage: String) -> String {
        let handler = "[{ hooks = [{ type = \"command\", command = \(Self.tomlBasicStringLiteral(command)), timeout = 2, statusMessage = \(Self.tomlBasicStringLiteral(statusMessage)) }] }]"
        return "-c \(Self.shellQuoted("hooks.\(event)=\(handler)")) "
    }

    private static func claudeCompletionHookSettings(command: String) -> String {
        let handler = "[{\"hooks\":[{\"type\":\"command\",\"command\":\(Self.jsonStringLiteral(command)),\"timeout\":2}]}]"
        return "{\"hooks\":{\"UserPromptSubmit\":\(handler),\"Stop\":\(handler),\"StopFailure\":\(handler),\"PreCompact\":\(handler),\"PostCompact\":\(handler)}}"
    }

    private static func appOwnedCompletionHookFlag(
        relayBridge: String,
        target: AgentTarget,
        voiceDelivery: SessionVoiceDelivery
    ) -> String {
        guard voiceDelivery == .appOwned else { return "" }
        let command = Self.completionHookCommand(relayBridge: relayBridge)
        switch target {
        case .codex:
            return "--enable hooks --dangerously-bypass-hook-trust "
                + Self.codexCompletionHookFlag(
                    event: "UserPromptSubmit",
                    command: command,
                    statusMessage: "Relay voice prompt binding"
                )
                + Self.codexCompletionHookFlag(
                    event: "Stop",
                    command: command,
                    statusMessage: "Relay voice completion"
                )
                + Self.codexCompletionHookFlag(
                    event: "PreCompact",
                    command: command,
                    statusMessage: "Relay compaction started"
                )
                + Self.codexCompletionHookFlag(
                    event: "PostCompact",
                    command: command,
                    statusMessage: "Relay compaction completed"
                )
        case .claude:
            return "--settings \(Self.shellQuoted(Self.claudeCompletionHookSettings(command: command))) "
        }
    }

    private static func agentLaunchLine(
        binary: String,
        target: AgentTarget,
        modelFlag: String,
        reasoningEffortFlag: String,
        automaticCompactionFlag: String,
        bypassFlag: String,
        appOwnedInstructionFlag: String,
        completionHookFlag: String,
        voiceDelivery: SessionVoiceDelivery
    ) -> String {
        let prefix = "\(Self.shellQuoted(binary)) \(modelFlag)\(reasoningEffortFlag)\(automaticCompactionFlag)\(appOwnedInstructionFlag)\(completionHookFlag)\(bypassFlag)"
            .trimmingCharacters(in: .whitespaces)
        guard voiceDelivery == .agentSkill else {
            return prefix
        }
        switch target {
        case .codex:
            return "\(prefix) \(Self.shellQuoted("Use the relay-bridge skill now."))"
        case .claude:
            return "\(prefix) \"/relay-bridge\""
        }
    }

    private static func bridgeStartLine(
        relayBridge: String,
        voiceDelivery: SessionVoiceDelivery,
        suppressStartupGreeting: Bool
    ) -> String {
        switch voiceDelivery {
        case .appOwned:
            let greetingFlag = suppressStartupGreeting
                ? " --suppress-startup-greeting"
                : ""
            return "\(Self.shellQuoted(relayBridge)) --start-daemon\(greetingFlag) || { echo '[Relay Runner] Voice bridge failed.'; exit 1; }"
        case .agentSkill:
            return "\(Self.shellQuoted(relayBridge)) --venv-only || { relay_record_support_event shell setup failed; echo '[Relay Runner] Setup failed.'; exit 1; }"
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
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        proc.environment = environment
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

    private static func bridgeStopRequested() -> Bool {
        FileManager.default.fileExists(atPath: bridgeStopRequestedPath)
    }

    private static func markBridgeStopRequested() {
        _ = FileManager.default.createFile(atPath: bridgeStopRequestedPath, contents: Data())
    }

    private static func clearBridgeStopRequested() {
        try? FileManager.default.removeItem(atPath: bridgeStopRequestedPath)
    }

    private static func removeLaunchdBridgeJob() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["remove", bridgeLaunchdLabel]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("[ProcessManager] Failed to remove voice bridge launchd job: \(error)")
        }
    }

    private static func stopHeartbeatRefresher() {
        let path = "/tmp/voice_bridge_heartbeat.pid"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        Darwin.kill(pid, SIGTERM)
    }

    /// Launch a command in Terminal.app via AppleScript `do script`.
    private func launchInTerminal(command: String) -> Bool {
        let appleScript = """
        tell application "Terminal"
            activate
            do script "bash '\(command)'"
        end tell
        """
        return runAppleScript(appleScript)
    }

    private func runAppleScript(_ script: String) -> Bool {
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
            return proc.terminationStatus == 0
        } catch {
            NSLog("[ProcessManager] osascript launch error: \(error)")
            return false
        }
    }
}
