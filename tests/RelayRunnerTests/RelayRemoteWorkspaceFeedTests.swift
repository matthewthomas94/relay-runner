import Foundation
import RelayRemoteProtocol
import XCTest
@testable import relay_runner

/// A board a test edits while a feed reads it from another thread (RR-535).
final class WorkspaceBoard: @unchecked Sendable {
    static let repoPath = "/repos/relay-runner"
    private let lock = NSLock()
    /// RR-551: where its tickets live, so a test can put real ticket files there.
    let repoPath: String
    private var stored: [(id: String, title: String, status: String)]

    init(tickets: [(String, String, String)], repoPath: String = WorkspaceBoard.repoPath) {
        self.repoPath = repoPath
        stored = tickets.map { (id: $0.0, title: $0.1, status: $0.2) }
    }

    var tickets: [(String, String, String)] {
        get { lock.withLock { stored.map { ($0.id, $0.title, $0.status) } } }
        set { lock.withLock { stored = newValue.map { (id: $0.0, title: $0.1, status: $0.2) } } }
    }

    /// The daemon's dashboard for these tickets: a ticket sits in the lane of its status.
    var snapshot: ProgramDashboardSnapshot {
        let all = tickets
        func lane(_ query: String, _ statuses: Set<String>) -> ProgramStatusResponse {
            let items = all.enumerated().filter { statuses.contains($0.element.2) }.map { index, ticket in
                ProgramStatusItem(
                    project: ProgramStatusProject(name: "relay-runner", path: repoPath),
                    ticketID: ticket.0, title: ticket.1, status: ticket.2, priority: "medium",
                    ticketModifiedAt: Date(timeIntervalSince1970: Double(1_000 + index)),
                    branch: "relay/\(ticket.0.lowercased())", activity: "reading \(repoPath)/secret.txt")
            }
            return ProgramStatusResponse(query: query, provider: nil, message: "", items: items,
                                         counts: ProgramStatusCounts(projects: 1, items: items.count))
        }
        return ProgramDashboardSnapshot(
            summary: lane("summary", []), backlogWork: lane("backlog_lane", ["backlog"]),
            readyWork: lane("ready_lane", ["ready"]),
            inProgressWork: lane("in_progress_lane", ["in_progress", "verification_blocked"]),
            doneWork: lane("done_lane", ["done", "canceled"]), awaitingMerge: lane("awaiting_merge", []))
    }
}

/// RR-535: the Workspace feed built from the program dashboard.
final class RelayRemoteWorkspaceFeedTests: XCTestCase {
    private let projects = [
        RelaySessionControlHost.Project(id: "p-relay", name: "relay-runner", path: WorkspaceBoard.repoPath,
                                        availability: "available"),
        RelaySessionControlHost.Project(id: "p-general", name: "general-tasks", path: "/support/general-tasks",
                                        availability: "available"),
    ]

    private func feed(_ board: WorkspaceBoard, owners: [String: String] = [:]) -> RelayRemoteWorkspaceFeed {
        RelayRemoteWorkspaceFeed(projects: { self.projects }, fetchDashboard: { _ in board.snapshot },
                                 fetchOwners: { owners })
    }

    func testStatusesMapToThePhonesThreeLanesAndClosedTicketsAreNotSent() async {
        let board = WorkspaceBoard(tickets: [
            ("RR-1", "Backlog one", "backlog"), ("RR-2", "Ready one", "ready"), ("RR-3", "Running", "in_progress"),
            ("RR-4", "Blocked on a device", "verification_blocked"), ("RR-5", "Shipped", "done"),
            ("RR-6", "Dropped", "canceled"),
        ])
        let state = await feed(board).load()
        XCTAssertNil(state.error)
        XCTAssertNil(state.truncated)
        XCTAssertEqual(state.projects, [WorkspaceProject(id: "p-relay", name: "relay-runner"),
                                        WorkspaceProject(id: "p-general", name: "general-tasks")])
        let byID = Dictionary(uniqueKeysWithValues: state.tickets.map { ($0.id, $0.status) })
        XCTAssertEqual(byID, ["RR-1": .backlog, "RR-2": .queued, "RR-3": .inProgress, "RR-4": .inProgress])
        XCTAssertTrue(state.tickets.allSatisfy { $0.projectId == "p-relay" })
    }

