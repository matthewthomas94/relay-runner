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
              "priority": "high",
              "depends_on": ["RR-0"],
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
        XCTAssertEqual(snapshot.inProgressWork.items.first?.priority, "high")
        XCTAssertEqual(snapshot.inProgressWork.items.first?.dependsOn, ["RR-0"])
    }

    func testProjectSelectionFiltersCanonicalTicketLanesAcrossProjects() throws {
        let clientPath = "/repo/client-dashboard"
        let toolsPath = "/repo/tools"
        let snapshot = ProgramDashboardSnapshot(
            summary: response(
                query: "summary",
                projects: 2,
                items: [
                    try projectItem(name: "Client Dashboard", path: clientPath, backlog: 1, ready: 1, done: 1),
                    try projectItem(name: "Tools", path: toolsPath, backlog: 1, inProgress: 1),
                ]
            ),
            backlogWork: response(
                query: "backlog_lane",
                projects: 2,
                items: [
                    try ticketItem(projectName: "Client Dashboard", path: clientPath, ticketID: "CD-1", title: "Client backlog", status: "backlog"),
                    try ticketItem(projectName: "Tools", path: toolsPath, ticketID: "TL-1", title: "Tools backlog", status: "backlog"),
                ]
            ),
            readyWork: response(
                query: "ready_lane",
                projects: 2,
                items: [
                    try ticketItem(projectName: "Client Dashboard", path: clientPath, ticketID: "CD-2", title: "Client ready", status: "ready"),
                ]
            ),
            inProgressWork: response(
                query: "in_progress_lane",
                projects: 2,
                items: [
                    try ticketItem(
                        projectName: "Tools",
                        path: toolsPath,
                        ticketID: "TL-2",
                        title: "Tools active",
                        status: "in progress",
                        runID: 41,
                        runState: "active",
                        provider: "Claude/sonnet"
                    ),
                ]
            ),
            doneWork: response(
                query: "done_lane",
                projects: 2,
                items: [
                    try ticketItem(
                        projectName: "Client Dashboard",
                        path: clientPath,
                        ticketID: "CD-3",
                        title: "Client done",
                        status: "done",
                        runState: "awaiting_merge",
                        provider: "Codex/gpt-5"
                    ),
                ]
            ),
            awaitingMerge: emptyResponse(query: "awaiting_merge", projects: 2)
        )

        XCTAssertEqual(snapshot.ticketItems(in: .backlog, selectedProjectPath: nil).map(\.ticketID), ["CD-1", "TL-1"])
        XCTAssertEqual(snapshot.ticketItems(in: .backlog, selectedProjectPath: clientPath).map(\.ticketID), ["CD-1"])
        XCTAssertEqual(snapshot.ticketItems(in: .ready, selectedProjectPath: toolsPath).map(\.ticketID), [])
        XCTAssertEqual(snapshot.ticketItems(in: .inProgress, selectedProjectPath: toolsPath).map(\.provider), ["Claude/sonnet"])
        XCTAssertEqual(snapshot.ticketItems(in: .done, selectedProjectPath: clientPath).map(\.provider), ["Codex/gpt-5"])
        XCTAssertTrue(snapshot.containsProject(path: toolsPath))
        XCTAssertEqual(snapshot.projectName(for: toolsPath), "Tools")

        let model = ProgramBoardViewModel()
        model.snapshot = snapshot
        let allProjectsRequest = try XCTUnwrap(model.dropRequest(
            for: snapshot.ticketItems(in: .backlog, selectedProjectPath: nil)[1],
            sourceLane: .backlog,
            targetLane: .done
        ))
        XCTAssertEqual(allProjectsRequest.ticketID, "TL-1")
        XCTAssertEqual(allProjectsRequest.repoPath, toolsPath)

        model.selectProject(path: clientPath)
        let selectedProjectRequest = try XCTUnwrap(model.dropRequest(
            for: model.ticketItems(in: .backlog)[0],
            sourceLane: .backlog,
            targetLane: .ready
        ))
        XCTAssertEqual(selectedProjectRequest.ticketID, "CD-1")
        XCTAssertEqual(selectedProjectRequest.repoPath, clientPath)
        XCTAssertTrue(selectedProjectRequest.shouldDispatch)
    }

    func testProgramBoardViewModelSelectionRestoresAllTicketsWithoutReload() throws {
        let clientPath = "/repo/client-dashboard"
        let toolsPath = "/repo/tools"
        let snapshot = ProgramDashboardSnapshot(
            summary: response(
                query: "summary",
                projects: 2,
                items: [
                    try projectItem(name: "Client Dashboard", path: clientPath),
                    try projectItem(name: "Tools", path: toolsPath),
                ]
            ),
            backlogWork: response(
                query: "backlog_lane",
                projects: 2,
                items: [
                    try ticketItem(projectName: "Client Dashboard", path: clientPath, ticketID: "CD-1", title: "Client backlog", status: "backlog"),
                    try ticketItem(projectName: "Tools", path: toolsPath, ticketID: "TL-1", title: "Tools backlog", status: "backlog"),
                ]
            ),
            readyWork: emptyResponse(query: "ready_lane", projects: 2),
            inProgressWork: emptyResponse(query: "in_progress_lane", projects: 2),
            doneWork: emptyResponse(query: "done_lane", projects: 2),
            awaitingMerge: emptyResponse(query: "awaiting_merge", projects: 2)
        )
        let model = ProgramBoardViewModel()
        model.snapshot = snapshot

        model.selectProject(path: toolsPath)
        XCTAssertFalse(model.isAllSelected)
        XCTAssertEqual(model.selectedScopeTitle, "Tools")
        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["TL-1"])

        model.selectAllProjects()
        XCTAssertTrue(model.isAllSelected)
        XCTAssertEqual(model.selectedScopeTitle, "All tickets")
        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["CD-1", "TL-1"])
    }

    func testProgramBoardEmptySnapshotHasNoTicketLanes() {
        let snapshot = ProgramDashboardSnapshot(
            summary: emptyResponse(query: "summary", projects: 0),
            backlogWork: emptyResponse(query: "backlog_lane", projects: 0),
            readyWork: emptyResponse(query: "ready_lane", projects: 0),
            inProgressWork: emptyResponse(query: "in_progress_lane", projects: 0),
            doneWork: emptyResponse(query: "done_lane", projects: 0),
            awaitingMerge: emptyResponse(query: "awaiting_merge", projects: 0)
        )

        XCTAssertFalse(snapshot.hasRegisteredProjects)
        XCTAssertFalse(snapshot.hasActiveWork)
        XCTAssertEqual(snapshot.ticketItems(in: .backlog, selectedProjectPath: nil), [])
    }

    func testProgramBoardDropRequestRejectsInvalidTargetsAndOwnedWorkerStates() throws {
        let model = ProgramBoardViewModel()
        let backlog = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-1",
            title: "Backlog",
            status: "backlog"
        )
        XCTAssertNil(model.dropRequest(for: backlog, sourceLane: .backlog, targetLane: .backlog))

        let missingProject = try ticketItem(
            projectName: "Unknown",
            path: "unknown",
            ticketID: "RR-2",
            title: "Missing project",
            status: "backlog"
        )
        XCTAssertNil(model.dropRequest(for: missingProject, sourceLane: .backlog, targetLane: .ready))

        let active = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-3",
            title: "Active",
            status: "in progress",
            runID: 51,
            runState: "active",
            provider: "Codex/gpt-5"
        )
        XCTAssertNil(model.dropRequest(for: active, sourceLane: .inProgress, targetLane: .done))

        let blocked = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-5",
            title: "Blocked",
            status: "backlog",
            blockedBy: ["RR-4"]
        )
        XCTAssertNil(model.dropRequest(for: blocked, sourceLane: .backlog, targetLane: .ready))

        let awaiting = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-4",
            title: "Awaiting merge",
            status: "done",
            runID: 52,
            runState: "awaiting_merge",
            provider: "Claude/sonnet"
        )
        XCTAssertNil(model.dropRequest(for: awaiting, sourceLane: .done, targetLane: .backlog))
    }

    func testProgramBoardResolvedDropRequiresSatisfiedReadyDependencies() {
        let dependencyBacklog = ticket(id: "RR-1", status: .backlog)
        let dependencyDone = ticket(id: "RR-1", status: .done)
        let blocked = ticket(id: "RR-2", status: .backlog, dependsOn: ["RR-1"])
        let request = ProgramBoardDropRequest(
            ticketID: "RR-2",
            repoPath: "/repo/relay-runner",
            targetStatus: .ready,
            shouldDispatch: true
        )

        XCTAssertNil(ProgramBoardDropPolicy.validateResolvedDrop(
            request: request,
            ticket: blocked,
            allTickets: [dependencyBacklog, blocked]
        ))

        let validated = ProgramBoardDropPolicy.validateResolvedDrop(
            request: request,
            ticket: blocked,
            allTickets: [dependencyDone, blocked]
        )
        XCTAssertEqual(validated?.ticketID, "RR-2")
        XCTAssertEqual(validated?.targetStatus, .ready)
        XCTAssertTrue(validated?.shouldDispatch == true)
    }

    func testProgramBoardResolvedDropRejectsNoOpCanceledAndClaimedTickets() {
        let request = ProgramBoardDropRequest(
            ticketID: "RR-1",
            repoPath: "/repo/relay-runner",
            targetStatus: .ready,
            shouldDispatch: true
        )

        XCTAssertNil(ProgramBoardDropPolicy.validateResolvedDrop(
            request: request,
            ticket: ticket(id: "RR-1", status: .ready),
            allTickets: []
        ))
        XCTAssertNil(ProgramBoardDropPolicy.validateResolvedDrop(
            request: request,
            ticket: ticket(id: "RR-1", status: .backlog, canceled: true),
            allTickets: []
        ))
        XCTAssertNil(ProgramBoardDropPolicy.validateResolvedDrop(
            request: request,
            ticket: ticket(id: "RR-1", status: .backlog, runId: 51),
            allTickets: []
        ))
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

    private func response(
        query: String,
        projects: Int = 1,
        items: [ProgramStatusItem]
    ) -> ProgramStatusResponse {
        ProgramStatusResponse(
            query: query,
            provider: nil,
            message: "Response.",
            items: items,
            counts: ProgramStatusCounts(projects: projects, items: items.count)
        )
    }

    private func emptyResponse(query: String, projects: Int = 1) -> ProgramStatusResponse {
        ProgramStatusResponse(
            query: query,
            provider: nil,
            message: "No work.",
            items: [],
            counts: ProgramStatusCounts(projects: projects, items: 0)
        )
    }

    private func projectItem(
        name: String,
        path: String,
        backlog: Int = 0,
        ready: Int = 0,
        inProgress: Int = 0,
        done: Int = 0
    ) throws -> ProgramStatusItem {
        try decodeItem([
            "project": ["name": name, "path": path],
            "backlog_tickets": backlog,
            "ready_tickets": ready,
            "in_progress_tickets": inProgress,
            "done_tickets": done,
            "providers": ["Codex", "Claude"],
        ])
    }

    private func ticketItem(
        projectName: String,
        path: String,
        ticketID: String,
        title: String,
        status: String,
        priority: String = "medium",
        dependsOn: [String] = [],
        blockedBy: [String] = [],
        runID: Int? = nil,
        runState: String? = nil,
        provider: String? = nil
    ) throws -> ProgramStatusItem {
        var object: [String: Any] = [
            "project": ["name": projectName, "path": path],
            "ticket_id": ticketID,
            "title": title,
            "status": status,
            "priority": priority,
            "depends_on": dependsOn,
            "blocked_by": blockedBy,
        ]
        if let runID {
            object["run_id"] = runID
        }
        if let runState {
            object["run_state"] = runState
        }
        if let provider {
            object["provider"] = provider
        }
        return try decodeItem(object)
    }

    private func decodeItem(_ object: [String: Any]) throws -> ProgramStatusItem {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(ProgramStatusItem.self, from: data)
    }

    private func ticket(
        id: String,
        status: Ticket.Status,
        dependsOn: [String] = [],
        canceled: Bool = false,
        runId: Int? = nil
    ) -> Ticket {
        Ticket(
            id: id,
            title: id,
            status: status,
            priority: .medium,
            dependsOn: dependsOn,
            runId: runId,
            canceled: canceled,
            order: 0,
            description: nil,
            body: ""
        )
    }
}
