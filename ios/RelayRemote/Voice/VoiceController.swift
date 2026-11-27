import AVFoundation
import Foundation
import RelayRemoteKit
import RelayRemoteProtocol

/// Speech on the phone (RR-429): spoken requests become `utterance` frames,
/// `speech` frames play here in the Mac's voice (RR-458), never in the phone's
/// own (user, 2026-11-28), while the Mac stays silent, and the
/// stop, replay and cancel buttons send `control` frames. One utterance at a
/// time: `pressToTalkBegan` opens it and `pressToTalkEnded` sends it, whether
/// the Talk control is held or toggled (RR-540; there is no hands-free mode).
/// RR-540: controls name the agent they are for.
@MainActor
@Observable
final class VoiceController {
    enum Activity: Equatable {
        case idle
        case listening
        case hearing
        case transcribing
        case buffering
        case speaking
    }

    /// The Remote mode switch (RR-454): the microphone opens only while it is
    /// on. Off, the Mac listens and speaks; `speech` frames it voiced arrive
    /// with `spoken_by: mac` and the playback queue only shows them.
    var remoteMode = true {
        didSet { if remoteMode != oldValue { remoteModeChanged() } }
    }
    /// Auto-play, or wait for `play()` (RR-458).
    var playbackMode = PlaybackMode.autoPlay {
        didSet { queue.mode = playbackMode }
    }
    /// The newest reply waiting for Play in play-on-demand mode.
    private(set) var waitingReply: String?
    /// RR-540: every reply waiting for Play, oldest first, and the seq playing now.
    private(set) var waitingSeqs: [Int] = []
    private(set) var currentSeq: Int?
    /// A reply is playing or about to (its audio not here yet). Kept here, not
    /// read from the queue, so views that read it update when it changes.
    private(set) var isSpeaking = false
    /// Replay was pressed and its audio has not started, or a reply's audio
    /// has not arrived yet: the dock reads "Preparing message".
    private(set) var isPreparing = false
    private(set) var activity = Activity.idle
    private(set) var transcript = ""
    private(set) var isListening = false {
        didSet { syncHold() }
    }
    private(set) var lastProblem: String?
    var readiness: SpeechRecognizer.Readiness { recognizer.readiness }
    /// True while the audio session is active, that is while recording or playing.
    var isAudioActive: Bool { audio.isActive }
    /// Fires when recording and playback have both ended.
    @ObservationIgnored var onAudioIdle: (() -> Void)?
    /// RR-540: takes a finished transcript, so the app can file it in the
    /// agent's chat and send it to that agent. Without it the transcript goes
    /// to the focused agent.
    @ObservationIgnored var onSpokenRequest: ((String) -> Void)?

    @ObservationIgnored private let session: RemoteSession
    @ObservationIgnored private let audio = AudioSessionController()
    @ObservationIgnored private let player = AudioQueueSpeechPlayer()
    @ObservationIgnored private let recognizer = SpeechRecognizer()
    /// What the microphone hears, for the sound wave and the listening dots.
    @ObservationIgnored let micLevel = MicLevelMeter()
    @ObservationIgnored private let queue: SpeechPlaybackQueue
    @ObservationIgnored private var utteranceOpen = false {
        didSet { syncHold() }
    }
    /// Pressed again while the last utterance was still finishing: open a new
    /// one as soon as it has, without stopping the microphone in between.
    @ObservationIgnored private var openAfterClose = false
    /// The user let go (true) or cancelled (false) while the utterance was
    /// still opening; it closes that way once open.
    @ObservationIgnored private var closeWhenOpen: Bool?
    @ObservationIgnored private var busy = false
    /// Replay was pressed in Remote mode and its reply has not started playing.
    @ObservationIgnored private var replayPending = false {
        didSet { queueChanged() }
    }
    @ObservationIgnored private var replayTimeout: Task<Void, Never>?

    init(session: RemoteSession) {
        self.session = session
        // No synthesizer: the phone never speaks in its own voice. The Mac
        // has taken up to 9 s to voice a reply, so its audio gets 30 s.
        queue = SpeechPlaybackQueue(synthesizer: nil, player: player, audioWait: 30, log: .system) { [weak session] ack in
            session?.send(ack: ack)
        }
        queue.onPlaybackStateChange = { [weak self] speaking in self?.playbackChanged(speaking) }
        queue.onChange = { [weak self] in self?.queueChanged() }
        session.resumeCeiling = { [weak self] in self?.queue.resumeCeiling }
        recognizer.onTranscript = { [weak self] text in self?.transcript = text }
        recognizer.onVoiceLevel = { [weak self] level in self?.micLevel.update(level) }
        audio.onInterruption = { [weak self] interruption in self?.interrupted(interruption) }
        audio.onRouteLost = { [weak self] in self?.routeLost() }
        Task { await recognizer.prepare(prompting: false) }
    }

