import Foundation
import Network
import NIOSSH
import os
import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

/// A scripted Mac bridge built from the shared protocol pieces, so it seqs,
/// replays, trims and de-duplicates exactly like services/relay_remote.py.
final class FakeMac: @unchecked Sendable {
    private let lock = NSLock()
    private var seq = SeqCounter()
    private var replay = ReplayBuffer()
    private var dedup = ClientIDDeduplicator()
    private var acceptedByID: [String: Accepted] = [:]
    private var connection: FakeConnection?
    private(set) var hellos: [Hello] = []
    private(set) var commands: [Utterance] = []
    private(set) var utteranceFrames: [Utterance] = []
    private(set) var acks: [Ack] = []
    /// When false, utterances are recorded but not accepted (a drop before the receipt).
    var acceptsUtterances = true
    /// Sent once before `welcome`, like the bridge's reply to the helper's `identify` line.
    var errorBeforeWelcome: ErrorFrame?
    var now: Double = 0

    var isConnected: Bool { lock.withLock { connection != nil } }

    func attach(_ connection: FakeConnection) {
        lock.withLock { self.connection = connection }
    }

    func receive(_ frame: Frame, on connection: FakeConnection) {
        lock.lock()
        defer { lock.unlock() }
        switch frame {
        case .hello(let hello):
            hellos.append(hello)
            if let error = errorBeforeWelcome { connection.deliver(.error(error)) }
            let resume = replay.resume(after: hello.resumeAfterSeq, at: now)
            connection.deliver(.welcome(Welcome(sessionState: "running", serverSeq: resume.serverSeq,
                                                resumedFrom: hello.resumeAfterSeq, dropped: resume.dropped)))
            resume.frames.forEach(connection.deliver)
        case .utterance(let utterance):
            utteranceFrames.append(utterance)
            guard acceptsUtterances else { return }
            if dedup.isDuplicate(utterance.clientId) {
                if let accepted = acceptedByID[utterance.clientId] { connection.deliver(.accepted(accepted)) }
                return
            }
            commands.append(utterance)
            let accepted = Accepted(clientId: utterance.clientId, relayCommandSeq: commands.count,
                                    relayCommandId: "cmd-\(commands.count)")
            acceptedByID[utterance.clientId] = accepted
            connection.deliver(.accepted(accepted))
        case .ack(let ack):
            acks.append(ack)
            replay.ack(ack.seq)
        case .ping(let ping):
            connection.deliver(.pong(Pong(t: ping.t)))
        default:
            break
        }
    }

    /// Emits a sequenced speech frame, held for replay while disconnected.
    @discardableResult
    func speak(_ text: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let frame = Frame.speech(Speech(seq: seq.next(), kind: .final, source: .orchestrator, text: text))
        try! replay.record(frame, at: now)
        connection?.deliver(frame)
        return seq.last
    }

    /// Ends the connection as a network drop would.
    func dropConnection() {
        let current = lock.withLock { () -> FakeConnection? in
            defer { connection = nil }
            return connection
        }
        current?.finish()
    }

    func detach(_ connection: FakeConnection) {
        lock.withLock { if self.connection === connection { self.connection = nil } }
    }
}

final class FakeConnection: RemoteConnection, @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private weak var mac: FakeMac?
    private let lock = NSLock()
    private(set) var sentLines: [Data] = []
    private(set) var closed = false
    /// Replaces the Mac for tests that answer by hand.
    var onSend: ((Data) -> Void)?

    init(mac: FakeMac?) {
        (lines, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.mac = mac
    }

    func send(_ line: Data) {
        lock.withLock { sentLines.append(line) }
        if let onSend { onSend(line); return }
        guard let mac, !closed, let frame = try? FrameCodec.decode(line) else { return }
        mac.receive(frame, on: self)
    }

    func close() {
        lock.withLock { closed = true }
        mac?.detach(self)
        continuation.finish()
    }

    func deliver(_ frame: Frame) {
        let line = try! FrameCodec.encode(frame)
        continuation.yield(line.dropLast())
    }

    func deliver(line: String) {
        continuation.yield(Data(line.utf8))
    }

    func finish(throwing error: Error? = nil) {
        lock.withLock { closed = true }
        continuation.finish(throwing: error)
    }

    var sentFrames: [Frame] { lock.withLock { sentLines }.compactMap { try? FrameCodec.decode($0) } }
}

