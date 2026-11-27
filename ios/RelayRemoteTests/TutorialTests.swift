import RelayRemoteProtocol
import XCTest
@testable import RelayRemote

/// The tutorial's step machine and model, driven by faked voice and session
/// signals (RR-542).
@MainActor
final class TutorialTests: XCTestCase {
    private var ready: TutorialSignals {
        var signals = TutorialSignals()
        signals.speech = .ready
        signals.agentAvailable = true
        return signals
    }

    /// A machine walked to "hold to talk".
    private func atHold() -> TutorialMachine {
        var machine = TutorialMachine()
        machine.observe(ready)
        return machine
    }

    /// A machine walked to "play the reply".
    private func atPlay() -> TutorialMachine {
        var machine = atHold()
        machine.holdBegan()
        var signals = ready
        signals.userMessages = 1
        machine.observe(signals)
        return machine
    }

    func testBasicsWaitsForSpeechAndAnAgent() {
        var machine = TutorialMachine()
        XCTAssertEqual(machine.step, .basics)
        var signals = TutorialSignals()
        signals.speech = .ready
        machine.observe(signals)
        XCTAssertEqual(machine.step, .basics, "speech is ready but no agent is")
        signals.agentAvailable = true
        machine.observe(signals)
        XCTAssertEqual(machine.step, .holdToTalk)
    }

    func testStepsAdvanceOnlyOnTheNamedAction() {
        var machine = atHold()
        machine.released()
        machine.playTapped()
        machine.stopTapped()
        XCTAssertEqual(machine.step, .holdToTalk, "only holding advances the first action")
        machine.holdBegan()
        XCTAssertEqual(machine.step, .releaseToSend)
        machine.playTapped()
        XCTAssertEqual(machine.step, .releaseToSend, "tapping a dimmed control does nothing")
        var signals = ready
        signals.userMessages = 1
        machine.observe(signals)
        XCTAssertEqual(machine.step, .playReply)
        machine.stopTapped()
        machine.holdBegan()
        XCTAssertEqual(machine.step, .playReply, "waits for Play")
        machine.playTapped()
        XCTAssertEqual(machine.step, .stopPlayback)
        machine.playTapped()
        XCTAssertEqual(machine.step, .stopPlayback)
        machine.stopTapped()
        XCTAssertEqual(machine.step, .allDone)
    }

    func testReleasingWithNothingToSendReturnsToHold() {
        var machine = atHold()
        machine.holdBegan()
        var signals = ready
        signals.isListening = true
        signals.voiceIdle = false
        machine.observe(signals)
        machine.released()
        signals.isListening = false
        machine.observe(signals)
        XCTAssertEqual(machine.step, .releaseToSend, "still transcribing")
        signals.voiceIdle = true
        machine.observe(signals)
        XCTAssertEqual(machine.step, .holdToTalk, "nothing was sent: try again")
    }

    func testAMessageSentBeforeThatCountsEvenFromHold() {
        var machine = atHold()
        machine.holdBegan()
        machine.released()
        var signals = ready
        machine.observe(signals) // looks idle for a moment: back to hold
        XCTAssertEqual(machine.step, .holdToTalk)
        signals.userMessages = 1
        machine.observe(signals)
        XCTAssertEqual(machine.step, .playReply)
    }

    func testReplyFinishingByItselfEndsPlaybackStep() {
        var machine = atPlay()
        machine.playTapped()
        var signals = ready
        signals.userMessages = 1
        signals.isPlaying = true
        machine.observe(signals)
        XCTAssertEqual(machine.step, .stopPlayback)
        signals.isPlaying = false
        machine.observe(signals)
        XCTAssertEqual(machine.step, .allDone)
    }

    func testStepFiveIgnoresSilenceBeforePlaybackStarts() {
        var machine = atPlay()
        machine.playTapped()
        var signals = ready
        signals.userMessages = 1
        machine.observe(signals)
        XCTAssertEqual(machine.step, .stopPlayback, "no audio yet is not a finished reply")
    }

    func testLitControlsPerStep() {
        XCTAssertEqual(TutorialStep.holdToTalk.litControls, [.talk])
        XCTAssertEqual(TutorialStep.releaseToSend.litControls, [.talk, .textBox])
        XCTAssertEqual(TutorialStep.playReply.litControls, [])
        XCTAssertEqual(TutorialStep.stopPlayback.litControls, [.stop])
        XCTAssertFalse(TutorialStep.basics.showsDock)
        XCTAssertFalse(TutorialStep.allDone.showsDock)
    }

