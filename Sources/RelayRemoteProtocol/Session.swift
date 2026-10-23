import Foundation

/// Per-device monotonically increasing sequence for Mac-to-phone frames.
public struct SeqCounter: Sendable {
    public private(set) var last: Int

    public init(last: Int = 0) { self.last = last }

    public mutating func next() -> Int {
        last += 1
        return last
    }
}

/// Remembers the most recent `window` client ids so a retry after a reconnect
/// never becomes a second command. A duplicate does not refresh its position.
public struct ClientIDDeduplicator: Sendable {
    public static let defaultWindow = 1024

    private let window: Int
    private var order: [String] = []
    private var seen: Set<String> = []

    public init(window: Int = ClientIDDeduplicator.defaultWindow) { self.window = window }

    /// Returns true when `clientId` was already seen inside the window.
    public mutating func isDuplicate(_ clientId: String) -> Bool {
        let key = clientId.lowercased()
        if seen.contains(key) { return true }
        seen.insert(key)
        order.append(key)
        if order.count > window { seen.remove(order.removeFirst()) }
        return false
    }
}

/// Holds the last 200 sequenced Mac-to-phone frames or five minutes, whichever
/// is smaller, trimmed by `ack`. Time is passed in so behaviour is deterministic.
public struct ReplayBuffer: Sendable {
    public static let maxFrames = 200
    public static let maxAge: Double = 300

    public struct Resume: Equatable, Sendable {
        public var frames: [Frame]
        public var dropped: Bool
        public var serverSeq: Int
    }

    private struct Entry: Sendable {
        var seq: Int
        var frame: Frame
        var at: Double
    }

    private var entries: [Entry] = []
    private var highestAcked = 0
    public private(set) var serverSeq = 0

    public init() {}

    public mutating func record(_ frame: Frame, at now: Double) throws {
        guard let seq = frame.seq, seq > serverSeq else { throw FrameError.invalidField("seq") }
        serverSeq = seq
        entries.append(Entry(seq: seq, frame: frame, at: now))
        prune(now: now)
    }

    public mutating func ack(_ seq: Int) {
        guard seq <= serverSeq else { return }
        highestAcked = max(highestAcked, seq)
        entries.removeAll { $0.seq <= highestAcked }
    }

    /// Frames after `after` in order, and whether any missed frame is gone.
    /// `nil` is a fresh connection: nothing to replay and nothing missed.
    public mutating func resume(after: Int?, at now: Double) -> Resume {
        prune(now: now)
        guard let after else { return Resume(frames: [], dropped: false, serverSeq: serverSeq) }
        guard after <= serverSeq else { return Resume(frames: [], dropped: true, serverSeq: serverSeq) }
        let effective = max(after, highestAcked)
        let frames = entries.filter { $0.seq > effective }.map(\.frame)
        let dropped = effective < serverSeq && (frames.first?.seq ?? Int.max) > effective + 1
        return Resume(frames: frames, dropped: dropped, serverSeq: serverSeq)
    }

    private mutating func prune(now: Double) {
        entries.removeAll { now - $0.at > Self.maxAge }
        if entries.count > Self.maxFrames { entries.removeFirst(entries.count - Self.maxFrames) }
    }
}
