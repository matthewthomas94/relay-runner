import XCTest
@testable import relay_runner

/// A session wheel switch is reported on the notch, never by raising the terminal.
final class SessionSwitchNoticeTests: XCTestCase {
    func testNoticeClaimsOnlyTheSwitchThatHappened() {
        XCTAssertEqual(SessionSwitchNotice(switchingTo: "vial-qmk", focused: true, pending: false, recording: false),
                       .switched(to: "vial-qmk"))
        // The in-flight recording keeps the session it started with.
        XCTAssertEqual(SessionSwitchNotice(switchingTo: "vial-qmk", focused: true, pending: false, recording: true),
                       .nextRecording(to: "vial-qmk"))
        XCTAssertEqual(SessionSwitchNotice(switchingTo: "vial-qmk", focused: false, pending: true, recording: false),
                       .pending(to: "vial-qmk"))
        XCTAssertNil(SessionSwitchNotice(switchingTo: "vial-qmk", focused: false, pending: false, recording: false))
    }

    func testNoticeLabelsNameTheNewProject() {
        XCTAssertEqual(SessionSwitchNotice.switched(to: "vial-qmk").label, "Switched to · vial-qmk")
        XCTAssertEqual(SessionSwitchNotice.nextRecording(to: "vial-qmk").label, "Next recording · vial-qmk")
        XCTAssertEqual(SessionSwitchNotice.pending(to: "vial-qmk").label, "Switch pending · vial-qmk")
    }

    func testPlannerShowsTheNoticeThenReturnsToTheNormalLabelAndListeningNamesTheNewProject() {
        let notice = SessionSwitchNotice.switched(to: "vial-qmk")
        let shown = NotchVisualLabelAllowlist.presentation(for: .idle, switchNotice: notice)
        XCTAssertEqual(shown.labels, ["Switched to · vial-qmk"])
        XCTAssertEqual(shown.hoverLabel, "Switched to · vial-qmk")
        XCTAssertTrue(shown.pinsLabel)
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .idle, switchNotice: notice), ["Switched to · vial-qmk"])
        XCTAssertEqual(NotchActivityLabelPlanner.hoverLabel(for: .idle, switchNotice: notice), "Switched to · vial-qmk")

        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .idle), [])
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .recording, voiceTargetName: "vial-qmk"),
            ["Listening · vial-qmk"]
        )
    }

    func testNoticeShowsOverPlayingAndOverListening() {
        let notice = SessionSwitchNotice.switched(to: "vial-qmk")
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .speaking, playbackTargetName: "relay-runner", switchNotice: notice),
            ["Switched to · vial-qmk"]
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .speaking, playbackTargetName: "relay-runner"),
            ["Playing · relay-runner"]
        )
        let next = SessionSwitchNotice.nextRecording(to: "vial-qmk")
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .recording, voiceTargetName: "relay-runner", switchNotice: next),
            ["Next recording · vial-qmk"]
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.hoverLabel(for: .speaking, playbackTargetName: "relay-runner", switchNotice: notice),
            "Switched to · vial-qmk"
        )
    }

    func testRepeatedSwitchesReplaceTheNoticeWithoutStacking() {
        let first = NotchActivityLabelPlanner.labels(for: .idle, switchNotice: .switched(to: "vial-qmk"))
        let second = NotchActivityLabelPlanner.labels(for: .idle, switchNotice: .switched(to: "relay-runner"))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second, ["Switched to · relay-runner"])
    }

    func testStartingUpStillWinsOverTheNotice() {
        let presentation = NotchVisualLabelAllowlist.presentation(
            for: .idle,
            bridgeStartingUp: true,
            switchNotice: .switched(to: "vial-qmk")
        )
        XCTAssertEqual(presentation.labels, ["Starting up..."])
    }
}
