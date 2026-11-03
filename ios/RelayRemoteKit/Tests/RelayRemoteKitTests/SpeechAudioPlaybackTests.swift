import Foundation
import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

@MainActor
final class FakeAudioPlayer: SpeechAudioPlaying {
    struct Stream {
        var slices: [Data] = []
        var ended = false
    }

    private(set) var streams: [Stream] = []
    private(set) var stops = 0
    private var completion: (@MainActor (AudioPlaybackEnd) -> Void)?

    var isPlaying: Bool { completion != nil }
    var current: Stream? { isPlaying ? streams.last : nil }
    /// Everything appended to the latest stream, as text.
    var played: String { (streams.last?.slices ?? []).map { String(decoding: $0, as: UTF8.self) }.joined() }

    func startStream(format: AudioFormat, sampleRate: Int, completion: @escaping @MainActor (AudioPlaybackEnd) -> Void) {
        streams.append(Stream())
        self.completion = completion
    }

    /// Fail on the first append, as an undecodable stream does.
    var failOnAppend = false

    func append(_ data: Data) {
        streams[streams.count - 1].slices.append(data)
        if failOnAppend { end(.failed) }
    }

    func endStream() {
        streams[streams.count - 1].ended = true
    }

    func stop() {
        stops += 1
        end(.stopped)
    }

    /// The player reached the end of an ended stream.
    func finishCurrent() {
        precondition(streams.last?.ended == true)
        end(.finished)
    }

    func end(_ end: AudioPlaybackEnd) {
        guard let completion else { return }
        self.completion = nil
        completion(end)
    }
}

/// Timers fire only when the test says so.
@MainActor
final class ManualTimers {
    private(set) var pending: [(delay: TimeInterval, fire: @MainActor () -> Void)] = []

    var schedule: SpeechTimer {
        { [unowned self] delay, fire in pending.append((delay, fire)) }
    }

    func fireAll(delay: TimeInterval) {
        let due = pending.filter { $0.delay == delay }
        pending.removeAll { $0.delay == delay }
        due.forEach { $0.fire() }
    }
}

final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var all: [String] { lock.withLock { events } }
    var logger: RemoteLogger { RemoteLogger { [self] event in lock.withLock { events.append(event) } } }
}

@MainActor
final class SpeechAudioPlaybackTests: XCTestCase {
    private var synthesizer: FakeSynthesizer!
    private var player: FakeAudioPlayer!
    private var timers: ManualTimers!
    private var logs: LogRecorder!
    private var acks: [Ack] = []
    private var states: [Bool] = []
    private var queue: SpeechPlaybackQueue!

    override func setUp() {
        super.setUp()
        synthesizer = FakeSynthesizer()
        player = FakeAudioPlayer()
        timers = ManualTimers()
        logs = LogRecorder()
        acks = []
        states = []
        queue = makeQueue(mode: .autoPlay)
    }

    private func makeQueue(mode: PlaybackMode) -> SpeechPlaybackQueue {
        let queue = SpeechPlaybackQueue(synthesizer: synthesizer, player: player, mode: mode, audioWait: 1.5,
                                        stallTimeout: 15, schedule: timers.schedule, log: logs.logger) { [unowned self] in
            acks.append($0)
        }
        queue.onPlaybackStateChange = { [unowned self] in states.append($0) }
        return queue
    }

    private func voiced(_ seq: Int, _ text: String = "Reply") -> Frame {
        .speech(Speech(seq: seq, kind: .final, source: .orchestrator, text: text, spokenBy: .phone, audio: true))
    }

    private func part(_ seq: Int, _ part: Int, _ text: String, last: Bool = false) -> Frame {
        .speechAudio(SpeechAudio(seq: seq, part: part, parts: last ? part + 1 : 0, format: .aac, sampleRate: 24000,
                                 data: Data(text.utf8).base64EncodedString(), last: last ? true : nil))
    }

    // MARK: - Streaming

