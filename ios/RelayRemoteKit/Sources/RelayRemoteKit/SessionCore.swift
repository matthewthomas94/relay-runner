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
/// - With no session running, the helper joins the channel to Relay Runner's
///   session-control socket instead (RR-456): `session_state` arrives where
///   `welcome` would. Once that session is `ready` the channel is closed and
///   reopened so the helper attaches to the new voice bridge.
public struct SessionCore: Sendable {
    /// When to reopen a session-control channel whose session became ready.
    public enum Reattach: Equatable, Sendable {
        /// The phone watched it start on this channel: reconnect at once.
        case now
        /// It was already ready on arrival, so the helper raced the bridge;
        /// back off so a Mac that keeps answering this way is not hammered.
        case afterBackoff
    }

    public struct Reaction: Equatable, Sendable {
        /// Frames to send now, in order.
        public var send: [Frame] = []
        /// True when the frame is new and belongs on the debug screen.
        public var isNew = false
        /// Utterances dropped because they outlived `outboxLifetime`.
        public var expired: [PendingUtterance] = []
        /// Close this channel and reconnect to attach to the session.
        public var reattach: Reattach?
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
    /// The Remote mode switch (RR-454), carried by every `hello`.
    public var remoteMode: Bool
    /// The Mac's latest `session_state` (RR-456), across connections. A
    /// state without `projects` keeps the last list.
    public private(set) var macSession: SessionState?
    /// The Mac's reason for a refused or failed session command, kept until
    /// the next command or until the session changes on its own.
    public private(set) var sessionError: String?
    /// The helper last reported that Relay Runner is not running on the Mac.
    /// Cleared by the next channel that gets further, or by a transport failure.
    public private(set) var appUnavailable = false
    /// This channel reached Relay Runner's session-control socket: there is
    /// no voice bridge, but sessions can be listed, started and stopped.
    public private(set) var isControlLink = false
    /// The session phase last reported on this channel.
    private var channelPhase: SessionPhase?
    /// `welcome.server_seq` until the first `pong` after it. The Mac writes
    /// `welcome` and every replayed frame before it reads our next line, so
    /// that pong proves the replay is complete even when nothing was replayed.
    private var replayBarrier: Int?

    public init(deviceID: String, deviceName: String, appVersion: String, resumeAfterSeq: Int?,
                remoteMode: Bool = true, outboxLifetime: Double = ReplayBuffer.maxAge) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.lastSeq = resumeAfterSeq
        self.remoteMode = remoteMode
        self.outboxLifetime = outboxLifetime
    }

    public var isWelcomed: Bool { welcome != nil }
    /// Welcomed by a voice bridge, or answered by the session-control socket.
    public var isEstablished: Bool { isWelcomed || isControlLink }

    /// The channel is open: the `hello` that must be the first frame.
    public mutating func connectionOpened() -> Hello {
        welcome = nil
        replayBarrier = nil
        isControlLink = false
        channelPhase = nil
        return Hello(deviceId: deviceID, deviceName: deviceName, appVersion: appVersion, resumeAfterSeq: lastSeq,
                     remoteMode: remoteMode)
    }

    public mutating func connectionClosed() {
        welcome = nil
        replayBarrier = nil
        isControlLink = false
        channelPhase = nil
    }

    /// No channel opened, or it failed: the Mac itself was not reached.
    public mutating func connectionFailed() {
        appUnavailable = false
    }

    /// A session command is about to go out; its answer replaces the old reason.
    public mutating func sessionCommandSent() {
        sessionError = nil
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
            appUnavailable = false
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
        case .sessionState(var state):
            let previous = macSession
            if state.projects == nil { state.projects = previous?.projects }
            if let error = state.error {
                sessionError = error
            } else if previous?.session != state.session || previous?.appRunning != state.appRunning {
                sessionError = nil
            }
            macSession = state
            appUnavailable = !state.appRunning
            if !isWelcomed, state.appRunning { isControlLink = true }
            if isControlLink, state.session == .ready {
                let watchedItStart = channelPhase != nil && channelPhase != .ready
                reaction.reattach = watchedItStart ? .now : .afterBackoff
            }
            channelPhase = state.session
            reaction.isNew = true
        case .speechAudio:
            // The Mac's voice for an earlier `speech` frame (RR-457). It takes no
            // seq of its own, so it never moves the resume point.
            break
        case .hello, .utterance, .control, .remoteMode, .sessionCommand, .ack, .ping:
            break
        }
        return reaction
    }
}
