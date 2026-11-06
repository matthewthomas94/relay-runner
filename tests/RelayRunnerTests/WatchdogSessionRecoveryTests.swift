import XCTest
@testable import relay_runner

/// RR-403: recovering one session's bridge never reaches into another's spool
/// or kills processes by pattern.
final class WatchdogSessionRecoveryTests: XCTestCase {
    private func script(provider: String, spool: String?) -> String {
        ProcessManager.bridgeRecoveryScript(
            relayBridge: "/usr/local/bin/relay-bridge",
            context: .init(workingDirectory: "/Users/example/dev", provider: provider, spoolDirectory: spool)
        )
    }

    func testRecoveryScriptStopsTheBridgeByRecordedPidNotByPattern() {
        for provider in ["codex", "claude"] {
            let script = script(provider: provider, spool: "/tmp/relay-sessions/a")
            XCTAssertFalse(script.contains("pkill"))
            XCTAssertTrue(script.contains("BRIDGE_PID=$(cat \(ProcessManager.bridgePIDPath)"))
            XCTAssertTrue(script.contains("grep -q '[v]oice_bridge.py'"))
            XCTAssertTrue(script.contains("kill \"$BRIDGE_PID\""))
            XCTAssertTrue(script.contains(ProcessManager.bridgePIDPath))
        }
    }

    func testRecoveryScriptReplaysAndClearsOnlyTheAffectedSessionsSpool() {
        for provider in ["codex", "claude"] {
            let a = script(provider: provider, spool: "/tmp/relay-sessions/a")
            let b = script(provider: provider, spool: "/tmp/relay-sessions/b")
            XCTAssertTrue(a.contains("RELAY_SESSION_SPOOL_DIR='/tmp/relay-sessions/a'"))
            XCTAssertFalse(a.contains("/tmp/relay-sessions/b"))
            XCTAssertTrue(b.contains("RELAY_SESSION_SPOOL_DIR='/tmp/relay-sessions/b'"))
            XCTAssertFalse(b.contains("/tmp/relay-sessions/a"))
            // Pending command capture, replay and cleanup all go through $SPOOL.
            XCTAssertTrue(a.contains("\"$SPOOL\"/voice_cmd_ready"))
        }
    }

    /// RR-447: the provider keeps running across a bridge restart, so its
    /// delivery evidence survives; a manual /tmp session still starts clean.
    func testAppOwnedRecoveryPreservesTheLiveProvidersDeliveryEvidence() throws {
        for provider in ["codex", "claude"] {
            let lines = script(provider: provider, spool: "/tmp/relay-sessions/a")
                .components(separatedBy: "\n")
            let unconditional = try XCTUnwrap(lines.first { $0.contains("rm -f /tmp/voice_in.fifo") })
            for preserved in [
                "\"$SPOOL\"/voice_cmd_claimed.json", "\"$SPOOL\"/voice_command_state.json",
                "/tmp/voice_provider_turns.json", "/tmp/voice_provider_turns_v2.json",
                "\"$SPOOL\"/relay_terminal_manual_submission.json",
                "\"$SPOOL\"/relay_terminal_delivery_events.jsonl",
            ] {
                XCTAssertFalse(unconditional.contains(preserved), preserved)
            }
            XCTAssertTrue(unconditional.contains("/tmp/voice_bridge.sock"))
            XCTAssertTrue(unconditional.contains("\"$SPOOL\"/voice_cmd_ready.meta"))
            let manualOnly = try XCTUnwrap(lines.firstIndex {
                $0.contains("if [ -z \"$RELAY_SESSION_SPOOL_DIR\" ] && [ -z \"$RELAY_PROVIDER_SESSION_ID\" ]; then")
            })
            XCTAssertTrue(lines[manualOnly + 1].contains("rm -f \"$SPOOL\"/voice_cmd_claimed.json /tmp/voice_provider_turns.json"))
            XCTAssertTrue(lines[manualOnly + 2].contains("rm -f \"$SPOOL\"/voice_command_state.json"))
            XCTAssertEqual(lines[manualOnly + 3].trimmingCharacters(in: .whitespaces), "fi")
        }
    }

