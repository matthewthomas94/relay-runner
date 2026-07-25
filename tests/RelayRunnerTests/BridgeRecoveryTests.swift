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

    func testWatchdogKeepsContextBackedDaemonWhenCodexTaskCompletes() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: false,
                daemonAlive: true,
                consumerAlive: false,
                hasSessionContext: true,
                wasAlive: false,
                sessionBridgeSeen: false,
                elapsedSinceSessionStart: 0
            ),
            .keepDaemon
        )
    }

    func testWatchdogRecoversContextBackedBridgeAfterForegroundTurnCompletes() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: false,
                daemonAlive: false,
                consumerAlive: false,
                hasSessionContext: true,
                wasAlive: true,
                sessionBridgeSeen: false,
                elapsedSinceSessionStart: 0
            ),
            .recoverDaemon
        )
    }

    func testWatchdogWaitsForConsumerWhenLiveDaemonHasTimedOutPendingVoiceCommand() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: false,
                daemonAlive: true,
                consumerAlive: false,
                hasSessionContext: true,
                wasAlive: true,
                sessionBridgeSeen: false,
                elapsedSinceSessionStart: 0,
                pendingDeliveryTimedOut: true
            ),
            .waitForConsumer
        )
    }

    func testWatchdogSurfacesQueuedCommandWhenConsumerIsHealthy() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: true,
                daemonAlive: true,
                consumerAlive: true,
                wasAlive: true,
                sessionBridgeSeen: true,
                elapsedSinceSessionStart: 120,
                pendingDeliveryState: .waiting
            ),
            .voiceCommandQueued
        )
    }

    func testVoiceCommandQueuedPresentationUsesPassiveReplacementCopy() {
        let presentation = AppState.voiceCommandQueuedPresentation

        XCTAssertEqual(presentation.statusText, "Voice command queued")
        XCTAssertEqual(presentation.title, "Voice command queued")
        XCTAssertTrue(presentation.body.contains("Speak again to replace"))
        XCTAssertFalse(presentation.body.contains("listener"))
        XCTAssertFalse(presentation.body.contains("new session"))
    }

    func testRecordingStartAllowsQueuedVoiceCommandWhenConsumerIsHealthy() {
        XCTAssertEqual(
            AppState.recordingStartBridgeAction(
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: true,
                hasSessionContext: true,
                pendingDeliveryState: .waiting
            ),
            .allowRecording
        )
    }

    func testRecordingStartBlocksWhenVoiceCommandDeliveryTimedOut() {
        XCTAssertEqual(
            AppState.recordingStartBridgeAction(
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: true,
                hasSessionContext: true,
                pendingDeliveryState: .timedOut
            ),
            .waitForPendingCommand
        )
    }

    func testRecordingStartRecoversMissingContextBackedBridge() {
        XCTAssertEqual(
            AppState.recordingStartBridgeAction(
                bridgeRecoveryInFlight: false,
                daemonAlive: false,
                consumerAlive: false,
                hasSessionContext: true,
                pendingDeliveryState: .none
            ),
            .recoverBridge
        )
    }

    func testRecordingStartPromptsWithoutSessionContext() {
        XCTAssertEqual(
            AppState.recordingStartBridgeAction(
                bridgeRecoveryInFlight: false,
                daemonAlive: false,
                consumerAlive: false,
                hasSessionContext: false,
                pendingDeliveryState: .none
            ),
            .promptForSession
        )
    }

    func testRecordingStartIgnoresClaimedOrStaleVoiceCommandState() {
        for state in [
            ProcessManager.PendingVoiceCommandDeliveryState.claimed,
            ProcessManager.PendingVoiceCommandDeliveryState.stale,
        ] {
            XCTAssertEqual(
                AppState.recordingStartBridgeAction(
                    bridgeRecoveryInFlight: false,
                    daemonAlive: true,
                    consumerAlive: true,
                    hasSessionContext: true,
                    pendingDeliveryState: state
                ),
                .allowRecording
            )
        }
    }

    func testRecordingStartBlocksWhenDaemonHasNoLiveConsumer() {
        XCTAssertEqual(
            AppState.recordingStartBridgeAction(
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: false,
                hasSessionContext: true,
                pendingDeliveryState: .none
            ),
            .waitForConsumer
        )

        XCTAssertEqual(
            AppState.recordingStartBridgeAction(
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: false,
                hasSessionContext: true,
                pendingDeliveryState: .waiting
            ),
            .waitForConsumer
        )
    }

    func testRecordingStartAllowsHealthyBridge() {
        XCTAssertEqual(
            AppState.recordingStartBridgeAction(
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: true,
                hasSessionContext: true,
                pendingDeliveryState: .none
            ),
            .allowRecording
        )
    }

    func testSessionReadySurfacesOnlyForFirstHealthyMenuConsumerHeartbeat() {
        XCTAssertTrue(
            AppState.shouldSurfaceSessionReady(
                menuSessionActive: true,
                sessionBridgeSeen: false,
                sessionReadyShownForCurrentBridgeSession: false,
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: true
            )
        )

        XCTAssertFalse(
            AppState.shouldSurfaceSessionReady(
                menuSessionActive: true,
                sessionBridgeSeen: false,
                sessionReadyShownForCurrentBridgeSession: false,
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: false
            )
        )

        XCTAssertFalse(
            AppState.shouldSurfaceSessionReady(
                menuSessionActive: true,
                sessionBridgeSeen: true,
                sessionReadyShownForCurrentBridgeSession: false,
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: true
            )
        )

        XCTAssertFalse(
            AppState.shouldSurfaceSessionReady(
                menuSessionActive: true,
                sessionBridgeSeen: false,
                sessionReadyShownForCurrentBridgeSession: true,
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: true
            )
        )

        XCTAssertFalse(
            AppState.shouldSurfaceSessionReady(
                menuSessionActive: false,
                sessionBridgeSeen: false,
                sessionReadyShownForCurrentBridgeSession: false,
                bridgeRecoveryInFlight: false,
                daemonAlive: true,
                consumerAlive: true
            )
        )

        XCTAssertFalse(
            AppState.shouldSurfaceSessionReady(
                menuSessionActive: true,
                sessionBridgeSeen: false,
                sessionReadyShownForCurrentBridgeSession: false,
                bridgeRecoveryInFlight: true,
                daemonAlive: true,
                consumerAlive: true
            )
        )
    }

    func testWatchdogRecoversTimedOutPendingVoiceCommandWhenDaemonIsMissing() {
        XCTAssertEqual(
            AppState.bridgeWatchdogAction(
                menuSessionActive: true,
                daemonAlive: false,
                consumerAlive: false,
                wasAlive: true,
                sessionBridgeSeen: true,
                elapsedSinceSessionStart: 120,
                pendingDeliveryTimedOut: true
            ),
            .recoverDaemon
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
            XCTAssertTrue(script.contains("VOICE_BRIDGE_LOG_REASON=watchdog-recovery"))
            XCTAssertTrue(script.contains("\"$2\" --relay >> \"$4\""))
            XCTAssertTrue(script.contains("launchctl bridge process exited status=$status"))
            XCTAssertTrue(script.contains("launchctl produced socket provider=${RELAY_PROVIDER:-none}"))
            XCTAssertTrue(script.contains("launchctl print follows"))
            XCTAssertTrue(script.contains("direct bridge process exited status=$status"))
            XCTAssertTrue(script.contains("direct fallback produced socket provider=${RELAY_PROVIDER:-none}"))
            XCTAssertTrue(script.contains("mv /tmp/voice_cmd_ready \"$REPLAY_DIR/voice_cmd_ready\""))
            XCTAssertTrue(script.contains("restore_replayed_command"))
            XCTAssertTrue(script.contains("app watchdog replayed pending voice command after bridge recovery"))
            XCTAssertTrue(script.contains("[ -f /tmp/voice_bridge_stop_requested ] && exit 1"))
            XCTAssertTrue(script.contains("/tmp/voice_cmd_ready.meta"))
            XCTAssertTrue(script.contains("/tmp/voice_command_state.json"))
            XCTAssertTrue(script.contains("/tmp/voice_cmd_claimed.json"))
            XCTAssertTrue(script.contains("nohup /bin/bash -lc"))
        }
    }

    func testRecoveryScriptHandlesManualBridgeWithoutProvider() {
        let script = ProcessManager.bridgeRecoveryScript(
            relayBridge: "/usr/local/bin/relay-bridge",
            context: .init(workingDirectory: "/Users/example/manual", provider: nil)
        )

        XCTAssertTrue(script.contains("RELAY_PROVIDER=''"))
        XCTAssertTrue(script.contains("unset RELAY_RUNNER_PROVIDER"))
        XCTAssertTrue(script.contains("provider=${3:-none}"))
    }

    func testPendingVoiceCommandTimesOutAfterDocumentedDeliveryTimeout() throws {
        let root = try makeFixture()
        let command = root.appendingPathComponent("voice_cmd_ready")
        let meta = root.appendingPathComponent("voice_cmd_ready.meta")
        let state = root.appendingPathComponent("voice_command_state.json")
        let claimed = root.appendingPathComponent("voice_cmd_claimed.json")
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let metadata: [String: Any] = [
            "relay_command_seq": 7,
            "relay_command_id": "cmd-7",
            "action": "create_ticket",
        ]

        try Data("dispatch RR-7".utf8).write(to: command)
        try setModified(command, to: now.addingTimeInterval(-(ProcessManager.pendingVoiceCommandTimeout + 1)))
        try writeJSON(metadata, to: meta)
        try writeJSON(metadata, to: state)

        XCTAssertEqual(
            ProcessManager.pendingVoiceCommandDeliveryState(
                commandURL: command,
                metaURL: meta,
                stateURL: state,
                claimedURL: claimed,
                now: now
            ),
            .timedOut
        )

        try setModified(command, to: now.addingTimeInterval(-(ProcessManager.pendingVoiceCommandTimeout - 1)))

        XCTAssertEqual(
            ProcessManager.pendingVoiceCommandDeliveryState(
                commandURL: command,
                metaURL: meta,
                stateURL: state,
                claimedURL: claimed,
                now: now
            ),
            .waiting
        )
    }

    func testPendingVoiceCommandSuppressesStaleReplayWhenSuperseded() throws {
        let root = try makeFixture()
        let command = root.appendingPathComponent("voice_cmd_ready")
        let meta = root.appendingPathComponent("voice_cmd_ready.meta")
        let state = root.appendingPathComponent("voice_command_state.json")
        let claimed = root.appendingPathComponent("voice_cmd_claimed.json")
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        try Data("old command".utf8).write(to: command)
        try setModified(command, to: now.addingTimeInterval(-20))
        try writeJSON(["relay_command_seq": 1, "relay_command_id": "old"], to: meta)
        try writeJSON(["relay_command_seq": 2, "relay_command_id": "new"], to: state)

        XCTAssertEqual(
            ProcessManager.pendingVoiceCommandDeliveryState(
                commandURL: command,
                metaURL: meta,
                stateURL: state,
                claimedURL: claimed,
                now: now
            ),
            .stale
        )
    }

    func testPendingVoiceCommandSuppressesDuplicateReplayWhenAlreadyClaimed() throws {
        let root = try makeFixture()
        let command = root.appendingPathComponent("voice_cmd_ready")
        let meta = root.appendingPathComponent("voice_cmd_ready.meta")
        let state = root.appendingPathComponent("voice_command_state.json")
        let claimed = root.appendingPathComponent("voice_cmd_claimed.json")
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let metadata: [String: Any] = ["relay_command_seq": 3, "relay_command_id": "claimed"]

        try Data("claimed command".utf8).write(to: command)
        try setModified(command, to: now.addingTimeInterval(-20))
        try writeJSON(metadata, to: meta)
        try writeJSON(metadata, to: state)
        try writeJSON(metadata, to: claimed)

        XCTAssertEqual(
            ProcessManager.pendingVoiceCommandDeliveryState(
                commandURL: command,
                metaURL: meta,
                stateURL: state,
                claimedURL: claimed,
                now: now
            ),
            .claimed
        )
    }

    func testRecoveryScriptDocumentsStaleAndDuplicateReplaySuppression() {
        let script = ProcessManager.bridgeRecoveryScript(
            relayBridge: "/usr/local/bin/relay-bridge",
            context: .init(workingDirectory: "/Users/example/dev", provider: "codex")
        )

        XCTAssertTrue(script.contains("Relay command state was superseded"))
        XCTAssertTrue(script.contains("Relay command was already claimed"))
        XCTAssertTrue(script.contains("another voice command is already pending"))
    }

    func testRecoveryFailurePresentationSurfacesUndeliveredCommand() {
        let presentation = AppState.bridgeRecoveryFailurePresentation(reason: "voice-delivery-timeout")

        XCTAssertEqual(presentation.statusText, "Voice bridge recovery failed")
        XCTAssertEqual(presentation.title, "Voice command not delivered")
        XCTAssertTrue(presentation.body.contains("voice delivery timeout"))
        XCTAssertTrue(presentation.body.contains("Start a new session"))
    }

    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayRunnerBridgeRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeJSON(_ payload: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url)
    }

    private func setModified(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
