import Foundation
import Network
import Observation
import RelayRemoteProtocol

public struct SessionTiming: Sendable {
    /// Seconds between pings once welcomed. App-level pings keep a NAT mapping
    /// warm and detect a dead path; swift-nio-ssh has no client keepalive, so
    /// sshd's ClientAliveInterval covers the other direction (RR-420).
    public var pingInterval: Double = 15
    /// No inbound line for this long closes the connection.
    public var livenessTimeout: Double = 40
    /// Connecting plus `welcome` must finish within this.
    public var handshakeTimeout: Double = 15
    /// A connection that stayed welcomed this long resets the backoff.
    public var stableAfter: Double = 15
    public var backoff = Backoff()

    public init() {}
}

/// Injected time and randomness so reconnect scheduling is testable.
public struct SessionEnvironment: Sendable {
    public enum SleepReason: Sendable { case backoff, handshake, ping }

    /// Monotonic seconds.
    public var now: @Sendable () -> Double
    public var sleep: @Sendable (SleepReason, Double) async throws -> Void
    public var random: @Sendable (ClosedRange<Double>) -> Double
    /// Unix seconds for `ping.t`.
    public var wallClock: @Sendable () -> Int

    public init(now: @escaping @Sendable () -> Double,
                sleep: @escaping @Sendable (SleepReason, Double) async throws -> Void,
                random: @escaping @Sendable (ClosedRange<Double>) -> Double,
                wallClock: @escaping @Sendable () -> Int) {
        self.now = now
        self.sleep = sleep
        self.random = random
        self.wallClock = wallClock
    }

    public static let live = SessionEnvironment(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { _, seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
        random: { Double.random(in: $0) },
        wallClock: { Int(Date().timeIntervalSince1970) }
    )
}

public struct SessionConfiguration: Sendable {
    public var deviceID: String
    public var deviceName: String
    public var appVersion: String
    public var credentials: SSHCredentials
    public var resumeAfterSeq: Int?
    public var timing = SessionTiming()

    public init(deviceID: String, deviceName: String, appVersion: String, credentials: SSHCredentials,
                resumeAfterSeq: Int? = nil) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.credentials = credentials
        self.resumeAfterSeq = resumeAfterSeq
    }
}

/// A frame as the debug screen lists it.
public struct FrameRecord: Equatable, Sendable, Identifiable {
    public enum Direction: Sendable { case sent, received }

    public let id: Int
    public let direction: Direction
    public let frame: Frame
}