    /// RR-542: the tutorial waits for speech recognition to be ready, asking
    /// for the microphone if it is undecided. False when it cannot be used.
    func prepareSpeech() async -> Bool {
        await recognizer.prepare(prompting: true)
        while !Task.isCancelled {
            switch readiness {
            case .ready: return true
            case .unsupported, .microphoneDenied, .failed: return false
            case .unknown, .downloading: try? await Task.sleep(for: .milliseconds(300))
            }
        }
        return false
    }

    // MARK: - Talk

    /// Opens an utterance for `agent` (nil: the focused agent). The control
    /// and the glow respond at once: `isListening` turns on before the
    /// microphone and the analyzer have started, and a press while the last
    /// utterance is still being transcribed is kept rather than ignored.
    func pressToTalkBegan(agent: String? = nil) {
        guard remoteMode, !isListening else { return }
        isListening = true
        closeWhenOpen = nil
        bargeIn(agent: agent)
        if utteranceOpen || busy {
            openAfterClose = true
            return
        }
        Task { await openUtterance() }
    }

    /// The speech speed the Mac reports, applied to the Mac's voice on the phone.
    func setSpeechSpeed(_ speed: Double) {
        player.rate = Float(speed)
    }

    /// Finishes the utterance and sends its transcript.
    func pressToTalkEnded() {
        finishTalking(send: true)
    }

    /// RR-540: drops the utterance without sending it.
    func cancelTalking() {
        finishTalking(send: false)
    }

    private func finishTalking(send: Bool) {
        guard isListening else { return }
        isListening = false
        if utteranceOpen, !busy {
            Task { await closeUtterance(send: send) }
        } else {
            // A quick tap: close once the utterance has opened.
            closeWhenOpen = send
        }
    }

    // MARK: - Controls

    /// Starting to talk is the interrupt: silence the phone, tell the Mac to
    /// stop, and only then open the utterance. The local stop happens even
    /// when the channel is down. Replay is unaffected (the Mac keeps the reply).
    private func bargeIn(agent: String?) {
        replayPending = false
        queue.stopAll()
        session.send(control: .stop, agent: agent)
    }

    /// Silences the phone at once and asks the Mac to stop each of `agents`
    /// (empty: the focused agent).
    func stop(agents: [String] = []) {
        replayPending = false
        queue.stopAll()
        if agents.isEmpty {
            session.send(control: .stop)
        } else {
            for agent in agents { session.send(control: .stop, agent: agent) }
        }
    }

    /// The Play control in play-on-demand mode.
    func play() {
        queue.play()
    }

    /// RR-540: plays one agent's waiting reply, skipping its older ones.
    func play(seq: Int, skipping: Set<Int>) {
        queue.play(seq: seq, skipping: skipping)
    }

