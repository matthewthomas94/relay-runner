import AppKit
import XCTest
@testable import relay_runner

final class AgentCycleGestureTests: XCTestCase {
    func testShiftOptionReleasedCyclesForward() {
        var gesture = AgentCycleGesture()
        XCTAssertNil(gesture.handleFlagsChanged([.shift]))
        XCTAssertNil(gesture.handleFlagsChanged([.shift, .option]))
        XCTAssertNil(gesture.handleFlagsChanged([.option]))
        XCTAssertEqual(gesture.handleFlagsChanged([]), .forward)
    }

    func testShiftControlReleasedCyclesBackward() {
        var gesture = AgentCycleGesture()
        XCTAssertNil(gesture.handleFlagsChanged([.control]))
        XCTAssertNil(gesture.handleFlagsChanged([.control, .shift]))
        XCTAssertNil(gesture.handleFlagsChanged([.shift]))
        XCTAssertEqual(gesture.handleFlagsChanged([]), .backward)
    }

    func testCapsLockDoesNotChangeTheChord() {
        var gesture = AgentCycleGesture()
        XCTAssertNil(gesture.handleFlagsChanged([.shift, .option, .capsLock]))
        XCTAssertEqual(gesture.handleFlagsChanged([.capsLock]), .forward)
    }

    func testAKeyTypedDuringTheChordIsAShortcut() {
        var gesture = AgentCycleGesture()
        _ = gesture.handleFlagsChanged([.shift, .option])
        gesture.handleKeyDown()
        XCTAssertNil(gesture.handleFlagsChanged([]))
        // The next clean chord still fires.
        _ = gesture.handleFlagsChanged([.shift, .option])
        XCTAssertEqual(gesture.handleFlagsChanged([]), .forward)
    }

    func testAKeyTypedWithShiftBeforeOptionIsAShortcut() {
        var gesture = AgentCycleGesture()
        _ = gesture.handleFlagsChanged([.shift])
        gesture.handleKeyDown()
        _ = gesture.handleFlagsChanged([.shift, .option])
        XCTAssertNil(gesture.handleFlagsChanged([]))
    }

    func testAnExtraModifierCancelsTheChord() {
        for extra: NSEvent.ModifierFlags in [.command, .control] {
            var gesture = AgentCycleGesture()
            _ = gesture.handleFlagsChanged([.shift, .option])
            _ = gesture.handleFlagsChanged([.shift, .option, extra])
            _ = gesture.handleFlagsChanged([.shift, .option])
            XCTAssertNil(gesture.handleFlagsChanged([]), "extra \(extra)")
        }
    }

    func testOtherModifiersAloneDoNothing() {
        var gesture = AgentCycleGesture()
        for flags: NSEvent.ModifierFlags in [[.shift], [.option], [.control], [.option, .control], [.shift, .command]] {
            _ = gesture.handleFlagsChanged(flags)
            XCTAssertNil(gesture.handleFlagsChanged([]), "\(flags)")
        }
    }

    func testAgentAfterWrapsInTableOrder() {
        let running: [SessionAgent] = [.sky, .puck, .george]
        XCTAssertEqual(AppState.agent(after: .puck, in: running, direction: .forward), .george)
        XCTAssertEqual(AppState.agent(after: .george, in: running, direction: .forward), .sky)
        XCTAssertEqual(AppState.agent(after: .sky, in: running, direction: .forward), .puck)
        XCTAssertEqual(AppState.agent(after: .puck, in: running, direction: .backward), .sky)
        XCTAssertEqual(AppState.agent(after: .george, in: running, direction: .backward), .puck)
    }

    func testAgentAfterNeedsAnotherRunningAgent() {
        XCTAssertNil(AppState.agent(after: .puck, in: [.puck], direction: .forward))
        XCTAssertNil(AppState.agent(after: .puck, in: [], direction: .backward))
        XCTAssertEqual(AppState.agent(after: nil, in: [.isabella], direction: .forward), .isabella)
        XCTAssertEqual(AppState.agent(after: .puck, in: [.george, .sky], direction: .forward), .george)
    }

    func testFollowingTheSpeakingAgentWaitsUntilYouAreQuiet() {
        let now = Date()
        XCTAssertTrue(AppState.followsSpeakingAgent(recording: false, lastTranscriptDeliveredAt: nil, now: now))
        XCTAssertFalse(AppState.followsSpeakingAgent(recording: true, lastTranscriptDeliveredAt: nil, now: now))
        XCTAssertFalse(AppState.followsSpeakingAgent(
            recording: false, lastTranscriptDeliveredAt: now.addingTimeInterval(-2), now: now))
        XCTAssertTrue(AppState.followsSpeakingAgent(
            recording: false, lastTranscriptDeliveredAt: now.addingTimeInterval(-6), now: now))
    }

    func testFollowingTheSpeakingAgentIsOnByDefaultAndSaved() {
        XCTAssertTrue(AwarenessConfig().follow_speaking_agent)
        XCTAssertTrue(RelayAppSettings.fields["awareness"]?.contains("follow_speaking_agent") == true)
    }
}