/// Holds one SSH exec channel to the paired Mac at a time and keeps it alive:
/// hello with `resume_after_seq`, acks, utterance retries, pings, and
/// reconnects with exponential backoff and jitter. Frames are only written
/// after the channel is open, so a refused host key sends nothing.
@MainActor
@Observable
public final class RemoteSession {
    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case connected
        case waiting(retryIn: Double)
        case failed(RemoteFailure)
    }

    public private(set) var state: State = .idle
    public private(set) var records: [FrameRecord] = []
    public private(set) var pending: [PendingUtterance] = []
    public private(set) var expiredCount = 0
    public private(set) var missedUpdates = false
    public private(set) var lastError: ErrorFrame?
    /// The code of the last non-terminal connection failure, for the debug screen.
    public private(set) var lastDisconnect: String?

    public var resumeAfterSeq: Int? { core.lastSeq }

    public static let recordLimit = 200
    /// Acks held while the channel is down; flushed after the next `welcome`.
    public static let ackOutboxLimit = 200

    /// Called on the main actor with every decoded inbound frame that is not a
    /// duplicate (`welcome`, `accepted`, `error` and `pong` included). The app
    /// feeds these to its speech playback queue.
    public var onInbound: ((Frame) -> Void)?
    private var ackOutbox: [Ack] = []

    @ObservationIgnored private let configuration: SessionConfiguration
    @ObservationIgnored private let transport: RemoteTransport
    @ObservationIgnored private let endpoints: EndpointProvider
    @ObservationIgnored private let environment: SessionEnvironment
    @ObservationIgnored private let log: RemoteLogger
    @ObservationIgnored private var core: SessionCore
    @ObservationIgnored private var backoff: Backoff
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var backoffSleep: Task<Void, Error>?
    @ObservationIgnored private var connection: RemoteConnection?
    @ObservationIgnored private var lastInbound: Double = 0
    @ObservationIgnored private var nextRecordID = 0

    public init(configuration: SessionConfiguration, transport: RemoteTransport, endpoints: EndpointProvider,
                environment: SessionEnvironment = .live, log: RemoteLogger = .system) {
        self.configuration = configuration
        self.transport = transport
        self.endpoints = endpoints
        self.environment = environment
        self.log = log
        self.core = SessionCore(deviceID: configuration.deviceID, deviceName: configuration.deviceName,
                                appVersion: configuration.appVersion, resumeAfterSeq: configuration.resumeAfterSeq)
        self.backoff = configuration.timing.backoff
    }

    /// Starts connecting; also the way out of `.failed` after the user acts.
    public func start() {
        guard loop == nil else { return }
        backoff.reset()
        loop = Task { [weak self] in await self?.run() }
    }

    /// Closes the channel and stops reconnecting (the app went to the
    /// background). A `.failed` state is kept so the refusal stays visible.
    public func stop() {
        loop?.cancel()
        loop = nil
        connection?.close()
        connection = nil
        core.connectionClosed()
        if case .failed = state { return }
        state = .idle
    }

    /// Skips the remaining backoff, for example after a network path change.
    public func retryNow() {
        guard case .waiting = state else { return }
        backoff.reset()
        backoffSleep?.cancel()
    }

    /// Queues a typed utterance and sends it when the channel is up.
    @discardableResult
    public func send(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let utterance = Utterance(clientId: UUID().uuidString.lowercased(), text: trimmed,
                                  capturedAt: Self.timestamp(Date()))
        guard (try? FrameCodec.encode(.utterance(utterance))) != nil else { return false }
        if let now = core.enqueue(utterance, now: environment.now()) {
            transmit(.utterance(now))
        }
        pending = core.pending
        return true
    }

    /// Sends a control frame (stop, interrupt, cancel, play, replay) with a
    /// fresh `client_id`. Returns false when the channel is down, since a
    /// control for a reply that may already be over has no value later.
    @discardableResult
    public func send(control action: ControlAction) -> Bool {
        guard connection != nil, core.isWelcomed else { return false }
        transmit(.control(Control(clientId: UUID().uuidString.lowercased(), action: action)))
        return true
    }

    /// Acknowledges a Mac frame. While the channel is down the ack waits in a
    /// bounded outbox so a reply that finished playing during a reconnect is
    /// still recorded as played.
    public func send(ack: Ack) {
        if connection != nil, core.isWelcomed {
            transmit(.ack(ack))
            return
        }
        ackOutbox.append(ack)
        if ackOutbox.count > Self.ackOutboxLimit {
            ackOutbox.removeFirst(ackOutbox.count - Self.ackOutboxLimit)
        }
    }

    public func dismissMissedUpdates() {
        core.clearMissedUpdates()
        missedUpdates = false
    }

    // MARK: Connection loop

    private func run() async {
        while !Task.isCancelled {
            state = .connecting
            var welcomedAt: Double?
            do {
                welcomedAt = try await connectAndServe()
            } catch let failure as RemoteFailure where failure.isTerminal && !Task.isCancelled {
                finishConnection()
                state = .failed(failure)
                log("session stopped: \(failure.code)")
                loop = nil
                return
            } catch {
                if !Task.isCancelled {
                    lastDisconnect = RemoteFailure.code(for: error)
                    log("connection ended: \(RemoteFailure.code(for: error))")
                }
            }
            // After stop() the session may already belong to a newer loop.
            guard !Task.isCancelled else { return }
            finishConnection()

            if let welcomedAt, environment.now() - welcomedAt >= configuration.timing.stableAfter {
                backoff.reset()
            }
            let delay = backoff.nextDelay(random: environment.random)
            state = .waiting(retryIn: delay)
            log("reconnect scheduled: attempt \(backoff.attempt)")
            let sleeper = Task { [environment] in try await environment.sleep(.backoff, delay) }
            backoffSleep = sleeper
            await withTaskCancellationHandler {
                _ = await sleeper.result
            } onCancel: {
                sleeper.cancel()
            }
            backoffSleep = nil
        }
    }

    /// Returns when the welcomed connection was established, or nil when it
    /// ended before `welcome`.
    private func connectAndServe() async throws -> Double? {
        let timing = configuration.timing
        let connection = try await openChannel()
        guard !Task.isCancelled else {
            connection.close()
            throw CancellationError()
        }
        self.connection = connection
        lastInbound = environment.now()

        let handshake = Task { [environment, weak self] in
            try await environment.sleep(.handshake, timing.handshakeTimeout)
            guard let self, !self.core.isWelcomed else { return }
            self.lastDisconnect = RemoteFailure.handshakeTimeout.code
            connection.close()
        }
        var pinger: Task<Void, Error>?
        defer {
            handshake.cancel()
            pinger?.cancel()
        }

        let hello = core.connectionOpened()
        transmit(.hello(hello), on: connection)
        var welcomedAt: Double?
        for try await line in connection.lines {
            lastInbound = environment.now()
            let frame: Frame
            do {
                frame = try FrameCodec.decode(line)
            } catch {
                log("frame ignored: \((error as? FrameError)?.code ?? "decode")")
                continue
            }
            let wasWelcomed = core.isWelcomed
            let reaction = core.receive(frame, now: environment.now())
            if reaction.isNew { append(.received, frame) }
            expiredCount += reaction.expired.count
            for out in reaction.send { transmit(out, on: connection) }
            if !wasWelcomed, core.isWelcomed {
                welcomedAt = environment.now()
                state = .connected
                lastDisconnect = nil
                log("welcomed")
                flushAckOutbox(on: connection)
                // The first ping doubles as the replay barrier.
                transmit(.ping(Ping(t: environment.wallClock())), on: connection)
                pinger = startPinger(connection)
            }
            pending = core.pending
            missedUpdates = core.missedUpdates
            lastError = core.lastError
            if reaction.isNew || frame.seq == nil { onInbound?(frame) }
        }
        return welcomedAt
    }

    /// Acks that waited out a disconnect. One above the Mac's current seq
    /// belongs to a sequence that no longer exists (the bridge restarted).
    private func flushAckOutbox(on connection: RemoteConnection) {
        guard !ackOutbox.isEmpty else { return }
        let serverSeq = core.welcome?.serverSeq ?? 0
        let held = ackOutbox
        ackOutbox.removeAll()
        for ack in held where ack.seq <= serverSeq {
            transmit(.ack(ack), on: connection)
        }
        log("ack outbox flushed")
    }

    /// Tries each candidate in order. A refused host key stops at once. A
    /// refused device key moves on to the next address, because a key paired
    /// with "Only from my home network and Tailscale" carries a `from=` list
    /// that sshd checks against the client address, so the same Mac can refuse
    /// one address and accept another. The refusal becomes terminal only when
    /// no candidate connected and every one that answered refused the key.
    private func openChannel() async throws -> RemoteConnection {
        let candidates = await endpoints.candidates()
        var lastFailure: Error = RemoteFailure.unreachable
        var keyRejected = false
        for endpoint in candidates {
            try Task.checkCancellation()
            do {
                let connection = try await transport.connect(to: endpoint, credentials: configuration.credentials)
                log("channel open")
                return connection
            } catch RemoteFailure.authenticationRejected {
                keyRejected = true
                log("candidate refused: \(RemoteFailure.authenticationRejected.code)")
            } catch let failure as RemoteFailure where failure.isTerminal {
                throw failure
            } catch {
                lastFailure = error
            }
        }
        if keyRejected { throw RemoteFailure.authenticationRejected }
        throw lastFailure
    }

    private func startPinger(_ connection: RemoteConnection) -> Task<Void, Error> {
        let timing = configuration.timing
        return Task { [environment, weak self] in
            while true {
                try await environment.sleep(.ping, timing.pingInterval)
                guard let self else { return }
                if environment.now() - self.lastInbound > timing.livenessTimeout {
                    self.lastDisconnect = RemoteFailure.livenessTimeout.code
                    connection.close()
                    return
                }
                self.transmit(.ping(Ping(t: environment.wallClock())), on: connection)
            }
        }
    }

    private func finishConnection() {
        connection?.close()
        connection = nil
        core.connectionClosed()
    }

    private func transmit(_ frame: Frame) {
        guard let connection, core.isWelcomed else { return }
        transmit(frame, on: connection)
    }

    private func transmit(_ frame: Frame, on connection: RemoteConnection) {
        guard let line = try? FrameCodec.encode(frame) else { return }
        connection.send(line)
        switch frame {
        case .hello, .utterance, .control: append(.sent, frame)
        default: break
        }
    }

    private func append(_ direction: FrameRecord.Direction, _ frame: Frame) {
        records.append(FrameRecord(id: nextRecordID, direction: direction, frame: frame))
        nextRecordID += 1
        if records.count > Self.recordLimit { records.removeFirst(records.count - Self.recordLimit) }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