/// Each connect takes the next scripted outcome; the last one repeats.
final class FakeTransport: RemoteTransport, @unchecked Sendable {
    enum Outcome {
        case fail(RemoteFailure)
        case connect
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private let mac: FakeMac?
    private(set) var attempts: [(endpoint: NWEndpoint, credentials: SSHCredentials)] = []
    private(set) var connections: [FakeConnection] = []
    /// Configures each connection before the caller can write to it.
    var onConnect: ((FakeConnection) -> Void)?

    init(mac: FakeMac?, outcomes: [Outcome] = [.connect]) {
        self.mac = mac
        self.outcomes = outcomes
    }

    func script(_ outcomes: [Outcome]) {
        lock.withLock { self.outcomes = outcomes }
    }

    func connect(to endpoint: NWEndpoint, credentials: SSHCredentials) async throws -> RemoteConnection {
        let outcome = lock.withLock { () -> Outcome in
            attempts.append((endpoint, credentials))
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        }
        switch outcome {
        case .fail(let failure):
            throw failure
        case .connect:
            let connection = FakeConnection(mac: mac)
            onConnect?(connection)
            mac?.attach(connection)
            lock.withLock { connections.append(connection) }
            return connection
        }
    }

    var attemptCount: Int { lock.withLock { attempts.count } }
    var lastConnection: FakeConnection? { lock.withLock { connections.last } }
}

/// Controlled time: backoff sleeps are recorded and return at once; handshake
/// and ping sleeps wait until cancelled unless a test releases them.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Double = 1000
    private(set) var backoffDelays: [Double] = []
    var holdBackoff = false
    var pingSleepsReturn = false

    var now: Double { lock.withLock { current } }

    func advance(_ seconds: Double) {
        lock.withLock { current += seconds }
    }

    var environment: SessionEnvironment {
        SessionEnvironment(
            now: { [self] in now },
            sleep: { [self] reason, seconds in
                switch reason {
                case .backoff:
                    let hold = lock.withLock { () -> Bool in
                        backoffDelays.append(seconds)
                        return holdBackoff
                    }
                    if hold { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
                case .ping where lock.withLock({ pingSleepsReturn }):
                    try await Task.sleep(nanoseconds: 1_000_000)
                default:
                    try await Task.sleep(nanoseconds: 3_600_000_000_000)
                }
            },
            random: { $0.upperBound },
            wallClock: { 1_761_124_443 }
        )
    }

    var delays: [Double] { lock.withLock { backoffDelays } }
}

final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var logger: RemoteLogger { RemoteLogger { [self] line in lock.withLock { lines.append(line) } } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}

enum Fixtures {
    static let hostPin = "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"

    static func credentials(pins: Set<String> = [hostPin]) -> SSHCredentials {
        SSHCredentials(user: "me", privateKey: NIOSSHPrivateKey(ed25519Key: .init()), pinnedHostKeys: pins)
    }

    static let endpoint = NWEndpoint.hostPort(host: "192.168.1.20", port: 22)

    @MainActor
    static func session(transport: RemoteTransport, clock: TestClock, resumeAfterSeq: Int? = nil,
                        log: RemoteLogger = .silent,
                        endpoints: [NWEndpoint] = [endpoint]) -> RemoteSession {
        var configuration = SessionConfiguration(deviceID: "b6f1c0d2-77a4-4e1b-8c39-2a5d9e0f4b13", deviceName: "Test iPhone",
                                                 appVersion: "0.1", credentials: credentials(),
                                                 resumeAfterSeq: resumeAfterSeq)
        configuration.timing.backoff = Backoff(base: 0.5, cap: 30)
        return RemoteSession(configuration: configuration, transport: transport, endpoints: StaticEndpoints(endpoints),
                             environment: clock.environment, log: log)
    }
}

extension XCTestCase {
    /// Polls `condition` on the main actor, yielding to the session's tasks.
    @MainActor
    func eventually(timeout: Double = 3, file: StaticString = #filePath, line: UInt = #line,
                    _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
