import Foundation
import RelayRemoteProtocol

/// The Workspace feed for the phone (RR-532 seam, RR-535 body).
///
/// A phone's `workspace_command` reaches the app over the session-control
/// socket and is answered with one `workspace_state`; the server then pushes a
/// fresh one while the board changes (docs/specs/relay-remote.md, "Workspace
/// feed"). The feed reads the same source as the desktop Workspace board, the
/// daemon's program dashboard, so the phone and the Mac agree. It is
/// read-only. The list sends only the fields `WorkspaceState` carries: never a
/// ticket body, a file path or a repository path. RR-551: a ticket's body is
/// sent only in answer to a `get` for that one ticket (`ticket(projectID:ticketID:)`),
/// read the way the desktop Workspace reads an open ticket, without its
/// frontmatter and without any path.
struct RelayRemoteWorkspaceFeed {
    typealias Project = RelaySessionControlHost.Project

    /// The answer when the app has no feed to offer, for example in a test.
    static let unavailable = WorkspaceState(
        projects: [], tickets: [], error: "The Workspace is not available from the phone on this Mac.")
    static let daemonDown = "Relay Runner's workspace service is not running on this Mac."
    static let timedOut = "The Mac's workspace service did not answer in time."
    static let unreadable = "The Workspace could not be read on this Mac right now."
    static let unknownProject = "That project is not available on this Mac."
    static let unknownTicket = "That ticket no longer exists."
    static let unreadableTicket = "That ticket could not be read on this Mac right now."
    static let unidentifiedTicket = "That ticket could not be identified."

    /// Open tickets sent at most, newest activity first.
    static let ticketLimit = 200
    /// Titles are cut to this many characters.
    static let titleLimit = 120
    /// A frame stays well inside `RelayRemoteProtocol.maxLineBytes`.
    static let frameBudget = 60 * 1024
    /// RR-551: a `get` reply's title is cut to this many characters.
    static let ticketTitleLimit = 300

    /// Registered projects in display order. Called on the main actor.
    var projects: () -> [Project]
    /// The program dashboard for these project paths.
    var fetchDashboard: ([String]) async throws -> ProgramDashboardSnapshot
    /// Ticket owners, keyed by `ownerKey`, or empty when the daemon cannot say.
    var fetchOwners: () async -> [String: String]
    /// RR-551: reads one ticket the way the desktop Workspace shows it.
    var loadTicket: (ProgramStatusItem) -> ProgramTicketDetail = { ProgramTicketDetail.load(item: $0) }
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

    // MARK: One ticket (RR-551)

    /// The text of one ticket, for the phone's `get`. Never throws and never
    /// waits longer than `timeout`: every failure is a `workspace_ticket` whose
    /// `error` the phone can show. Only a ticket in a registered, available
    /// project that `load()` would list is served, or one that has since become
    /// done; its frontmatter and its paths never leave the Mac.
    func ticket(projectID: String, ticketID: String) async -> WorkspaceTicketDetail {
        func failure(_ message: String) -> WorkspaceTicketDetail {
            WorkspaceTicketDetail(projectId: projectID, ticketId: ticketID, error: message)
        }
        let registered = await MainActor.run { projects() }
        guard let project = registered.first(where: { $0.id == projectID && $0.availability == "available" }) else {
            return failure(Self.unknownProject)
        }
        do {
            let fetchDashboard = fetchDashboard
            let fetchOwners = fetchOwners
            let (snapshot, owners) = try await Self.withTimeout(timeout) {
                async let owners = fetchOwners()
                return (try await fetchDashboard([project.path]), await owners)
            }
            let normalized = ProgramBoardProjectPath.normalized(project.path)
            let lanes: [(ProgramStatusResponse, TicketDetailStatus)] = [
                (snapshot.inProgressWork, .inProgress), (snapshot.readyWork, .queued),
                (snapshot.backlogWork, .backlog), (snapshot.doneWork, .done),
            ]
            for (lane, status) in lanes {
                guard let item = lane.items.first(where: { candidate in
                    guard candidate.ticketID == ticketID, let path = candidate.project?.path,
                          ProgramBoardProjectPath.normalized(path) == normalized else { return false }
                    if status == .done { return Self.isDone(candidate.status) || Self.isDone(candidate.ticketState) }
                    return !Self.isClosed(candidate.status) && !Self.isClosed(candidate.ticketState)
                }) else { continue }
                return Self.detail(of: loadTicket(item), item: item, projectID: projectID, ticketID: ticketID,
                                   status: status, agent: owners[Self.ownerKey(path: normalized, ticketID: ticketID)])
            }
            return failure(Self.unknownTicket)
        } catch {
            return failure(Self.message(for: error))
        }
    }

    /// The reply for a ticket that was found on the board.
    static func detail(of loaded: ProgramTicketDetail, item: ProgramStatusItem, projectID: String, ticketID: String,
                       status: TicketDetailStatus, agent: String?) -> WorkspaceTicketDetail {
        guard let ticket = loaded.ticket else {
            let onDisk = loaded.ticketPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            return WorkspaceTicketDetail(projectId: projectID, ticketId: ticketID,
                                         error: onDisk ? unreadableTicket : unknownTicket)
        }
        var reply = WorkspaceTicketDetail(projectId: projectID, ticketId: ticketID,
                                          title: String(ticket.title.prefix(ticketTitleLimit)), status: status,
                                          agent: agent)
        // The body is cut to its cap, then further while JSON escaping would
        // push the frame past one protocol line.
        var limit = WorkspaceTicketDetail.maxMarkdownBytes
        while true {
            let (markdown, cut) = cap(ticket.body, bytes: limit)
            reply.markdown = markdown
            reply.truncated = cut ? true : nil
            do {
                _ = try FrameCodec.encode(.workspaceTicket(reply))
                return reply
            } catch FrameError.lineTooLong(let size) where limit > 0 {
                limit = max(0, limit - max(256, size - RelayRemoteProtocol.maxLineBytes))
            } catch {
                reply.markdown = nil
                reply.truncated = nil
                reply.error = unreadableTicket
                return reply
            }
        }
    }

    /// `text` cut to at most `bytes` of UTF-8 on a character boundary, and
    /// whether it was cut.
    static func cap(_ text: String, bytes: Int) -> (String, Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            used += text.utf8.distance(from: index, to: next)
            if used > bytes { break }
            end = next
        }
        return (String(text[..<end]), true)
    }

    private static func isDone(_ value: String?) -> Bool { value?.lowercased() == "done" }

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
