import Foundation
import RelayRemoteKit
import RelayRemoteProtocol

/// The Agents tab's per-agent state (RR-540): which agent is selected, each
/// agent's chat, the Mac's per-agent state, and which agents have a reply the
/// user has not seen. Replies are filed under the agent they are for whichever
/// tab is selected.
@MainActor
@Observable
final class AgentsModel {
    static let slugs = RelayRemoteProtocol.agents
    static let selectionKey = "selectedAgent"

    /// The Mac's link as the Agents tab shows it.
    enum Reachability: Equatable {
        case reachable
        /// SSH did not get through: the "Mac unreachable" banner.
        case unreachable
        /// The Mac answered but Relay Runner is not running there.
        case appNotRunning
    }

    private(set) var selected: String
    private(set) var chats: [String: [ChatMessage]] = [:]
    /// Agents with a reply that arrived while another tab was selected.
    private(set) var marked: Set<String> = []
    /// What the Mac last reported for each agent while it was reachable.
    private(set) var activities: [String: AgentActivity] = [:]
    /// Agents the phone asked to start, until the Mac reports them running.
    private(set) var starting: Set<String> = []
    private(set) var reachability = Reachability.reachable
    /// The Mac's active agent, which owns a reply that names no agent.
    private(set) var activeAgent: String?

    /// The session messages and starts go through; nil before pairing.
    @ObservationIgnored weak var session: RemoteSession?
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored private let store: ChatStore
    @ObservationIgnored private let defaults: UserDefaults
    /// Which agent each reply's seq was filed under, for playback.
    @ObservationIgnored private var seqOwners: [Int: String] = [:]
    /// Agents whose newest reply the user asked to hear again. The Mac sends
    /// a replay as a new `speech` frame; it plays but is not a new message.
    @ObservationIgnored private var replaying: Set<String> = []

