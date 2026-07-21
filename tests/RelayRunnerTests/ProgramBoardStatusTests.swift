import XCTest
@testable import relay_runner

final class ProgramBoardStatusTests: XCTestCase {
    func testProgramBoardUsesSolidDarkFigmaSurfaces() {
        let panelFill = BoardDarkSurfaceStyle.panelFillNSColor.usingColorSpace(.sRGB)
        let border = BoardDarkSurfaceStyle.borderNSColor.usingColorSpace(.sRGB)

        XCTAssertEqual(ProgramBoardBackdropStyle.backdropOpacity, 1, accuracy: 0.001)
        XCTAssertEqual(panelFill?.redComponent ?? 0, 9 / 255, accuracy: 0.001)
        XCTAssertEqual(panelFill?.greenComponent ?? 0, 11 / 255, accuracy: 0.001)
        XCTAssertEqual(panelFill?.blueComponent ?? 0, 15 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.redComponent ?? 0, 17 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.greenComponent ?? 0, 22 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.blueComponent ?? 0, 29 / 255, accuracy: 0.001)
        XCTAssertEqual(BoardDarkSurfaceStyle.workspaceCornerRadius, 16)
        XCTAssertEqual(BoardDarkSurfaceStyle.columnCornerRadius, 16)
        XCTAssertEqual(BoardDarkSurfaceStyle.nestedCardCornerRadius, 14)
        XCTAssertEqual(BoardDarkSurfaceStyle.floatingPanelCornerRadius, 16)
        XCTAssertEqual(BoardSurfaceLayout.horizontalPadding, 8)
        XCTAssertEqual(BoardSurfaceLayout.columnSpacing, 12)
        XCTAssertEqual(BoardSurfaceLayout.navigationTopPadding, 7)
        XCTAssertEqual(BoardSurfaceLayout.navigationHeight, 24)
        XCTAssertEqual(BoardSurfaceLayout.navigationToPanelSpacing, 16)
        XCTAssertEqual(BoardSurfaceLayout.columnTopPadding, 47)
        XCTAssertEqual(BoardSurfaceLayout.columnHeight, 667)
        XCTAssertEqual(ProgramBoardBackdropStyle.bottomPadding, 22)
        XCTAssertEqual(ProgramBoardBackdropStyle.bottomCornerRadius, 16)
        XCTAssertEqual(
            ProgramBoardBackdropStyle.bottomCornerRadius,
            BoardDarkSurfaceStyle.workspaceCornerRadius
        )
        XCTAssertLessThanOrEqual(
            BoardDarkSurfaceStyle.columnCornerRadius,
            BoardDarkSurfaceStyle.workspaceCornerRadius
        )
        XCTAssertLessThanOrEqual(
            BoardDarkSurfaceStyle.nestedCardCornerRadius,
            BoardDarkSurfaceStyle.columnCornerRadius
        )
        XCTAssertLessThanOrEqual(
            BoardDarkSurfaceStyle.floatingPanelCornerRadius,
            BoardDarkSurfaceStyle.workspaceCornerRadius
        )
        XCTAssertEqual(BoardDarkSurfaceStyle.shadowOpacity, 0.08, accuracy: 0.001)
        XCTAssertEqual(
            ProgramBoardBackdropStyle.backdropHeight,
            BoardSurfaceLayout.columnTopPadding
                + BoardSurfaceLayout.columnHeight
                + ProgramBoardBackdropStyle.bottomPadding
        )
    }

    func testProgramBoardLayoutUsesCompactHeaderControls() {
        XCTAssertEqual(ProgramBoardLayout.panelHorizontalPadding, 8)
        XCTAssertEqual(ProgramBoardLayout.panelVerticalPadding, 16)
        XCTAssertEqual(ProgramBoardLayout.headerHorizontalInset, 16)
        XCTAssertEqual(ProgramBoardLayout.headerLeadingInset, 24)
        XCTAssertEqual(ProgramBoardLayout.projectsHeaderHeight, 32)
        XCTAssertEqual(ProgramBoardLayout.selectAllButtonWidth, 68)
        XCTAssertEqual(ProgramBoardLayout.selectAllButtonHeight, 24)
        XCTAssertEqual(ProgramBoardLayout.selectAllButtonHorizontalPadding, 8)
        XCTAssertEqual(ProgramBoardLayout.selectAllButtonVerticalPadding, 4)
        XCTAssertEqual(
            ProgramBoardLayout.newTicketButtonSize,
            ProgramBoardLayout.selectAllButtonHeight
        )
        XCTAssertEqual(ProgramBoardLayout.workHeaderHeight, 36)
        XCTAssertEqual(ProgramBoardLayout.workCardTopOffset, 100)
        XCTAssertEqual(ProgramBoardLayout.projectHeaderToListSpacing, 48)
        XCTAssertEqual(ProgramBoardLayout.projectListTopOffset, 96)
        XCTAssertEqual(ProgramBoardLayout.projectCardHeight, 136)
        XCTAssertEqual(ProgramBoardLayout.projectCardSpacing, 8)
        XCTAssertEqual(ProgramBoardLayout.statePanelHeight, BoardSurfaceLayout.columnHeight)
        XCTAssertEqual(ProgramBoardLayout.statePanelHorizontalPadding, BoardSurfaceLayout.horizontalPadding)
    }

