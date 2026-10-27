import XCTest
import RelayRemoteProtocol
@testable import RelayRemoteKit

@MainActor
final class FakeSynthesizer: SpeechSynthesizing {
    var spoken: [String] = []
    var stops = 0
    private var completions: [@MainActor (Bool) -> Void] = []

    func speak(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        spoken.append(text)
        completions.append(completion)
    }

    func stopSpeaking() {
        stops += 1
        guard !completions.isEmpty else { return }
        completions.removeFirst()(false)
    }

    func finishCurrent() {
        completions.removeFirst()(true)
    }

    var pendingCount: Int { completions.count }
}

@MainActor
final class SpeechPlaybackTests: XCTestCase {
    private var synthesizer: FakeSynthesizer!
    private var acks: [Ack] = []
    private var states: [Bool] = []
    private var queue: SpeechPlaybackQueue!

    override func setUp() {
        super.setUp()
        synthesizer = FakeSynthesizer()
        acks = []
        states = []
        queue = SpeechPlaybackQueue(synthesizer: synthesizer) { [unowned self] in acks.append($0) }
        queue.onPlaybackStateChange = { [unowned self] in states.append($0) }
    }

    private func speech(_ seq: Int, _ text: String) -> Frame {
        .speech(Speech(seq: seq, kind: .final, source: .orchestrator, text: text, relayCommandSeq: 7))
    }

    func testFramesPlayInSeqOrderAndPlayedAcksFollowCompletion() {
        queue.receive(speech(45, "Looking at RR-120 now."))
        queue.receive(speech(46, "RR-120 is in ready and dispatching."))
        XCTAssertEqual(synthesizer.spoken, ["Looking at RR-120 now."])
        XCTAssertTrue(acks.isEmpty, "no ack before playback completes")
        XCTAssertEqual(states, [true])

        synthesizer.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 45, played: true)])
        XCTAssertEqual(synthesizer.spoken.last, "RR-120 is in ready and dispatching.")
        XCTAssertTrue(queue.isSpeaking)

        synthesizer.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 45, played: true), Ack(seq: 46, played: true)])
        XCTAssertFalse(queue.isSpeaking)
        XCTAssertEqual(states, [true, false])
    }

    func testSpeechControlStopsCurrentDropsQueuedAndAcksUnplayedInOrder() {
        queue.receive(speech(45, "First"))
        queue.receive(speech(46, "Second"))
        queue.receive(.speechControl(SpeechControl(seq: 47, action: .stop, reason: "superseded")))

        XCTAssertEqual(synthesizer.stops, 1)
        XCTAssertEqual(acks, [Ack(seq: 45, played: false), Ack(seq: 46, played: false), Ack(seq: 47, played: false)])
        XCTAssertEqual(synthesizer.spoken, ["First"], "the dropped frame is never spoken")
        XCTAssertFalse(queue.isSpeaking)
        XCTAssertEqual(states, [true, false])
    }

    func testFrameBelowTheAckWatermarkIsIgnored() {
        // The session's seq high-water mark already hides such a frame; the
        // queue agrees rather than acknowledging out of order.
        queue.receive(.speechControl(SpeechControl(seq: 47, action: .skip, reason: "stale")))
        queue.receive(speech(46, "Arrived late"))
        XCTAssertTrue(synthesizer.spoken.isEmpty)
        XCTAssertEqual(acks, [Ack(seq: 47, played: false)])
    }

    func testReplayedDuplicateIsSpokenAndAckedOnce() {
        queue.receive(speech(45, "Once"))
        queue.receive(speech(45, "Once"))
        synthesizer.finishCurrent()
        queue.receive(speech(45, "Once"))
        XCTAssertEqual(synthesizer.spoken, ["Once"])
        XCTAssertEqual(acks, [Ack(seq: 45, played: true)])
        XCTAssertEqual(synthesizer.pendingCount, 0)
    }

    func testStatusAckWaitsBehindEarlierSpeech() {
        queue.receive(speech(45, "Working"))
        queue.receive(.status(Status(seq: 46, text: "worker RR-120 started")))
        XCTAssertTrue(acks.isEmpty, "seq 46 must not be acknowledged before 45 resolves")
        synthesizer.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 45, played: true), Ack(seq: 46, played: false)])
    }

    func testLocalStopSilencesEverything() {
        queue.receive(speech(45, "First"))
        queue.receive(speech(46, "Second"))
        queue.stopAll()
        XCTAssertEqual(synthesizer.stops, 1)
        XCTAssertEqual(acks, [Ack(seq: 45, played: false), Ack(seq: 46, played: false)])
        XCTAssertFalse(queue.isSpeaking)
    }

    func testFramesWithoutSeqAreIgnored() {
        queue.receive(.accepted(Accepted(clientId: "c", relayCommandSeq: 1, relayCommandId: "id")))
        queue.receive(.error(ErrorFrame(code: "no_session", message: "x")))
        XCTAssertTrue(acks.isEmpty)
        XCTAssertTrue(synthesizer.spoken.isEmpty)
    }
}
