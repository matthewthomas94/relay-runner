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

    /// Interim rule for an Add control ("+", Command-T): the
    /// first agent in table order that is not running; nil when all four are.
    static func toAdd(running: Set<SessionAgent>) -> SessionAgent? {
        allCases.first { !running.contains($0) }
    }

    /// Interim rule for every other start path: the most recently active
    /// agent, which is the saved active context's, or Puck if none has run.
    static func toStart(activeContext: AssistantSessionContext) -> SessionAgent {
        SessionAgent(context: activeContext)
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
