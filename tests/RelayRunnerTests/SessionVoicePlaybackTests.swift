import XCTest
@testable import relay_runner

/// RR-401: the bridge publishes each session's playback control state.
final class SessionVoicePlaybackTests: XCTestCase {
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

    /// RR-488: the bridge no longer keeps a reply badge file in the spool.
    func testSpoolHasNoReplyBadgeFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let spool = VoiceSessionSpool(key: "a", rootDirectory: root)
        try spool.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(root)/a/voice_reply_badge.json"))
    }
}
