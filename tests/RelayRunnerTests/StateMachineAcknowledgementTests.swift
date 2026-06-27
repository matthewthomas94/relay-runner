import XCTest
@testable import relay_runner

final class StateMachineAcknowledgementTests: XCTestCase {
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
}