    func testTheOwningAgentIsCarriedWhenThereIsOne() async throws {
        let board = WorkspaceBoard(tickets: [("RR-1", "Owned", "in_progress"), ("RR-2", "Nobody's", "backlog")])
        let presence = """
        {"agents":[
          {"agent":"puck","name":"Puck","running":true,"repositories":[
            {"repo_path":"\(WorkspaceBoard.repoPath)","last_seen":"2026-11-26T10:00:00Z","tickets":["RR-1"]}]},
          {"agent":"sky","name":"Sky","running":true,"repositories":[
            {"repo_path":"\(WorkspaceBoard.repoPath)","last_seen":"2026-11-26T10:05:00Z","tickets":["RR-1"]}]},
          {"agent":"george","name":"George","running":false,"repositories":[
            {"repo_path":"\(WorkspaceBoard.repoPath)","last_seen":"2026-11-26T11:00:00Z","tickets":["RR-2"]}]}
        ]}
        """
        let owners = RelayRemoteWorkspaceFeed.owners(fromPresence: Data(presence.utf8))
        let state = await feed(board, owners: owners).load()
        XCTAssertEqual(state.tickets.first { $0.id == "RR-1" }?.agent, "sky", "the more recently active agent owns it")
        XCTAssertNil(state.tickets.first { $0.id == "RR-2" }?.agent, "a stopped agent owns nothing")
        XCTAssertEqual(RelayRemoteWorkspaceFeed.owners(fromPresence: Data("not json".utf8)), [:])
    }

