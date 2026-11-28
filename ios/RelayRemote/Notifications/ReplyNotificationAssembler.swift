import Foundation
import RelayRemoteKit
import RelayRemoteProtocol

/// One agent reply ready to post as a local notification (RR-545).
struct ReplyNotice: Equatable {
    /// The agent's slug.
    let agent: String
    /// The seq of the reply's first `speech` frame, which names the notification.
    let seq: Int
    let body: String
}

/// Joins the `speech` frames of one reply into one notification (RR-545). A
/// reply is the frames one agent speaks for one Relay command
/// (`relay_command_seq`): a handoff, any progress, then the `final`,
/// `clarification` or `fallback` that ends it. A frame with no command is a
/// reply of its own, as is a lifecycle update. A reply still open when the
/// same agent starts another is posted as it stands.
struct ReplyNotificationAssembler {
    /// The body's length on the lock screen: a few lines, not the whole reply.
    static let bodyLimit = 240
    private static let seenLimit = 400

    private struct OpenReply {
        let command: Int
        let seq: Int
        var texts: [String]
    }

    private var open: [String: OpenReply] = [:]
    /// Frames replayed after a reconnect are not counted twice.
    private var seen: [Int] = []

    /// Takes one `speech` frame filed under `agent` and returns the replies it
    /// completes, oldest first; usually none or one.
    mutating func receive(_ speech: Speech, agent: String) -> [ReplyNotice] {
        guard !seen.contains(speech.seq) else { return [] }
        seen.append(speech.seq)
        if seen.count > Self.seenLimit { seen.removeFirst(seen.count - Self.seenLimit) }
        // `control` speech acknowledges a stop or cancel; it is not a reply.
        let text = speech.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard speech.kind != .control, !text.isEmpty else { return [] }

        var done: [ReplyNotice] = []
        if let pending = open[agent], pending.command != speech.relayCommandSeq {
            done.append(Self.notice(agent: agent, seq: pending.seq, texts: pending.texts))
            open[agent] = nil
        }
        guard let command = speech.relayCommandSeq else {
            done.append(Self.notice(agent: agent, seq: speech.seq, texts: [text]))
            return done
        }
        var reply = open[agent] ?? OpenReply(command: command, seq: speech.seq, texts: [])
        reply.texts.append(text)
        if Self.endsReply(speech.kind) {
            done.append(Self.notice(agent: agent, seq: reply.seq, texts: reply.texts))
            open[agent] = nil
        } else {
            open[agent] = reply
        }
        return done
    }

    static func endsReply(_ kind: SpeechKind) -> Bool {
        switch kind {
        case .final, .clarification, .fallback: return true
        case .handoff, .progress, .control: return false
        }
    }

    /// The frames' text joined into one line and cut at a word near `bodyLimit`.
    static func body(_ texts: [String]) -> String {
        let joined = texts.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard joined.count > bodyLimit else { return joined }
        let cut = joined.prefix(bodyLimit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    private static func notice(agent: String, seq: Int, texts: [String]) -> ReplyNotice {
        ReplyNotice(agent: agent, seq: seq, body: body(texts))
    }
}

/// The lost-connection rule (RR-545): in the background the session's own
/// reconnects get `attemptLimit` tries; when none of them gets through, or the
/// Mac refuses the phone outright, the connection is lost. It is reported once
/// and not again until the app has been opened, which makes a new watch.
struct ConnectionLossWatch {
    /// Six backoff waits are the drop itself and five failed reconnects, about
    /// 16–32 s of backoff plus the connection attempts (`Backoff`).
    static let attemptLimit = 6

    private(set) var failedAttempts = 0
    private(set) var reported = false

    /// Takes the session's next state; true when the loss is to be reported now.
    mutating func observe(_ state: RemoteSession.State) -> Bool {
        switch state {
        case .connected, .connectedToApp:
            failedAttempts = 0
            return false
        case .idle, .connecting:
            return false
        case .waiting:
            failedAttempts += 1
        case .failed:
            failedAttempts = Self.attemptLimit
        }
        guard !reported, failedAttempts >= Self.attemptLimit else { return false }
        reported = true
        return true
    }
}