    func testProblems() {
        var machine = TutorialMachine()
        var signals = TutorialSignals()
        signals.reachable = false
        machine.observe(signals)
        XCTAssertEqual(machine.problem, .macUnreachable)
        signals = TutorialSignals()
        signals.speech = .unavailable
        machine.observe(signals)
        XCTAssertEqual(machine.problem, .speechUnavailable)
    }

    func testNoReplyTimeoutShowsAProblemUntilAReplyArrives() {
        var machine = atPlay()
        machine.replyTimeoutElapsed()
        XCTAssertEqual(machine.problem, .noReply)
        var signals = ready
        signals.userMessages = 1
        signals.replyWaiting = true
        machine.observe(signals)
        XCTAssertNil(machine.problem)
    }

    func testTimeoutBeforeStepFourDoesNothing() {
        var machine = atHold()
        machine.replyTimeoutElapsed()
        XCTAssertNil(machine.problem)
    }

    // MARK: - The model

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testModelTimesOutWaitingForAReply() async {
        let model = TutorialModel(sleep: { seconds in
            // Only the 30 s reply timeout elapses at once.
            if seconds == TutorialModel.replyTimeout { return }
            try? await Task.sleep(for: .seconds(seconds))
        }, onFinished: {})
        model.observe(ready)
        model.holdBegan()
        var signals = ready
        signals.userMessages = 1
        model.observe(signals)
        await waitUntil(model.machine.problem == .noReply)
        XCTAssertEqual(model.machine.problem, .noReply)
    }

    func testModelNeverTimesOutBeforeTheReplyStep() async {
        let model = TutorialModel(sleep: { _ in }, onFinished: {})
        model.observe(ready)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.machine.problem)
    }

    func testSkipFinishesOnceAtAnyStep() {
        for steps in 0...5 {
            var finished = 0
            let model = TutorialModel(sleep: { _ in try? await Task.sleep(for: .seconds(60)) },
                                      onFinished: { finished += 1 })
            if steps >= 1 { model.observe(ready) }
            if steps >= 2 { model.holdBegan() }
            if steps >= 3 {
                var signals = ready
                signals.userMessages = 1
                model.observe(signals)
            }
            if steps >= 4 { model.playTapped() }
            if steps >= 5 { model.stopTapped() }
            model.skip()
            model.skip()
            XCTAssertEqual(finished, 1, "skip at step index \(steps)")
            XCTAssertTrue(model.machine.isFinished)
        }
    }

    func testAllDoneHoldsThenFinishes() async {
        var finished = 0
        let model = TutorialModel(sleep: { _ in }, onFinished: { finished += 1 })
        model.observe(ready)
        model.holdBegan()
        var signals = ready
        signals.userMessages = 1
        model.observe(signals)
        model.playTapped()
        model.stopTapped()
        XCTAssertEqual(model.machine.step, .allDone)
        await waitUntil(finished == 1)
        XCTAssertEqual(finished, 1)
    }

    func testAgentChoice() {
        XCTAssertNil(TutorialAgent.choose(activities: [:], active: nil), "the Mac has not reported yet")
        let stopped: [String: AgentActivity] = ["puck": .off, "isabella": .off, "george": .off, "sky": .off]
        XCTAssertEqual(TutorialAgent.choose(activities: stopped, active: nil), "george")
        var running = stopped
        running["isabella"] = .ready
        running["sky"] = .working
        XCTAssertEqual(TutorialAgent.choose(activities: running, active: nil), "isabella")
        XCTAssertEqual(TutorialAgent.choose(activities: running, active: "sky"), "sky")
        XCTAssertEqual(TutorialAgent.choose(activities: running, active: "puck"), "isabella")
        XCTAssertFalse(TutorialAgent.isAvailable(.starting))
        XCTAssertFalse(TutorialAgent.isAvailable(.off))
        XCTAssertTrue(TutorialAgent.isAvailable(.ready))
    }

    func testTutorialHeroLinesFollowTheReferenceImages() {
        XCTAssertEqual(TutorialStep.playReply.hero(talkMode: .hold).lines.count, 2)
        XCTAssertEqual(TutorialStep.basics.hero(talkMode: .hold).lines.count, 1)
        XCTAssertEqual(TutorialStep.stopPlayback.hero(talkMode: .hold).lines.count, 1)
    }
}
