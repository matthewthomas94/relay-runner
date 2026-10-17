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