    func testProgramBoardProjectListInsetsPreserveLaneAlignedCardEdges() {
        XCTAssertEqual(ProgramBoardLayout.projectScrollContentInsets.top, 0)
        XCTAssertEqual(ProgramBoardLayout.projectScrollContentInsets.leading, 0)
        XCTAssertEqual(ProgramBoardLayout.projectScrollContentInsets.trailing, 0)
        XCTAssertEqual(ProgramBoardLayout.projectScrollContentInsets.bottom, 28)
    }

    func testProgramBoardEmptyLanePresentationMatchesFigmaBody() {
        let disabled = ProgramBoardStyle.disabledTextNSColor.usingColorSpace(.sRGB)

        XCTAssertEqual(ProgramBoardLayout.emptyLaneBodyHeight, 551)
        XCTAssertEqual(disabled?.redComponent ?? 0, 100 / 255, accuracy: 0.001)
        XCTAssertEqual(disabled?.greenComponent ?? 0, 116 / 255, accuracy: 0.001)
        XCTAssertEqual(disabled?.blueComponent ?? 0, 139 / 255, accuracy: 0.001)
    }

    func testProgramBoardSessionToolbarMatchesWorkspaceNavigation() {
        XCTAssertEqual(
            ProgramBoardLayout.sessionToolbarTopPadding,
            BoardSurfaceLayout.navigationTopPadding
        )
        XCTAssertEqual(ProgramBoardLayout.sessionToolbarTrailingPadding, 40)
        XCTAssertEqual(
            WorkspaceNavigationStyle.controlHeight,
            BoardSurfaceLayout.navigationHeight
        )
        XCTAssertEqual(WorkspaceNavigationStyle.horizontalPadding, 2)
        XCTAssertEqual(WorkspaceNavigationStyle.cornerRadius, 4)
        XCTAssertEqual(WorkspaceNavigationStyle.iconTextSpacing, 6)
        XCTAssertEqual(WorkspaceNavigationStyle.iconSize, 10)
        XCTAssertTrue(WorkspaceNavigationStyle.systemFocusEffectDisabled)
        XCTAssertLessThan(
            WorkspaceNavigationStyle.iconSize,
            AppTypography.definition(for: .menuTab).size
        )
    }

    func testProgramBoardSessionToolbarEndsFortyPointsFromReferenceScreenEdge() {
        let screenWidth: CGFloat = 1_728
        let buttonTrailingEdge = screenWidth - ProgramBoardLayout.sessionToolbarTrailingPadding

        XCTAssertEqual(screenWidth - buttonTrailingEdge, 40)
    }

    func testProgramProjectsHeaderPresentationUsesActiveTextForAllProjects() {
        let allProjects = ProgramProjectsHeaderPresentation(
            isAllSelected: true,
            selectedScopeTitle: "All projects"
        )
        let selectedProject = ProgramProjectsHeaderPresentation(
            isAllSelected: false,
            selectedScopeTitle: "mentistic"
        )

        XCTAssertEqual(allProjects.selectAllTitle, "Select all")
        XCTAssertEqual(allProjects.selectedScopeTitle, "All projects")
        XCTAssertTrue(allProjects.selectAllUsesActiveText)
        XCTAssertEqual(selectedProject.selectedScopeTitle, "mentistic")
        XCTAssertFalse(selectedProject.selectAllUsesActiveText)

        let activeText = ProgramBoardStyle.neutralTextNSColor.usingColorSpace(.sRGB)
        XCTAssertEqual(activeText?.redComponent ?? 0, 248 / 255, accuracy: 0.001)
        XCTAssertEqual(activeText?.greenComponent ?? 0, 250 / 255, accuracy: 0.001)
        XCTAssertEqual(activeText?.blueComponent ?? 0, 252 / 255, accuracy: 0.001)
    }