    /// RR-465: a watchdog restart that carries the provider session id keeps
    /// the turn ledger and claim the completion hook needs; explicit stop
    /// still removes them.
    func testSameSessionRecoveryPreservesTurnLedgerAndExplicitStopCleansIt() throws {
        for spool in ["/tmp/relay-sessions/a", nil] as [String?] {
            let lines = script(provider: "claude", spool: spool).components(separatedBy: "\n")
            let unconditional = try XCTUnwrap(lines.first { $0.contains("rm -f /tmp/voice_in.fifo") })
            XCTAssertFalse(unconditional.contains("/tmp/voice_provider_turns.json"))
            XCTAssertFalse(unconditional.contains("\"$SPOOL\"/voice_cmd_claimed.json"))
            let manualOnly = try XCTUnwrap(lines.firstIndex { $0.contains("[ -z \"$RELAY_PROVIDER_SESSION_ID\" ]; then") })
            XCTAssertTrue(lines[manualOnly + 1].contains("/tmp/voice_provider_turns.json"))
            XCTAssertTrue(lines[manualOnly + 1].contains("\"$SPOOL\"/voice_cmd_claimed.json"))

            let marker = try XCTUnwrap(lines.firstIndex { $0.contains("if [ -n \"$RELAY_PROVIDER_SESSION_ID\" ]; then") })
            XCTAssertTrue(lines[marker + 1].contains("\"$RELAY_PROVIDER_SESSION_ID\" \"$BRIDGE_PID\" > \(ProcessManager.bridgeWatchdogRestartPath)"))
            let kill = try XCTUnwrap(lines.firstIndex { $0.contains("kill \"$BRIDGE_PID\"") })
            XCTAssertLessThan(marker, kill, "the marker exists before the bridge is signalled")
        }
        for path in ["/tmp/voice_provider_turns.json", "/tmp/voice_cmd_claimed.json",
                     ProcessManager.bridgeWatchdogRestartPath] {
            XCTAssertTrue(ProcessManager.bridgeRuntimePaths.contains(path), "explicit stop removes \(path)")
        }
    }

    func testRecordedBridgeLivenessSignalsThePidWithoutSpawning() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr465-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("voice_bridge.pid").path
        try "4242\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
        let bridge = "python3 /app/services/voice_bridge.py --relay"

        func probe(
            signal: Int32,
            kernel: String?,
            ps: ProcessManager.ProcessCommandLineLookup = .unavailable
        ) -> ProcessManager.BridgeLivenessReport {
            ProcessManager.recordedBridgeProcessLiveness(
                pidFile: pidFile,
                signalProbe: { _ in signal },
                kernelCommandLine: { _ in kernel },
                psCommandLine: { _ in ps }
            )
        }

