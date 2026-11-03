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

/// How one stream given to `SpeechAudioPlaying` ended.
public enum AudioPlaybackEnd: Equatable, Sendable {
    /// `endStream()` was called and everything appended has played.
    case finished
    /// `stop()` was called.
    case stopped
    /// The stream could not be decoded or played.
    case failed
}

/// Plays the Mac's voice for one `speech` frame at a time (RR-458): the
/// consecutive slices of one encoded stream, appended as they arrive and played
/// without gaps. The kit's `AudioQueueSpeechPlayer` plays AAC in ADTS framing;
/// tests use a fake. Exactly one completion per `startStream`.
@MainActor
public protocol SpeechAudioPlaying: AnyObject {
    func startStream(format: AudioFormat, sampleRate: Int,
                     completion: @escaping @MainActor (AudioPlaybackEnd) -> Void)
    /// The next consecutive slice of the stream.
    func append(_ data: Data)
    /// No more slices follow; completion reports `.finished` once they have played.
    func endStream()
    /// Stop now; completion reports `.stopped`.
    func stop()
}

/// Whether replies play as they arrive or wait for the user's Play (RR-458).
public enum PlaybackMode: String, CaseIterable, Sendable {
    case autoPlay
    case onDemand
}

/// What the queue's current reply is doing, for the state label (RR-458).
public enum PlaybackState: Equatable, Sendable {
    case idle
    /// A reply in the Mac's voice is due but no audio has reached the player yet.
    case buffering
    case playing
}

