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

        XCTAssertEqual(snapshot.ticketItems(in: .backlog, selectedProjectPath: nil).map(\.ticketID), ["TL-1", "CD-1"])
        XCTAssertEqual(snapshot.ticketItems(in: .backlog, selectedProjectPath: clientPath).map(\.ticketID), ["CD-1"])
        XCTAssertEqual(snapshot.ticketItems(in: .ready, selectedProjectPath: toolsPath).map(\.ticketID), [])
        XCTAssertEqual(snapshot.ticketItems(in: .inProgress, selectedProjectPath: toolsPath).map(\.provider), ["Claude/sonnet"])
        XCTAssertEqual(snapshot.ticketItems(in: .done, selectedProjectPath: clientPath).map(\.provider), ["Codex/gpt-5"])
        XCTAssertTrue(snapshot.containsProject(path: toolsPath))
        XCTAssertEqual(snapshot.projectName(for: toolsPath), "Tools")

        let model = ProgramBoardViewModel()
        model.snapshot = snapshot
        let allProjectsRequest = try XCTUnwrap(model.dropRequest(
            for: snapshot.ticketItems(in: .backlog, selectedProjectPath: nil)[0],
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

    func testProgramBoardTicketLanesSortByOwningTicketFileModifiedAt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let clientRepo = root.appendingPathComponent("client-dashboard", isDirectory: true)
        let toolsRepo = root.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: clientRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: toolsRepo, withIntermediateDirectories: true)

        try writeTicket(repo: clientRepo, id: "CD-90", title: "Old client backlog", status: "backlog", body: "")
        try writeTicket(repo: clientRepo, id: "CD-1", title: "Recent client backlog", status: "backlog", body: "")
        try writeTicket(repo: toolsRepo, id: "TL-8", title: "Middle tools backlog", status: "backlog", body: "")

        try setModifiedAt(
            Date(timeIntervalSince1970: 1_700_000_000),
            forTicket: "CD-90",
            in: clientRepo
        )
        try setModifiedAt(
            Date(timeIntervalSince1970: 1_700_000_900),
            forTicket: "CD-1",
            in: clientRepo
        )
        try setModifiedAt(
            Date(timeIntervalSince1970: 1_700_000_500),
            forTicket: "TL-8",
            in: toolsRepo
        )

        let snapshot = ProgramDashboardSnapshot(
            summary: response(
                query: "summary",
                projects: 2,
                items: [
                    try projectItem(name: "Client Dashboard", path: clientRepo.path),
                    try projectItem(name: "Tools", path: toolsRepo.path),
                ]
            ),
            backlogWork: response(
                query: "backlog_lane",
                projects: 2,
                items: [
                    try ticketItem(projectName: "Client Dashboard", path: clientRepo.path, ticketID: "CD-90", title: "Old client backlog", status: "backlog"),
                    try ticketItem(projectName: "Tools", path: toolsRepo.path, ticketID: "TL-8", title: "Middle tools backlog", status: "backlog"),
                    try ticketItem(projectName: "Client Dashboard", path: clientRepo.path, ticketID: "CD-1", title: "Recent client backlog", status: "backlog"),
                ]
            ),
            readyWork: emptyResponse(query: "ready_lane", projects: 2),
            inProgressWork: emptyResponse(query: "in_progress_lane", projects: 2),
            doneWork: emptyResponse(query: "done_lane", projects: 2),
            awaitingMerge: emptyResponse(query: "awaiting_merge", projects: 2)
        )

        XCTAssertEqual(snapshot.ticketItems(in: .backlog, selectedProjectPath: nil).map(\.ticketID), ["CD-1", "TL-8", "CD-90"])
        XCTAssertEqual(snapshot.ticketItems(in: .backlog, selectedProjectPath: clientRepo.path).map(\.ticketID), ["CD-1", "CD-90"])
    }

    func testProgramBoardTicketLanesFallBackToNumericIdWhenModifiedAtTies() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("client-dashboard", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try writeTicket(repo: repo, id: "CD-90", title: "High id", status: "backlog", body: "")
        try writeTicket(repo: repo, id: "CD-1", title: "Low id", status: "backlog", body: "")
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try setModifiedAt(modifiedAt, forTicket: "CD-90", in: repo)
        try setModifiedAt(modifiedAt, forTicket: "CD-1", in: repo)

        let snapshot = ProgramDashboardSnapshot(
            summary: response(
                query: "summary",
                items: [try projectItem(name: "Client Dashboard", path: repo.path)]
            ),
            backlogWork: response(
                query: "backlog_lane",
                items: [
                    try ticketItem(projectName: "Client Dashboard", path: repo.path, ticketID: "CD-1", title: "Low id", status: "backlog"),
                    try ticketItem(projectName: "Client Dashboard", path: repo.path, ticketID: "CD-90", title: "High id", status: "backlog"),
                ]
            ),
            readyWork: emptyResponse(query: "ready_lane"),
            inProgressWork: emptyResponse(query: "in_progress_lane"),
            doneWork: emptyResponse(query: "done_lane"),
            awaitingMerge: emptyResponse(query: "awaiting_merge")
        )

        XCTAssertEqual(snapshot.ticketItems(in: .backlog, selectedProjectPath: nil).map(\.ticketID), ["CD-90", "CD-1"])
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
        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["TL-1", "CD-1"])
    }

    func testProgramBoardCreateFlowRequiresProjectWhenAllSelectedAndPreselectsFilteredProject() throws {
        let clientPath = "/repo/client-dashboard"
        let toolsPath = "/repo/tools"
        let snapshot = try programBoardSnapshot(clientPath: clientPath, toolsPath: toolsPath)
        let model = ProgramBoardViewModel()
        model.snapshot = snapshot

        model.beginCreate(in: .backlog)
        XCTAssertNil(model.creating?.selectedProjectPath)
        XCTAssertNil(model.createRequest(
            selectedProjectPath: nil,
            title: "  New client work  ",
            description: "Describe it."
        ))
        XCTAssertNil(model.createRequest(
            selectedProjectPath: "/repo/unknown",
            title: "Unknown work",
            description: "This should not mint."
        ))

        let allProjectsRequest = try XCTUnwrap(model.createRequest(
            selectedProjectPath: toolsPath,
            title: "  New tools work  ",
            description: "Build the tools flow."
        ))
        XCTAssertEqual(allProjectsRequest.repoPath, toolsPath)
        XCTAssertEqual(allProjectsRequest.status, .backlog)
        XCTAssertEqual(allProjectsRequest.title, "New tools work")
        XCTAssertFalse(allProjectsRequest.shouldDispatch)

        model.selectProject(path: clientPath)
        model.beginCreate(in: .ready)
        XCTAssertEqual(model.creating?.selectedProjectPath, clientPath)
        let selectedProjectRequest = try XCTUnwrap(model.createRequest(
            selectedProjectPath: model.creating?.selectedProjectPath,
            title: "",
            description: "Ready work."
        ))
        XCTAssertEqual(selectedProjectRequest.repoPath, clientPath)
        XCTAssertEqual(selectedProjectRequest.status, .ready)
        XCTAssertEqual(selectedProjectRequest.title, "Untitled")
        XCTAssertTrue(selectedProjectRequest.shouldDispatch)
    }

    func testProgramBoardTicketCreatorWritesOnlySelectedProjectAndClearsDraft() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let clientRepo = root.appendingPathComponent("client-dashboard", isDirectory: true)
        let toolsRepo = root.appendingPathComponent("tools", isDirectory: true)
        try writeConfig(repo: clientRepo, prefix: "CD", nextID: 3)
        try writeConfig(repo: toolsRepo, prefix: "TL", nextID: 7)

        let request = ProgramBoardCreateRequest(
            repoPath: toolsRepo.path,
            status: .ready,
            title: "Build tools flow",
            description: "Implement the selected project flow."
        )
        let result = try ProgramBoardTicketCreator.create(request)

        XCTAssertEqual(result.ticket.id, "TL-7")
        XCTAssertEqual(result.ticket.status, .ready)
        XCTAssertFalse(result.ticket.draft)
        XCTAssertTrue(result.shouldDispatch)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".orchestrator").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: clientRepo.appendingPathComponent(".orchestrator/CD-3.md").path
        ))
        XCTAssertEqual(
            try String(contentsOf: clientRepo.appendingPathComponent(".orchestrator/config.toml"), encoding: .utf8),
            """
            prefix = "CD"
            next_id = 3

            """
        )
        XCTAssertEqual(
            try String(contentsOf: toolsRepo.appendingPathComponent(".orchestrator/config.toml"), encoding: .utf8),
            """
            prefix = "TL"
            next_id = 8

            """
        )

        let ticketContents = try String(
            contentsOf: toolsRepo.appendingPathComponent(".orchestrator/TL-7.md"),
            encoding: .utf8
        )
        let ticket = try TicketParser.parse(contents: ticketContents)
        XCTAssertEqual(ticket.title, "Build tools flow")
        XCTAssertEqual(ticket.description, "Implement the selected project flow.")
        XCTAssertFalse(ticket.draft)
    }

    func testProgramBoardViewModelReloadUsesDashboardFetcherForAllAndSelectedScopes() async throws {
        let clientPath = "/repo/client-dashboard"
        let toolsPath = "/repo/tools"
        let snapshot = try programBoardSnapshot(clientPath: clientPath, toolsPath: toolsPath)
        let spy = ProgramDashboardFetchSpy(results: [.success(snapshot)], delayNanoseconds: 10_000_000)
        let model = ProgramBoardViewModel(fetchDashboard: spy.fetch)

        let allTask = model.reload()
        XCTAssertEqual(model.reloadState, .loading)
        await allTask.value

        XCTAssertEqual(spy.callCount, 1)
        XCTAssertEqual(model.reloadState, .succeeded)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["TL-1", "CD-1"])

        model.selectProject(path: toolsPath)
        await model.reload().value

        XCTAssertEqual(spy.callCount, 2)
        XCTAssertEqual(model.selectedScopeTitle, "Tools")
        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["TL-1"])
    }

    func testProgramBoardViewModelReloadFailureKeepsPreviousDataVisible() async throws {
        let previous = try programBoardSnapshot(
            clientPath: "/repo/client-dashboard",
            toolsPath: "/repo/tools"
        )
        let spy = ProgramDashboardFetchSpy(results: [
            .failure(ProgramBoardTestError(message: "daemon unavailable")),
        ])
        let model = ProgramBoardViewModel(fetchDashboard: spy.fetch)
        model.snapshot = previous

        await model.reload().value

        XCTAssertEqual(spy.callCount, 1)
        XCTAssertEqual(model.snapshot, previous)
        XCTAssertEqual(model.errorMessage, "daemon unavailable")
        XCTAssertEqual(model.reloadState, .failed("daemon unavailable"))
        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["TL-1", "CD-1"])
    }

    func testProgramBoardTicketDetailResolvesChildTicketFileFromAllProjects() throws {
        let root = try temporaryDirectory()
        let clientRepo = root.appendingPathComponent("client-dashboard", isDirectory: true)
        try writeTicket(
            repo: clientRepo,
            id: "CD-1",
            title: "Client backlog",
            status: "backlog",
            dependsOn: ["CD-0"],
            body: """
            ## Description

            Prepare the client dashboard ticket for implementation.

            ## Acceptance criteria

            - [ ] User can inspect the dashboard ticket.
            """
        )
        let item = try ticketItem(
            projectName: "Client Dashboard",
            path: clientRepo.path,
            ticketID: "CD-1",
            title: "Client backlog",
            status: "backlog",
            dependsOn: ["CD-0"],
            runID: 41,
            runState: "active",
            branch: "relay/cd-1",
            provider: "Codex/gpt-5"
        )
        let model = ProgramBoardViewModel()
        model.snapshot = ProgramDashboardSnapshot(
            summary: response(
                query: "summary",
                items: [try projectItem(name: "Client Dashboard", path: clientRepo.path, backlog: 1)]
            ),
            backlogWork: response(query: "backlog_lane", items: [item]),
            readyWork: emptyResponse(query: "ready_lane"),
            inProgressWork: emptyResponse(query: "in_progress_lane"),
            doneWork: emptyResponse(query: "done_lane"),
            awaitingMerge: emptyResponse(query: "awaiting_merge")
        )

        model.selectTicket(item)
        let detail = try XCTUnwrap(model.selectedTicketDetail)

        XCTAssertEqual(detail.identity?.projectPath, clientRepo.path)
        XCTAssertEqual(detail.identity?.ticketID, "CD-1")
        XCTAssertEqual(
            detail.ticketPath,
            clientRepo
                .appendingPathComponent(".orchestrator", isDirectory: true)
                .appendingPathComponent("CD-1.md")
                .path
        )
        XCTAssertEqual(detail.description, "Prepare the client dashboard ticket for implementation.")
        XCTAssertTrue(detail.acceptanceCriteria?.contains("User can inspect the dashboard ticket.") == true)
        XCTAssertEqual(detail.ticket?.dependsOn, ["CD-0"])
        XCTAssertEqual(detail.item.branch, "relay/cd-1")
        XCTAssertEqual(detail.item.provider, "Codex/gpt-5")
        XCTAssertEqual(detail.item.runID, "41")
    }

    func testProgramBoardFilteredSelectionResolvesOwningChildRepoForClaudeTicket() throws {
        let root = try temporaryDirectory()
        let clientRepo = root.appendingPathComponent("client-dashboard", isDirectory: true)
        let toolsRepo = root.appendingPathComponent("tools", isDirectory: true)
        try writeTicket(
            repo: clientRepo,
            id: "CD-1",
            title: "Client backlog",
            status: "backlog",
            body: "## Description\n\nClient work."
        )
        try writeTicket(
            repo: toolsRepo,
            id: "TL-1",
            title: "Tools backlog",
            status: "backlog",
            body: """
            ## Description

            Tools work.

            ## Acceptance criteria

            - [ ] Tooling work is inspectable.
            """
        )
        let clientItem = try ticketItem(
            projectName: "Client Dashboard",
            path: clientRepo.path,
            ticketID: "CD-1",
            title: "Client backlog",
            status: "backlog",
            provider: "Codex/gpt-5"
        )
        let toolsItem = try ticketItem(
            projectName: "Tools",
            path: toolsRepo.path,
            ticketID: "TL-1",
            title: "Tools backlog",
            status: "backlog",
            blockedBy: ["TL-0"],
            runID: 52,
            runState: "awaiting_merge",
            branch: "relay/tl-1",
            provider: "Claude/sonnet"
        )
        let model = ProgramBoardViewModel()
        model.snapshot = ProgramDashboardSnapshot(
            summary: response(
                query: "summary",
                projects: 2,
                items: [
                    try projectItem(name: "Client Dashboard", path: clientRepo.path, backlog: 1),
                    try projectItem(name: "Tools", path: toolsRepo.path, backlog: 1),
                ]
            ),
            backlogWork: response(query: "backlog_lane", projects: 2, items: [clientItem, toolsItem]),
            readyWork: emptyResponse(query: "ready_lane", projects: 2),
            inProgressWork: emptyResponse(query: "in_progress_lane", projects: 2),
            doneWork: emptyResponse(query: "done_lane", projects: 2),
            awaitingMerge: emptyResponse(query: "awaiting_merge", projects: 2)
        )

        model.selectProject(path: toolsRepo.path)
        let filteredItem = try XCTUnwrap(model.ticketItems(in: .backlog).first)
        model.selectTicket(filteredItem)
        let detail = try XCTUnwrap(model.selectedTicketDetail)

        XCTAssertEqual(filteredItem.ticketID, "TL-1")
        XCTAssertEqual(detail.identity?.projectPath, toolsRepo.path)
        XCTAssertEqual(
            detail.ticketPath,
            toolsRepo
                .appendingPathComponent(".orchestrator", isDirectory: true)
                .appendingPathComponent("TL-1.md")
                .path
        )
        XCTAssertTrue(detail.acceptanceCriteria?.contains("Tooling work is inspectable.") == true)
        XCTAssertEqual(detail.item.blockedBy, ["TL-0"])
        XCTAssertTrue(detail.item.isAwaitingMerge)
        XCTAssertEqual(detail.item.branch, "relay/tl-1")
        XCTAssertEqual(detail.item.provider, "Claude/sonnet")
        XCTAssertEqual(detail.item.runID, "52")
    }

    func testProgramBoardTicketDetailReportsMissingChildTicketFile() throws {
        let root = try temporaryDirectory()
        let missingRepo = root.appendingPathComponent("missing-project", isDirectory: true)
        let item = try ticketItem(
            projectName: "Missing",
            path: missingRepo.path,
            ticketID: "MP-1",
            title: "Missing file",
            status: "backlog"
        )

        let detail = ProgramTicketDetail.load(item: item)

        XCTAssertEqual(detail.identity?.ticketID, "MP-1")
        XCTAssertEqual(
            detail.ticketPath,
            missingRepo
                .appendingPathComponent(".orchestrator", isDirectory: true)
                .appendingPathComponent("MP-1.md")
                .path
        )
        XCTAssertNil(detail.ticket)
        XCTAssertTrue(detail.unavailableMessage?.contains("Ticket file was not found") == true)
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

    private func programBoardSnapshot(clientPath: String, toolsPath: String) throws -> ProgramDashboardSnapshot {
        ProgramDashboardSnapshot(
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
        branch: String? = nil,
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
        if let branch {
            object["branch"] = branch
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTicket(
        repo: URL,
        id: String,
        title: String,
        status: String,
        dependsOn: [String] = [],
        body: String
    ) throws {
        let dir = repo.appendingPathComponent(".orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let contents = """
        ---
        id: \(id)
        title: \(title)
        status: \(status)
        priority: medium
        depends_on: [\(dependsOn.joined(separator: ", "))]
        run_id: null
        canceled: false
        ---

        \(body)
        """
        try contents.write(
            to: dir.appendingPathComponent("\(id).md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeConfig(repo: URL, prefix: String, nextID: Int) throws {
        let dir = repo.appendingPathComponent(".orchestrator", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let contents = """
        prefix = "\(prefix)"
        next_id = \(nextID)

        """
        try contents.write(
            to: dir.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func setModifiedAt(_ date: Date, forTicket id: String, in repo: URL) throws {
        let path = repo.appendingPathComponent(".orchestrator/\(id).md").path
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
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

private final class ProgramDashboardFetchSpy {
    private let lock = NSLock()
    private var results: [Result<ProgramDashboardSnapshot, Error>]
    private let delayNanoseconds: UInt64
    private var calls = 0

    init(results: [Result<ProgramDashboardSnapshot, Error>], delayNanoseconds: UInt64 = 0) {
        self.results = results
        self.delayNanoseconds = delayNanoseconds
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func fetch() async throws -> ProgramDashboardSnapshot {
        let result = nextResult()

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result.get()
    }

    private func nextResult() -> Result<ProgramDashboardSnapshot, Error> {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

private struct ProgramBoardTestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
