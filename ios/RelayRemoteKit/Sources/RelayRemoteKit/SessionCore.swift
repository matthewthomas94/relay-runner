import Foundation
import RelayRemoteProtocol

/// A typed utterance waiting for the Mac's `accepted` receipt.
public struct PendingUtterance: Equatable, Sendable, Identifiable {
    public var id: String { utterance.clientId }
    public let utterance: Utterance
    /// Monotonic seconds when it was queued.
    public let queuedAt: Double
}

/// The phone side of the wire protocol (docs/specs/relay-remote.md, "Wire
/// protocol"), free of I/O and clocks so it can be tested directly.
///
/// - `hello` carries `resume_after_seq`, the highest Mac seq received.
/// - Every sequenced Mac frame is answered with `ack`, duplicates included, so
///   the Mac's replay buffer trims. Until speech exists (RR-429) acks say
///   `played: false`, which the coordinator records as receipt only.
/// - Utterances stay queued until `accepted` and are resent with their
///   original `client_id` after every `welcome`; the Mac de-duplicates them.
public struct SessionCore: Sendable {
    public struct Reaction: Equatable, Sendable {
        /// Frames to send now, in order.
        public var send: [Frame] = []
        /// True when the frame is new and belongs on the debug screen.
        public var isNew = false
        /// Utterances dropped because they outlived `outboxLifetime`.
        public var expired: [PendingUtterance] = []
    }

    public let deviceID: String
    public let deviceName: String
    public let appVersion: String
    /// Utterances older than this are not resent: a typed or spoken command
    /// should not run minutes after the user gave up on it.
    public let outboxLifetime: Double

    public private(set) var lastSeq: Int?
    public private(set) var pending: [PendingUtterance] = []
    public private(set) var welcome: Welcome?
    public private(set) var missedUpdates = false
    public private(set) var lastError: ErrorFrame?
    /// `welcome.server_seq` until the first `pong` after it. The Mac writes
    /// `welcome` and every replayed frame before it reads our next line, so
    /// that pong proves the replay is complete even when nothing was replayed.
    private var replayBarrier: Int?

    public init(deviceID: String, deviceName: String, appVersion: String, resumeAfterSeq: Int?,
                outboxLifetime: Double = ReplayBuffer.maxAge) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.lastSeq = resumeAfterSeq
        self.outboxLifetime = outboxLifetime
    }

    public var isWelcomed: Bool { welcome != nil }

    /// The channel is open: the `hello` that must be the first frame.
    public mutating func connectionOpened() -> Hello {
        welcome = nil
        replayBarrier = nil
        return Hello(deviceId: deviceID, deviceName: deviceName, appVersion: appVersion, resumeAfterSeq: lastSeq)
    }

    public mutating func connectionClosed() {
        welcome = nil
        replayBarrier = nil
    }

    /// Queues an utterance; returns it when it can be sent right away.
    public mutating func enqueue(_ utterance: Utterance, now: Double) -> Utterance? {
        pending.append(PendingUtterance(utterance: utterance, queuedAt: now))
        return isWelcomed ? utterance : nil
    }

    public mutating func clearMissedUpdates() {
        missedUpdates = false
    }

    public mutating func receive(_ frame: Frame, now: Double) -> Reaction {
        var reaction = Reaction()
        switch frame {
        case .welcome(let welcome):
            let requested = lastSeq
            if requested == nil || requested! > welcome.serverSeq {
                // A fresh device, or the bridge restarted and its seq began
                // again: adopt the Mac's position or every new frame would
                // look like a duplicate.
                lastSeq = welcome.serverSeq
            } else {
                replayBarrier = welcome.serverSeq
            }
            if welcome.dropped { missedUpdates = true }
            self.welcome = welcome
            reaction.expired = pending.filter { now - $0.queuedAt > outboxLifetime }
            pending.removeAll { now - $0.queuedAt > outboxLifetime }
            reaction.send = pending.map { .utterance($0.utterance) }
            reaction.isNew = true
        case .accepted(let accepted):
            let before = pending.count
            pending.removeAll { $0.utterance.clientId.caseInsensitiveCompare(accepted.clientId) == .orderedSame }
            reaction.isNew = pending.count < before
        case .speech, .speechControl, .status:
            // Acknowledged by the app once the frame has played or been
            // skipped (SpeechPlaybackQueue), never here: the Mac honours only
            // the first ack per seq, so an early `played: false` would hide
            // the real outcome.
            let seq = frame.seq!
            if seq > (lastSeq ?? 0) {
                lastSeq = seq
                reaction.isNew = true
            }
        case .pong:
            if let barrier = replayBarrier {
                lastSeq = max(lastSeq ?? 0, barrier)
                replayBarrier = nil
            }
        case .error(let error):
            // Not fatal: the Mac closes the channel itself when it gives up.
            lastError = error
            reaction.isNew = true
        case .hello, .utterance, .control, .ack, .ping:
            break
        }
        return reaction
    }
}
