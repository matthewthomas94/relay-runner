import XCTest
@testable import relay_runner

final class BridgeConsumerLivenessTests: XCTestCase {

    func testMissingHeartbeatHasBoundedGrace() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)

        try writeFile(fixture.socket, modifiedAt: now.addingTimeInterval(-5))
        XCTAssertTrue(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))

        try writeFile(fixture.socket, modifiedAt: now.addingTimeInterval(-31))
        XCTAssertFalse(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))
    }

    func testStaleHeartbeatMarksConsumerDead() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        try writeFile(fixture.socket, modifiedAt: now)
        try writeFile(fixture.heartbeat, modifiedAt: now.addingTimeInterval(-31))

        XCTAssertFalse(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))
    }

    func testPendingVoiceCommandMarksConsumerDead() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        try writeFile(fixture.socket, modifiedAt: now)
        try writeFile(fixture.heartbeat, modifiedAt: now)
        try writeFile(fixture.command, modifiedAt: now.addingTimeInterval(-11))

        XCTAssertFalse(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))
    }

    func testCurrentPendingVoiceCommandWithMetadataMarksConsumerDead() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let metadata: [String: Any] = [
            "relay_command_seq": 7,
            "relay_command_id": "cmd-7",
        ]
        try writeFile(fixture.socket, modifiedAt: now)
        try writeFile(fixture.heartbeat, modifiedAt: now)
        try writeFile(fixture.command, modifiedAt: now.addingTimeInterval(-11))
        try writeJSON(metadata, to: fixture.meta)
        try writeJSON(metadata, to: fixture.state)

        XCTAssertFalse(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            voiceCommandMetaPath: fixture.meta.path,
            voiceCommandStatePath: fixture.state.path,
            voiceCommandClaimedPath: fixture.claimed.path,
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))
    }

    func testCurrentPendingVoiceCommandWaitsWhileProviderTurnIsActive() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let metadata: [String: Any] = [
            "relay_command_seq": 10,
            "relay_command_id": "cmd-10",
        ]
        try writeFile(fixture.socket, modifiedAt: now)
        try writeFile(fixture.heartbeat, modifiedAt: now)
        try writeFile(
            fixture.command,
            modifiedAt: now.addingTimeInterval(-(ProcessManager.pendingVoiceCommandTimeout + 5))
        )
        try writeJSON(metadata, to: fixture.meta)
        try writeJSON(metadata, to: fixture.state)
        try writeJSON([
            "version": 1,
            "records": [[
                "relay_command_seq": 9,
                "relay_command_id": "cmd-9",
                "state": "active",
                "provider_session_id": "other-session",
            ]],
        ], to: fixture.providerTurns)

        XCTAssertTrue(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            voiceCommandMetaPath: fixture.meta.path,
            voiceCommandStatePath: fixture.state.path,
            voiceCommandClaimedPath: fixture.claimed.path,
            voiceProviderTurnsPath: fixture.providerTurns.path,
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))

        XCTAssertEqual(
            ProcessManager.pendingVoiceCommandDeliveryState(
                commandURL: fixture.command,
                metaURL: fixture.meta,
                stateURL: fixture.state,
                claimedURL: fixture.claimed,
                now: now,
                providerTurnsURL: fixture.providerTurns
            ),
            .waiting
        )

        XCTAssertEqual(
            ProcessManager.pendingVoiceCommandDeliveryState(
                commandURL: fixture.command,
                metaURL: fixture.meta,
                stateURL: fixture.state,
                claimedURL: fixture.claimed,
                now: now,
                providerTurnsURL: fixture.providerTurns,
                providerSessionID: "current-session"
            ),
            .timedOut
        )
        XCTAssertFalse(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            voiceCommandMetaPath: fixture.meta.path,
            voiceCommandStatePath: fixture.state.path,
            voiceCommandClaimedPath: fixture.claimed.path,
            voiceProviderTurnsPath: fixture.providerTurns.path,
            voiceProviderSessionID: "current-session",
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))
    }

    func testClaimedPendingVoiceCommandDoesNotMarkConsumerDead() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let metadata: [String: Any] = [
            "relay_command_seq": 8,
            "relay_command_id": "cmd-8",
        ]
        try writeFile(fixture.socket, modifiedAt: now)
        try writeFile(fixture.heartbeat, modifiedAt: now)
        try writeFile(fixture.command, modifiedAt: now.addingTimeInterval(-30))
        try writeJSON(metadata, to: fixture.meta)
        try writeJSON(metadata, to: fixture.state)
        try writeJSON(metadata, to: fixture.claimed)

        XCTAssertTrue(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            voiceCommandMetaPath: fixture.meta.path,
            voiceCommandStatePath: fixture.state.path,
            voiceCommandClaimedPath: fixture.claimed.path,
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))
    }

    func testSupersededPendingVoiceCommandDoesNotMarkConsumerDead() throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        try writeFile(fixture.socket, modifiedAt: now)
        try writeFile(fixture.heartbeat, modifiedAt: now)
        try writeFile(fixture.command, modifiedAt: now.addingTimeInterval(-30))
        try writeJSON(["relay_command_seq": 9, "relay_command_id": "old"], to: fixture.meta)
        try writeJSON(["relay_command_seq": 10, "relay_command_id": "new"], to: fixture.state)

        XCTAssertTrue(ProcessManager.relayConsumerAlive(
            voiceCommandPath: fixture.command.path,
            voiceCommandMetaPath: fixture.meta.path,
            voiceCommandStatePath: fixture.state.path,
            voiceCommandClaimedPath: fixture.claimed.path,
            heartbeatPath: fixture.heartbeat.path,
            sessionMarkerPaths: [fixture.socket.path],
            now: now
        ))
    }

    func testRelaySessionSurvivesCompletedCodexTurnWithBridgeContext() {
        XCTAssertTrue(ProcessManager.relaySessionAlive(
            daemonAlive: true,
            consumerAlive: false,
            hasSessionContext: true
        ))

        XCTAssertFalse(ProcessManager.relaySessionAlive(
            daemonAlive: true,
            consumerAlive: false,
            hasSessionContext: false
        ))

        XCTAssertFalse(ProcessManager.relaySessionAlive(
            daemonAlive: false,
            consumerAlive: true,
            hasSessionContext: true
        ))
    }

    private func makeFixture() throws -> (
        root: URL,
        socket: URL,
        command: URL,
        meta: URL,
        state: URL,
        claimed: URL,
        providerTurns: URL,
        heartbeat: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayRunnerBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (
            root: root,
            socket: root.appendingPathComponent("voice_bridge.sock"),
            command: root.appendingPathComponent("voice_cmd_ready"),
            meta: root.appendingPathComponent("voice_cmd_ready.meta"),
            state: root.appendingPathComponent("voice_command_state.json"),
            claimed: root.appendingPathComponent("voice_cmd_claimed.json"),
            providerTurns: root.appendingPathComponent("voice_provider_turns.json"),
            heartbeat: root.appendingPathComponent("voice_bridge_heartbeat")
        )
    }

    private func writeFile(_ url: URL, modifiedAt date: Date) throws {
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func writeJSON(_ payload: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url)
    }
}
