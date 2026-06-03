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

    private func makeFixture() throws -> (root: URL, socket: URL, command: URL, heartbeat: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayRunnerBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (
            root: root,
            socket: root.appendingPathComponent("voice_bridge.sock"),
            command: root.appendingPathComponent("voice_cmd_ready"),
            heartbeat: root.appendingPathComponent("voice_bridge_heartbeat")
        )
    }

    private func writeFile(_ url: URL, modifiedAt date: Date) throws {
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
