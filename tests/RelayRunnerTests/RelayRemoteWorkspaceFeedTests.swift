import Foundation
import RelayRemoteProtocol
import XCTest
@testable import relay_runner

/// A board a test edits while a feed reads it from another thread (RR-535).
final class WorkspaceBoard: @unchecked Sendable {
    static let repoPath = "/repos/relay-runner"
    private let lock = NSLock()
    private var stored: [(id: String, title: String, status: String)]

    init(tickets: [(String, String, String)]) { stored = tickets.map { (id: $0.0, title: $0.1, status: $0.2) } }

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
                    project: ProgramStatusProject(name: "relay-runner", path: Self.repoPath),
                    ticketID: ticket.0, title: ticket.1, status: ticket.2, priority: "medium",
                    ticketModifiedAt: Date(timeIntervalSince1970: Double(1_000 + index)),
                    branch: "relay/\(ticket.0.lowercased())", activity: "reading /repos/relay-runner/secret.txt")
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
}
