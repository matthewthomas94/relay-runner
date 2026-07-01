import XCTest
@testable import relay_runner

final class StateMachineAcknowledgementTests: XCTestCase {
    func testAcknowledgementStateUsesNotchOnlyPresentation() {
        let state = OverlayState.acknowledgement(text: "Got it: add tests.", autoDismiss: 3.25)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: state), "Acknowledged")
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: state), ["Acknowledged"])
        XCTAssertNil(state.particleTheme)
    }

    func testAdjacentVoiceAndResponseStatesKeepBottomOverlayPresentation() {
        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.listening), "Listening")
        XCTAssertEqual(OverlayState.listening.particleTheme, .stt)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.processing), "Thinking")
        XCTAssertEqual(OverlayState.processing.particleTheme, .tts)

        let messageWaiting = OverlayState.messageWaiting(preview: "Done.")
        XCTAssertEqual(NotchActivityLabelPlanner.label(for: messageWaiting), "Response ready")
        XCTAssertEqual(messageWaiting.particleTheme, .tts)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.preparing), "Preparing speech")
        XCTAssertEqual(OverlayState.preparing.particleTheme, .tts)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.speaking), "Playing")
        XCTAssertEqual(OverlayState.speaking.particleTheme, .tts)
    }

    func testBridgeAcknowledgementDuringSentIsDeferredUntilAfterSentWindowPlusPause() {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let stateMachine = StateMachine(now: { now })

        stateMachine.updateSTT(isRecording: true, partial: "hello")
        stateMachine.updateSTT(isRecording: false, partial: "")
        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "Got it: add tests.",
            autoDismiss: 3.25
        )

        XCTAssertEqual(stateMachine.state, .sent)

        now = now.addingTimeInterval(StateMachine.sentAutoDismissDuration)
        stateMachine.dismissSent()
        stateMachine.promotePendingAcknowledgementIfReady()
        XCTAssertEqual(stateMachine.state, .idle)

        now = now.addingTimeInterval(StateMachine.acknowledgementDelayAfterSent - 0.01)
        stateMachine.promotePendingAcknowledgementIfReady()
        XCTAssertEqual(stateMachine.state, .idle)

        now = now.addingTimeInterval(0.01)
        stateMachine.promotePendingAcknowledgementIfReady()

        XCTAssertEqual(
            stateMachine.state,
            .acknowledgement(text: "Got it: add tests.", autoDismiss: 3.25)
        )
    }

    func testBridgeAcknowledgementUsesExplicitStateAndDismissesToIdle() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "Got it: add tests.",
            autoDismiss: 3.25
        )

        guard case .acknowledgement(let text, let autoDismiss) = stateMachine.state else {
            return XCTFail("Expected acknowledgement state")
        }
        XCTAssertEqual(text, "Got it: add tests.")
        XCTAssertEqual(autoDismiss, 3.25)

        stateMachine.dismissAcknowledgement()

        XCTAssertEqual(stateMachine.state, .idle)
    }

    func testBridgeAcknowledgementFallsBackWhenTextIsBlank() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "  ",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .acknowledgement(text: "Got it. I'm on it.", autoDismiss: 3.0))
    }

    func testBridgeAcknowledgementDoesNotReplaceSubstantiveTTSResponse() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Here is the detailed response.",
            autoDismiss: nil
        )
        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "Got it: late acknowledgement.",
            autoDismiss: 3.0
        )

        XCTAssertEqual(stateMachine.state, .messageWaiting(preview: "Here is the detailed response."))
    }

    func testDelayedAcknowledgementIsSuppressedWhenSubstantiveTTSArrivesFirst() {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let stateMachine = StateMachine(now: { now })

        stateMachine.updateSTT(isRecording: true, partial: "hello")
        stateMachine.updateSTT(isRecording: false, partial: "")
        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "Got it: late acknowledgement.",
            autoDismiss: 3.0
        )
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Here is the detailed response.",
            autoDismiss: nil
        )

        now = now.addingTimeInterval(
            StateMachine.sentAutoDismissDuration + StateMachine.acknowledgementDelayAfterSent
        )
        stateMachine.promotePendingAcknowledgementIfReady()

        XCTAssertEqual(stateMachine.state, .messageWaiting(preview: "Here is the detailed response."))
    }

    func testBridgeWorkingEventStoresProgressWithoutChangingVisibleState() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "working",
            text: "  First pass found 102 SKILL.md files.\nNarrowing the audit now.  ",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .idle)
        XCTAssertEqual(
            stateMachine.workingProgress,
            "First pass found 102 SKILL.md files. Narrowing the audit now."
        )

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "preparing",
            text: nil,
            autoDismiss: nil
        )

        XCTAssertNil(stateMachine.workingProgress)
    }
}
