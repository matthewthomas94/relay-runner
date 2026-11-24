import Foundation

/// RR-519: the four fixed, named PM agents. Each is a permanent slot with its
/// own conversation in every context; at most one session per agent per
/// context, and at most four sessions run at once. This is the one
/// definition of their order, names, slugs and voices.
enum SessionAgent: String, CaseIterable, Codable, Identifiable {
    case puck, isabella, george, sky

    var id: String { slug }
    var slug: String { rawValue }

    var name: String {
        switch self {
        case .puck: return "Puck"
        case .isabella: return "Isabella"
        case .george: return "George"
        case .sky: return "Sky"
        }
    }

    /// RR-521: the two-letter label on the session wheel's agent segments.
    /// The full name is used everywhere else, VoiceOver included.
    var shortLabel: String {
        switch self {
        case .puck: return "PK"
        case .isabella: return "IS"
        case .george: return "GE"
        case .sky: return "SK"
        }
    }

    /// The agent's Kokoro voice: everything said for its session speaks in it
    /// (RR-520). relay-speech maps the slug to the same voice in `agents.rs`;
    /// `tests/fixtures/session_agent_voices.json` pins the two together.
    var voiceID: String {
        switch self {
        case .puck: return "am_puck"
        case .isabella: return "bf_isabella"
        case .george: return "bm_george"
        case .sky: return "af_sky"
        }
    }

    /// 1-based table order.
    var order: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The agent's tab identity in `AssistantSessionContext.tab`. Puck owns
    /// the first tab (nil), so the conversation saved before agents existed
    /// is Puck's; the others use their slug.
    var tab: String? { self == .puck ? nil : slug }

    /// The agent a context's tab belongs to; nil for a tab no agent owns,
    /// such as a pre-RR-519 random tab id.
    init?(tab: String?) {
        guard let tab else { self = .puck; return }
        guard let agent = Self(rawValue: tab), agent != .puck else { return nil }
        self = agent
    }

    init?(contextID: String) {
        guard let range = contextID.range(of: AssistantSessionContext.tabSeparator) else { self = .puck; return }
        self.init(tab: String(contextID[range.upperBound...]))
    }

    /// The agent of a context; a context no agent owns is treated as Puck's.
    init(context: AssistantSessionContext) {
        self = Self(tab: context.tab) ?? .puck
    }

    /// The `RELAY_SESSION_AGENT` value and the spool's `session_agent` file.
    static let environmentName = "RELAY_SESSION_AGENT"
    static let spoolFileName = "session_agent"

    /// The startup instruction that tells the foreground PM its name.
    var startupInstruction: String {
        "You are \(name) in this session; the user may address you by that name. Relay Runner runs up to four named agents (Puck, Isabella, George and Sky), each with its own conversation."
    }

    /// RR-528: the card shows its own state line ("Currently working on")
    /// above the agent's description, which names the work in two to four
    /// words and fits one line.
    static let workDescriptionWordLimit = 4
    static let workDescriptionLimit = 40
    static let workDescriptionExample = "Settings dropdown dividers"

    /// The startup instruction that has the agent keep its card's description current.
    static let workDescriptionInstruction = "Agent card: your card in Relay Runner shows \"Currently working on\" above a short description of your work. When you start a piece of work or move to a different one, call mcp__relay-app__set_working_on with two to four words naming the work, at most \(workDescriptionLimit) characters, for example \"\(workDescriptionExample)\". Do not repeat \"Currently working on\" or start with a verb such as \"Working on\". If set_working_on refuses the description, shorten it to two to four words and call it again straight away. Do not call it again while the work is the same, and not for questions or small talk."

    /// Why `set_working_on` refuses a description, which is already collapsed
    /// to single spaces; nil when the card can show it. Fewer than two words
    /// is accepted. The message has the agent send a shorter one at once.
    static func workDescriptionRefusal(_ description: String) -> String? {
        let words = description.split(separator: " ").count
        guard words > workDescriptionWordLimit || description.count > workDescriptionLimit else { return nil }
        return "description is \(words) words and \(description.count) characters; the card shows two to four words, at most \(workDescriptionLimit) characters. Call set_working_on again now with two to four words naming the work, for example \"\(workDescriptionExample)\"."
    }

    /// RR-523: an agent named by slug or name, ignoring case and spaces; nil
    /// for anything else.
    init?(choice: String) {
        let value = choice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let agent = Self.allCases.first(where: { $0.slug == value || $0.name.lowercased() == value }) else {
            return nil
        }
        self = agent
    }

    /// RR-523: a session never starts without the user choosing its agent.
    /// Only the paths that cannot show a menu use this rule: a Relay Remote
    /// start without `agent` (an older phone build), the Notetaker hand-off
    /// and the double-tap session prompt. It is the most recently active
    /// agent, which is the saved active context's, or Puck if none has run.
    static func mostRecentlyActive(activeContext: AssistantSessionContext) -> SessionAgent {
        SessionAgent(context: activeContext)
    }

    /// RR-523: the agents a start menu offers: those not running, in table order.
    static func startable(running: Set<SessionAgent>) -> [SessionAgent] {
        allCases.filter { !running.contains($0) }
    }

    /// The "+" reason while all four agents run.
    static let allRunningReason = "All four agents running"

    /// "Puck, Isabella, George and Sky", or any subset, in table order.
    static func list(_ agents: [SessionAgent]) -> String {
        let names = agents.map(\.name)
        guard names.count > 1 else { return names.first ?? "none" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// `start_session`'s refusal when `agent` is missing or unknown: it names
    /// the four agents and which of them run.
    static func choiceRefusal(given: String?, running: Set<SessionAgent>) -> String {
        let choices = allCases.map { "\($0.slug) (\($0.name))" }.joined(separator: ", ")
        let lead = given.map { "Unknown agent '\($0)'." } ?? "start_session needs agent."
        let runningNames = list(allCases.filter(running.contains))
        return "\(lead) Choose one of the four agents: \(choices). Running: \(runningNames). Ask the user which agent to start when they have not said."
    }

    static var limitMessage: String {
        "Relay Runner runs at most four agents at once: Puck, Isabella, George and Sky. Stop one before starting another."
    }

    /// One agent's state in `app_status`.
    struct Status: Equatable {
        let agent: SessionAgent
        let isRunning: Bool
        let isActive: Bool

        var json: [String: Any] {
            ["name": agent.name, "slug": agent.slug, "order": agent.order,
             "running": isRunning, "active": isActive]
        }
    }

    /// Every agent in table order with whether it runs and which is active.
    static func statuses(liveContextIDs: [String], activeContextID: String?) -> [Status] {
        let running = Set(liveContextIDs.compactMap(SessionAgent.init(contextID:)))
        let active = activeContextID.flatMap { id in liveContextIDs.contains(id) ? SessionAgent(contextID: id) : nil }
        return allCases.map { Status(agent: $0, isRunning: running.contains($0), isActive: $0 == active) }
    }
}
