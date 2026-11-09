import XCTest
@testable import relay_runner

/// RR-468: watchdog recovery never races a session start, never launches a
/// legacy /tmp bridge for an app-owned session, and leaves one bridge.
final class BridgeRecoverySessionStartTests: XCTestCase {
    private func script(provider: String, spool: String?, appOwned: Bool) -> String {
        ProcessManager.bridgeRecoveryScript(
            relayBridge: "/usr/local/bin/relay-bridge",
            context: .init(
                workingDirectory: "/Users/example/dev",
                provider: provider,
                spoolDirectory: spool,
                appOwnedSession: appOwned
            )
        )
    }

    private func runBash(_ script: String, environment: [String: String] = [:]) throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        proc.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    private func temporaryDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("rr468-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The generated script up to its first mutation, logging into `log`.
    private func preamble(_ script: String, log: String) throws -> String {
        let lines = script.components(separatedBy: "\n")
        let firstMutation = try XCTUnwrap(lines.firstIndex { $0.contains("REPLAY_DIR=$(mktemp") })
        return lines[..<firstMutation].joined(separator: "\n")
            .replacingOccurrences(of: "VOICE_BRIDGE_LOG=/tmp/voice_bridge.log", with: "VOICE_BRIDGE_LOG=\(log)")
            + "\nexit 0\n"
    }

    func testAppOwnedRecoveryLaunchCarriesTheSessionSpoolAndProviderSessionID() throws {
        for provider in ["codex", "claude"] {
            let text = script(provider: provider, spool: "/tmp/relay-sessions/a", appOwned: true)
            XCTAssertTrue(text.contains("RELAY_APP_OWNED_SESSION=1"))
            XCTAssertTrue(text.contains("RELAY_SESSION_SPOOL_DIR='/tmp/relay-sessions/a'"))
            XCTAssertTrue(text.contains("RELAY_PROVIDER_SESSION_ID=$(cat \"$SPOOL\"/voice_provider_session_id"))
            let launches = text.components(separatedBy: "\n").filter {
                $0.contains("launchctl submit") || $0.contains("nohup /bin/bash")
            }
            XCTAssertEqual(launches.count, 2)
            for launch in launches {
                // $5 is the provider session id and ${11} the spool dir.
                XCTAssertTrue(launch.contains(
                    "\"$VOICE_BRIDGE_LOG\" \"$RELAY_PROVIDER_SESSION_ID\" \"$RELAY_RECOVERY_GENERATION\""))
                XCTAssertTrue(launch.contains("\"$RELAY_PRESERVE_CONTEXT_AUTHORIZATION\" \"$RELAY_SESSION_SPOOL_DIR\""))
            }

            let lines = text.components(separatedBy: "\n")
            let guardLine = try XCTUnwrap(lines.firstIndex { $0.contains("[ \"$RELAY_APP_OWNED_SESSION\" = \"1\" ]") })
            for mutation in ["REPLAY_DIR=$(mktemp", "launchctl remove", "kill ", "rm -f ", "launchctl submit"] {
                let index = try XCTUnwrap(lines.firstIndex { $0.contains(mutation) }, mutation)
                XCTAssertLessThan(guardLine, index, "the guard refuses before \(mutation)")
            }
        }
        XCTAssertTrue(script(provider: "codex", spool: nil, appOwned: false).contains("RELAY_APP_OWNED_SESSION=0"))
    }

    func testAppOwnedRecoveryWithAnEmptyContextAbortsInsteadOfLaunchingLegacy() throws {
        let dir = try temporaryDirectory()
        let log = dir.appendingPathComponent("voice_bridge.log").path
        let spool = dir.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)

        // No spool dir: the session id would come from legacy /tmp.
        let empty = try preamble(script(provider: "claude", spool: nil, appOwned: true), log: log)
        XCTAssertEqual(try runBash(empty), 1)
        XCTAssertTrue(try String(contentsOfFile: log, encoding: .utf8).contains("recovery refused"))

        // A spool without the provider session id is refused too.
        let noSession = try preamble(script(provider: "codex", spool: spool.path, appOwned: true), log: log)
        XCTAssertEqual(try runBash(noSession), 1)

        try "session-123\n".write(to: spool.appendingPathComponent("voice_provider_session_id"),
                                  atomically: true, encoding: .utf8)
        XCTAssertEqual(try runBash(noSession), 0, "spool and session id present")

        // A manual /tmp session keeps its legacy recovery.
        let manual = try preamble(script(provider: "claude", spool: nil, appOwned: false), log: log)
        XCTAssertEqual(try runBash(manual), 0)
    }