        XCTAssertEqual(probe(signal: 0, kernel: bridge).result, .alive)
        XCTAssertEqual(probe(signal: EPERM, kernel: bridge).result, .alive)
        XCTAssertEqual(probe(signal: ESRCH, kernel: nil), .init(result: .dead, failedProbes: ["pid_signal"]))
        XCTAssertEqual(probe(signal: 0, kernel: "/usr/bin/vim"), .init(result: .dead, failedProbes: ["pid_signal"]))
        XCTAssertEqual(probe(signal: EAGAIN, kernel: bridge), .init(result: .unknown, failedProbes: ["pid_signal"]))
        XCTAssertEqual(probe(signal: 0, kernel: nil, ps: .found(bridge)).result, .alive)
        XCTAssertEqual(probe(signal: 0, kernel: nil, ps: .missing), .init(result: .dead, failedProbes: ["ps"]))
        XCTAssertEqual(probe(signal: 0, kernel: nil, ps: .unavailable), .init(result: .unknown, failedProbes: ["ps"]),
                       "a ps that cannot spawn is not a dead bridge")
        try FileManager.default.removeItem(atPath: pidFile)
        XCTAssertEqual(probe(signal: 0, kernel: bridge).result, .dead, "no pid file")
    }

    func testDaemonLivenessUsesPgrepOnlyWhenThePidCheckIsInconclusive() {
        var pgrepRuns = 0
        func probe(
            socket: Bool,
            recorded: ProcessManager.BridgeLivenessReport,
            pgrep: ProcessManager.BridgeProbeResult
        ) -> ProcessManager.BridgeLivenessReport {
            ProcessManager.bridgeDaemonLiveness(
                socketExists: { socket },
                recordedProcess: { recorded },
                pgrep: { pgrepRuns += 1; return pgrep }
            )
        }
        let deadPid = ProcessManager.BridgeLivenessReport(result: .dead, failedProbes: ["pid_signal"])

        XCTAssertEqual(probe(socket: false, recorded: .init(result: .alive), pgrep: .alive),
                       .init(result: .dead, failedProbes: ["socket_missing"]))
        XCTAssertEqual(probe(socket: true, recorded: .init(result: .alive), pgrep: .dead).result, .alive)
        XCTAssertEqual(pgrepRuns, 0, "a verified pid never spawns pgrep")
        XCTAssertEqual(probe(socket: true, recorded: deadPid, pgrep: .alive).result, .alive)
        XCTAssertEqual(probe(socket: true, recorded: deadPid, pgrep: .dead),
                       .init(result: .dead, failedProbes: ["pid_signal", "pgrep"]))
        XCTAssertEqual(probe(socket: true, recorded: deadPid, pgrep: .unknown),
                       .init(result: .unknown, failedProbes: ["pid_signal", "pgrep"]))
    }

    func testKernelProcessArgumentsReadsThisProcessWithoutSpawning() throws {
        let arguments = try XCTUnwrap(ProcessManager.kernelProcessArguments(of: getpid()))
        let executable = try XCTUnwrap(CommandLine.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertTrue(arguments.contains(executable), arguments)
        XCTAssertNil(ProcessManager.kernelProcessArguments(of: 999_999))
    }

    func testRecordedBridgeProcessAliveRequiresAVerifiedBridgePid() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr447-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("voice_bridge.pid").path
        try "4242\n".write(toFile: pidFile, atomically: true, encoding: .utf8)

        XCTAssertTrue(ProcessManager.recordedBridgeProcessAlive(
            pidFile: pidFile, commandLine: { _ in "python3 /app/services/voice_bridge.py --relay" }))
        XCTAssertFalse(ProcessManager.recordedBridgeProcessAlive(
            pidFile: pidFile, commandLine: { _ in "/usr/bin/vim notes.txt" }), "recycled pid")
        XCTAssertFalse(ProcessManager.recordedBridgeProcessAlive(
            pidFile: pidFile, commandLine: { _ in nil }), "dead pid")
        try FileManager.default.removeItem(atPath: pidFile)
        XCTAssertFalse(ProcessManager.recordedBridgeProcessAlive(
            pidFile: pidFile, commandLine: { _ in "voice_bridge.py" }), "no pid file")
    }

    func testRecoveryNeverOverwritesTheLiveSharedAuthorizationLedger() {
        let script = script(provider: "codex", spool: "/tmp/relay-sessions/a")
        XCTAssertTrue(script.contains(
            "[ ! -f /tmp/voice_command_authorizations.json ] && cp \"$REPLAY_DIR/voice_command_authorizations.json\""))
    }

    func testTerminateRecordedBridgeSignalsOnlyAVerifiedBridgePid() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr403-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appendingPathComponent("voice_bridge.pid").path

        func run(pid: String?, command: String?) -> [pid_t] {
            if let pid { try? "\(pid)\n".write(toFile: pidFile, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(atPath: pidFile) }
            var signalled: [pid_t] = []
            ProcessManager.terminateRecordedBridge(
                pidFile: pidFile, commandLine: { _ in command }, signal: { signalled.append($0) })
            return signalled
        }

        XCTAssertEqual(run(pid: "4242", command: "python3 /app/services/voice_bridge.py --relay"), [4242])
        XCTAssertEqual(run(pid: "4242", command: "/usr/bin/vim notes.txt"), [], "recycled pid")
        XCTAssertEqual(run(pid: "4242", command: nil), [], "dead pid")
        XCTAssertEqual(run(pid: nil, command: "voice_bridge.py"), [], "no pid file")
        XCTAssertEqual(run(pid: "1", command: "voice_bridge.py"), [], "never pid 1")
        XCTAssertEqual(run(pid: "not-a-pid", command: "voice_bridge.py"), [])
    }
}