    func testProgramBoardProjectHoverPresentationKeepsSelectedAndDisabledPrecedence() {
        let hoverFill = BoardDarkSurfaceStyle.hoverFillNSColor.usingColorSpace(.sRGB)
        let hover = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard,
            isHovered: true
        )
        let selected = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard,
            isSelected: true
        )
        let selectedHover = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard,
            isSelected: true,
            isHovered: true
        )
        let disabledHover = ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard,
            isEnabled: false,
            isHovered: true
        )

        XCTAssertEqual(hover.accent, .neutral)
        XCTAssertTrue(hover.usesHoverFill)
        XCTAssertEqual(hover.fillOverlayOpacity, 0)
        XCTAssertEqual(hoverFill?.redComponent ?? 0, 18 / 255, accuracy: 0.001)
        XCTAssertEqual(hoverFill?.greenComponent ?? 0, 22 / 255, accuracy: 0.001)
        XCTAssertEqual(hoverFill?.blueComponent ?? 0, 30 / 255, accuracy: 0.001)
        XCTAssertEqual(selected.accent, .selected)
        XCTAssertTrue(selected.usesHoverFill)
        XCTAssertEqual(selected.fillOverlayOpacity, 0)
        XCTAssertEqual(selectedHover.accent, .selected)
        XCTAssertTrue(selectedHover.usesHoverFill)
        XCTAssertGreaterThan(selectedHover.strokeOpacity, hover.strokeOpacity)
        XCTAssertEqual(selectedHover.fillOverlayOpacity, 0)
        XCTAssertFalse(disabledHover.usesHoverFill)
        XCTAssertEqual(disabledHover.fillOverlayOpacity, 0)
        XCTAssertEqual(disabledHover.strokeOpacity, 0)
    }

    func testProgramBoardTicketHoverPresentationSuppressesDraggingAndReducedMotion() {
        let hover = ProgramBoardInteractionPresentation.resolve(
            surface: .ticketCard,
            isHovered: true
        )
        let draggingHover = ProgramBoardInteractionPresentation.resolve(
            surface: .ticketCard,
            isHovered: true,
            isDraggingSource: true
        )
        let selectedHover = ProgramBoardInteractionPresentation.resolve(
            surface: .ticketCard,
            isSelected: true,
            isHovered: true
        )
        let reducedMotionHover = ProgramBoardInteractionPresentation.resolve(
            surface: .ticketCard,
            isHovered: true,
            reduceMotion: true
        )

        XCTAssertEqual(hover.accent, .neutral)
        XCTAssertTrue(hover.usesHoverFill)
        XCTAssertEqual(hover.fillOverlayOpacity, 0)
        XCTAssertFalse(draggingHover.usesHoverFill)
        XCTAssertEqual(draggingHover.fillOverlayOpacity, 0)
        XCTAssertEqual(draggingHover.strokeOpacity, 0)
        XCTAssertEqual(selectedHover.accent, .selected)
        XCTAssertTrue(selectedHover.usesHoverFill)
        XCTAssertGreaterThan(selectedHover.strokeOpacity, hover.strokeOpacity)
        XCTAssertTrue(reducedMotionHover.usesHoverFill)
        XCTAssertEqual(reducedMotionHover.animationDuration, 0)
    }

    func testProgramBoardControlHoverPresentationUsesNeutralGenericHover() {
        let hover = ProgramBoardInteractionPresentation.resolve(
            surface: .control,
            isHovered: true
        )
        let focused = ProgramBoardInteractionPresentation.resolve(
            surface: .control,
            isFocused: true
        )
        let disabled = ProgramBoardInteractionPresentation.resolve(
            surface: .control,
            isEnabled: false,
            isHovered: true,
            isFocused: true
        )

        XCTAssertEqual(hover.accent, .neutral)
        XCTAssertTrue(hover.usesHoverFill)
        XCTAssertEqual(hover.fillOverlayOpacity, 0)
        XCTAssertGreaterThan(hover.strokeOpacity, 0)
        XCTAssertEqual(focused.accent, .selected)
        XCTAssertFalse(focused.usesHoverFill)
        XCTAssertGreaterThan(focused.strokeOpacity, hover.strokeOpacity)
        XCTAssertFalse(disabled.usesHoverFill)
        XCTAssertEqual(disabled.fillOverlayOpacity, 0)
        XCTAssertEqual(disabled.foregroundOpacity, 0.45)
    }

    func testBoardUpdateCheckUsesUserFacingNotchStatus() {
        XCTAssertEqual(BoardUpdateStatus.workingLabel, "Checking for updates")
    }

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
              "worker_model": "strong",
              "worker_effort": "high",
              "worker_sizing_rationale": "Cross-provider dispatch enforcement.",
              "worker_provider_notes": "Codex uses model_reasoning_effort; Claude uses --effort.",
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
        XCTAssertEqual(snapshot.inProgressWork.items.first?.workerModel, "strong")
        XCTAssertEqual(snapshot.inProgressWork.items.first?.workerEffort, "high")
        XCTAssertEqual(snapshot.inProgressWork.items.first?.workerSizingRationale, "Cross-provider dispatch enforcement.")
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
        XCTAssertEqual(model.selectedScopeTitle, "All projects")
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
            description: "Queued work."
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

    func testProgramBoardViewModelReloadPassesWorkspaceProjectScopeToDashboardFetcher() async throws {
        let snapshot = try programBoardSnapshot(
            clientPath: "/demo/aurora-web",
            toolsPath: "/demo/harbor-api"
        )
        let spy = ScopedProgramDashboardFetchSpy(snapshot: snapshot)
        let model = ProgramBoardViewModel(fetchDashboard: spy.fetch)
        model.projectPaths = ["/demo/aurora-web", "/demo/harbor-api"]

        await model.reload().value

        XCTAssertEqual(spy.scopes, [["/demo/aurora-web", "/demo/harbor-api"]])
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

    func testProgramBoardViewModelExplainsPersistentLocalServiceFailure() {
        XCTAssertEqual(
            ProgramBoardViewModel.reloadErrorMessage(for: URLError(.cannotConnectToHost)),
            "Relay Runner couldn’t reconnect to its local workspace service. Try again, or reopen the app if the problem continues."
        )
    }

    func testProgramBoardViewModelPrepareForOpeningPreservesVisibleSnapshot() throws {
        let clientPath = "/repo/client-dashboard"
        let toolsPath = "/repo/tools"
        let snapshot = try programBoardSnapshot(clientPath: clientPath, toolsPath: toolsPath)
        let item = try XCTUnwrap(snapshot.ticketItems(in: .backlog, selectedProjectPath: nil).first)
        let model = ProgramBoardViewModel()
        model.snapshot = snapshot
        model.reloadState = .failed("stale")
        model.errorMessage = "stale"
        model.selectProject(path: clientPath)
        model.selectTicket(item)
        model.beginCreate(in: .backlog)
        model.beginDrag(
            item: item,
            sourceLane: .backlog,
            location: CGPoint(x: 12, y: 34),
            cardCenterOffset: .zero,
            target: ProgramBoardDropTarget(lane: .ready, isValid: true)
        )

        model.prepareForOpening()

        XCTAssertEqual(model.snapshot, snapshot)
        XCTAssertEqual(model.reloadState, .idle)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedProjectPath, clientPath)
        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["CD-1"])
        XCTAssertNil(model.selectedTicketDetail)
        XCTAssertNil(model.creating)
        XCTAssertNil(model.editing)
        XCTAssertNil(model.dragItemID)
        XCTAssertNil(model.dragTarget)
        XCTAssertNil(model.dragPreview)
    }

    func testProgramBoardViewModelTracksActiveSessionForHeaderActions() {
        let model = ProgramBoardViewModel()

        XCTAssertFalse(model.hasActiveSession)

        model.hasActiveSession = true

        XCTAssertTrue(model.hasActiveSession)
    }

    func testProgramStatusItemActiveWorkerBadgeShowsActivity() throws {
        let active = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-117",
            title: "Add End Session",
            status: "active",
            runID: 155,
            runState: "active",
            activity: "Running Swift tests"
        )
        let fallback = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-118",
            title: "No activity yet",
            status: "active",
            runID: 156,
            runState: "active"
        )

        XCTAssertEqual(active.activeWorkerBadgeLabel, "Running Swift tests")
        XCTAssertEqual(fallback.activeWorkerBadgeLabel, "Running")
    }

    func testProgramStatusItemCardPresentationOrdersMetadataAndShowsAgentActivity() throws {
        let codexActive = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-117",
            title: "Add End Session",
            status: "active",
            runID: 155,
            runState: "active",
            activity: "Reviewing code",
            provider: "Codex/gpt-5"
        )
        let claudeActive = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-118",
            title: "Check Claude parity",
            status: "active",
            runID: 156,
            runState: "active",
            activity: "Running Swift tests",
            provider: "Claude/sonnet"
        )

        XCTAssertEqual(codexActive.programCardMetadataParts, ["RR-117", "Relay Runner"])
        XCTAssertEqual(codexActive.programAgentActivityLine, "Reviewing code")
        XCTAssertEqual(claudeActive.programAgentActivityLine, "Running Swift tests")
    }

    func testProgramBoardViewModelExposesSelectedProjectForSessionLaunch() throws {
        let clientPath = "/repo/client-dashboard"
        let toolsPath = "/repo/tools"
        let snapshot = try programBoardSnapshot(clientPath: clientPath, toolsPath: toolsPath)
        let model = ProgramBoardViewModel()
        model.snapshot = snapshot

        XCTAssertNil(model.selectedSessionProjectPath)

        model.selectProject(path: clientPath)
        XCTAssertEqual(model.selectedSessionProjectPath, clientPath)

        model.selectProject(path: "/repo/missing")
        XCTAssertNil(model.selectedSessionProjectPath)
    }

    func testProgramBoardViewModelApplyTicketMovesVisibleTicketImmediately() throws {
        let clientPath = "/repo/client-dashboard"
        let toolsPath = "/repo/tools"
        let snapshot = try programBoardSnapshot(clientPath: clientPath, toolsPath: toolsPath)
        let model = ProgramBoardViewModel()
        model.snapshot = snapshot

        model.applyTicket(ticket(id: "CD-1", status: .ready), projectPath: clientPath)

        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["TL-1"])
        XCTAssertEqual(model.ticketItems(in: .ready).map(\.ticketID), ["CD-1"])
        XCTAssertEqual(model.ticketItems(in: .ready).first?.status, "ready")
        XCTAssertEqual(model.snapshot?.backlogWork.counts.items, 1)
        XCTAssertEqual(model.snapshot?.readyWork.counts.items, 1)
    }

    func testProgramBoardViewModelRemoveTicketUpdatesVisibleSnapshotImmediately() throws {
        let clientPath = "/repo/client-dashboard"
        let toolsPath = "/repo/tools"
        let snapshot = try programBoardSnapshot(clientPath: clientPath, toolsPath: toolsPath)
        let model = ProgramBoardViewModel()
        model.snapshot = snapshot

        model.removeTicket(ticketID: "CD-1", projectPath: clientPath)

        XCTAssertEqual(model.ticketItems(in: .backlog).map(\.ticketID), ["TL-1"])
        XCTAssertEqual(model.snapshot?.backlogWork.counts.items, 1)
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

    func testProgramBoardEditRequestRoutesAllAndFilteredItemsToOwningChildRepo() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

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

            - [ ] Tooling work is editable.
            """
        )
        let snapshot = try programBoardSnapshot(clientPath: clientRepo.path, toolsPath: toolsRepo.path)
        let model = ProgramBoardViewModel()
        model.snapshot = snapshot

        let allProjectsItem = try XCTUnwrap(snapshot.ticketItems(
            in: .backlog,
            selectedProjectPath: nil
        ).first { $0.ticketID == "TL-1" })
        model.beginEdit(item: allProjectsItem)
        let allProjectsRequest = try XCTUnwrap(model.editRequest(
            title: "  Updated tools  ",
            status: .ready,
            priority: .high,
            description: "Updated tools work.",
            acceptanceCriteria: "- [ ] Updated tools criteria."
        ))
        XCTAssertEqual(allProjectsRequest.repoPath, toolsRepo.path)
        XCTAssertEqual(allProjectsRequest.ticketID, "TL-1")
        XCTAssertEqual(allProjectsRequest.title, "Updated tools")
        XCTAssertEqual(allProjectsRequest.status, .ready)
        XCTAssertEqual(allProjectsRequest.priority, .high)

        model.cancelEdit()
        model.selectProject(path: clientRepo.path)
        let filteredItem = try XCTUnwrap(model.ticketItems(in: .backlog).first)
        model.beginEdit(item: filteredItem)
        let filteredRequest = try XCTUnwrap(model.editRequest(
            title: "",
            status: .done,
            priority: .low,
            description: "Client done.",
            acceptanceCriteria: ""
        ))
        XCTAssertEqual(filteredRequest.repoPath, clientRepo.path)
        XCTAssertEqual(filteredRequest.ticketID, "CD-1")
        XCTAssertEqual(filteredRequest.title, "Untitled")

        let missingIdentity = try ticketItem(
            projectName: "Missing",
            path: "",
            ticketID: "MS-1",
            title: "Missing owner",
            status: "backlog"
        )
        model.beginEdit(item: missingIdentity)
        XCTAssertNil(model.editing)
        XCTAssertNil(model.editRequest(
            title: "No owner",
            status: .backlog,
            priority: .medium,
            description: "",
            acceptanceCriteria: ""
        ))
    }

    func testProgramBoardTicketEditorSavesOnlyOwningChildTicketAndEditableFields() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

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
            dependsOn: ["TL-0"],
            body: """
            ## Description

            Tools work.

            ## Acceptance criteria

            - [ ] Tooling work is editable.

            ## Notes

            Preserve this section.
            """
        )

        let request = ProgramBoardEditRequest(
            repoPath: toolsRepo.path,
            ticketID: "TL-1",
            title: "Updated tools",
            status: .ready,
            priority: .urgent,
            description: "Updated tools work.\n\nSecond paragraph.",
            acceptanceCriteria: "- [x] Tooling work is editable.\n- [ ] Program Board refreshes."
        )
        let result = try ProgramBoardTicketEditor.save(request)

        XCTAssertEqual(result.ticket.id, "TL-1")
        XCTAssertEqual(result.ticket.status, .ready)
        XCTAssertEqual(result.ticket.priority, .urgent)
        XCTAssertFalse(result.shouldDispatch)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".orchestrator").path
        ))
        XCTAssertTrue(
            try String(contentsOf: clientRepo.appendingPathComponent(".orchestrator/CD-1.md"), encoding: .utf8)
                .contains("title: Client backlog")
        )

        let savedContents = try String(
            contentsOf: toolsRepo.appendingPathComponent(".orchestrator/TL-1.md"),
            encoding: .utf8
        )
        let saved = try TicketParser.parse(contents: savedContents)
        XCTAssertEqual(saved.title, "Updated tools")
        XCTAssertEqual(saved.status, .ready)
        XCTAssertEqual(saved.priority, .urgent)
        XCTAssertEqual(saved.dependsOn, ["TL-0"])
        XCTAssertEqual(TicketParser.extractFullDescription(saved.body), "Updated tools work.\n\nSecond paragraph.")
        XCTAssertEqual(
            TicketParser.extractAcceptanceCriteria(saved.body),
            "- [x] Tooling work is editable.\n- [ ] Program Board refreshes."
        )
        XCTAssertTrue(saved.body.contains("## Notes\n\nPreserve this section."))
    }

    func testProgramBoardTicketEditorRejectsMissingTicketWithoutCreatingPlaceholder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("tools", isDirectory: true)
        try writeConfig(repo: repo, prefix: "TL", nextID: 2)
        let missingPath = repo.appendingPathComponent(".orchestrator/TL-1.md").path
        let request = ProgramBoardEditRequest(
            repoPath: repo.path,
            ticketID: "TL-1",
            title: "Should not save",
            status: .backlog,
            priority: .medium,
            description: "No file exists.",
            acceptanceCriteria: "- [ ] Do not create."
        )

        XCTAssertThrowsError(try ProgramBoardTicketEditor.save(request)) { error in
            XCTAssertEqual(error as? ProgramBoardEditError, .missingTicketFile(missingPath))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
    }

    func testProgramBoardTicketDeleterDeletesOnlyOwningChildTicket() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

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
            body: "## Description\n\nTools work."
        )

        let result = try ProgramBoardTicketDeleter.delete(ProgramBoardDeleteRequest(
            repoPath: toolsRepo.path,
            ticketID: "TL-1"
        ))

        XCTAssertEqual(result.ticketID, "TL-1")
        XCTAssertEqual(result.repoPath, toolsRepo.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: clientRepo.appendingPathComponent(".orchestrator/CD-1.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: toolsRepo.appendingPathComponent(".orchestrator/TL-1.md").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(".orchestrator").path
        ))
    }

    func testProgramBoardTicketDeleterTreatsMissingTicketAsNoOpWithoutCreatingPlaceholder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("tools", isDirectory: true)
        try writeConfig(repo: repo, prefix: "TL", nextID: 2)
        let missingPath = repo.appendingPathComponent(".orchestrator/TL-1.md").path

        let result = try ProgramBoardTicketDeleter.delete(ProgramBoardDeleteRequest(
            repoPath: repo.path,
            ticketID: "TL-1"
        ))

        XCTAssertEqual(result.ticketID, "TL-1")
        XCTAssertEqual(result.repoPath, repo.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
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
        let blockedRequest = try XCTUnwrap(model.dropRequest(
            for: blocked,
            sourceLane: .backlog,
            targetLane: .ready
        ))
        XCTAssertEqual(blockedRequest.ticketID, "RR-5")
        XCTAssertEqual(blockedRequest.targetStatus, .ready)

        let awaiting = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-4",
            title: "Awaiting review",
            status: "done",
            runID: 52,
            runState: "awaiting_merge",
            provider: "Claude/sonnet"
        )
        XCTAssertNil(model.dropRequest(for: awaiting, sourceLane: .done, targetLane: .backlog))
    }

    func testProgramBoardDragPreviewPreservesGrabOffsetAndSeparatesTarget() throws {
        let model = ProgramBoardViewModel()
        let item = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-1",
            title: "Drag me",
            status: "backlog"
        )
        let validTarget = ProgramBoardDropTarget(lane: .ready, isValid: true)

        model.beginDrag(
            item: item,
            sourceLane: .backlog,
            location: CGPoint(x: 120, y: 80),
            cardCenterOffset: CGSize(width: 35, height: -18),
            target: validTarget
        )

        XCTAssertEqual(model.dragItemID, item.id)
        XCTAssertEqual(model.dragTarget, validTarget)
        XCTAssertEqual(model.dragPreview?.cardCenter, CGPoint(x: 155, y: 62))

        model.updateDrag(
            location: CGPoint(x: 150, y: 110),
            target: ProgramBoardDropTarget(lane: .done, isValid: true)
        )

        XCTAssertEqual(model.dragTarget?.lane, .done)
        XCTAssertEqual(model.dragPreview?.cardCenter, CGPoint(x: 185, y: 92))

        model.updateDrag(location: CGPoint(x: 160, y: 120), target: model.dragTarget)

        XCTAssertEqual(model.dragTarget?.lane, .done)
        XCTAssertEqual(model.dragPreview?.cardCenter, CGPoint(x: 195, y: 102))

        model.endDrag()

        XCTAssertNil(model.dragItemID)
        XCTAssertNil(model.dragTarget)
        XCTAssertNil(model.dragPreview)
    }

    func testProgramBoardDragOffsetUsesReportedCardFrame() {
        let offset = ProgramBoardDragState.cardCenterOffset(
            cardFrame: CGRect(x: 100, y: 50, width: 246, height: 90),
            startLocation: CGPoint(x: 126, y: 70)
        )

        XCTAssertEqual(offset, CGSize(width: 97, height: 25))
        XCTAssertEqual(
            ProgramBoardDragState.cardCenterOffset(cardFrame: nil, startLocation: CGPoint(x: 126, y: 70)),
            .zero
        )
    }

    func testProgramBoardDropTargetUsesColumnFrameCoordinates() throws {
        let model = ProgramBoardViewModel()
        let item = try ticketItem(
            projectName: "Relay Runner",
            path: "/repo/relay-runner",
            ticketID: "RR-1",
            title: "Drag me",
            status: "backlog"
        )
        model.columnFrames = [
            .backlog: CGRect(x: 100, y: 50, width: 270, height: 633),
            .ready: CGRect(x: 390, y: 50, width: 270, height: 633),
            .done: CGRect(x: 970, y: 50, width: 270, height: 633),
        ]

        XCTAssertEqual(
            model.dropTarget(at: CGPoint(x: 430, y: 180), for: item, sourceLane: .backlog),
            ProgramBoardDropTarget(lane: .ready, isValid: true)
        )
        XCTAssertEqual(
            model.dropTarget(at: CGPoint(x: 180, y: 180), for: item, sourceLane: .backlog),
            ProgramBoardDropTarget(lane: .backlog, isValid: false)
        )
        XCTAssertNil(model.dropTarget(at: CGPoint(x: 30, y: 180), for: item, sourceLane: .backlog))
    }

    func testProgramBoardResolvedDropQueuesUnsatisfiedReadyDependenciesWithoutDispatch() {
        let dependencyBacklog = ticket(id: "RR-1", status: .backlog)
        let dependencyDone = ticket(id: "RR-1", status: .done)
        let blocked = ticket(id: "RR-2", status: .backlog, dependsOn: ["RR-1"])
        let request = ProgramBoardDropRequest(
            ticketID: "RR-2",
            repoPath: "/repo/relay-runner",
            targetStatus: .ready,
            shouldDispatch: true
        )

        let queued = ProgramBoardDropPolicy.validateResolvedDrop(
            request: request,
            ticket: blocked,
            allTickets: [dependencyBacklog, blocked]
        )
        XCTAssertEqual(queued?.ticketID, "RR-2")
        XCTAssertEqual(queued?.targetStatus, .ready)
        XCTAssertFalse(queued?.shouldDispatch == true)

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

    func testProgramBoardTicketMoverWritesOwningRepoAndRoutesReadyDispatch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeTicket(repo: root, id: "RR-1", title: "Parent copy", status: "backlog", body: "Parent body")
        try writeTicket(repo: child, id: "RR-1", title: "Child work", status: "backlog", body: "Child body")

        let defaults = TicketWriter.WorkerSizingDefaults(
            workerModel: "strong",
            workerEffort: "xhigh",
            workerSizingRationale: "User default from Relay Runner Settings.",
            workerProviderNotes: "User default applies to Codex and Claude; Codex uses model_reasoning_effort and Claude uses --effort."
        )

        let result = try ProgramBoardTicketMover.move(ProgramBoardDropRequest(
            ticketID: "RR-1",
            repoPath: child.path,
            targetStatus: .ready,
            shouldDispatch: true
        ), workerSizingDefaults: defaults)

        let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertEqual(result.ticket.status, .ready)
        XCTAssertEqual(
            result.dispatchRequest,
            ProgramBoardDispatchRequest(ticketID: "RR-1", repoPath: childPath, source: "board-drop")
        )
        XCTAssertEqual(try readTicket(repo: child, id: "RR-1").status, .ready)
        XCTAssertEqual(try readTicket(repo: child, id: "RR-1").workerModel, "strong")
        XCTAssertEqual(try readTicket(repo: child, id: "RR-1").workerEffort, "xhigh")
        XCTAssertEqual(try readTicket(repo: root, id: "RR-1").status, .backlog)

        let dispatch = try XCTUnwrap(result.dispatchRequest)
        let request = try XCTUnwrap(OrchestratorClient.dispatchRequest(
            ticketId: dispatch.ticketID,
            repoPath: dispatch.repoPath,
            source: dispatch.source,
            port: 8123
        ))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8123/v1/runs")
        let body = try jsonBody(request)
        XCTAssertEqual(body["ticket_id"] as? String, "RR-1")
        XCTAssertEqual(body["repo_path"] as? String, childPath)
        XCTAssertEqual(body["source"] as? String, "board-drop")
    }

    func testProgramBoardTicketMoverQueuesUnsatisfiedDependenciesWithoutDispatch() throws {
        let repo = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeTicket(repo: repo, id: "RR-1", title: "Dependency", status: "backlog", body: "Dependency body")
        try writeTicket(
            repo: repo,
            id: "RR-2",
            title: "Dependent",
            status: "backlog",
            dependsOn: ["RR-1"],
            body: "Dependent body"
        )

        let result = try ProgramBoardTicketMover.move(ProgramBoardDropRequest(
            ticketID: "RR-2",
            repoPath: repo.path,
            targetStatus: .ready,
            shouldDispatch: true
        ))

        XCTAssertEqual(result.ticket.status, .ready)
        XCTAssertNil(result.dispatchRequest)
        XCTAssertEqual(try readTicket(repo: repo, id: "RR-2").status, .ready)
    }

    func testProgramBoardTicketMoverRejectsInvalidResolvedDropWithoutChangingFile() throws {
        let repo = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repo) }
        try writeTicket(
            repo: repo,
            id: "RR-2",
            title: "Blocked work",
            status: "ready",
            body: "Blocked body"
        )
        let ticketURL = repo
            .appendingPathComponent(".orchestrator", isDirectory: true)
            .appendingPathComponent("RR-2.md")
        let before = try String(contentsOf: ticketURL)

        XCTAssertThrowsError(try ProgramBoardTicketMover.move(ProgramBoardDropRequest(
            ticketID: "RR-2",
            repoPath: repo.path,
            targetStatus: .ready,
            shouldDispatch: true
        ))) { error in
            guard case ProgramBoardDropError.rejected(let ticketID) = error else {
                return XCTFail("Expected rejected drop, got \(error)")
            }
            XCTAssertEqual(ticketID, "RR-2")
        }
        XCTAssertEqual(try String(contentsOf: ticketURL), before)
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
          "message": "Awaiting review: 1 ticket.",
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
        XCTAssertTrue(message.body.contains("Awaiting review:"))
        XCTAssertTrue(message.body.contains("Desktop Tools DT-12 - Check Claude parity"))
        XCTAssertTrue(message.body.contains("Claude/sonnet, awaiting review, run 52"))
    }

    func testProgramStatusOverlayFormatsEmptyState() {
        let message = ProgramStatusOverlayFormatter.message(
            active: emptyResponse(query: "in_progress_lane"),
            awaitingMerge: emptyResponse(query: "awaiting_merge")
        )

        XCTAssertEqual(message.title, "Program Status")
        XCTAssertEqual(message.body, "No active workers or tickets awaiting review.")
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

    func testProgramBoardContentPresentationDistinguishesLoadingAndFirstLoadFailure() {
        XCTAssertEqual(
            ProgramBoardContentPresentation.resolve(
                hasSnapshot: false,
                hasRegisteredProjects: false,
                reloadState: .loading
            ),
            .empty
        )
        XCTAssertEqual(
            ProgramBoardContentPresentation.resolve(
                hasSnapshot: false,
                hasRegisteredProjects: false,
                reloadState: .failed("daemon unavailable")
            ),
            .loadFailure
        )
        XCTAssertEqual(
            ProgramBoardContentPresentation.resolve(
                hasSnapshot: true,
                hasRegisteredProjects: false,
                reloadState: .succeeded
            ),
            .noRegisteredProjects
        )
        XCTAssertEqual(
            ProgramBoardContentPresentation.resolve(
                hasSnapshot: true,
                hasRegisteredProjects: true,
                reloadState: .succeeded
            ),
            .board
        )
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
        activity: String? = nil,
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
        if let activity {
            object["activity"] = activity
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

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(decoded as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readTicket(repo: URL, id: String) throws -> Ticket {
        let url = repo
            .appendingPathComponent(".orchestrator", isDirectory: true)
            .appendingPathComponent("\(id).md")
        let contents = try String(contentsOf: url)
        return try TicketParser.parse(contents: contents)
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

private final class ScopedProgramDashboardFetchSpy {
    private let snapshot: ProgramDashboardSnapshot
    private(set) var scopes: [[String]] = []

    init(snapshot: ProgramDashboardSnapshot) {
        self.snapshot = snapshot
    }

    func fetch(repoPaths: [String]) async throws -> ProgramDashboardSnapshot {
        scopes.append(repoPaths)
        return snapshot
    }
}

private struct ProgramBoardTestError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