    init(store: ChatStore = .standard, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.selectionKey)
        selected = saved.flatMap { Self.slugs.contains($0) ? $0 : nil } ?? Self.slugs[0]
        for slug in Self.slugs { chats[slug] = store.load(slug) }
    }

    static func name(_ slug: String) -> String {
        slug.prefix(1).uppercased() + slug.dropFirst()
    }

    func chat(_ slug: String) -> [ChatMessage] { chats[slug] ?? [] }

    /// Switches the whole chat to `slug` and remembers it across launches.
    /// Also how a notification opens an agent's chat (RR-545).
    func select(_ slug: String) {
        guard Self.slugs.contains(slug) else { return }
        selected = slug
        marked.remove(slug)
        defaults.set(slug, forKey: Self.selectionKey)
    }

    // MARK: - Replies

    /// Files every inbound `speech` and `status` frame under its agent and
    /// follows the Mac's active agent.
    func receive(_ frame: Frame) {
        switch frame {
        case .speech(let speech):
            let agent = owner(of: speech.agent)
            if replaying.contains(agent),
               chats[agent]?.suffix(10).contains(where: { $0.role == .agent && $0.text == speech.text }) == true {
                replaying.remove(agent)
                seqOwners[speech.seq] = agent
                return
            }
            file(ChatMessage(role: .agent, text: speech.text, date: now(), seq: speech.seq), to: owner(of: speech.agent))
        case .status(let status):
            file(ChatMessage(role: .status, text: status.text, date: now(), seq: status.seq), to: owner(of: status.agent))
        case .sessionState(let state):
            activeAgent = state.session == .ready || state.session == .starting ? state.activeAgent : nil
        default:
            break
        }
    }

    /// The agent a frame is filed under: the one it names; one that names
    /// none (a Mac before RR-534) belongs to the Mac's active agent, or to the
    /// selected agent when the Mac reports none.
    func owner(of tag: String?) -> String {
        if let tag, Self.slugs.contains(tag) { return tag }
        if let activeAgent, Self.slugs.contains(activeAgent) { return activeAgent }
        return selected
    }

    /// Replay was pressed for `agent`: its replayed reply plays without
    /// being filed again.
    func replayRequested(for agent: String) {
        replaying.insert(agent)
    }

    /// The agent whose chat holds the reply `seq`.
    func agent(ofSeq seq: Int?) -> String? {
        seq.flatMap { seqOwners[$0] }
    }

    private func file(_ message: ChatMessage, to agent: String) {
        var chat = chats[agent] ?? []
        // A reconnect after a relaunch can replay a reply already filed.
        if let seq = message.seq,
           chat.suffix(20).contains(where: { $0.seq == seq && $0.role == message.role && $0.text == message.text }) {
            seqOwners[seq] = agent
            return
        }
        chat.append(message)
        chat = ChatStore.capped(chat)
        chats[agent] = chat
        store.save(chat, for: agent)
        if let seq = message.seq { seqOwners[seq] = agent }
        if message.role == .agent, agent != selected { marked.insert(agent) }
    }

    // MARK: - Sending

    /// Sends `text` to `agent` (the selected one by default) and files it in
    /// that agent's chat. A message to a stopped agent starts it first.
    @discardableResult
    func send(_ text: String, to agent: String? = nil) -> Bool {
        let agent = agent ?? selected
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session else { return false }
        if isStopped(agent) { start(agent) }
        guard session.send(text: trimmed, agent: agent) else { return false }
        file(ChatMessage(role: .user, text: trimmed, date: now()), to: agent)
        return true
    }

    /// Starts `agent` on the Mac with no project (its general-tasks project).
    func start(_ agent: String) {
        guard let session, session.send(sessionCommand: .start, agent: agent) else { return }
        starting.insert(agent)
    }

    // MARK: - The Mac's state

    /// Takes the Mac's latest state. While it is unreachable the last known
    /// agent states stay, under the banner.
    func update(_ status: MacSessionStatus) {
        switch status.phase {
        case .unreachable:
            reachability = .unreachable
            return
        case .appNotRunning:
            reachability = .appNotRunning
            return
        case .connecting:
            return
        case .noSession, .starting, .ready, .failed:
            reachability = .reachable
        }
        var next: [String: AgentActivity] = [:]
        for slug in Self.slugs { next[slug] = Self.activity(of: slug, in: status) }
        activities = next
        // A start the phone asked for ends once the Mac reports the agent, or refuses.
        let refused = status.phase == .failed || status.error != nil
        starting = starting.filter { !refused && next[$0] == .off }
    }

    /// One agent's state from the Mac's report: its own `agents` entry when the
    /// Mac sends one (RR-532), otherwise the running agents (RR-523).
    static func activity(of slug: String, in status: MacSessionStatus) -> AgentActivity {
        if let agent = status.agent(slug) {
            if !agent.running { return agent.state == .starting ? .starting : .off }
            return agent.state == .off ? .ready : agent.state
        }
        switch status.phase {
        case .ready, .starting:
            let running: [String]? = status.runningAgents.isEmpty ? status.activeAgent.map { [$0] } : status.runningAgents
            guard let running else {
                // A Mac that names no agents: every one is reachable through it.
                return status.phase == .ready ? .ready : .starting
            }
            guard running.contains(slug) else { return .off }
            return status.phase == .starting && slug == status.activeAgent ? .starting : .ready
        default:
            return .off
        }
    }

    /// The Mac reports `slug` stopped and the phone has not asked to start it.
    func isStopped(_ slug: String) -> Bool {
        activities[slug] == .off && !starting.contains(slug)
    }

    /// The tab glyph. The phone's own talking and playback win over the Mac's
    /// report; a start shows as the spinning glyph, as the desktop's starting
    /// notch does, and the grey dot splits into four when it begins.
    func glyph(for slug: String, talking: String?, playing: String?) -> StatusGlyphState {
        if slug == talking { return .listening }
        if slug == playing { return .playing }
        if starting.contains(slug) { return .working }
        return Self.glyph(activities[slug] ?? .off)
    }

    static func glyph(_ activity: AgentActivity) -> StatusGlyphState {
        switch activity {
        case .off: return .off
        case .starting, .working: return .working
        case .ready: return .ready
        case .listening: return .listening
        case .playing: return .playing
        }
    }

    #if DEBUG
    /// Sample screens: set every field the screen reads.
    func setSample(activities: [String: AgentActivity], marked: Set<String>, reachability: Reachability,
                   chats: [String: [ChatMessage]]) {
        self.activities = activities
        self.marked = marked
        self.reachability = reachability
        for (slug, chat) in chats {
            self.chats[slug] = chat
            for message in chat { if let seq = message.seq { seqOwners[seq] = slug } }
        }
    }
    #endif
}
