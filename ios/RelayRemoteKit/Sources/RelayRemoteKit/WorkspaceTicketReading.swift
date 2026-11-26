import RelayRemoteProtocol

/// RR-551: what the ticket modal on the Workspace tab shows, from the row that
/// was tapped, the Mac's latest list and the Mac's `workspace_ticket` reply.
/// Free of I/O so it can be tested directly.
public struct WorkspaceTicketReading: Equatable, Sendable {
    /// The ticket body, below the header.
    public enum Body: Equatable, Sendable {
        /// Only the body waits: the header is already filled from the row.
        case loading
        case text(String, truncated: Bool)
        case error(String)
        /// The Mac predates ticket text.
        case unsupported
    }

    public static let unsupportedMessage = "Ticket text is not available on this Mac."
    public static let silentMessage = "Your Mac did not answer."

    public let ticketID: String
    public let projectName: String?
    public let title: String
    public let status: TicketDetailStatus
    /// The owning agent's slug, when there is one.
    public let agent: String?
    public let body: Body

    /// `row` is the list entry that was tapped. `workspace` is the Mac's latest
    /// list: while the ticket is open a pushed list updates the status and
    /// owner, and a ticket that has left it is done (unless the list was cut
    /// short, when absence says nothing). `reply` is the Mac's answer to `get`.
    /// `timedOut` is set by the caller when no answer came in time.
    public init(row: WorkspaceTicket, workspace: WorkspaceState?, reply: WorkspaceTicketDetail?,
                unsupported: Bool = false, timedOut: Bool = false) {
        ticketID = row.id
        projectName = workspace?.projects.first { $0.id == row.projectId }?.name
        title = reply?.title ?? row.title
        var status = reply?.status ?? TicketDetailStatus(row.status)
        var agent = reply?.agent ?? row.agent
        if let workspace, workspace.error == nil {
            if let live = workspace.tickets.first(where: { $0.id == row.id && $0.projectId == row.projectId }) {
                status = TicketDetailStatus(live.status)
                agent = live.agent
            } else if workspace.truncated != true {
                status = .done
            }
        }
        self.status = status
        self.agent = agent
        if let message = reply?.error {
            body = .error(message)
        } else if let markdown = reply?.markdown {
            body = .text(markdown, truncated: reply?.truncated == true)
        } else if unsupported {
            body = .unsupported
        } else if timedOut {
            body = .error(Self.silentMessage)
        } else {
            body = .loading
        }
    }

    /// The header's first line: the ticket id and its project.
    public var eyebrow: String { [ticketID, projectName].compactMap { $0 }.joined(separator: " · ") }

    /// The header's last line: the status in words, then the agent's name.
    public var statusLine: String {
        [status.label, agent.map { $0.prefix(1).uppercased() + $0.dropFirst() }].compactMap { $0 }.joined(separator: " · ")
    }
}

extension TicketDetailStatus {
    init(_ status: TicketStatus) {
        switch status {
        case .inProgress: self = .inProgress
        case .queued: self = .queued
        case .backlog: self = .backlog
        }
    }

    /// The status in words.
    public var label: String {
        switch self {
        case .inProgress: return "In progress"
        case .queued: return "Queued"
        case .backlog: return "Backlog"
        case .done: return "Done"
        }
    }
}
