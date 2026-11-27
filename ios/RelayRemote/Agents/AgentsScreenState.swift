import Foundation

/// What the Talk control does with a touch in each talk mode (RR-540). Hold:
/// touching starts and letting go sends. Toggle: one tap starts and the next
/// tap sends.
enum TalkGesture {
    enum Command: Equatable {
        case none, start, send
    }

    static func touchDown(mode: TalkMode, isTalking: Bool) -> Command {
        mode == .hold && !isTalking ? .start : .none
    }

    static func touchUp(mode: TalkMode, isTalking: Bool) -> Command {
        switch mode {
        case .hold: return isTalking ? .send : .none
        case .toggle: return isTalking ? .send : .start
        }
    }
}

/// The voice layer as the Agents tab reads it.
struct VoiceSnapshot: Equatable {
    var isTalking = false
    /// The live transcript while talking.
    var transcript = ""
    /// The reply playing now.
    var playingSeq: Int?
    /// Replies waiting for Play in Queue mode, oldest first.
    var waitingSeqs: [Int] = []
    /// A replay or reply is on its way but its audio has not started.
    var isPreparing = false
}

/// Everything the Agents screen draws, derived from the per-agent model and
/// the voice layer (RR-540). Sample screens build it the same way.
struct AgentsScreenState: Equatable {
    struct Tab: Identifiable, Equatable {
        let slug: String
        var id: String { slug }
        let name: String
        let glyph: StatusGlyphState
        /// A reply arrived while another tab was selected.
        let marked: Bool
    }

    /// The selected agent's newest reply waiting for Play in Queue mode. It
    /// shows in the chat as a normal bubble; the dock's Play plays it.
    struct WaitingReply: Equatable {
        let seq: Int
        /// That agent's older waiting replies, skipped when this one plays.
        let skipping: Set<Int>
    }

    var tabs: [Tab]
    var selected: String
    var name: String
    var orb: AgentOrbState
    /// The line under the name: what the agent is doing right now.
    var status: String
    /// The selected agent's work style, for the header's switch; nil hides it
    /// (a Mac that does not report one).
    var workStyle: String?
    var feed: [ChatMessage]
    /// The reply in the feed that is playing now.
    var speakingSeq: Int?
    /// A reply is playing, any agent's, on the phone or on the Mac (a Replay
    /// plays on the Mac when Remote mode is off): the dock's control reads Stop.
    var isPlaying: Bool
    /// The phone is waiting for a replay or a reply's audio: "Preparing message".
    var isPreparing: Bool
    var waiting: WaitingReply?
    /// The selected agent is starting up: nothing can be sent to it yet.
    var isStarting: Bool
    /// The Mac reports the selected agent stopped (screen 24).
    var notRunning: Bool
    var reachability: AgentsModel.Reachability
    var isTalking: Bool
    var transcript: String
    var talkMode: TalkMode

    @MainActor
    init(agents: AgentsModel, voice: VoiceSnapshot, talkMode: TalkMode) {
        let selected = agents.selected
        let talking = voice.isTalking ? selected : nil
        let playing = agents.agent(ofSeq: voice.playingSeq)
        let waitingAgents = Set(voice.waitingSeqs.compactMap { agents.agent(ofSeq: $0) })
        tabs = AgentsModel.slugs.map { slug in
            Tab(slug: slug, name: AgentsModel.name(slug),
                glyph: agents.glyph(for: slug, talking: talking, playing: playing, waiting: waitingAgents),
                marked: agents.marked.contains(slug))
        }
        self.selected = selected
        name = AgentsModel.name(selected)
        orb = talking != nil ? .listening : playing == selected ? .playing : .idle
        status = Self.status(glyph: agents.glyph(for: selected, talking: talking, playing: playing),
                             workingOn: agents.workingOn[selected],
                             replyWaiting: waitingAgents.contains(selected),
                             starting: agents.isStarting(selected))
        workStyle = agents.workStyle(selected)
        let chat = agents.chat(selected)
        let mine = voice.waitingSeqs.filter { agents.agent(ofSeq: $0) == selected }
        // Every reply shows as a bubble at once (RR-554). The dock's Play
        // plays the newest waiting one and skips the agent's older ones (such
        // as the messenger's quick acknowledgement before the full reply).
        feed = chat
        speakingSeq = playing == selected ? voice.playingSeq : nil
        isPlaying = voice.playingSeq != nil || agents.activities.values.contains(.playing)
        isPreparing = voice.isPreparing
        waiting = mine.last.map { WaitingReply(seq: $0, skipping: Set(mine.dropLast())) }
        isStarting = agents.isStarting(selected)
        notRunning = agents.isStopped(selected) && !voice.isTalking
        reachability = agents.reachability
        isTalking = voice.isTalking
        transcript = voice.transcript
        self.talkMode = talkMode
    }

    /// Talking and playback first, then an agent still starting up (it can't
    /// take a message until it says Ready, user 2026-11-28), then what the
    /// Mac's agent card says it is working on, then its state.
    static func status(glyph: StatusGlyphState, workingOn: String?, replyWaiting: Bool,
                       starting: Bool = false) -> String {
        switch glyph {
        case .listening: return "Listening"
        case .playing: return "Playing reply"
        case .off: return "Not running"
        case .working, .ready:
            if starting { return "Starting up" }
            if let workingOn, !workingOn.isEmpty { return workingOn }
            if replyWaiting { return "New reply" }
            return glyph == .working ? "Working" : "Ready"
        }
    }
}