    func testRecoveryStopsOlderBridgesButNotTheRecordedOneOrOtherProcesses() throws {
        let dir = try temporaryDirectory()
        let bridgeScript = dir.appendingPathComponent("voice_bridge.py")
        let otherScript = dir.appendingPathComponent("other_worker.pl")
        for url in [bridgeScript, otherScript] {
            try "sleep 30;\n".write(to: url, atomically: true, encoding: .utf8)
        }
        func spawn(_ url: URL) throws -> Process {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            proc.arguments = [url.path]
            try proc.run()
            addTeardownBlock { if proc.isRunning { proc.terminate() } }
            return proc
        }
        let olderGeneration = try spawn(bridgeScript)
        let olderBuild = try spawn(bridgeScript)
        let recorded = try spawn(bridgeScript)
        let unrelated = try spawn(otherScript)
        let pids = [olderGeneration, olderBuild, recorded, unrelated].map { String($0.processIdentifier) }
        let log = dir.appendingPathComponent("voice_bridge.log").path

        let stop = ProcessManager.strayBridgeStopScript(listing: "ps -p \(pids.joined(separator: ",")) -o pid=,command=")
        XCTAssertEqual(try runBash(stop, environment: [
            "BRIDGE_PID": String(recorded.processIdentifier),
            "VOICE_BRIDGE_LOG": log,
        ]), 0)

        for proc in [olderGeneration, olderBuild] {
            let deadline = Date().addingTimeInterval(5)
            while proc.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            XCTAssertFalse(proc.isRunning, "a stray bridge is stopped")
        }
        XCTAssertTrue(recorded.isRunning, "the recorded bridge is stopped by its PID step")
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertTrue(try String(contentsOfFile: log, encoding: .utf8)
            .contains("stopping stray voice bridge pid=\(olderGeneration.processIdentifier)"))
    }

    func testStrayStopListsOnlyThisUsersProcessesAndNeverMatchesTheRecoveryScript() {
        let stop = ProcessManager.strayBridgeStopScript()
        XCTAssertTrue(stop.contains("ps -U \"$(id -u)\" -o pid=,command="))
        for provider in ["codex", "claude"] {
            let text = script(provider: provider, spool: "/tmp/relay-sessions/a", appOwned: true)
            XCTAssertTrue(text.contains(stop))
            XCTAssertFalse(text.contains("pkill"))
            XCTAssertFalse(text.contains("voice_bridge.py"), "the script and its subshells must not match the stray pattern")
            let lines = text.components(separatedBy: "\n")
            let recordedKill = lines.firstIndex { $0.contains("kill \"$BRIDGE_PID\"") } ?? Int.max
            let strayKill = lines.firstIndex { $0.contains("kill \"$stray_pid\"") } ?? -1
            let launch = lines.firstIndex { $0.contains("launchctl submit") } ?? -1
            XCTAssertLessThan(recordedKill, strayKill)
            XCTAssertLessThan(strayKill, launch, "strays stop before the new bridge launches")
        }
    }

    func testRecoveryWaitsWhileASessionStartStillOwnsTheBridgeLaunch() {
        func deferred(pending: Bool = false, menu: Bool = true, seen: Bool = false, elapsed: TimeInterval) -> Bool {
            AppState.bridgeRecoveryDeferredForSessionStart(
                sessionLaunchPending: pending,
                menuSessionActive: menu,
                sessionBridgeSeen: seen,
                elapsedSinceSessionStart: elapsed
            )
        }
        XCTAssertTrue(deferred(pending: true, menu: false, elapsed: 1_000), "launch still preparing")
        XCTAssertTrue(deferred(elapsed: 7), "bridge not yet ready")
        XCTAssertTrue(deferred(elapsed: AppState.sessionBridgeLaunchGrace))
        XCTAssertFalse(deferred(elapsed: AppState.sessionBridgeLaunchGrace + 1), "launch grace elapsed")
        XCTAssertFalse(deferred(seen: true, elapsed: 7), "session bridge already seen")
        XCTAssertFalse(deferred(menu: false, elapsed: 7), "no session start in progress")

        // The watchdog's own launch wait uses the same grace.
        XCTAssertEqual(AppState.bridgeWatchdogAction(
            menuSessionActive: true, daemonAlive: false, consumerAlive: false, wasAlive: false,
            sessionBridgeSeen: false, elapsedSinceSessionStart: AppState.sessionBridgeLaunchGrace
        ), .waitForLaunch)
    }
}
