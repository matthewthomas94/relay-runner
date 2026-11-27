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
    var feed: [ChatMessage]
    /// The reply in the feed that is playing now.
    var speakingSeq: Int?
    /// A reply is playing on the phone, any agent's: the dock's control reads Stop.
    var isPlaying: Bool
    var waiting: WaitingReply?
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
        tabs = AgentsModel.slugs.map { slug in
            Tab(slug: slug, name: AgentsModel.name(slug),
                glyph: agents.glyph(for: slug, talking: talking, playing: playing),
                marked: agents.marked.contains(slug))
        }
        self.selected = selected
        name = AgentsModel.name(selected)
        orb = talking != nil ? .listening : playing == selected ? .playing : .idle
        let chat = agents.chat(selected)
        let mine = voice.waitingSeqs.filter { agents.agent(ofSeq: $0) == selected }
        // Every reply shows as a bubble at once (RR-554). The dock's Play
        // plays the newest waiting one and skips the agent's older ones (such
        // as the messenger's quick acknowledgement before the full reply).
        feed = chat
        speakingSeq = playing == selected ? voice.playingSeq : nil
        isPlaying = voice.playingSeq != nil
        waiting = mine.last.map { WaitingReply(seq: $0, skipping: Set(mine.dropLast())) }
        notRunning = agents.isStopped(selected) && !voice.isTalking
        reachability = agents.reachability
        isTalking = voice.isTalking
        transcript = voice.transcript
        self.talkMode = talkMode
    }
}
