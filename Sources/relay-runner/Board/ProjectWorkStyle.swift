import Foundation

/// How an agent routes change requests. Mirrors `WORK_STYLES` in
/// rust/relay-services/src/command_actions.rs, which reads each agent's
/// choice from `[agents.<slug>] work_style` in config.toml (`AgentConfig`).
enum ProjectWorkStyle: String, CaseIterable, Identifiable, Codable {
    case auto
    case direct
    case orchestrated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .direct: return "Direct"
        case .orchestrated: return "Orchestrated"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Decides per request, and asks when unsure"
        case .direct: return "Makes changes now, without tickets"
        case .orchestrated: return "Turns changes into tickets for workers"
        }
    }
}