/// Arms a one-shot timer on the main actor. Firing late or for a superseded
/// stream is harmless: the queue checks a token before acting.
public typealias SpeechTimer = @MainActor (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Void

/// Plays `speech` frames in `seq` order and answers every Mac frame that carries a
/// `seq` with one `ack` (docs/specs/relay-remote.md, "Wire protocol").
///
/// - `played: true` leaves only after the frame finished playing, so the Mac's
///   realization record and played coverage stay truthful.
/// - A frame that was stopped, skipped, superseded by `speech_control`, or that
///   never speaks (`status`, `speech_control` itself) is acknowledged with
///   `played: false`.
/// - Acks leave in `seq` order, because the Mac trims its replay buffer through
///   the highest acknowledged seq. A frame waits behind earlier unresolved ones.
/// - A seq seen before is ignored, so a reconnect replay never speaks twice.
/// - A `speech` frame with `spoken_by: mac` is the Mac's own Kokoro speech
///   shown while Remote mode is off (RR-454): it is never synthesised here and
///   is acknowledged `played: true` at once, in seq order.
/// - A `speech` frame with `audio: true` plays the Mac's voice from the
///   `speech_audio` parts that follow it (RR-458), in part order whatever order
///   they arrive in, and a replayed part is dropped by `seq` and `part`. If no
///   audio arrives within `audioWait` of the frame's turn, or the Mac ends the
///   stream with an empty final part before any audio, or the player fails,
///   the text is synthesised instead. A stream that stops delivering for
///   `stallTimeout` ends with what it has and is acknowledged `played: false`.
/// - In `.onDemand` mode speech waits for `play()`; status and control frames
///   resolve as before.
@MainActor
public final class SpeechPlaybackQueue {
    public private(set) var isSpeaking = false
    public private(set) var currentSeq: Int?
    /// Fires with `true` when playback starts from idle and `false` when the
    /// queue drains; the app keeps the audio session active in between.
    public var onPlaybackStateChange: ((Bool) -> Void)?
    /// Fires after anything that may change `playbackState` or `waitingReply`.
    public var onChange: (() -> Void)?

    public var mode: PlaybackMode {
        didSet {
            guard mode != oldValue else { return }
            log(mode == .autoPlay ? "playback mode auto" : "playback mode on demand")
            pump()
        }
    }

    public var playbackState: PlaybackState {
        guard currentSeq != nil else { return .idle }
        return currentVoice == .pending ? .buffering : .playing
    }

    /// The newest reply waiting for `play()` in `.onDemand` mode.
    public var waitingReply: String? {
        guard mode == .onDemand else { return nil }
        return entries.last(where: { $0.state == .waiting && !$0.released })?.text
    }

    /// The highest seq a reconnect may resume after without losing audio: one
    /// below the first reply whose stream is still incomplete, so the Mac
    /// replays that frame with its parts. `nil` when nothing is missing.
    public var resumeCeiling: Int? {
        entries.first(where: { entry in
            guard let audio = entry.audio, !audio.ended, !audio.receivedAll else { return false }
            if case .resolved = entry.state { return false }
            return true
        }).map { $0.seq - 1 }
    }

    private enum State: Equatable {
        case waiting
        case speaking
        case resolved(played: Bool)
    }

    private enum Voice {
        /// Waiting for the first audio of the Mac's voice.
        case pending
        case player
        case synthesizer
    }

    private struct AudioStream {
        var parts: [Int: Data] = [:]
        var lastPart: Int?
        var format: AudioFormat = .aac
        var sampleRate = 24_000
        /// Parts handed to the player, which are always 0..<fed.
        var fed = 0
        var appendedBytes = 0
        /// The player was told no more slices follow, or the stream was abandoned.
        var ended = false
        /// Stopped short of its last part: acknowledged `played: false`.
        var truncated = false

        var receivedAll: Bool {
            guard let lastPart else { return false }
            return (0...lastPart).allSatisfy { parts[$0] != nil }
        }
    }

    private struct Entry {
        let seq: Int
        let text: String?
        var state: State
        var audio: AudioStream?
        /// Allowed to play in `.onDemand` mode.
        var released = false
    }

    private let synthesizer: SpeechSynthesizing
    private let player: SpeechAudioPlaying?
    private let audioWait: TimeInterval
    private let stallTimeout: TimeInterval
    private let schedule: SpeechTimer
    private let sendAck: (Ack) -> Void
    private let log: RemoteLogger
    private var entries: [Entry] = []
    private var ackedThrough = 0
    private var stoppedThrough = 0
    private var generation = 0
    private var timerToken = 0
    private var currentVoice: Voice?
    private var reportedSpeaking = false
    /// Set by `playNextReply()`: the next speech plays even in `.onDemand` mode.
    private var releaseNext = false

    /// - Parameters:
    ///   - player: plays `audio: true` frames in the Mac's voice; without one
    ///     every frame is synthesised.
    ///   - audioWait: how long a reply in the Mac's voice waits for its first
    ///     audio before the text is synthesised instead.
    ///   - stallTimeout: how long a started stream may go without a new part.
    public init(synthesizer: SpeechSynthesizing, player: SpeechAudioPlaying? = nil,
                mode: PlaybackMode = .autoPlay, audioWait: TimeInterval = 1.5,
                stallTimeout: TimeInterval = 15, schedule: SpeechTimer? = nil,
                log: RemoteLogger = .silent, sendAck: @escaping (Ack) -> Void) {
        self.synthesizer = synthesizer
        self.player = player
        self.mode = mode
        self.audioWait = audioWait
        self.stallTimeout = stallTimeout
        self.schedule = schedule ?? Self.mainTimer
        self.log = log
        self.sendAck = sendAck
    }

    public static let mainTimer: SpeechTimer = { delay, fire in
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            fire()
        }
    }

    /// Feed every inbound frame; frames without a `seq` other than
    /// `speech_audio` and `welcome` are ignored.
    public func receive(_ frame: Frame) {
        switch frame {
        case .speech(let speech):
            let audio = speech.audio == true && speech.spokenBy != .mac && player != nil ? AudioStream() : nil
            guard insert(seq: speech.seq, text: speech.text, audio: audio) else { return }
            if speech.spokenBy == .mac {
                resolve(seq: speech.seq, played: true)
                log("speech shown")
            } else if speech.seq <= stoppedThrough {
                resolve(seq: speech.seq, played: false)
                log("speech superseded")
            } else {
                if releaseNext, let index = index(of: speech.seq) {
                    entries[index].released = true
                    releaseNext = false
                }
                log(audio == nil ? "speech received" : "speech received with audio")
            }
        case .speechAudio(let part):
            receiveAudio(part)
        case .speechControl(let control):
            guard insert(seq: control.seq, text: nil, audio: nil) else { return }
            resolve(seq: control.seq, played: false)
            stoppedThrough = max(stoppedThrough, control.seq)
            log(control.action == .skip ? "speech control skip" : "speech control stop")
            discardPending(before: control.seq)
        case .status(let status):
            guard insert(seq: status.seq, text: nil, audio: nil) else { return }
            resolve(seq: status.seq, played: false)
        case .welcome(let welcome):
            // A server seq below what this queue already acknowledged means the
            // bridge restarted and numbering began again: nothing queued can be
            // acknowledged against the new sequence, so start over.
            guard welcome.serverSeq < ackedThrough else { return }
            log("speech queue reset")
            generation += 1
            silenceVoice()
            entries.removeAll()
            isSpeaking = false
            currentSeq = nil
            currentVoice = nil
            ackedThrough = welcome.serverSeq
            stoppedThrough = 0
            reportPlayback()
            onChange?()
            return
        default:
            return
        }
        pump()
    }

    /// The local stop button: silence everything that is queued or speaking.
    public func stopAll() {
        log("speech stopped locally")
        releaseNext = false
        discardPending(before: Int.max)
        pump()
    }

    /// The Play control in `.onDemand` mode: play the newest waiting reply.
    /// Older replies still waiting are skipped and acknowledged unplayed.
    public func play() {
        guard mode == .onDemand, let latest = entries.lastIndex(where: { $0.state == .waiting }) else { return }
        for index in entries.indices where index < latest && entries[index].state == .waiting {
            entries[index].state = .resolved(played: false)
        }
        entries[latest].released = true
        log("speech play requested")
        pump()
    }

    /// The user asked the Mac to replay: let the next reply play at once even
    /// in `.onDemand` mode, so Replay behaves the same in both modes.
    public func playNextReply() {
        releaseNext = true
    }

    // MARK: - Internals

    private func index(of seq: Int) -> Int? {
        entries.firstIndex(where: { $0.seq == seq })
    }

    /// Returns false for a duplicate seq.
    private func insert(seq: Int, text: String?, audio: AudioStream?) -> Bool {
        guard seq > ackedThrough, index(of: seq) == nil else {
            log("frame duplicate")
            return false
        }
        let entry = Entry(seq: seq, text: text, state: .waiting, audio: audio)
        if let index = entries.firstIndex(where: { $0.seq > seq }) {
            entries.insert(entry, at: index)
        } else {
            entries.append(entry)
        }
        return true
    }

    private func resolve(seq: Int, played: Bool) {
        guard let index = index(of: seq) else { return }
        entries[index].state = .resolved(played: played)
    }

    /// Resolve queued speech below `seq` as unplayed and stop a current one.
    private func discardPending(before seq: Int) {
        for index in entries.indices where entries[index].seq < seq && entries[index].state == .waiting {
            entries[index].state = .resolved(played: false)
        }
        if let current = currentSeq, current < seq {
            stopVoice()
        }
    }

    /// Stops whatever voices the current frame; its completion resolves it.
    private func stopVoice() {
        if currentVoice == .pending, let seq = currentSeq {
            finished(seq: seq, generation: generation, played: false)
        } else {
            silenceVoice()
        }
    }

    /// Stops the synthesizer or player now. After a `generation` bump their
    /// completion is ignored.
    private func silenceVoice() {
        switch currentVoice {
        case .synthesizer: synthesizer.stopSpeaking()
        case .player: player?.stop()
        case .pending, nil: break
        }
    }

    private func isPlayable(_ entry: Entry) -> Bool {
        entry.state == .waiting && (mode == .autoPlay || entry.released)
    }

    private func pump() {
        flushAcks()
        if !isSpeaking, let index = entries.firstIndex(where: isPlayable) {
            entries[index].state = .speaking
            isSpeaking = true
            currentSeq = entries[index].seq
            generation += 1
            reportPlayback()
            if entries[index].audio != nil {
                currentVoice = .pending
                armTimer(audioWait) { [weak self] in self?.audioWaitExpired() }
                feedPlayer()
            } else {
                synthesize(entries[index])
            }
        }
        reportPlayback()
        onChange?()
    }

    private func reportPlayback() {
        guard reportedSpeaking != isSpeaking else { return }
        reportedSpeaking = isSpeaking
        onPlaybackStateChange?(isSpeaking)
    }

    private func synthesize(_ entry: Entry) {
        currentVoice = .synthesizer
        let generation = self.generation
        synthesizer.speak(entry.text ?? "") { [weak self] played in
            self?.finished(seq: entry.seq, generation: generation, played: played)
        }
    }

    /// Falls back to the phone's own voice for the current frame.
    private func fallBack(_ event: String) {
        guard let seq = currentSeq, let index = index(of: seq) else { return }
        log(event)
        generation += 1
        silenceVoice()
        entries[index].audio?.ended = true
        synthesize(entries[index])
        onChange?()
    }

    private func receiveAudio(_ part: SpeechAudio) {
        guard let index = index(of: part.seq), var audio = entries[index].audio, !audio.ended,
              audio.parts[part.part] == nil else { return }
        if case .resolved = entries[index].state { return }
        let data: Data
        if let decoded = Data(base64Encoded: part.data) {
            data = decoded
        } else {
            log("speech audio part unreadable")
            data = Data()
        }
        audio.parts[part.part] = data
        audio.format = part.format
        audio.sampleRate = part.sampleRate
        if part.last == true { audio.lastPart = part.part }
        entries[index].audio = audio
        if currentSeq == part.seq {
            feedPlayer()
            onChange?()
        }
    }

    /// Hands the current frame's consecutive parts to the player and ends the
    /// stream after its last part.
    private func feedPlayer() {
        guard let seq = currentSeq, let index = index(of: seq), var audio = entries[index].audio,
              !audio.ended, currentVoice == .pending || currentVoice == .player, let player else { return }
        let generation = self.generation
        let before = audio.fed
        var slices: [Data] = []
        while let data = audio.parts[audio.fed] {
            audio.fed += 1
            if !data.isEmpty { slices.append(data) }
        }
        let complete = audio.lastPart.map { audio.fed > $0 } ?? false
        if audio.appendedBytes == 0 && slices.isEmpty {
            entries[index].audio = audio
            // An empty final part with nothing before it: the Mac's voice failed.
            if complete { fallBack("speech audio failed on the Mac, speaking text") }
            return
        }
        if currentVoice == .pending {
            currentVoice = .player
            player.startStream(format: audio.format, sampleRate: audio.sampleRate) { [weak self] end in
                self?.playerEnded(seq: seq, generation: generation, end: end)
            }
        }
        for slice in slices where generation == self.generation {
            audio.appendedBytes += slice.count
            player.append(slice)
        }
        // A player that failed has already handed over to the synthesizer.
        guard generation == self.generation else { return }
        if complete {
            audio.ended = true
            // An empty final part after some audio ends a stream the Mac could not finish.
            audio.truncated = audio.parts[audio.lastPart!]?.isEmpty == true
            entries[index].audio = audio
            player.endStream()
        } else {
            entries[index].audio = audio
            if audio.fed > before { armTimer(stallTimeout) { [weak self] in self?.streamStalled() } }
        }
    }

    private func armTimer(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
        timerToken += 1
        let token = timerToken
        let generation = self.generation
        schedule(delay) { [weak self] in
            guard let self, token == self.timerToken, generation == self.generation else { return }
            fire()
        }
    }

    private func audioWaitExpired() {
        guard currentVoice == .pending else { return }
        fallBack("speech audio missing, speaking text")
    }

    private func streamStalled() {
        guard currentVoice == .player, let seq = currentSeq, let index = index(of: seq),
              var audio = entries[index].audio, !audio.ended else { return }
        log("speech audio stalled")
        audio.ended = true
        audio.truncated = true
        entries[index].audio = audio
        player?.endStream()
    }

    private func playerEnded(seq: Int, generation: Int, end: AudioPlaybackEnd) {
        guard generation == self.generation, currentSeq == seq else { return }
        switch end {
        case .finished:
            let truncated = index(of: seq).flatMap { entries[$0].audio?.truncated } ?? false
            finished(seq: seq, generation: generation, played: !truncated)
        case .stopped:
            finished(seq: seq, generation: generation, played: false)
        case .failed:
            fallBack("speech audio could not play, speaking text")
        }
    }

    private func finished(seq: Int, generation: Int, played: Bool) {
        guard generation == self.generation, currentSeq == seq else { return }
        isSpeaking = false
        currentSeq = nil
        currentVoice = nil
        timerToken += 1
        resolve(seq: seq, played: played)
        log(played ? "speech played" : "speech stopped")
        pump()
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
