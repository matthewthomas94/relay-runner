import XCTest
@testable import relay_runner

/// RR-401: background-session replies are badged, then read out on request.
final class VoiceReplyBadgeTests: XCTestCase {
    @MainActor
    func testPlaybackSnapshotSurvivesRecordingAndDoesNotReplaceTheNotchState() {
        let state = StateMachine()
        state.updateSTT(isRecording: true, partial: "")
        state.handleServiceEvent(source: "bridge", newState: "session_playback",
                                 text: #"{"a":"play","b":"stop","c":"replay"}"#)
        XCTAssertEqual(state.state, .recording)
        XCTAssertEqual(state.sessionPlayback, ["a": .play, "b": .stop, "c": .replay])
        state.updateSTT(isRecording: false, partial: "")
        XCTAssertEqual(state.sessionPlayback["a"], .play)
        state.handleServiceEvent(source: "bridge", newState: "session_playback", text: "{}")
        XCTAssertTrue(state.sessionPlayback.isEmpty)
    }

    func testBadgeCountsUnheardRepliesAndOutcomesFromTheBridgeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let spool = VoiceSessionSpool(key: "a", rootDirectory: root)
        try spool.prepare()
        XCTAssertEqual(spool.replyBadge, "\(root)/a/voice_reply_badge.json")
        XCTAssertEqual(VoiceReplyBadge.load(path: spool.replyBadge).count, 0)

        let badge = #"{"outcome_count": 2, "replies": [{"text": "A finished."}], "unread_count": 1}"#
        try badge.write(toFile: spool.replyBadge, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            VoiceReplyBadge.load(path: spool.replyBadge),
            VoiceReplyBadge(unreadCount: 1, outcomeCount: 2)
        )
        XCTAssertEqual(VoiceReplyBadge.load(path: spool.replyBadge).count, 3)
    }
}
