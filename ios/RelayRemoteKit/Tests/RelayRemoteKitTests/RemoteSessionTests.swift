import Network
import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

@MainActor
final class RemoteSessionTests: XCTestCase {
    func testHelloIsFirstAndEveryMacFrameIsAcked() async throws {
        let mac = FakeMac()
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: TestClock())
        session.start()
        await eventually { session.state == .connected }

        XCTAssertEqual(mac.hellos.count, 1)
        XCTAssertNil(mac.hellos[0].resumeAfterSeq, "a fresh device has nothing to resume")
        XCTAssertEqual(mac.hellos[0].deviceId, "b6f1c0d2-77a4-4e1b-8c39-2a5d9e0f4b13")
        guard case .hello = transport.lastConnection?.sentFrames.first else {
            return XCTFail("hello must be the first frame")
        }

        mac.speak("one")
        mac.speak("two")
        await eventually { mac.acks.count == 2 }
        XCTAssertEqual(mac.acks, [Ack(seq: 1, played: false), Ack(seq: 2, played: false)])
        XCTAssertEqual(session.resumeAfterSeq, 2)
        XCTAssertEqual(session.records.compactMap(\.speechText), ["one", "two"])
        session.stop()
    }

    func testReconnectBackoffGrowsExponentiallyWithJitterBoundsAndCap() async throws {
        let clock = TestClock()
        let transport = FakeTransport(mac: FakeMac(), outcomes: Array(repeating: .fail(.unreachable), count: 9) + [.connect])
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { session.state == .connected }

        // random returns the upper bound, so each delay is the ceiling.
        XCTAssertEqual(clock.delays, [0.5, 1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(transport.attemptCount, 10)
        session.stop()

        var backoff = Backoff(base: 0.5, cap: 30)
        for attempt in 0..<12 {
            let ceiling = min(30, 0.5 * Double(1 << attempt))
            let delay = backoff.nextDelay { range in
                XCTAssertEqual(range, ceiling / 2...ceiling)
                return range.lowerBound
            }
            XCTAssertEqual(delay, ceiling / 2)
        }
    }

    func testStableConnectionResetsBackoffButAFlappingOneDoesNot() async throws {
        let clock = TestClock()
        let mac = FakeMac()
        let transport = FakeTransport(mac: mac, outcomes: [.fail(.unreachable), .fail(.unreachable), .connect])
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { session.state == .connected }
        XCTAssertEqual(clock.delays, [0.5, 1])

        // Dropped straight after welcome: the backoff keeps growing.
        mac.dropConnection()
        await eventually { clock.delays.count == 3 && session.state == .connected }
        XCTAssertEqual(clock.delays.last, 2)

        // Up for longer than stableAfter: the next retry starts from the base.
        clock.advance(20)
        mac.dropConnection()
        await eventually { clock.delays.count == 4 && session.state == .connected }
        XCTAssertEqual(clock.delays.last, 0.5)
        session.stop()
    }

    func testResumeAfterSeqReplaysFramesMissedWhileDisconnected() async throws {
        let mac = FakeMac()
        let clock = TestClock()
        clock.holdBackoff = true
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { session.state == .connected }
        mac.speak("one")
        mac.speak("two")
        await eventually { mac.acks.count == 2 }

        mac.dropConnection()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        mac.speak("three")
        mac.speak("four")

        session.retryNow()
        await eventually { mac.acks.count == 4 }
        XCTAssertEqual(mac.hellos.last?.resumeAfterSeq, 2)
        XCTAssertEqual(session.records.compactMap(\.speechText), ["one", "two", "three", "four"])
        XCTAssertFalse(session.missedUpdates)
        XCTAssertEqual(session.resumeAfterSeq, 4)
        session.stop()
    }

    func testReplayedDuplicatesAreAckedAgainButShownOnce() async throws {
        let mac = FakeMac()
        mac.speak("one")
        mac.speak("two")
        // The phone already saw seq 1 and 2 but its acks never arrived, so the
        // Mac replays them from its buffer.
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: TestClock(), resumeAfterSeq: 0)
        session.start()
        await eventually { mac.acks.count == 2 }
        XCTAssertEqual(session.records.compactMap(\.speechText), ["one", "two"])

        let mac2 = FakeMac()
        mac2.speak("one")
        mac2.speak("two")
        let resumed = Fixtures.session(transport: FakeTransport(mac: mac2), clock: TestClock(), resumeAfterSeq: 2)
        resumed.start()
        await eventually { resumed.state == .connected }
        mac2.speak("three")
        await eventually { mac2.acks.count == 1 }
        XCTAssertEqual(resumed.records.compactMap(\.speechText), ["three"])
        session.stop()
        resumed.stop()
    }

    func testDroppedWindowIsSurfacedAndTheNextResumeStartsAtTheMacPosition() async throws {
        let mac = FakeMac()
        for index in 1...3 { mac.speak("old \(index)") }
        mac.now = 1000  // past the five-minute replay window
        let clock = TestClock()
        clock.holdBackoff = true
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: clock, resumeAfterSeq: 1)
        session.start()
        await eventually { session.state == .connected && session.resumeAfterSeq == 3 }
        XCTAssertTrue(session.missedUpdates, "frames 2 and 3 expired on the Mac")
        XCTAssertTrue(session.records.compactMap(\.speechText).isEmpty)

        mac.dropConnection()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        session.retryNow()
        await eventually { mac.hellos.count == 2 && session.state == .connected }
        XCTAssertEqual(mac.hellos.last?.resumeAfterSeq, 3, "the replay barrier moved resume to server_seq")
        session.dismissMissedUpdates()
        XCTAssertFalse(session.missedUpdates)
        session.stop()
    }

    func testBridgeRestartAdoptsTheNewSequence() async throws {
        let mac = FakeMac()  // a restarted bridge starts again at seq 0
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: TestClock(), resumeAfterSeq: 50)
        session.start()
        await eventually { session.state == .connected }
        XCTAssertTrue(session.missedUpdates)
        mac.speak("after restart")
        await eventually { mac.acks.count == 1 }
        XCTAssertEqual(session.records.compactMap(\.speechText), ["after restart"])
        XCTAssertEqual(session.resumeAfterSeq, 1)
        session.stop()
    }

    func testUnacceptedUtteranceIsResentWithItsOriginalClientIDAndRunsOnce() async throws {
        let mac = FakeMac()
        mac.acceptsUtterances = false
        let clock = TestClock()
        clock.holdBackoff = true
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: clock)
        session.start()
        await eventually { session.state == .connected }

        XCTAssertTrue(session.send(text: "  move RR-120 to ready "))
        await eventually { mac.utteranceFrames.count == 1 }
        XCTAssertEqual(session.pending.count, 1)
        let clientID = mac.utteranceFrames[0].clientId
        XCTAssertNotNil(UUID(uuidString: clientID))
        XCTAssertEqual(mac.utteranceFrames[0].text, "move RR-120 to ready")

        mac.dropConnection()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        mac.acceptsUtterances = true
        session.retryNow()
        await eventually { session.pending.isEmpty }
        XCTAssertEqual(mac.utteranceFrames.map(\.clientId), [clientID, clientID])
        XCTAssertEqual(mac.commands.count, 1)

        // A retry the Mac already accepted is de-duplicated, not run twice.
        mac.dropConnection()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        session.retryNow()
        await eventually { session.state == .connected }
        XCTAssertEqual(mac.commands.count, 1)
        session.stop()
    }

    func testUtteranceTypedWhileDisconnectedIsSentAfterWelcome() async throws {
        let mac = FakeMac()
        let clock = TestClock()
        clock.holdBackoff = true
        let transport = FakeTransport(mac: mac, outcomes: [.fail(.unreachable), .connect])
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        session.send(text: "hello there")
        XCTAssertTrue(mac.utteranceFrames.isEmpty)

        session.retryNow()
        await eventually { session.pending.isEmpty }
        XCTAssertEqual(mac.commands.map(\.text), ["hello there"])
        let sent = transport.lastConnection!.sentFrames
        guard case .hello = sent.first, case .utterance = sent[1] else {
            return XCTFail("the utterance must follow hello: \(sent.map(\.typeName))")
        }
        session.stop()
    }

    func testUtteranceOlderThanTheOutboxLifetimeIsNotResent() async throws {
        let mac = FakeMac()
        let clock = TestClock()
        clock.holdBackoff = true
        let transport = FakeTransport(mac: mac, outcomes: [.fail(.unreachable), .connect])
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        session.send(text: "stale command")
        clock.advance(ReplayBuffer.maxAge + 1)
        session.retryNow()
        await eventually { session.state == .connected }
        XCTAssertTrue(mac.utteranceFrames.isEmpty)
        XCTAssertTrue(session.pending.isEmpty)
        XCTAssertEqual(session.expiredCount, 1)
        session.stop()
    }

    func testChangedHostKeyStopsWithAVisibleErrorWithoutSendingOrRetrying() async throws {
        let clock = TestClock()
        let transport = FakeTransport(mac: FakeMac(), outcomes: [.fail(.hostKeyMismatch)])
        let session = Fixtures.session(transport: transport, clock: clock,
                                       endpoints: [Fixtures.endpoint, .hostPort(host: "100.100.1.2", port: 22)])
        session.send(text: "must not be sent")
        session.start()
        await eventually { session.state == .failed(.hostKeyMismatch) }

        XCTAssertEqual(transport.attemptCount, 1, "another address must not be tried")
        XCTAssertTrue(transport.connections.isEmpty)
        XCTAssertTrue(clock.delays.isEmpty, "no reconnect is scheduled")
        XCTAssertEqual(session.pending.count, 1)
        XCTAssertTrue(RemoteFailure.hostKeyMismatch.userMessage.contains("sent nothing"))

        // Nothing happens until the user acts, and backgrounding keeps the error.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.attemptCount, 1)
        session.stop()
        XCTAssertEqual(session.state, .failed(.hostKeyMismatch))
    }

    func testRejectedDeviceKeyStops() async throws {
        let clock = TestClock()
        let transport = FakeTransport(mac: FakeMac(), outcomes: [.fail(.authenticationRejected)])
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { session.state == .failed(.authenticationRejected) }
        XCTAssertTrue(clock.delays.isEmpty)

        transport.script([.connect])
        session.start()
        await eventually { session.state == .connected }
        session.stop()
    }

    func testKeyRefusedOnOneAddressFallsBackToTheNext() async throws {
        // A from= restricted key refused on the Bonjour link-local path still
        // connects through the stored LAN address.
        let clock = TestClock()
        let transport = FakeTransport(mac: FakeMac(), outcomes: [.fail(.authenticationRejected), .connect])
        let lan = NWEndpoint.hostPort(host: "192.168.1.21", port: 22)
        let session = Fixtures.session(transport: transport, clock: clock, endpoints: [Fixtures.endpoint, lan])
        session.start()
        await eventually { session.state == .connected }
        XCTAssertEqual(transport.attempts.map(\.endpoint), [Fixtures.endpoint, lan])
        XCTAssertTrue(clock.delays.isEmpty)
        session.stop()
    }

    func testKeyRefusedOnEveryAddressStops() async throws {
        let clock = TestClock()
        let transport = FakeTransport(mac: FakeMac(), outcomes: [.fail(.authenticationRejected)])
        let lan = NWEndpoint.hostPort(host: "192.168.1.21", port: 22)
        let session = Fixtures.session(transport: transport, clock: clock, endpoints: [Fixtures.endpoint, lan])
        session.start()
        await eventually { session.state == .failed(.authenticationRejected) }
        XCTAssertEqual(transport.attemptCount, 2)
        XCTAssertTrue(clock.delays.isEmpty, "no reconnect is scheduled")
    }

    func testKeyRefusedWhereTheOtherAddressesAreUnreachableStops() async throws {
        // A revoked key must still reach "pair again" when, say, the Tailscale
        // address is down; unreachable candidates do not count as answers.
        let clock = TestClock()
        let transport = FakeTransport(mac: FakeMac(), outcomes: [.fail(.unreachable), .fail(.authenticationRejected),
                                                                 .fail(.unreachable)])
        let session = Fixtures.session(transport: transport, clock: clock,
                                       endpoints: [NWEndpointFixture.tailscale, Fixtures.endpoint,
                                                   .hostPort(host: "192.168.1.21", port: 22)])
        session.start()
        await eventually { session.state == .failed(.authenticationRejected) }
        XCTAssertEqual(transport.attemptCount, 3)
        XCTAssertTrue(clock.delays.isEmpty)
    }

    func testCandidatesAreTriedInOrderUntilOneConnects() async throws {
        let transport = FakeTransport(mac: FakeMac(), outcomes: [.fail(.unreachable), .connect])
        let tailscale = NWEndpointFixture.tailscale
        let session = Fixtures.session(transport: transport, clock: TestClock(), endpoints: [Fixtures.endpoint, tailscale])
        session.start()
        await eventually { session.state == .connected }
        XCTAssertEqual(transport.attempts.map(\.endpoint), [Fixtures.endpoint, tailscale])
        session.stop()
    }

    func testErrorFrameBeforeWelcomeIsShownButNotFatal() async throws {
        let mac = FakeMac()
        mac.errorBeforeWelcome = ErrorFrame(code: "unknown_type", message: "Frame rejected")
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: TestClock())
        session.start()
        await eventually { session.state == .connected }
        XCTAssertEqual(session.lastError?.code, "unknown_type")
        session.stop()
    }

    func testSilentMacIsDetectedByPingsAndTheSessionReconnects() async throws {
        let clock = TestClock()
        clock.holdBackoff = true
        clock.pingSleepsReturn = true
        let transport = FakeTransport(mac: nil)
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { transport.lastConnection != nil }
        let connection = transport.lastConnection!
        connection.deliver(.welcome(Welcome(sessionState: "running", serverSeq: 0, dropped: false)))
        await eventually { session.state == .connected }
        // Pings go out while the clock stands still; nothing answers them.
        await eventually { connection.sentFrames.filter { $0.typeName == "ping" }.count > 2 }
        XCTAssertEqual(session.state, .connected)

        clock.advance(41)
        await eventually { if case .waiting = session.state { return true } else { return false } }
        XCTAssertTrue(connection.closed)
        XCTAssertEqual(session.lastDisconnect, "liveness_timeout")
        session.stop()
    }

    func testPingsCarryTheWallClockAndPongsKeepTheConnection() async throws {
        let mac = FakeMac()
        let clock = TestClock()
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: clock)
        session.start()
        await eventually { session.state == .connected }
        let pings = transport.lastConnection!.sentFrames.filter { $0.typeName == "ping" }
        XCTAssertEqual(pings, [.ping(Ping(t: 1_761_124_443))])
        session.stop()
    }

    func testStopClosesTheChannelAndStaysIdle() async throws {
        let mac = FakeMac()
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: TestClock())
        session.start()
        await eventually { session.state == .connected }
        session.stop()
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(transport.lastConnection!.closed)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.attemptCount, 1)
        XCTAssertEqual(session.state, .idle)

        session.start()
        await eventually { session.state == .connected && transport.attemptCount == 2 }
        session.stop()
    }
}

