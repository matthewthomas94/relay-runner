import XCTest
@testable import relay_runner

final class BridgeRecoveryTests: XCTestCase {

    func testWatchdogKeepsActiveDaemonWhenConsumerHeartbeatStales() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: true,
                daemonAlive: true,
                consumerAlive: false,
                wasAlive: true,
                sessionBridgeSeen: true,
                elapsedSinceSessionStart: 120
            ),
            .keepDaemon
        )
    }

    func testWatchdogRecoversMenuStartedDaemonAfterItWasSeen() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: true,
                daemonAlive: false,
                consumerAlive: false,
                wasAlive: true,
                sessionBridgeSeen: true,
                elapsedSinceSessionStart: 120
            ),
            .recoverDaemon
        )
    }

    func testWatchdogWaitsDuringInitialMenuLaunchGrace() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: true,
                daemonAlive: false,
                consumerAlive: false,
                wasAlive: false,
                sessionBridgeSeen: false,
                elapsedSinceSessionStart: 10
            ),
            .waitForLaunch
        )
    }

    func testWatchdogMarksExternalDaemonDeadWithoutRecovery() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: false,
                daemonAlive: false,
                consumerAlive: false,
                wasAlive: true,
                sessionBridgeSeen: false,
                elapsedSinceSessionStart: 0
            ),
            .markDead
        )
    }

    func testWatchdogKeepsObservedExternalDaemonWhenConsumerHeartbeatStales() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: false,
                daemonAlive: true,
                consumerAlive: false,
                wasAlive: true,
                sessionBridgeSeen: false,
                elapsedSinceSessionStart: 0
            ),
            .keepDaemon
        )
    }

    func testWatchdogSuppressesRecoveryDuringSparkleRelaunch() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: false,
                daemonAlive: false,
                consumerAlive: false,
                wasAlive: true,
                sessionBridgeSeen: false,
                elapsedSinceSessionStart: 0,
                recoverySuppressed: true
            ),
            .markDead
        )
    }

    func testWatchdogReapsDaemonWhenSessionStopWasRequested() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: true,
                daemonAlive: true,
                consumerAlive: true,
                wasAlive: true,
                sessionBridgeSeen: true,
                elapsedSinceSessionStart: 120,
                stopRequested: true
            ),
            .reapOrphan
        )

        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: true,
                daemonAlive: false,
                consumerAlive: false,
                wasAlive: true,
                sessionBridgeSeen: true,
                elapsedSinceSessionStart: 120,
                stopRequested: true
            ),
            .markDead
        )
    }

    func testWatchdogStillReapsPreexistingOrphanDaemon() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: false,
                daemonAlive: true,
                consumerAlive: false,
                wasAlive: false,
                sessionBridgeSeen: false,
                elapsedSinceSessionStart: 0
            ),
            .reapOrphan
        )
    }

    func testRecoveryContextReadsBridgeMetadata() throws {
        let root = try makeFixture()
        let cwdFile = root.appendingPathComponent("voice_bridge.cwd")
        let providerFile = root.appendingPathComponent("voice_bridge.provider")
        try Data("/Users/example/dev repo\n".utf8).write(to: cwdFile)
        try Data("Claude\n".utf8).write(to: providerFile)

        let context = try XCTUnwrap(ProcessManager.bridgeRecoveryContext(
            cwdFile: cwdFile,
            providerFile: providerFile
        ))

        XCTAssertEqual(context.workingDirectory, "/Users/example/dev repo")
        XCTAssertEqual(context.provider, "claude")
    }

    func testRecoveryContextAllowsManualBridgeWithoutProviderMetadata() throws {
        let root = try makeFixture()
        let cwdFile = root.appendingPathComponent("voice_bridge.cwd")
        try Data("/Users/example/manual\n".utf8).write(to: cwdFile)

        let context = try XCTUnwrap(ProcessManager.bridgeRecoveryContext(
            cwdFile: cwdFile,
            providerFile: root.appendingPathComponent("voice_bridge.provider")
        ))

        XCTAssertEqual(context.workingDirectory, "/Users/example/manual")
        XCTAssertNil(context.provider)
    }

    func testRecoveryScriptPreservesWorkspaceAndProviderForCodexAndClaude() {
        for provider in ["codex", "claude"] {
            let script = ProcessManager.bridgeRecoveryScript(
                relayBridge: "/Applications/Relay Runner.app/Contents/SharedSupport/scripts/relay-bridge",
                context: .init(workingDirectory: "/Users/example/dev repo", provider: provider)
            )

            XCTAssertTrue(script.contains("RELAY_CWD='/Users/example/dev repo'"))
            XCTAssertTrue(script.contains("RELAY_PROVIDER='\(provider)'"))
            XCTAssertTrue(script.contains("export RELAY_RUNNER_PROVIDER=\"$3\""))
            XCTAssertTrue(script.contains("exec \"$2\" --relay"))
            XCTAssertTrue(script.contains("[ -f /tmp/voice_bridge_stop_requested ] && exit 1"))
            XCTAssertTrue(script.contains("/tmp/voice_cmd_ready.meta"))
            XCTAssertTrue(script.contains("/tmp/voice_command_state.json"))
            XCTAssertTrue(script.contains("/tmp/voice_cmd_claimed.json"))
            XCTAssertTrue(script.contains("RELAY_RUNNER_PROVIDER=\"$RELAY_PROVIDER\" nohup \"$RELAY_BRIDGE\" --relay"))
        }
    }

    func testRecoveryScriptHandlesManualBridgeWithoutProvider() {
        let script = ProcessManager.bridgeRecoveryScript(
            relayBridge: "/usr/local/bin/relay-bridge",
            context: .init(workingDirectory: "/Users/example/manual", provider: nil)
        )

        XCTAssertTrue(script.contains("RELAY_PROVIDER=''"))
        XCTAssertTrue(script.contains("unset RELAY_RUNNER_PROVIDER"))
        XCTAssertTrue(script.contains("env -u RELAY_RUNNER_PROVIDER nohup \"$RELAY_BRIDGE\" --relay"))
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayRunnerBridgeRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
