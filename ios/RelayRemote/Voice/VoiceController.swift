import AVFoundation
import Foundation
import RelayRemoteKit
import RelayRemoteProtocol

/// Speech on the phone (RR-429): spoken requests become `utterance` frames,
/// `speech` frames are spoken here while the Mac stays silent, and the stop,
/// replay and cancel buttons send `control` frames. Two input modes: push to
/// talk (hold the button) and hands-free (continuous listening with the kit's
/// endpointer deciding where an utterance ends).
@MainActor
@Observable
final class VoiceController {
    enum Mode: String, CaseIterable {
        case pushToTalk = "Push to talk"
        case handsFree = "Hands-free"
    }

    enum Activity: Equatable {
        case idle
        case listening
        case hearing
        case transcribing
        case speaking
    }

    var mode = Mode.pushToTalk {
        didSet { if mode != oldValue { modeChanged() } }
    }
    private(set) var activity = Activity.idle
    private(set) var transcript = ""
    private(set) var isListening = false
    private(set) var lastProblem: String?
    var readiness: SpeechRecognizer.Readiness { recognizer.readiness }
    var isSpeaking: Bool { queue.isSpeaking }
    /// True while the audio session is active, that is while recording or playing.
    var isAudioActive: Bool { audio.isActive }
    /// Fires when recording and playback have both ended.
    @ObservationIgnored var onAudioIdle: (() -> Void)?

    @ObservationIgnored private let session: RemoteSession
    @ObservationIgnored private let audio = AudioSessionController()
    @ObservationIgnored private let synthesizer = SystemSpeechSynthesizer()
    @ObservationIgnored private let recognizer = SpeechRecognizer()
    @ObservationIgnored private let queue: SpeechPlaybackQueue
    @ObservationIgnored private var endpointer = UtteranceEndpointer()
    @ObservationIgnored private var utteranceOpen = false
    @ObservationIgnored private var busy = false

    init(session: RemoteSession) {
        self.session = session
        queue = SpeechPlaybackQueue(synthesizer: synthesizer, log: .system) { [weak session] ack in
            session?.send(ack: ack)
        }
        queue.onPlaybackStateChange = { [weak self] speaking in self?.playbackChanged(speaking) }
        session.onInbound = { [weak self] frame in self?.queue.receive(frame) }
        recognizer.onLevel = { [weak self] level, time in self?.observeLevel(level, at: time) }
        recognizer.onTranscript = { [weak self] text in self?.transcript = text }
        audio.onInterruption = { [weak self] interruption in self?.interrupted(interruption) }
        audio.onRouteLost = { [weak self] in self?.routeLost() }
        Task { await recognizer.prepare(prompting: false) }
    }

    // MARK: - Push to talk

    func pressToTalkBegan() {
        guard mode == .pushToTalk, !utteranceOpen, !busy else { return }
        isListening = true
        Task { await openUtterance() }
    }

    func pressToTalkEnded() {
        guard mode == .pushToTalk else { return }
        isListening = false
        Task { await closeUtterance(send: true) }
    }

    // MARK: - Hands-free

    func startListening() {
        guard mode == .handsFree, !isListening else { return }
        isListening = true
        endpointer = UtteranceEndpointer()
        Task { await openUtterance() }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        Task { await closeUtterance(send: false) }
    }

    // MARK: - Controls

    /// Silences the phone at once and asks the Mac to stop as well.
    func stop() {
        queue.stopAll()
        session.send(control: .stop)
    }

    func replay() {
        session.send(control: .replay)
    }

    func cancel() {
        queue.stopAll()
        session.send(control: .cancel)
    }

    /// Called when the Mac is forgotten: release the microphone and speaker.
    func shutdown() {
        isListening = false
        synthesizer.stopSpeaking()
        Task { await closeUtterance(send: false) }
    }

    // MARK: - Internals

    private func modeChanged() {
        if isListening {
            isListening = false
            Task { await closeUtterance(send: false) }
        }
        transcript = ""
    }

    private func openUtterance() async {
        guard !utteranceOpen, !busy else { return }
        busy = true
        defer { busy = false }
        if readiness != .ready {
            await recognizer.prepare(prompting: true)
        }
        guard readiness == .ready else {
            lastProblem = readinessProblem
            isListening = false
            return
        }
        do {
            try audio.setRecording(true)
            try await recognizer.startUtterance()
            utteranceOpen = true
            transcript = ""
            lastProblem = nil
            endpointer.reset()
            if !queue.isSpeaking { activity = .listening }
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
            session.send(text: text)
            transcript = text
        } else if send {
            transcript = ""
        }
        let keepMicrophone = mode == .handsFree && isListening
        if !keepMicrophone {
            recognizer.stopCapture()
            try? audio.setRecording(false)
        }
        refreshActivity()
        continueHandsFreeIfNeeded()
        notifyIfIdle()
    }

    /// Hands-free keeps one utterance open whenever the phone is not speaking.
    private func continueHandsFreeIfNeeded() {
        guard mode == .handsFree, isListening, !utteranceOpen, !busy, !queue.isSpeaking else { return }
        Task { await openUtterance() }
    }

    private func observeLevel(_ level: Float, at time: TimeInterval) {
        guard mode == .handsFree, isListening, utteranceOpen, !busy, !queue.isSpeaking else { return }
        switch endpointer.observe(level: level, at: time) {
        case .none:
            break
        case .started:
            activity = .hearing
        case .ended:
            Task { await closeUtterance(send: true) }
        case .discarded:
            Task { await closeUtterance(send: false) }
        }
    }

    private func playbackChanged(_ speaking: Bool) {
        try? audio.setPlaying(speaking)
        if speaking {
            activity = .speaking
            if utteranceOpen {
                // Do not transcribe the phone's own voice.
                recognizer.pauseFeeding()
                endpointer.reset()
            }
        } else {
            refreshActivity()
            if mode == .handsFree, isListening, utteranceOpen {
                Task {
                    await closeUtterance(send: false)
                }
            } else {
                notifyIfIdle()
            }
        }
    }

    private func interrupted(_ interruption: AudioSessionController.Interruption) {
        switch interruption {
        case .began:
            if queue.isSpeaking { synthesizer.pause() }
            if utteranceOpen {
                if mode == .pushToTalk { isListening = false }
                Task { await closeUtterance(send: false) }
            }
        case .ended(let shouldResume):
            audio.reactivate()
            if synthesizer.isPaused {
                if shouldResume { synthesizer.resume() } else { synthesizer.stopSpeaking() }
            }
            continueHandsFreeIfNeeded()
        }
    }

    private func routeLost() {
        guard utteranceOpen else { return }
        if mode == .pushToTalk { isListening = false }
        Task { await closeUtterance(send: false) }
    }

    private func refreshActivity() {
        if queue.isSpeaking {
            activity = .speaking
        } else if utteranceOpen {
            activity = .listening
        } else {
            activity = .idle
        }
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
