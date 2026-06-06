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
              "providers": ["Claude", "Codex"],
              "provider_health": []
            }
          ],
          "counts": {"projects": 1, "items": 1}
        }
        """)
        let active = try decode("""
        {
          "query": "active_work",
          "provider": null,
          "message": "Active work: 2 runs across 1 indexed project.",
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
        let empty = emptyResponse(query: "ready_work")
        let snapshot = ProgramDashboardSnapshot(
            summary: summary,
            activeWork: active,
            readyWork: empty,
            blockedWork: emptyResponse(query: "blocked_work"),
            awaitingMerge: emptyResponse(query: "awaiting_merge")
        )

        XCTAssertTrue(snapshot.hasRegisteredProjects)
        XCTAssertTrue(snapshot.hasActiveWork)
        XCTAssertEqual(snapshot.projects.first?.providers, ["Claude", "Codex"])
        XCTAssertEqual(snapshot.activeWork.items.map(\.provider), ["Codex/gpt-5", "Claude/sonnet"])
        XCTAssertEqual(snapshot.activeWork.items.first?.runID, "27")
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
