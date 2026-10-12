import XCTest
@testable import relay_runner

final class StoryboardDemoTests: XCTestCase {
    func testNormalLaunchIgnoresScriptedRecording() {
        let machine = StateMachine(storyboardDemoEnabled: false)
        machine.handleServiceEvent(source: "storyboard_demo", newState: "recording", text: "Hello")
        XCTAssertEqual(machine.state, .idle)
        XCTAssertEqual(machine.partialTranscription, "")
    }

    func testScriptedTranscriptSurvivesMicrophonePollingAndReleasesOnSend() {
        let machine = StateMachine(storyboardDemoEnabled: true)
        machine.handleServiceEvent(source: "storyboard_demo", newState: "recording", text: "Hey, is the server running?")
        machine.updateSTT(isRecording: false, partial: "")
        XCTAssertEqual(machine.state, .recording)
        XCTAssertEqual(machine.partialTranscription, "Hey, is the server running?")

        machine.handleServiceEvent(source: "storyboard_demo", newState: "sent", text: nil)
        XCTAssertEqual(machine.state, .sent)
        machine.handleServiceEvent(source: "tts", newState: "speaking", text: "It is running.")
        XCTAssertEqual(machine.state, .speaking)
        XCTAssertEqual(machine.messagePreview, "It is running.")

        machine.handleServiceEvent(source: "storyboard_demo", newState: "idle", text: nil)
        machine.updateSTT(isRecording: true, partial: "Live input")
        XCTAssertEqual(machine.partialTranscription, "Live input")
        XCTAssertEqual(machine.state, .recording)
    }

    func testResetReleasesScriptedRecording() {
        let machine = StateMachine(storyboardDemoEnabled: true)
        machine.handleServiceEvent(source: "storyboard_demo", newState: "recording", text: "Demo")
        machine.reset()
        machine.updateSTT(isRecording: true, partial: "Live")
        XCTAssertEqual(machine.partialTranscription, "Live")
    }
}
