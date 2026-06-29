import AppKit
import XCTest
@testable import relay_runner

final class StateMachineAcknowledgementTests: XCTestCase {
    func testAcknowledgementCopySplitsTitleAndSummaryLines() {
        XCTAssertEqual(
            TranscriptionPill.acknowledgementCopy(
                from: "Ok I've got it\n\nYou want me to update the UI for the modal."
            ),
            TranscriptionPill.AcknowledgementCopy(
                title: "Ok I've got it",
                body: "You want me to update the UI for the modal."
            )
        )

        XCTAssertEqual(
            TranscriptionPill.acknowledgementCopy(from: "Got it: add tests."),
            TranscriptionPill.AcknowledgementCopy(title: "Got it", body: "add tests.")
        )

        XCTAssertEqual(
            TranscriptionPill.acknowledgementCopy(from: "  "),
            TranscriptionPill.AcknowledgementCopy(title: "Got it", body: nil)
        )
    }

    func testAcknowledgementPillUsesDedicatedCompactFootprint() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        let pill = TranscriptionPill(frame: .zero)
        host.addSubview(pill)

        pill.showAcknowledgement(
            text: "Ok I've got it\n\nYou want me to update the UI for the modal.",
            theme: .tts,
            animated: false
        )

        XCTAssertGreaterThanOrEqual(pill.frame.width, 344)
        XCTAssertLessThanOrEqual(pill.frame.width, 420)
        XCTAssertGreaterThan(pill.frame.height, 48)
        XCTAssertLessThan(pill.frame.height, 96)
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