enum NWEndpointFixture {
    static let tailscale = NWEndpoint.hostPort(host: "100.100.1.2", port: 22)
}

extension FrameRecord {
    var speechText: String? {
        if direction == .received, case .speech(let speech) = frame { return speech.text }
        return nil
    }
}

@MainActor
final class RemoteSessionSpeechPlumbingTests: XCTestCase {
    func testControlIsSentWithAFreshUUIDAndRecorded() async throws {
        let mac = FakeMac()
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: TestClock())
        XCTAssertFalse(session.send(control: .stop), "no channel yet")
        session.start()
        await eventually { session.state == .connected }

        XCTAssertTrue(session.send(control: .stop))
        XCTAssertTrue(session.send(control: .replay))
        await eventually { mac.controls.count == 2 }
        XCTAssertEqual(mac.controls.map(\.action), [.stop, .replay])
        XCTAssertNotNil(UUID(uuidString: mac.controls[0].clientId))
        XCTAssertNotEqual(mac.controls[0].clientId, mac.controls[1].clientId)
        let sentControls = session.records.filter { record in
            if case .control = record.frame, record.direction == .sent { return true } else { return false }
        }
        XCTAssertEqual(sentControls.count, 2)
        session.stop()
    }

    func testInboundHookSeesNewFramesOnlyAndAcksAreAppDriven() async throws {
        let mac = FakeMac()
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: TestClock(), autoAck: false)
        var seen: [String] = []
        session.onInbound = { seen.append($0.typeName) }
        session.start()
        await eventually { session.state == .connected }

        mac.speak("one")
        mac.status("worker started")
        await eventually { seen.contains("status") }
        XCTAssertTrue(mac.acks.isEmpty, "the session never acks on its own")
        XCTAssertEqual(seen.filter { $0 == "speech" || $0 == "status" }, ["speech", "status"])
        XCTAssertEqual(seen.first, "welcome")

        session.send(ack: Ack(seq: 1, played: true))
        session.send(ack: Ack(seq: 2, played: false))
        await eventually { mac.acks.count == 2 }
        XCTAssertEqual(mac.acks, [Ack(seq: 1, played: true), Ack(seq: 2, played: false)])
        session.stop()
    }

    func testAckHeldWhileDisconnectedIsFlushedAfterReconnect() async throws {
        let mac = FakeMac()
        let clock = TestClock()
        clock.holdBackoff = true
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: clock, autoAck: false)
        session.start()
        await eventually { session.state == .connected }
        mac.speak("long reply")
        await eventually { session.records.compactMap(\.speechText) == ["long reply"] }

        mac.dropConnection()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        session.send(ack: Ack(seq: 1, played: true))
        XCTAssertTrue(mac.acks.isEmpty, "nothing can be sent while disconnected")

        session.retryNow()
        await eventually { mac.acks.count == 1 }
        XCTAssertEqual(mac.acks, [Ack(seq: 1, played: true)])
        XCTAssertEqual(mac.hellos.last?.resumeAfterSeq, 1)
        session.stop()
    }

    func testPlaybackQueueDrivenBySessionAcksOnlyAfterPlayback() async throws {
        let mac = FakeMac()
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: TestClock(), autoAck: false)
        let synthesizer = FakeSynthesizer()
        let queue = SpeechPlaybackQueue(synthesizer: synthesizer) { [weak session] in session?.send(ack: $0) }
        session.onInbound = { queue.receive($0) }
        session.start()
        await eventually { session.state == .connected }

        mac.speak("first")
        mac.speak("second")
        await eventually { synthesizer.spoken == ["first"] }
        XCTAssertTrue(mac.acks.isEmpty)
        synthesizer.finishCurrent()
        await eventually { mac.acks == [Ack(seq: 1, played: true)] }
        XCTAssertEqual(synthesizer.spoken, ["first", "second"])
        mac.speechControl(.stop, reason: "superseded")
        await eventually { mac.acks.count == 3 }
        XCTAssertEqual(mac.acks, [Ack(seq: 1, played: true), Ack(seq: 2, played: false), Ack(seq: 3, played: false)])
        XCTAssertEqual(synthesizer.stops, 1)
        session.stop()
    }
}