    func testStreamedPartsPlayInOrderThroughThePlayerAndAckOnceAfterPlayback() {
        queue.receive(voiced(46, "RR-120 is in ready."))
        XCTAssertEqual(queue.playbackState, .buffering)
        XCTAssertEqual(states, [true], "the audio session opens while the first audio is on its way")
        queue.receive(part(46, 0, "aa"))
        XCTAssertEqual(queue.playbackState, .playing)
        queue.receive(part(46, 1, "bb", last: true))

        XCTAssertEqual(player.played, "aabb")
        XCTAssertEqual(player.current?.ended, true)
        XCTAssertTrue(acks.isEmpty, "no ack before the audio has played")
        XCTAssertEqual(synthesizer.spoken, [], "the phone's own voice stays silent")

        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: true)])
        XCTAssertEqual(queue.playbackState, .idle)
        XCTAssertEqual(states, [true, false])

        queue.receive(part(46, 1, "bb", last: true))
        queue.receive(voiced(46, "RR-120 is in ready."))
        XCTAssertEqual(acks.count, 1, "a late or replayed part never acks again")
        XCTAssertEqual(player.streams.count, 1)
    }

    func testOutOfOrderPartsAreFedInPartOrder() {
        queue.receive(voiced(46))
        queue.receive(part(46, 2, "cc", last: true))
        queue.receive(part(46, 1, "bb"))
        XCTAssertEqual(player.streams.count, 0, "nothing plays until part 0 arrives")
        XCTAssertEqual(queue.playbackState, .buffering)
        queue.receive(part(46, 0, "aa"))
        XCTAssertEqual(player.played, "aabbcc")
        XCTAssertEqual(player.current?.ended, true)
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: true)])
    }

    func testPartsArrivingWhileAnEarlierReplyPlaysAreBufferedForTheirTurn() {
        queue.receive(voiced(45, "First"))
        queue.receive(part(45, 0, "first", last: true))
        queue.receive(voiced(46, "Second"))
        queue.receive(part(46, 0, "sec"))
        queue.receive(part(46, 1, "ond", last: true))
        XCTAssertEqual(player.played, "first")
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 45, played: true)])
        XCTAssertEqual(player.played, "second")
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 45, played: true), Ack(seq: 46, played: true)])
        XCTAssertEqual(states, [true, false])
    }

    func testTextOnlyFramesStillUseTheSynthesizer() {
        queue.receive(.speech(Speech(seq: 1, kind: .final, source: .orchestrator, text: "No voice", audio: false)))
        queue.receive(.speech(Speech(seq: 2, kind: .final, source: .orchestrator, text: "Older Mac")))
        XCTAssertEqual(synthesizer.spoken, ["No voice"])
        XCTAssertEqual(queue.playbackState, .playing)
        synthesizer.finishCurrent()
        synthesizer.finishCurrent()
        XCTAssertEqual(synthesizer.spoken, ["No voice", "Older Mac"])
        XCTAssertEqual(player.streams.count, 0)
        XCTAssertEqual(acks, [Ack(seq: 1, played: true), Ack(seq: 2, played: true)])
    }

    func testWithoutAPlayerVoicedFramesAreSynthesised() {
        let queue = SpeechPlaybackQueue(synthesizer: synthesizer, schedule: timers.schedule) { [unowned self] in
            acks.append($0)
        }
        queue.receive(voiced(1, "Spoken here"))
        XCTAssertEqual(synthesizer.spoken, ["Spoken here"])
        XCTAssertTrue(timers.pending.isEmpty)
    }

    // MARK: - Fallback

    func testMissingAudioFallsBackToLocalSynthesisAfterTheWaitAndIsLogged() {
        queue.receive(voiced(46, "Fallback text"))
        XCTAssertEqual(timers.pending.map(\.delay), [1.5])
        XCTAssertEqual(synthesizer.spoken, [])

        timers.fireAll(delay: 1.5)
        XCTAssertEqual(synthesizer.spoken, ["Fallback text"])
        XCTAssertTrue(logs.all.contains("speech audio missing, speaking text"))
        XCTAssertEqual(queue.playbackState, .playing)

        queue.receive(part(46, 0, "late", last: true))
        XCTAssertEqual(player.streams.count, 0, "audio arriving after the fallback is dropped")
        synthesizer.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: true)])
    }

    func testTheWaitIsCancelledOnceAudioArrives() {
        queue.receive(voiced(46))
        queue.receive(part(46, 0, "aa"))
        timers.fireAll(delay: 1.5)
        XCTAssertEqual(synthesizer.spoken, [])
        XCTAssertEqual(player.played, "aa")
    }

    func testEmptyFinalPartBeforeAnyAudioSpeaksTheTextAtOnce() {
        queue.receive(voiced(46, "Mac voice failed"))
        queue.receive(.speechAudio(SpeechAudio(seq: 46, part: 0, parts: 1, format: .aac, sampleRate: 24000,
                                               data: "", last: true)))
        XCTAssertEqual(synthesizer.spoken, ["Mac voice failed"])
        XCTAssertEqual(player.streams.count, 0)
        synthesizer.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: true)])
    }

    func testEmptyFinalPartAfterAudioEndsTheStreamUnplayed() {
        queue.receive(voiced(46))
        queue.receive(part(46, 0, "aa"))
        queue.receive(.speechAudio(SpeechAudio(seq: 46, part: 1, parts: 2, format: .aac, sampleRate: 24000,
                                               data: "", last: true)))
        XCTAssertEqual(player.current?.ended, true)
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: false)], "a reply cut short is not reported as played")
        XCTAssertEqual(synthesizer.spoken, [])
    }

    func testPlayerFailureFallsBackToSynthesis() {
        queue.receive(voiced(46, "Undecodable"))
        queue.receive(part(46, 0, "zz", last: true))
        player.end(.failed)
        XCTAssertEqual(synthesizer.spoken, ["Undecodable"])
        XCTAssertTrue(logs.all.contains("speech audio could not play, speaking text"))
        synthesizer.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: true)])
    }

    func testPlayerFailingWhileAppendingHandsOverOnce() {
        player.failOnAppend = true
        queue.receive(voiced(46, "Fails at once"))
        queue.receive(part(46, 0, "aa"))
        queue.receive(part(46, 1, "bb", last: true))
        XCTAssertEqual(synthesizer.spoken, ["Fails at once"])
        XCTAssertEqual(player.streams.count, 1)
        XCTAssertNil(queue.resumeCeiling, "a reply handed to the synthesizer needs no more audio")
        synthesizer.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: true)])
    }

    func testStalledStreamEndsWithWhatItHasAndAcksUnplayed() {
        queue.receive(voiced(46))
        queue.receive(part(46, 0, "aa"))
        timers.fireAll(delay: 15)
        XCTAssertEqual(player.current?.ended, true)
        XCTAssertTrue(logs.all.contains("speech audio stalled"))
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: false)])
    }

    // MARK: - Play on demand

    func testOnDemandDefersPlaybackAndTheAckUntilPlay() {
        queue = makeQueue(mode: .onDemand)
        queue.receive(voiced(46, "Waiting reply"))
        queue.receive(part(46, 0, "aa", last: true))
        XCTAssertEqual(player.streams.count, 0)
        XCTAssertTrue(acks.isEmpty)
        XCTAssertEqual(states, [])
        XCTAssertEqual(queue.playbackState, .idle)
        XCTAssertEqual(queue.waitingReply, "Waiting reply")
        XCTAssertEqual(queue.resumeCeiling, nil, "its audio is complete")

        queue.play()
        XCTAssertNil(queue.waitingReply)
        XCTAssertEqual(player.played, "aa")
        XCTAssertTrue(acks.isEmpty)
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: true)])
    }

    func testOnDemandTextOnlyReplyIsSynthesisedOnPlay() {
        queue = makeQueue(mode: .onDemand)
        queue.receive(.speech(Speech(seq: 1, kind: .final, source: .orchestrator, text: "Text only", audio: false)))
        queue.receive(.status(Status(seq: 2, text: "worker started")))
        XCTAssertEqual(synthesizer.spoken, [])
        XCTAssertTrue(acks.isEmpty, "the status ack waits behind the unplayed reply")
        queue.play()
        synthesizer.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 1, played: true), Ack(seq: 2, played: false)])
    }

    func testOnDemandPlayPlaysTheNewestReplyAndSkipsOlderOnes() {
        queue = makeQueue(mode: .onDemand)
        queue.receive(voiced(45, "Looking now"))
        queue.receive(voiced(46, "Here is the answer"))
        XCTAssertEqual(queue.waitingReply, "Here is the answer")
        queue.play()
        XCTAssertEqual(acks, [Ack(seq: 45, played: false)])
        queue.receive(part(46, 0, "answer", last: true))
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 45, played: false), Ack(seq: 46, played: true)])
        XCTAssertEqual(player.streams.count, 1)
    }

    func testAutoPlayBehavesAsBeforeAndPlayDoesNothing() {
        queue.receive(voiced(45))
        queue.receive(voiced(46))
        XCTAssertNil(queue.waitingReply)
        queue.play()
        XCTAssertTrue(acks.isEmpty, "play never skips anything in auto-play")
    }

    func testSwitchingToAutoPlayPlaysWhatWaits() {
        queue = makeQueue(mode: .onDemand)
        queue.receive(voiced(46))
        queue.receive(part(46, 0, "aa", last: true))
        queue.mode = .autoPlay
        XCTAssertEqual(player.played, "aa")
    }

    func testReplayPlaysAtOnceInOnDemandMode() {
        queue = makeQueue(mode: .onDemand)
        queue.playNextReply()
        queue.receive(voiced(50, "Replayed"))
        XCTAssertEqual(queue.playbackState, .buffering)
        queue.receive(part(50, 0, "re", last: true))
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 50, played: true)])
        queue.receive(voiced(51, "Next"))
        XCTAssertEqual(queue.waitingReply, "Next", "only the replayed reply skips the Play control")
    }

    func testStopAndCancelDiscardTheWaitingReplyInOnDemandMode() {
        queue = makeQueue(mode: .onDemand)
        queue.receive(voiced(46))
        queue.stopAll()
        XCTAssertEqual(acks, [Ack(seq: 46, played: false)])
        XCTAssertNil(queue.waitingReply)
    }

    // MARK: - Stop, skip and interrupt

    func testLocalStopDuringStreamingStopsThePlayerAndLeavesTheReplyReplayable() {
        queue.receive(voiced(46, "A long reply"))
        queue.receive(part(46, 0, "aa"))
        queue.stopAll() // the Stop button, Cancel, and starting to talk (RR-455)
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(acks, [Ack(seq: 46, played: false)], "played: false keeps the reply replayable on the Mac")
        XCTAssertEqual(queue.playbackState, .idle)
        XCTAssertEqual(states, [true, false])

        queue.receive(part(46, 1, "bb", last: true))
        XCTAssertEqual(player.streams.count, 1, "parts of a stopped reply are dropped")

        // The Mac replays the reply under a fresh seq.
        queue.receive(voiced(47, "A long reply"))
        queue.receive(part(47, 0, "aabb", last: true))
        XCTAssertEqual(player.played, "aabb")
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 46, played: false), Ack(seq: 47, played: true)])
    }

    func testStopWhileBufferingResolvesWithoutAPlayer() {
        queue.receive(voiced(46))
        queue.stopAll()
        XCTAssertEqual(acks, [Ack(seq: 46, played: false)])
        timers.fireAll(delay: 1.5)
        XCTAssertEqual(synthesizer.spoken, [], "the expired wait of a stopped reply does nothing")
    }

    func testSpeechControlSkipDuringStreamingStopsThePlayer() {
        queue.receive(voiced(45))
        queue.receive(part(45, 0, "aa"))
        queue.receive(voiced(46))
        queue.receive(.speechControl(SpeechControl(seq: 47, action: .skip, reason: "newer_command")))
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(acks, [Ack(seq: 45, played: false), Ack(seq: 46, played: false), Ack(seq: 47, played: false)])
        XCTAssertEqual(player.streams.count, 1)
        XCTAssertFalse(queue.isSpeaking)
    }

    // MARK: - Reconnect

    func testResumeCeilingSitsBelowAReplyWithIncompleteAudio() {
        queue.receive(.status(Status(seq: 44, text: "started")))
        queue.receive(voiced(45))
        queue.receive(part(45, 0, "aa"))
        XCTAssertEqual(queue.resumeCeiling, 44)
        queue.receive(part(45, 1, "bb", last: true))
        XCTAssertNil(queue.resumeCeiling)
    }

    func testReconnectReplayDoesNotPlayAnySeqTwice() {
        queue.receive(voiced(45, "Interrupted by a drop"))
        queue.receive(part(45, 0, "aa"))
        queue.receive(.status(Status(seq: 46, text: "worker started")))
        XCTAssertEqual(queue.resumeCeiling, 44)

        // The channel dropped; the Mac replays 45 with all its parts, then 46.
        queue.receive(.welcome(Welcome(sessionState: "running", serverSeq: 46, resumedFrom: 44, dropped: false)))
        queue.receive(voiced(45, "Interrupted by a drop"))
        queue.receive(part(45, 0, "aa"))
        queue.receive(part(45, 1, "bb", last: true))
        queue.receive(.status(Status(seq: 46, text: "worker started")))

        XCTAssertEqual(player.streams.count, 1)
        XCTAssertEqual(player.played, "aabb", "part 0 is not appended twice")
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 45, played: true), Ack(seq: 46, played: false)])
        XCTAssertEqual(synthesizer.spoken, [])
    }

    func testWelcomeWithLowerServerSeqResetsAStreamingReply() {
        queue.receive(voiced(10))
        queue.receive(part(10, 0, "aa", last: true))
        player.finishCurrent()
        queue.receive(voiced(11))
        queue.receive(part(11, 0, "bb"))
        XCTAssertEqual(acks, [Ack(seq: 10, played: true)])

        // The bridge restarted: numbering begins again.
        queue.receive(.welcome(Welcome(sessionState: "running", serverSeq: 0, dropped: false)))
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(queue.playbackState, .idle)
        XCTAssertEqual(states, [true, false, true, false])
        XCTAssertNil(queue.resumeCeiling)

        queue.receive(voiced(1, "New bridge"))
        queue.receive(part(1, 0, "cc", last: true))
        XCTAssertEqual(player.played, "cc")
        player.finishCurrent()
        XCTAssertEqual(acks, [Ack(seq: 10, played: true), Ack(seq: 1, played: true)])
    }

    func testPlaybackModePreferenceDefaultsToAutoPlayAndPersists() throws {
        let suite = "PlaybackModePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PlaybackModePreference(defaults: defaults).mode, .autoPlay)
        PlaybackModePreference(defaults: defaults).mode = .onDemand
        XCTAssertEqual(PlaybackModePreference(defaults: defaults).mode, .onDemand)
    }
}
