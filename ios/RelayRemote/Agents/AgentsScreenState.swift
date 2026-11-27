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

    /// The selected agent's newest reply waiting for Play in Queue mode.
    struct WaitingReply: Equatable {
        let seq: Int
        /// The chat message holding this reply. Seqs start again when the
        /// Mac restarts, so the feed keys rows by this, not by `seq`.
        let messageID: UUID?
        /// That agent's older waiting replies, skipped when this one plays.
        let skipping: Set<Int>
        let receivedAt: Date
    }

    var tabs: [Tab]
    var selected: String
    var name: String
    var orb: AgentOrbState
    var feed: [ChatMessage]
    /// The reply in the feed that is playing now.
    var speakingSeq: Int?
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
        // The newest reply waiting for Play shows as "New reply from <agent>"
        // until it plays. Older ones (such as the messenger's quick
        // acknowledgement before the full reply) show as bubbles: Play skips
        // them anyway, and revealing them only on Play made the chat jump.
        let waitingMessage = mine.last.flatMap { last in chat.last(where: { $0.seq == last }) }
        feed = chat.filter { $0.id != waitingMessage?.id }
        speakingSeq = playing == selected ? voice.playingSeq : nil
        if let last = mine.last {
            waiting = WaitingReply(seq: last, messageID: waitingMessage?.id, skipping: Set(mine.dropLast()),
                                   receivedAt: waitingMessage?.date ?? agents.now())
        } else {
            waiting = nil
        }
        notRunning = agents.isStopped(selected) && !voice.isTalking
        reachability = agents.reachability
        isTalking = voice.isTalking
        transcript = voice.transcript
        self.talkMode = talkMode
    }
}