    func testFramesCarryNoTicketBodyAndNoPaths() async throws {
        let board = WorkspaceBoard(tickets: [("RR-1", "Plain title", "in_progress")])
        let state = await feed(board).load()
        let line = String(decoding: try FrameCodec.encode(.workspaceState(state)), as: UTF8.self)
        XCTAssertFalse(line.contains("/repos"), line)
        XCTAssertFalse(line.contains("secret.txt"), line)
        XCTAssertFalse(line.contains("relay/rr-1"), line)
        XCTAssertFalse(line.contains("/support"), line)
        // Every key in the frame is one the protocol defines.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["type", "projects", "tickets"])
        let ticket = try XCTUnwrap((object["tickets"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(ticket.keys), ["id", "title", "status", "project_id"])
    }

    func testTheListIsCappedNewestFirstAndSaysSo() async {
        let board = WorkspaceBoard(tickets: (0..<250).map { ("RR-\($0)", "Ticket \($0)", "backlog") })
        let state = await feed(board).load()
        XCTAssertEqual(state.tickets.count, RelayRemoteWorkspaceFeed.ticketLimit)
        XCTAssertEqual(state.truncated, true)
        XCTAssertEqual(state.tickets.first?.id, "RR-249", "newest activity first")
        XCTAssertEqual(state.tickets.last?.id, "RR-50")
    }

    func testAFullListOfLongTitlesStaysInsideOneFrame() throws {
        let board = WorkspaceBoard(tickets: (0..<200).map { ("RR-\($0)", String(repeating: "word ", count: 80), "ready") })
        let state = RelayRemoteWorkspaceFeed.state(projects: projects, snapshot: board.snapshot, owners: [:])
        XCTAssertTrue(state.tickets.allSatisfy { $0.title.count <= RelayRemoteWorkspaceFeed.titleLimit })
        XCTAssertLessThanOrEqual(try FrameCodec.encode(.workspaceState(state)).count, RelayRemoteProtocol.maxLineBytes)
    }

    func testATicketInNoRegisteredProjectIsLeftOut() {
        let board = WorkspaceBoard(tickets: [("RR-1", "Mine", "backlog")])
        let state = RelayRemoteWorkspaceFeed.state(projects: [projects[1]], snapshot: board.snapshot, owners: [:])
        XCTAssertEqual(state.tickets, [])
        XCTAssertEqual(state.projects.map(\.id), ["p-general"])
    }

    func testAnUnreachableDaemonIsAWellFormedError() async throws {
        let down = RelayRemoteWorkspaceFeed(
            projects: { self.projects }, fetchDashboard: { _ in throw URLError(.cannotConnectToHost) },
            fetchOwners: { [:] })
        let state = await down.load()
        XCTAssertEqual(state.error, RelayRemoteWorkspaceFeed.daemonDown)
        XCTAssertEqual(state.tickets, [])
        XCTAssertEqual(state.projects.count, 2)
        XCTAssertNoThrow(try FrameCodec.encode(.workspaceState(state)))

        let broken = RelayRemoteWorkspaceFeed(
            projects: { self.projects }, fetchDashboard: { _ in throw OrchestratorClientError.badStatus(500, "/Users/x/secret") },
            fetchOwners: { [:] })
        let other = await broken.load()
        XCTAssertEqual(other.error, RelayRemoteWorkspaceFeed.unreadable, "the daemon's own text, which may hold a path, is not passed on")
    }

    func testAnUnansweringDaemonTimesOut() async {
        var hung = RelayRemoteWorkspaceFeed(
            projects: { self.projects },
            fetchDashboard: { _ in
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return WorkspaceBoard(tickets: []).snapshot
            },
            fetchOwners: { [:] })
        hung.timeout = 0.2
        let started = Date()
        let state = await hung.load()
        XCTAssertEqual(state.error, RelayRemoteWorkspaceFeed.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: RR-551: one ticket's text

    /// A project directory holding real ticket files, and a feed that reads them.
    private func ticketFeed(_ tickets: [(id: String, title: String, status: String, body: String)]) throws
        -> (RelayRemoteWorkspaceFeed, URL) {
        let root = URL(fileURLWithPath: "/tmp/rrw-\(UUID().uuidString.prefix(8))")
        let orchestrator = root.appendingPathComponent(".orchestrator")
        try FileManager.default.createDirectory(at: orchestrator, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for ticket in tickets {
            let contents = """
            ---
            id: \(ticket.id)
            title: "\(ticket.title)"
            status: \(ticket.status)
            priority: medium
            execution_mode: implementation
            depends_on: []
            run_id: null
            canceled: false
            worker_model: balanced
            worker_effort: high
            ---
            \(ticket.body)
            """
            try contents.write(to: orchestrator.appendingPathComponent("\(ticket.id).md"), atomically: true, encoding: .utf8)
        }
        let board = WorkspaceBoard(tickets: tickets.map { ($0.id, $0.title, $0.status) }, repoPath: root.path)
        let registered = [RelaySessionControlHost.Project(id: "p-relay", name: "relay-runner", path: root.path,
                                                           availability: "available")]
        let feed = RelayRemoteWorkspaceFeed(projects: { registered }, fetchDashboard: { _ in board.snapshot },
                                            fetchOwners: { [:] })
        return (feed, root)
    }

    func testGetReturnsTheBodyWithoutItsFrontmatter() async throws {
        let body = "\n## Description\n\nOpen a ticket — café ☕.\n\n- [ ] one\n- [x] two\n"
        let (feed, _) = try ticketFeed([("RR-1", "Read me", "in_progress", body)])
        let reply = await feed.ticket(projectID: "p-relay", ticketID: "RR-1")
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.title, "Read me")
        XCTAssertEqual(reply.status, .inProgress)
        XCTAssertNil(reply.truncated)
        let markdown = try XCTUnwrap(reply.markdown)
        XCTAssertTrue(markdown.contains("## Description"))
        XCTAssertTrue(markdown.contains("- [x] two"))
        let line = String(decoding: try FrameCodec.encode(.workspaceTicket(reply)), as: UTF8.self)
        for key in ["worker_model", "worker_effort", "execution_mode", "depends_on", "priority: medium", "status: in_progress"] {
            XCTAssertFalse(line.contains(key), "\(key) is frontmatter and must not be sent")
        }
        XCTAssertFalse(line.contains("/tmp/rrw"), "no filesystem path is added")
        XCTAssertFalse(line.contains("secret.txt"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["type", "project_id", "ticket_id", "title", "status", "markdown"])
        XCTAssertEqual(markdown, body, "the body is sent as written")
    }

    func testGetCarriesTheOwningAgentAndStatusLanes() async throws {
        let first = try ticketFeed([("RR-1", "A", "ready", "x"), ("RR-2", "B", "backlog", "y"), ("RR-3", "C", "done", "z"),
                                    ("RR-4", "D", "canceled", "w")])
        let lanes = [("RR-1", TicketDetailStatus.queued), ("RR-2", .backlog), ("RR-3", .done)]
        for (id, status) in lanes {
            let reply = await first.0.ticket(projectID: "p-relay", ticketID: id)
            XCTAssertEqual(reply.status, status, id)
            XCTAssertNil(reply.error, id)
        }
        let canceled = await first.0.ticket(projectID: "p-relay", ticketID: "RR-4")
        XCTAssertEqual(canceled.error, RelayRemoteWorkspaceFeed.unknownTicket)

        var owned = first.0
        let root = ProgramBoardProjectPath.normalized(first.1.path)
        owned.fetchOwners = { [RelayRemoteWorkspaceFeed.ownerKey(path: root, ticketID: "RR-1"): "sky"] }
        let withOwner = await owned.ticket(projectID: "p-relay", ticketID: "RR-1")
        XCTAssertEqual(withOwner.agent, "sky")
        let without = await owned.ticket(projectID: "p-relay", ticketID: "RR-2")
        XCTAssertNil(without.agent)
    }

    func testGetForAnUnknownProjectOrTicketIsAnErrorWithNoBody() async throws {
        let (feed, _) = try ticketFeed([("RR-1", "Mine", "backlog", "body")])
        let project = await feed.ticket(projectID: "nope", ticketID: "RR-1")
        XCTAssertEqual(project.error, RelayRemoteWorkspaceFeed.unknownProject)
        XCTAssertNil(project.markdown)
        let ticket = await feed.ticket(projectID: "p-relay", ticketID: "RR-404")
        XCTAssertEqual(ticket.error, RelayRemoteWorkspaceFeed.unknownTicket)
        XCTAssertNil(ticket.markdown)
        XCTAssertEqual(ticket.ticketId, "RR-404")
        XCTAssertNoThrow(try FrameCodec.encode(.workspaceTicket(ticket)))
        // On the board but with no file behind it.
        let board = WorkspaceBoard(tickets: [("RR-9", "Ghost", "ready")], repoPath: "/tmp/rrw-missing")
        let ghost = RelayRemoteWorkspaceFeed(
            projects: { [.init(id: "p", name: "x", path: "/tmp/rrw-missing", availability: "available")] },
            fetchDashboard: { _ in board.snapshot }, fetchOwners: { [:] })
        let gone = await ghost.ticket(projectID: "p", ticketID: "RR-9")
        XCTAssertEqual(gone.error, RelayRemoteWorkspaceFeed.unknownTicket)
        XCTAssertFalse(String(decoding: try FrameCodec.encode(.workspaceTicket(gone)), as: UTF8.self).contains("/tmp/rrw-missing"))
    }

    func testGetWithTheDaemonDownIsAWellFormedError() async throws {
        var (feed, _) = try ticketFeed([("RR-1", "Mine", "backlog", "body")])
        feed.fetchDashboard = { _ in throw URLError(.cannotConnectToHost) }
        let down = await feed.ticket(projectID: "p-relay", ticketID: "RR-1")
        XCTAssertEqual(down.error, RelayRemoteWorkspaceFeed.daemonDown)
        XCTAssertNil(down.markdown)
        feed.fetchDashboard = { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return WorkspaceBoard(tickets: []).snapshot
        }
        feed.timeout = 0.2
        let slow = await feed.ticket(projectID: "p-relay", ticketID: "RR-1")
        XCTAssertEqual(slow.error, RelayRemoteWorkspaceFeed.timedOut)
    }

    func testABodyOverTheCapIsCutOnACharacterBoundaryAndMarkedTruncated() async throws {
        // 4-byte characters never divide evenly into the cap plus one, so a byte cut would split one.
        let long = String(repeating: "🙂a", count: 40_000)
        let (feed, _) = try ticketFeed([("RR-1", "Long", "ready", long)])
        let reply = await feed.ticket(projectID: "p-relay", ticketID: "RR-1")
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.truncated, true)
        let markdown = try XCTUnwrap(reply.markdown)
        XCTAssertLessThanOrEqual(markdown.utf8.count, WorkspaceTicketDetail.maxMarkdownBytes)
        XCTAssertTrue(long.hasPrefix(markdown), "a prefix of the body, with no replacement character")
        XCTAssertFalse(markdown.contains("\u{FFFD}"))
        XCTAssertLessThanOrEqual(try FrameCodec.encode(.workspaceTicket(reply)).count, RelayRemoteProtocol.maxLineBytes)
    }

    func testCapKeepsAShortBodyAndCutsAtTheLimit() {
        XCTAssertEqual(RelayRemoteWorkspaceFeed.cap("hello", bytes: 5).0, "hello")
        XCTAssertFalse(RelayRemoteWorkspaceFeed.cap("hello", bytes: 5).1)
        let cut = RelayRemoteWorkspaceFeed.cap("ab🙂cd", bytes: 5)
        XCTAssertEqual(cut.0, "ab", "a character that does not fit is left out whole")
        XCTAssertTrue(cut.1)
        XCTAssertEqual(RelayRemoteWorkspaceFeed.cap("ab🙂cd", bytes: 6).0, "ab🙂")
    }

    func testABodyThatEscapesLargeStillFitsOneFrame() async throws {
        let quotes = String(repeating: "\"\\\n", count: 20_000)
        let (feed, _) = try ticketFeed([("RR-1", "Escapes", "ready", quotes)])
        let reply = await feed.ticket(projectID: "p-relay", ticketID: "RR-1")
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.truncated, true)
        XCTAssertLessThanOrEqual(try FrameCodec.encode(.workspaceTicket(reply)).count, RelayRemoteProtocol.maxLineBytes)
    }

    func testTheListStillCarriesNoBodyWhenTicketsHaveText() async throws {
        let (feed, _) = try ticketFeed([("RR-1", "Mine", "backlog", "SECRET BODY TEXT")])
        let state = await feed.load()
        XCTAssertEqual(state.tickets.map(\.id), ["RR-1"])
        XCTAssertFalse(String(decoding: try FrameCodec.encode(.workspaceState(state)), as: UTF8.self).contains("SECRET BODY TEXT"))
    }
}
