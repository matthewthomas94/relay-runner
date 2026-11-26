import RelayRemoteKit
import RelayRemoteProtocol
import XCTest
@testable import RelayRemote

/// RR-543: which body the Workspace tab shows for each feed.
final class WorkspaceTabTests: XCTestCase {
    private let ticket = WorkspaceTicket(id: "RR-1", title: "One", status: .queued, projectId: "p")
    private let projects = [WorkspaceProject(id: "p", name: "relay-runner")]

    func testNothingYetIsLoading() {
        XCTAssertEqual(WorkspacePhase(WorkspaceFeed(sample: nil), project: nil), .loading)
    }

    func testAListShowsItsGroups() {
        let state = WorkspaceState(projects: projects, tickets: [ticket])
        guard case .list(let listing) = WorkspacePhase(WorkspaceFeed(sample: state), project: nil) else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(listing.groups.map(\.status), [.queued])
    }

    func testAnEmptyListIsStillAListSoTheEmptyLineShows() {
        guard case .list(let listing) = WorkspacePhase(
            WorkspaceFeed(sample: WorkspaceState(projects: projects, tickets: [])), project: nil)
        else { return XCTFail("expected a list") }
        XCTAssertTrue(listing.isEmpty)
    }

    func testTheMacsErrorShowsAsAnError() {
        let state = WorkspaceState(projects: [], tickets: [], error: "unsupported")
        XCTAssertEqual(WorkspacePhase(WorkspaceFeed(sample: state), project: nil), .error("unsupported"))
    }

    func testUnreachableKeepsTheLastListAndWithoutOneStaysQuiet() {
        let state = WorkspaceState(projects: projects, tickets: [ticket])
        let kept = WorkspacePhase(WorkspaceFeed(sample: state, isUnreachable: true), project: nil)
        guard case .list = kept else { return XCTFail("the last list stays under the banner") }
        XCTAssertEqual(WorkspacePhase(WorkspaceFeed(sample: nil, isUnreachable: true), project: nil), .loading)
    }

    func testTheSelectedProjectFilters() {
        let other = WorkspaceTicket(id: "X-1", title: "Other", status: .backlog, projectId: "q")
        let state = WorkspaceState(projects: projects + [WorkspaceProject(id: "q", name: "x")], tickets: [ticket, other])
        guard case .list(let listing) = WorkspacePhase(WorkspaceFeed(sample: state), project: "q") else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(listing.groups.flatMap(\.tickets).map(\.id), ["X-1"])
    }

    @MainActor
    func testTheProjectSelectionLastsForTheAppSession() {
        let model = AppModel()
        model.workspaceProject = "q"
        XCTAssertEqual(model.workspaceProject, "q")
    }

    func testSampleLaunchOption() {
        XCTAssertEqual(LaunchOptions(arguments: ["--workspace-sample=empty"]).workspaceSample, "empty")
    }
}
