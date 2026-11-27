import Foundation

/// The tutorial's six steps (screens 15–20).
enum TutorialStep: Int, CaseIterable, Equatable {
    case basics, holdToTalk, releaseToSend, playReply, stopPlayback, allDone

    /// The dock controls that stay lit. Everything else is dimmed to 30% and
    /// takes no touches, as does the tab bar.
    var litControls: Set<DockControl> {
        switch self {
        case .basics, .allDone: return []
        case .playReply: return [.replay]
        case .holdToTalk: return [.talk]
        case .releaseToSend: return [.talk, .textBox]
        case .stopPlayback: return [.stop]
        }
    }

    /// The real dock and tab bar show from the first action on, until the closing line.
    var showsDock: Bool { self != .basics && self != .allDone }
}

/// Why the tutorial can't go on without the user leaving. Each shows as one
/// short line, and Skip is the way on.
enum TutorialProblem: Equatable {
    case macUnreachable, speechUnavailable, noReply

    var line: String {
        switch self {
        case .macUnreachable: return "Can’t reach your Mac. Skip to carry on."
        case .speechUnavailable: return "Speech isn’t available here. Skip to carry on."
        case .noReply: return "No reply yet. Skip to carry on."
        }
    }
}

/// What the tutorial reads from the voice layer and the Mac's session. The
/// live screen builds one from the app model; tests build them by hand.
struct TutorialSignals: Equatable {
    enum Speech: Equatable {
        case preparing, ready, unavailable
    }

    var speech = Speech.preparing
    /// The agent the tutorial talks to is running.
    var agentAvailable = false
    var reachable = true
    var isListening = false
    /// The voice layer has nothing in flight: not listening, transcribing or playing.
    var voiceIdle = true
    /// Messages the user has sent to the tutorial's agent so far.
    var userMessages = 0
    /// A reply to the tutorial's agent is queued, waiting for Play.
    var replyWaiting = false
    var isPlaying = false
}

/// The tutorial as a step machine. Each step advances only on the user's
/// action or on the automatic condition the design names; there are no Next
/// buttons. It is pure: the live screen feeds it the user's actions and
/// `TutorialSignals`, and tests feed it faked ones.
struct TutorialMachine: Equatable {
    private(set) var step = TutorialStep.basics
    private(set) var signals = TutorialSignals()
    /// Skipped or done: the tutorial ends and nothing moves it again.
    private(set) var isFinished = false
    private(set) var replyTimedOut = false

    private var messagesAtStart = 0
    /// The user let go in "release to send" and the message is on its way.
    private var awaitingSend = false
    /// Playback has been heard in "stop playback".
    private var heardPlayback = false

    /// The one problem to tell the user about, if any.
    var problem: TutorialProblem? {
        guard !isFinished, step != .allDone else { return nil }
        if !signals.reachable { return .macUnreachable }
        if step == .basics, signals.speech == .unavailable { return .speechUnavailable }
        if step == .playReply, replyTimedOut, !signals.replyWaiting { return .noReply }
        return nil
    }

    // MARK: - Signals

    mutating func observe(_ new: TutorialSignals) {
        guard !isFinished else { return }
        let old = signals
        signals = new
        switch step {
        case .basics:
            if new.speech == .ready, new.agentAvailable, new.reachable { enter(.holdToTalk) }
        case .holdToTalk, .releaseToSend:
            if new.userMessages > messagesAtStart {
                enter(.playReply)
            } else if step == .releaseToSend, awaitingSend, !new.isListening, new.voiceIdle {
                // Let go with nothing to send: try again.
                enter(.holdToTalk)
            }
        case .playReply:
            // Playback only starts from the Play tap; this is the net if it starts otherwise.
            if new.isPlaying, !old.isPlaying { enter(.stopPlayback) }
        case .stopPlayback:
            if new.isPlaying { heardPlayback = true }
            // The reply finished by itself.
            if heardPlayback, old.isPlaying, !new.isPlaying { enter(.allDone) }
        case .allDone:
            break
        }
    }

    // MARK: - The user's actions

    /// The user starts holding Hold to talk.
    mutating func holdBegan() {
        guard !isFinished, step == .holdToTalk else { return }
        messagesAtStart = signals.userMessages
        enter(.releaseToSend)
    }

    /// The user lets go of Hold to talk.
    mutating func released() {
        guard !isFinished, step == .releaseToSend else { return }
        awaitingSend = true
    }

    /// The user taps the dock's Play for the queued reply.
    mutating func playTapped() {
        guard !isFinished, step == .playReply else { return }
        enter(.stopPlayback)
    }

    /// The user taps Stop.
    mutating func stopTapped() {
        guard !isFinished, step == .stopPlayback else { return }
        enter(.allDone)
    }

    /// About 30 seconds passed on "play the reply" with no reply.
    mutating func replyTimeoutElapsed() {
        guard !isFinished, step == .playReply, !signals.replyWaiting else { return }
        replyTimedOut = true
    }

    /// Skip → or the end of the closing line: the app takes over.
    mutating func finish() {
        isFinished = true
    }

    private mutating func enter(_ next: TutorialStep) {
        step = next
        awaitingSend = false
        heardPlayback = signals.isPlaying
        if next == .holdToTalk { messagesAtStart = signals.userMessages }
        if next == .playReply { replyTimedOut = false }
    }
}
