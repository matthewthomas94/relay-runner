import XCTest
@testable import relay_runner

final class BoardViewModelTests: XCTestCase {
    func testLaneTicketsUseEffectiveRunPlacementForCounts() {
        let model = BoardViewModel()
        model.tickets = [
            ticket(id: "RR-1", status: .backlog),
            ticket(id: "RR-2", status: .ready),
            ticket(id: "RR-3", status: .ready),
            ticket(id: "RR-4", status: .done),
        ]
        model.runStates = [
            "RR-2": runState(ticketId: "RR-2", state: "Running", runId: 42),
            "RR-3": runState(ticketId: "RR-3", state: "Succeeded", runId: 43),
        ]

        XCTAssertEqual(model.tickets(in: .backlog).map(\.id), ["RR-1"])
        XCTAssertEqual(model.tickets(in: .ready).map(\.id), [])
        XCTAssertEqual(model.tickets(in: .inProgress).map(\.id), ["RR-2"])
        XCTAssertEqual(model.tickets(in: .done).map(\.id), ["RR-4", "RR-3"])
    }

    private func ticket(id: String, status: Ticket.Status) -> Ticket {
        Ticket(
            id: id,
            title: id,
            status: status,
            priority: .medium,
            dependsOn: [],
            runId: nil,
            canceled: false,
            order: 0,
            description: nil,
            body: ""
        )
    }

    private func runState(ticketId: String, state: String, runId: Int) -> RunState {
        RunState(
            ticketId: ticketId,
            repoPath: "/repo",
            runId: runId,
            state: state,
            lastError: nil,
            activity: nil,
            activityAt: nil
        )
    }
}
