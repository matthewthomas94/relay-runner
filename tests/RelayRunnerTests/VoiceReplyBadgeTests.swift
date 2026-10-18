import XCTest
@testable import relay_runner

/// RR-401: background-session replies are badged, then read out on request.
final class VoiceReplyBadgeTests: XCTestCase {
    func testSessionPlaybackUsesLiveQueueBeforeSavedReplayAndIgnoresOutcomeBadges() {
        XCTAssertEqual(SessionVoicePlayback.resolve(live: .play, unreadCount: 0, hasStoredReply: false), .play)
        XCTAssertEqual(SessionVoicePlayback.resolve(live: .stop, unreadCount: 2, hasStoredReply: true), .stop)
        XCTAssertEqual(SessionVoicePlayback.resolve(live: .replay, unreadCount: 1, hasStoredReply: true), .play)
        XCTAssertEqual(SessionVoicePlayback.resolve(live: .replay, unreadCount: 0, hasStoredReply: false), .replay)
        XCTAssertEqual(SessionVoicePlayback.resolve(live: nil, unreadCount: 0, hasStoredReply: true), .replay)
        XCTAssertNil(SessionVoicePlayback.resolve(live: nil, unreadCount: 0, hasStoredReply: false))
    }

    func testPlaybackControlsCarrySessionAndExplicitAction() throws {
        for action in [SessionVoicePlayback.play, .replay, .stop] {
            let message = try XCTUnwrap(AppState.sessionPlaybackMessage(sessionKey: "context-a", action: action))
            XCTAssertTrue(message.hasPrefix("__SESSION_PLAYBACK__:"))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(message.dropFirst("__SESSION_PLAYBACK__:".count).utf8)) as? [String: String])
            XCTAssertEqual(payload, ["session_key": "context-a", "action": action.rawValue])
        }
    }

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

    func testReadOutSendsAReplayControlForTheSession() throws {
        let message = try XCTUnwrap(AppState.voiceReplayMessage(sessionKey: "context-a"))
        XCTAssertTrue(message.hasPrefix("__REPLAY__:"))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.dropFirst("__REPLAY__:".count).utf8)) as? [String: String]
        )
        XCTAssertEqual(payload, ["session_key": "context-a"])
    }

    func testWheelPlaybackAvailabilityRequiresALatestStoredMessage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(VoiceReplyBadge.hasStoredReply(path: url.path))
        for text in ["invalid", "{}", #"{"replies":[]}"#, #"{"replies":[{"text":"Old"},{"text":" "}]}"#] {
            try text.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertFalse(VoiceReplyBadge.hasStoredReply(path: url.path))
        }
        try #"{"unread_count":0,"replies":[{"text":"Ready to replay"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(VoiceReplyBadge.hasStoredReply(path: url.path))
    }
}
