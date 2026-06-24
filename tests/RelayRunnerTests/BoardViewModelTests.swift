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

    func testProjectBoardDragOffsetUsesReportedCardFrame() {
        let offset = DragState.cardCenterOffset(
            cardFrame: CGRect(x: 100, y: 50, width: 310, height: 82),
            startLocation: CGPoint(x: 126, y: 70)
        )
        let state = DragState(
            ticket: ticket(id: "RR-1", status: .backlog),
            location: CGPoint(x: 220, y: 180),
            cardCenterOffset: offset,
            insertTarget: nil
        )

        XCTAssertEqual(offset, CGSize(width: 129, height: 21))
        XCTAssertEqual(state.cardCenter, CGPoint(x: 349, y: 201))
        XCTAssertEqual(
            DragState.cardCenterOffset(cardFrame: nil, startLocation: CGPoint(x: 126, y: 70)),
            .zero
        )
    }

    func testProjectBoardDropTargetUsesColumnFrameCoordinates() {
        let model = BoardViewModel()
        model.tickets = [
            ticket(id: "RR-1", status: .backlog),
            ticket(id: "RR-2", status: .ready),
            ticket(id: "RR-3", status: .ready),
        ]
        model.columnFrames = [
            .backlog: CGRect(x: 100, y: 50, width: 358, height: 633),
            .ready: CGRect(x: 480, y: 50, width: 358, height: 633),
        ]
        model.cardFrames = [
            "RR-2": CGRect(x: 520, y: 120, width: 310, height: 80),
            "RR-3": CGRect(x: 520, y: 230, width: 310, height: 80),
        ]

        XCTAssertEqual(
            model.computeInsertTarget(at: CGPoint(x: 540, y: 130), draggedId: "RR-1"),
            DropTarget(status: .ready, index: 0)
        )
        XCTAssertEqual(
            model.computeInsertTarget(at: CGPoint(x: 540, y: 350), draggedId: "RR-1"),
            DropTarget(status: .ready, index: 2)
        )
        XCTAssertNil(model.computeInsertTarget(at: CGPoint(x: 40, y: 130), draggedId: "RR-1"))
    }

    func testProjectBoardQueuedTicketReportsUnsatisfiedDependencies() {
        let model = BoardViewModel()
        model.tickets = [
            ticket(id: "RR-1", status: .backlog),
            ticket(id: "RR-2", status: .ready, dependsOn: ["RR-1", "RR-missing"]),
            ticket(id: "RR-3", status: .done),
            ticket(id: "RR-4", status: .ready, dependsOn: ["RR-3"]),
            ticket(id: "RR-5", status: .ready),
            ticket(id: "RR-6", status: .ready, dependsOn: ["RR-5"]),
        ]
        model.runStates = [
            "RR-5": runState(ticketId: "RR-5", state: "Succeeded", runId: 45),
        ]

        XCTAssertEqual(model.waitingOn(for: model.tickets[1]), ["RR-1", "RR-missing"])
        XCTAssertEqual(model.waitingOn(for: model.tickets[3]), [])
        XCTAssertEqual(model.waitingOn(for: model.tickets[5]), ["RR-5"])
    }

    private func ticket(
        id: String,
        status: Ticket.Status,
        dependsOn: [String] = []
    ) -> Ticket {
        Ticket(
            id: id,
            title: id,
            status: status,
            priority: .medium,
            dependsOn: dependsOn,
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
