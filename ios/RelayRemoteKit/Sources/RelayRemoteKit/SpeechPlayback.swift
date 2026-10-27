import Foundation
import RelayRemoteProtocol

/// Speaks one text at a time for `SpeechPlaybackQueue`. The app adapts
/// `AVSpeechSynthesizer`; tests use a fake. Exactly one completion per `speak`:
/// `true` when the text finished, `false` when it was stopped early.
@MainActor
public protocol SpeechSynthesizing: AnyObject {
    func speak(_ text: String, completion: @escaping @MainActor (Bool) -> Void)
    /// Stop the current text now. Its completion must then report `false`.
    func stopSpeaking()
}

/// Plays `speech` frames in `seq` order and answers every Mac frame that carries a
/// `seq` with one `ack` (docs/specs/relay-remote.md, "Wire protocol").
///
/// - `played: true` leaves only after the synthesizer finished the text, so the
///   Mac's realization record and played coverage stay truthful.
/// - A frame that was stopped, skipped, superseded by `speech_control`, or that
///   never speaks (`status`, `speech_control` itself) is acknowledged with
///   `played: false`.
/// - Acks leave in `seq` order, because the Mac trims its replay buffer through
///   the highest acknowledged seq. A frame waits behind earlier unresolved ones.
/// - A seq seen before is ignored, so a reconnect replay never speaks twice.
@MainActor
public final class SpeechPlaybackQueue {
    public private(set) var isSpeaking = false
    public private(set) var currentSeq: Int?
    /// Fires with `true` when playback starts from idle and `false` when the
    /// queue drains; the app keeps the audio session active in between.
    public var onPlaybackStateChange: ((Bool) -> Void)?

    private enum State: Equatable {
        case waiting
        case speaking
        case resolved(played: Bool)
    }

    private struct Entry {
        let seq: Int
        let text: String?
        var state: State
    }

    private let synthesizer: SpeechSynthesizing
    private let sendAck: (Ack) -> Void
    private let log: RemoteLogger
    private var entries: [Entry] = []
    private var ackedThrough = 0
    private var stoppedThrough = 0
    private var generation = 0

    public init(synthesizer: SpeechSynthesizing, log: RemoteLogger = .silent,
                sendAck: @escaping (Ack) -> Void) {
        self.synthesizer = synthesizer
        self.log = log
        self.sendAck = sendAck
    }

    /// Feed every inbound frame; frames without a `seq` are ignored.
    public func receive(_ frame: Frame) {
        switch frame {
        case .speech(let speech):
            guard insert(seq: speech.seq, text: speech.text) else { return }
            if speech.seq <= stoppedThrough {
                resolve(seq: speech.seq, played: false)
                log("speech superseded")
            } else {
                log("speech received")
            }
        case .speechControl(let control):
            guard insert(seq: control.seq, text: nil) else { return }
            resolve(seq: control.seq, played: false)
            stoppedThrough = max(stoppedThrough, control.seq)
            log(control.action == .skip ? "speech control skip" : "speech control stop")
            discardPending(before: control.seq)
        case .status(let status):
            guard insert(seq: status.seq, text: nil) else { return }
            resolve(seq: status.seq, played: false)
        case .welcome(let welcome):
            // A server seq below what this queue already acknowledged means the
            // bridge restarted and numbering began again: nothing queued can be
            // acknowledged against the new sequence, so start over.
            guard welcome.serverSeq < ackedThrough else { return }
            log("speech queue reset")
            generation += 1
            let wasSpeaking = isSpeaking
            if wasSpeaking { synthesizer.stopSpeaking() }
            entries.removeAll()
            isSpeaking = false
            currentSeq = nil
            ackedThrough = welcome.serverSeq
            stoppedThrough = 0
            if wasSpeaking { onPlaybackStateChange?(false) }
            return
        default:
            return
        }
        pump()
    }

    /// The local stop button: silence everything that is queued or speaking.
    public func stopAll() {
        log("speech stopped locally")
        discardPending(before: Int.max)
        pump()
    }

    // MARK: - Internals

    /// Returns false for a duplicate seq.
    private func insert(seq: Int, text: String?) -> Bool {
        guard seq > ackedThrough, !entries.contains(where: { $0.seq == seq }) else {
            log("frame duplicate")
            return false
        }
        let entry = Entry(seq: seq, text: text, state: .waiting)
        if let index = entries.firstIndex(where: { $0.seq > seq }) {
            entries.insert(entry, at: index)
        } else {
            entries.append(entry)
        }
        return true
    }

    private func resolve(seq: Int, played: Bool) {
        guard let index = entries.firstIndex(where: { $0.seq == seq }) else { return }
        entries[index].state = .resolved(played: played)
    }

    /// Resolve queued speech below `seq` as unplayed and stop a current one.
    private func discardPending(before seq: Int) {
        for index in entries.indices where entries[index].seq < seq && entries[index].state == .waiting {
            entries[index].state = .resolved(played: false)
        }
        if let current = currentSeq, current < seq {
            synthesizer.stopSpeaking()
        }
    }

    private func pump(wasSpeaking: Bool? = nil) {
        let wasSpeaking = wasSpeaking ?? isSpeaking
        flushAcks()
        if !isSpeaking, let index = entries.firstIndex(where: { $0.state == .waiting }) {
            let entry = entries[index]
            entries[index].state = .speaking
            isSpeaking = true
            currentSeq = entry.seq
            generation += 1
            let generation = self.generation
            synthesizer.speak(entry.text ?? "") { [weak self] played in
                self?.finished(seq: entry.seq, generation: generation, played: played)
            }
        }
        if wasSpeaking != isSpeaking {
            onPlaybackStateChange?(isSpeaking)
        }
    }

    private func finished(seq: Int, generation: Int, played: Bool) {
        guard generation == self.generation, currentSeq == seq else { return }
        isSpeaking = false
        currentSeq = nil
        resolve(seq: seq, played: played)
        log(played ? "speech played" : "speech stopped")
        pump(wasSpeaking: true)
    }

    /// Send acks for resolved frames at the head of the queue, in seq order.
    private func flushAcks() {
        while let head = entries.first, case .resolved(let played) = head.state {
            entries.removeFirst()
            ackedThrough = max(ackedThrough, head.seq)
            sendAck(Ack(seq: head.seq, played: played))
        }
    }
}