    /// The replayed reply plays at once in either playback mode.
    func replay(agent: String? = nil) {
        queue.playNextReply()
        session.send(control: .replay, agent: agent)
        // With Remote mode off the Mac plays the replay itself.
        guard remoteMode else { return }
        replayPending = true
        // The Mac sends the replay at once; nothing within 10 s means it had none.
        replayTimeout?.cancel()
        replayTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.replayPending = false
        }
    }

    func cancel() {
        replayPending = false
        queue.stopAll()
        session.send(control: .cancel)
    }

    /// RR-540: every inbound frame from the session, for the playback queue.
    func receive(_ frame: Frame) {
        if case .settingsState(let settings) = frame, let percent = settings.speechSpeedPercent {
            setSpeechSpeed(Double(percent) / 100)
        }
        queue.receive(frame)
    }

    /// RR-545: holds the audio session in the background for `reason`, or
    /// releases it. Returns whether the session is held. Releasing with nothing
    /// recording or playing reports the audio idle.
    @discardableResult
    func setKeepAlive(_ on: Bool, for reason: KeepAliveReason) -> Bool {
        let held = (try? audio.setKeepAlive(on, for: reason)) != nil && audio.isKeepingAlive
        if !on { notifyIfIdle() }
        return held
    }

    /// Called when the Mac is forgotten: release the microphone and speaker.
    func shutdown() {
        isListening = false
        player.stop()
        Task { await closeUtterance(send: false) }
    }

    // MARK: - Internals

    private func remoteModeChanged() {
        guard !remoteMode else { return }
        // The Mac owns the turn now: release the microphone and fall silent
        // without asking the Mac to stop its own speech.
        queue.stopAll()
        if isListening {
            isListening = false
            Task { await closeUtterance(send: false) }
        }
        transcript = ""
    }

    private func openUtterance() async {
        guard remoteMode, !utteranceOpen, !busy else { return }
        busy = true
        defer {
            busy = false
            if let send = closeWhenOpen {
                closeWhenOpen = nil
                Task { await closeUtterance(send: send) }
            }
        }
        if readiness != .ready {
            await recognizer.prepare(prompting: true)
        }
        guard readiness == .ready else {
            lastProblem = readinessProblem
            isListening = false
            return
        }
        do {
            try await audio.startRecording()
            try await recognizer.startUtterance()
            utteranceOpen = true
            transcript = ""
            lastProblem = nil
            if queue.isSpeaking {
                // Playback began while the utterance was opening.
                recognizer.pauseFeeding()
            } else {
                activity = .listening
            }
        } catch {
            lastProblem = "Recording could not start."
            isListening = false
            recognizer.stopCapture()
            try? audio.setRecording(false)
        }
    }

    private func closeUtterance(send: Bool) async {
        guard utteranceOpen, !busy else { return }
        busy = true
        let text: String
        if send {
            activity = .transcribing
            text = await recognizer.finishUtterance()
        } else {
            await recognizer.cancelUtterance()
            text = ""
        }
        utteranceOpen = false
        busy = false
        if !text.isEmpty {
            if let onSpokenRequest {
                onSpokenRequest(text)
            } else {
                session.send(text: text)
            }
        }
        // The text box shows the transcript only while the user talks.
        transcript = ""
        let reopen = openAfterClose && isListening
        openAfterClose = false
        if reopen {
            // Pressed again while this one finished: keep the microphone open.
            Task { await openUtterance() }
            return
        }
        recognizer.stopCapture()
        try? audio.setRecording(false)
        refreshActivity()
        notifyIfIdle()
    }

    private func playbackChanged(_ speaking: Bool) {
        try? audio.setPlaying(speaking)
        if speaking {
            activity = .speaking
            if utteranceOpen {
                // Do not transcribe the phone's own voice.
                recognizer.pauseFeeding()
            }
        } else {
            refreshActivity()
            if utteranceOpen {
                // Audio heard during playback was dropped; resume from here.
                recognizer.resumeFeeding()
            } else {
                notifyIfIdle()
            }
        }
    }

    private func interrupted(_ interruption: AudioSessionController.Interruption) {
        switch interruption {
        case .began:
            if queue.isSpeaking {
                player.pause()
            }
            if utteranceOpen {
                isListening = false
                Task { await closeUtterance(send: false) }
            }
        case .ended(let shouldResume):
            audio.reactivate()
            if player.isPaused {
                if shouldResume { player.resume() } else { player.stop() }
            }
        }
    }

    private func routeLost() {
        guard utteranceOpen else { return }
        isListening = false
        Task { await closeUtterance(send: false) }
    }

    private func queueChanged() {
        waitingReply = queue.waitingReply
        waitingSeqs = queue.waitingSeqs
        currentSeq = queue.currentSeq
        isSpeaking = queue.isSpeaking
        // The replay is under way once its audio plays (or anything else does).
        if replayPending, queue.playbackState == .playing {
            replayPending = false
            replayTimeout?.cancel()
        }
        isPreparing = replayPending || queue.playbackState == .buffering
        if queue.isSpeaking { refreshActivity() }
    }

    private func refreshActivity() {
        if queue.isSpeaking {
            activity = queue.playbackState == .buffering ? .buffering : .speaking
        } else if utteranceOpen {
            activity = .listening
        } else {
            activity = .idle
        }
    }

    /// Replies wait while the user is talking or their words are still being
    /// transcribed, then play in turn.
    private func syncHold() {
        queue.isHeld = isListening || utteranceOpen
    }

    private func notifyIfIdle() {
        if !audio.isActive { onAudioIdle?() }
    }

    private var readinessProblem: String {
        switch readiness {
        case .unknown, .downloading: return "The speech model is still being prepared."
        case .unsupported: return "On-device speech recognition is not available for this language on this iPhone."
        case .microphoneDenied: return "Allow microphone access in Settings to speak to your Mac."
        case .failed: return "The speech model could not be installed."
        case .ready: return ""
        }
    }
}
