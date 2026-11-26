import Foundation
import RelayRemoteProtocol

/// The Workspace feed for the phone (RR-532 seam, RR-535 body).
///
/// A phone's `workspace_command` reaches the app over the session-control
/// socket and is answered with one `workspace_state`; the server then pushes a
/// fresh one while the board changes (docs/specs/relay-remote.md, "Workspace
/// feed"). The feed reads the same source as the desktop Workspace board, the
/// daemon's program dashboard, so the phone and the Mac agree. It is
/// read-only and sends only the fields `WorkspaceState` carries: never a
/// ticket body, a file path or a repository path.
struct RelayRemoteWorkspaceFeed {
    typealias Project = RelaySessionControlHost.Project

    /// The answer when the app has no feed to offer, for example in a test.
    static let unavailable = WorkspaceState(
        projects: [], tickets: [], error: "The Workspace is not available from the phone on this Mac.")
    static let daemonDown = "Relay Runner's workspace service is not running on this Mac."
    static let timedOut = "The Mac's workspace service did not answer in time."
    static let unreadable = "The Workspace could not be read on this Mac right now."

    /// Open tickets sent at most, newest activity first.
    static let ticketLimit = 200
    /// Titles are cut to this many characters.
    static let titleLimit = 120
    /// A frame stays well inside `RelayRemoteProtocol.maxLineBytes`.
    static let frameBudget = 60 * 1024

    /// Registered projects in display order. Called on the main actor.
    var projects: () -> [Project]
    /// The program dashboard for these project paths.
    var fetchDashboard: ([String]) async throws -> ProgramDashboardSnapshot
    /// Ticket owners, keyed by `ownerKey`, or empty when the daemon cannot say.
    var fetchOwners: () async -> [String: String]
    var timeout: TimeInterval = 8

    /// The live feed: the daemon's dashboard without its ready sweep, and its
    /// agent presence for owners.
    static func live(projects: @escaping () -> [Project]) -> RelayRemoteWorkspaceFeed {
        RelayRemoteWorkspaceFeed(
            projects: projects,
            fetchDashboard: { paths in
                try await OrchestratorClient.fetchProgramDashboardSnapshot(
                    trigger: "relay-remote-workspace", repoPaths: paths, sweepsReadyTickets: false)
            },
            fetchOwners: {
                guard let data = try? await OrchestratorClient.fetchAgentPresence() else { return [:] }
                return owners(fromPresence: data)
            }
        )
    }

    /// The current Workspace. Never throws and never waits longer than
    /// `timeout`: a daemon that cannot be read is a `workspace_state` whose
    /// `error` the phone can show.
    func load() async -> WorkspaceState {
        let registered = await MainActor.run { projects() }
        let summaries = registered.map { WorkspaceProject(id: $0.id, name: $0.name) }
        let paths = registered.filter { $0.availability == "available" }.map(\.path)
        guard !paths.isEmpty else { return WorkspaceState(projects: summaries, tickets: []) }
        do {
            let fetchDashboard = fetchDashboard
            let fetchOwners = fetchOwners
            let (snapshot, owners) = try await Self.withTimeout(timeout) {
                async let owners = fetchOwners()
                return (try await fetchDashboard(paths), await owners)
            }
            return Self.state(projects: registered, snapshot: snapshot, owners: owners)
        } catch {
            return WorkspaceState(projects: summaries, tickets: [], error: Self.message(for: error))
        }
    }

    // MARK: Building the frame

    /// The open tickets of `snapshot` on the phone's three lanes, as one frame.
    /// A ticket belongs to the registered project whose path it was read from;
    /// one in no registered project is left out.
    static func state(projects: [Project], snapshot: ProgramDashboardSnapshot, owners: [String: String]) -> WorkspaceState {
        let summaries = projects.map { WorkspaceProject(id: $0.id, name: $0.name) }
        let idByPath = Dictionary(
            projects.map { (ProgramBoardProjectPath.normalized($0.path), $0.id) }, uniquingKeysWith: { first, _ in first })
        let lanes: [(ProgramStatusResponse, TicketStatus)] = [
            (snapshot.inProgressWork, .inProgress), (snapshot.readyWork, .queued), (snapshot.backlogWork, .backlog),
        ]
        var seen = Set<String>()
        var found: [(ticket: WorkspaceTicket, activity: Date?)] = []
        for (lane, status) in lanes {
            for item in lane.items {
                guard let id = item.ticketID, let title = item.title, let path = item.project?.path,
                      !isClosed(item.status), !isClosed(item.ticketState) else { continue }
                let normalized = ProgramBoardProjectPath.normalized(path)
                guard let projectID = idByPath[normalized], seen.insert(projectID + "\u{1F}" + id).inserted else { continue }
                found.append((
                    WorkspaceTicket(id: id, title: String(title.prefix(titleLimit)), status: status,
                                    projectId: projectID, agent: owners[ownerKey(path: normalized, ticketID: id)]),
                    item.ticketModifiedAt))
            }
        }
        // Newest activity first; tickets with no date last, in lane order.
        let ordered = found.enumerated().sorted { lhs, rhs in
            switch (lhs.element.activity, rhs.element.activity) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element.ticket)
        var tickets = Array(ordered.prefix(ticketLimit))
        var state = WorkspaceState(projects: summaries, tickets: tickets)
        while let size = try? FrameCodec.encode(.workspaceState(state)).count, size > frameBudget, !tickets.isEmpty {
            tickets.removeLast(min(10, tickets.count))
            state.tickets = tickets
        }
        if tickets.count < ordered.count { state.truncated = true }
        return state
    }

    private static func isClosed(_ value: String?) -> Bool {
        ["done", "canceled", "cancelled"].contains(value?.lowercased() ?? "")
    }

    // MARK: Owners

    static func ownerKey(path: String, ticketID: String) -> String { path + "\u{1F}" + ticketID }

    /// Which running agent owns each ticket, from the daemon's agent presence:
    /// the tickets an agent wrote or dispatched in a repository. When two
    /// agents list a ticket the more recently active one owns it.
    static func owners(fromPresence data: Data) -> [String: String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let agents = object["agents"] as? [[String: Any]] else { return [:] }
        var owners: [String: (agent: String, seen: String)] = [:]
        for agent in agents {
            guard let slug = agent["agent"] as? String, agent["running"] as? Bool == true,
                  SessionAgent(choice: slug) != nil else { continue }
            for repository in agent["repositories"] as? [[String: Any]] ?? [] {
                guard let path = repository["repo_path"] as? String else { continue }
                let seen = repository["last_seen"] as? String ?? ""
                for ticket in repository["tickets"] as? [String] ?? [] {
                    let key = ownerKey(path: ProgramBoardProjectPath.normalized(path), ticketID: ticket)
                    if let known = owners[key], known.seen >= seen { continue }
                    owners[key] = (slug, seen)
                }
            }
        }
        return owners.mapValues(\.agent)
    }

    // MARK: Failure

    private struct TimedOut: Error {}

    static func message(for error: Error) -> String {
        if error is TimedOut { return timedOut }
        if OrchestratorClient.isTransientDaemonConnectionError(error) { return daemonDown }
        return unreadable
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
