import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

/// RR-543: grouping, filtering and the pushed-update path of the Workspace
/// tab's list, against the scripted Mac.
@MainActor
final class WorkspaceListingTests: XCTestCase {
    private let state = WorkspaceState(
        projects: [WorkspaceProject(id: "p1", name: "relay-runner"), WorkspaceProject(id: "p2", name: "cad-engine"),
                   WorkspaceProject(id: "p3", name: "empty")],
        tickets: [
            WorkspaceTicket(id: "RR-3", title: "Backlog one", status: .backlog, projectId: "p1"),
            WorkspaceTicket(id: "RR-1", title: "Running", status: .inProgress, projectId: "p1", agent: "george"),
            WorkspaceTicket(id: "CE-8", title: "Review", status: .inProgress, projectId: "p2", agent: "sky"),
            WorkspaceTicket(id: "RR-2", title: "Waiting", status: .queued, projectId: "p1"),
        ])

    func testGroupsAreOrderedAndEmptyOnesHidden() {
        let all = WorkspaceListing(state)
        XCTAssertEqual(all.groups.map(\.status), [.inProgress, .queued, .backlog])
        XCTAssertEqual(all.groups[0].tickets.map(\.id), ["RR-1", "CE-8"], "the Mac's order within a group")
        let cad = WorkspaceListing(state, project: "p2")
        XCTAssertEqual(cad.groups.map(\.status), [.inProgress])
        XCTAssertEqual(WorkspaceListing(state, project: "p3").groups, [])
        XCTAssertTrue(WorkspaceListing(state, project: "p3").isEmpty)
        XCTAssertTrue(WorkspaceListing(WorkspaceState(projects: [], tickets: [])).isEmpty)
    }

    func testTabsAreAllThenEachProjectWithCounts() {
        let tabs = WorkspaceListing(state).tabs
        XCTAssertEqual(tabs.map(\.name), ["All", "relay-runner", "cad-engine", "empty"])
        XCTAssertEqual(tabs.map(\.count), [4, 3, 1, 0])
        XCTAssertEqual(tabs.map(\.id), [nil, "p1", "p2", "p3"])
        XCTAssertEqual(WorkspaceListing(state, project: "p1").tabs, tabs, "filtering keeps the strip")
    }

    func testFilteringAndUnknownSelection() {
        let relay = WorkspaceListing(state, project: "p1")
        XCTAssertEqual(relay.groups.flatMap(\.tickets).map(\.id), ["RR-1", "RR-2", "RR-3"])
        XCTAssertEqual(WorkspaceListing(state, project: "gone").groups, WorkspaceListing(state).groups)
        XCTAssertEqual(relay.projectName(of: state.tickets[2]), "cad-engine")
    }

    func testTruncatedFlag() {
        XCTAssertFalse(WorkspaceListing(state).truncated)
        var cut = state
        cut.truncated = true
        XCTAssertTrue(WorkspaceListing(cut).truncated)
    }

    func testPushedStateAndRefreshReachTheSession() async throws {
        let mac = FakeMac()
        mac.sessionRunning = false
        mac.workspace = state
        let transport = FakeTransport(mac: mac)
        let session = Fixtures.session(transport: transport, clock: TestClock())
        session.start()
        await eventually { session.state == .connectedToApp }
        XCTAssertTrue(session.requestWorkspace())
        await eventually { session.workspace == state }
        XCTAssertEqual(WorkspaceListing(try XCTUnwrap(session.workspace)).groups.count, 3)

        let changed = WorkspaceState(projects: state.projects, tickets: [state.tickets[1]], truncated: true)
        mac.workspace = changed
        XCTAssertTrue(session.requestWorkspace(), "pull to refresh asks again")
        await eventually { session.workspace == changed }
        XCTAssertEqual(mac.workspaceCommands.count, 2)
        XCTAssertTrue(WorkspaceListing(try XCTUnwrap(session.workspace)).truncated)
        session.stop()
    }

    func testAnErrorFromTheMacIsKept() async throws {
        let mac = FakeMac()
        mac.sessionRunning = false
        mac.workspace = WorkspaceState(projects: [], tickets: [], error: "The Workspace is not available.")
        let session = Fixtures.session(transport: FakeTransport(mac: mac), clock: TestClock())
        session.start()
        await eventually { session.state == .connectedToApp }
        session.requestWorkspace()
        await eventually { session.workspace?.error != nil }
        XCTAssertEqual(session.workspace?.error, "The Workspace is not available.")
        session.stop()
    }

    func testTruncatedRoundTripsAndAbsentMeansComplete() throws {
        let data = try JSONEncoder().encode(WorkspaceState(projects: [], tickets: [], truncated: true))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceState.self, from: data).truncated, true)
        let bare = Data(#"{"projects":[],"tickets":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceState.self, from: bare).truncated)
    }
}
