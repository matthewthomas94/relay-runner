import XCTest
@testable import relay_runner

final class ProgramBoardStatusTests: XCTestCase {

    func testDecodesSummaryAndProviderNeutralWorkItems() throws {
        let summary = try decode("""
        {
          "query": "summary",
          "provider": null,
          "message": "Program summary: 1 indexed project.",
          "items": [
            {
              "project": {"name": "Relay Runner", "path": "/repo/relay-runner"},
              "open_tickets": 4,
              "active_runs": 2,
              "blocked": 1,
              "awaiting_merge": 1,
              "stale_runs": 0,
              "backlog_tickets": 1,
              "ready_tickets": 1,
              "in_progress_tickets": 1,
              "done_tickets": 1,
              "providers": ["Claude", "Codex"],
              "provider_health": []
            }
          ],
          "counts": {"projects": 1, "items": 1}
        }
        """)
        let inProgress = try decode("""
        {
          "query": "in_progress_lane",
          "provider": null,
          "message": "In progress: 2 tickets across 1 indexed project.",
          "items": [
            {
              "project": {"name": "Relay Runner", "path": "/repo/relay-runner"},
              "ticket_id": "RR-1",
              "title": "Build Program Board",
              "status": "active",
              "run_id": 27,
              "run_state": "active",
              "provider": "Codex/gpt-5",
              "branch": "relay/rr-42",
              "activity": "Editing Swift files"
            },
            {
              "project": {"name": "Relay Runner", "path": "/repo/relay-runner"},
              "ticket_id": "RR-2",
              "title": "Check Claude parity",
              "status": "active",
              "run_id": 28,
              "run_state": "active",
              "provider": "Claude/sonnet"
            }
          ],
          "counts": {"projects": 1, "items": 2}
        }
        """)
        let snapshot = ProgramDashboardSnapshot(
            summary: summary,
            backlogWork: emptyResponse(query: "backlog_lane"),
            readyWork: emptyResponse(query: "ready_lane"),
            inProgressWork: inProgress,
            doneWork: emptyResponse(query: "done_lane"),
            awaitingMerge: emptyResponse(query: "awaiting_merge")
        )

        XCTAssertTrue(snapshot.hasRegisteredProjects)
        XCTAssertTrue(snapshot.hasActiveWork)
        XCTAssertEqual(snapshot.projects.first?.providers, ["Claude", "Codex"])
        XCTAssertEqual(snapshot.projects.first?.backlogTickets, 1)
        XCTAssertEqual(snapshot.projects.first?.readyTickets, 1)
        XCTAssertEqual(snapshot.projects.first?.inProgressTickets, 1)
        XCTAssertEqual(snapshot.projects.first?.doneTickets, 1)
        XCTAssertEqual(snapshot.inProgressWork.items.map(\.provider), ["Codex/gpt-5", "Claude/sonnet"])
        XCTAssertEqual(snapshot.inProgressWork.items.first?.runID, "27")
    }

    func testProgramStatusOverlayFormatsActiveAndAwaitingMergeWorkers() throws {
        let active = try decode("""
        {
          "query": "in_progress_lane",
          "provider": null,
          "message": "In progress: 1 ticket.",
          "items": [
            {
              "project": {"name": "Relay Runner", "path": "/repo/relay-runner"},
              "ticket_id": "RR-58",
              "title": "Show program status in response overlay",
              "run_id": 46,
              "run_state": "active",
              "provider": "Codex/gpt-5"
            }
          ],
          "counts": {"projects": 1, "items": 1}
        }
        """)
        let awaitingMerge = try decode("""
        {
          "query": "awaiting_merge",
          "provider": null,
          "message": "Awaiting merge: 1 ticket.",
          "items": [
            {
              "project": {"name": "Desktop Tools", "path": "/repo/desktop-tools"},
              "ticket_id": "DT-12",
              "title": "Check Claude parity",
              "run_id": 52,
              "run_state": "awaiting_merge",
              "provider": "Claude/sonnet"
            }
          ],
          "counts": {"projects": 2, "items": 1}
        }
        """)

        let message = ProgramStatusOverlayFormatter.message(
            active: active,
            awaitingMerge: awaitingMerge
        )

        XCTAssertEqual(message.title, "Program Status")
        XCTAssertTrue(message.body.contains("Active:"))
        XCTAssertTrue(message.body.contains("Relay Runner RR-58 - Show program status in response overlay"))
        XCTAssertTrue(message.body.contains("Codex/gpt-5, active, run 46"))
        XCTAssertTrue(message.body.contains("Awaiting merge:"))
        XCTAssertTrue(message.body.contains("Desktop Tools DT-12 - Check Claude parity"))
        XCTAssertTrue(message.body.contains("Claude/sonnet, awaiting merge, run 52"))
    }

    func testProgramStatusOverlayFormatsEmptyState() {
        let message = ProgramStatusOverlayFormatter.message(
            active: emptyResponse(query: "in_progress_lane"),
            awaitingMerge: emptyResponse(query: "awaiting_merge")
        )

        XCTAssertEqual(message.title, "Program Status")
        XCTAssertEqual(message.body, "No active workers or tickets awaiting merge.")
    }

    func testProgramStatusOverlayFormatsUnavailableDaemonState() {
        let message = ProgramStatusOverlayFormatter.errorMessage(
            for: URLError(.cannotConnectToHost)
        )

        XCTAssertEqual(message.title, "Program status unavailable")
        XCTAssertEqual(message.body, "Relay Runner orchestrator is not reachable.")
    }

    func testProgramStatusStateDoesNotUseTTSMessagePreview() {
        let stateMachine = StateMachine()

        stateMachine.showProgramStatus(title: "Program Status", body: "Local status")

        XCTAssertEqual(
            stateMachine.state,
            .programStatus(title: "Program Status", body: "Local status")
        )
        XCTAssertNil(stateMachine.messagePreview)
    }

    private func decode(_ json: String) throws -> ProgramStatusResponse {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(ProgramStatusResponse.self, from: data)
    }

    private func emptyResponse(query: String) -> ProgramStatusResponse {
        ProgramStatusResponse(
            query: query,
            provider: nil,
            message: "No work.",
            items: [],
            counts: ProgramStatusCounts(projects: 1, items: 0)
        )
    }
}
