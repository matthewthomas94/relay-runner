import RelayRemoteProtocol

/// RR-543: the Workspace tab's list, derived from the Mac's `workspace_state`:
/// open tickets grouped In progress, Queued, Backlog (an empty group left
/// out) and the project tabs with their counts.
public struct WorkspaceListing: Equatable, Sendable {
    public struct Group: Equatable, Sendable {
        public let status: TicketStatus
        public let tickets: [WorkspaceTicket]
    }

    /// One tab of the strip. `id` is nil for "All".
    public struct ProjectTab: Equatable, Sendable {
        public let id: String?
        public let name: String
        public let count: Int
    }

    public static let statusOrder: [TicketStatus] = [.inProgress, .queued, .backlog]

    public let groups: [Group]
    public let tabs: [ProjectTab]
    public let truncated: Bool
    private let projectNames: [String: String]

    public var isEmpty: Bool { groups.isEmpty }

    /// `project` is the selected tab's id, nil for All. A selection the Mac no
    /// longer lists shows everything, as All does.
    public init(_ state: WorkspaceState, project: String? = nil) {
        let known = Set(state.projects.map(\.id))
        let selected = project.flatMap { known.contains($0) ? $0 : nil }
        let visible = state.tickets.filter { selected == nil || $0.projectId == selected }
        groups = Self.statusOrder.compactMap { status in
            let tickets = visible.filter { $0.status == status }
            return tickets.isEmpty ? nil : Group(status: status, tickets: tickets)
        }
        tabs = [ProjectTab(id: nil, name: "All", count: state.tickets.count)]
            + state.projects.map { project in
                ProjectTab(id: project.id, name: project.name,
                           count: state.tickets.filter { $0.projectId == project.id }.count)
            }
        truncated = state.truncated == true
        projectNames = Dictionary(state.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    public func projectName(of ticket: WorkspaceTicket) -> String? {
        projectNames[ticket.projectId]
    }
}

extension TicketStatus {
    /// The group heading.
    public var heading: String {
        switch self {
        case .inProgress: return "In progress"
        case .queued: return "Queued"
        case .backlog: return "Backlog"
        }
    }
}
