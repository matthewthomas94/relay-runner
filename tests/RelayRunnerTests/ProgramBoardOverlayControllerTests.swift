import XCTest
@testable import relay_runner

final class ProgramBoardOverlayControllerTests: XCTestCase {
    func testStatusPollRefreshesTheDashboardOnlyOnTheWorkTab() {
        // RR-440: a session keeps the Workspace open on its Terminal tab, and
        // each 10 s dashboard refresh made the daemon re-sweep every project.
        XCTAssertTrue(ProgramBoardOverlayController.statusPollRefreshesDashboard(
            selectedTab: .work,
            isEditing: false
        ))
        XCTAssertFalse(ProgramBoardOverlayController.statusPollRefreshesDashboard(
            selectedTab: .work,
            isEditing: true
        ))
        for tab in WorkspaceTab.allCases where tab != .work {
            XCTAssertFalse(ProgramBoardOverlayController.statusPollRefreshesDashboard(
                selectedTab: tab,
                isEditing: false
            ), "\(tab)")
        }
    }

    @MainActor
    func testWarmUpLoadsTheBoardWhileHiddenWithoutTouchingTheNotchOrLoader() async throws {
        // RR-471: launch and session start load the board in the background,
        // so the first Workspace open shows content instead of the sketch.
        let fetched = LockedScopes()
        let model = ProgramBoardViewModel(fetchDashboardRequest: { request in
            fetched.append(request.repoPaths)
            return .empty()
        })
        let project = ProjectResolver.LinkedProject(repoPath: URL(fileURLWithPath: "/repo/client-dashboard"))
        var route = ProjectResolver.BoardRoute.unavailable
        let controller = ProgramBoardOverlayController(boardRouteResolver: { route }, model: model)
        var loadingStates: [ProgramBoardLoadingState] = []
        controller.setLoadingStateHandler { loadingStates.append($0) }
        controller.setGeneralContextProvider { false }
        controller.setRequiresConfirmedProjectProvider { true }
        controller.setProjectScopeProvider { ["/repo/client-dashboard", "/repo/tools"] }

        XCTAssertFalse(controller.warmUp(), "no project route yet; the caller retries")
        XCTAssertNil(model.snapshot)

        route = .project(project)
        XCTAssertTrue(controller.warmUp())
        await model.inFlightReloadTask?.value

        XCTAssertEqual(fetched.values, [["/repo/client-dashboard", "/repo/tools"]])
        XCTAssertNotNil(model.snapshot)
        XCTAssertEqual(model.projectPaths, ["/repo/client-dashboard", "/repo/tools"])
        XCTAssertTrue(loadingStates.isEmpty, "a hidden warm-up must not animate the notch")
        XCTAssertFalse(controller.isVisible)

        // The opening finds a snapshot of exactly its projects and shows it
        // at once, as `show` decides.
        func opening(hasCachedSnapshot: Bool) -> ProgramBoardOverlayController.WorkspaceOpening? {
            ProgramBoardOverlayController.workspaceOpening(
                route: route,
                initialTab: .work,
                hasTerminalTab: true,
                hasSettingsTab: true,
                hasCachedSnapshot: hasCachedSnapshot,
                activityProjectPaths: ["/repo/client-dashboard", "/repo/tools"],
                showsRegisteredProjectCatalog: true
            )
        }
        let scope = try XCTUnwrap(opening(hasCachedSnapshot: false)?.projectScope)
        let warm = opening(hasCachedSnapshot: model.snapshot != nil && model.projectPaths == scope)
        XCTAssertEqual(warm?.contentLoadBlocked, false)
        XCTAssertEqual(warm?.startsLoading, false)
    }

    func testBoardChangeRefreshesOnlyAnOpenWorkTabAfterTheFirstObservation() {
        let before: [String: WorkspaceActivitySnapshotStore.FileRevision] = [
            "/repo/.orchestrator/RR-1.md": .init(modifiedAt: Date(timeIntervalSince1970: 1), size: 10),
        ]
        var after = before
        after["/repo/.orchestrator/RR-2.md"] = .init(modifiedAt: Date(timeIntervalSince1970: 2), size: 12)

        func refreshes(
            previous: [String: WorkspaceActivitySnapshotStore.FileRevision]?,
            isVisible: Bool = true,
            tab: WorkspaceTab = .work,
            isEditing: Bool = false
        ) -> Bool {
            ProgramBoardOverlayController.boardChangeRefreshesDashboard(
                previous: previous,
                current: after,
                isVisible: isVisible,
                selectedTab: tab,
                isEditing: isEditing
            )
        }

        XCTAssertTrue(refreshes(previous: before))
        XCTAssertFalse(refreshes(previous: nil), "the first observation is not a change")
        XCTAssertFalse(refreshes(previous: after), "unchanged files")
        XCTAssertFalse(refreshes(previous: before, isVisible: false), "a hidden board waits for its next open")
        XCTAssertFalse(refreshes(previous: before, tab: .terminal))
        XCTAssertFalse(refreshes(previous: before, isEditing: true))
    }

    func testActivityPollDrivesBoardWarmUpAndChangeRefresh() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"),
            encoding: .utf8
        )
        let refresh = try XCTUnwrap(appState.range(of: "private func refreshWorkspaceActivity("))
        let refreshEnd = try XCTUnwrap(
            appState.range(of: "private func cancelWorkspaceActivityRefresh(", range: refresh.upperBound..<appState.endIndex)
        )
        let refreshBody = String(appState[refresh.lowerBound..<refreshEnd.lowerBound])
        XCTAssertTrue(refreshBody.contains("programBoardOverlay.boardFilesDidChange(snapshot.ticketFileRevisions)"))
        XCTAssertTrue(refreshBody.contains("self.programBoardWarmUpPending, self.programBoardOverlay.warmUp()"))

        let launch = try XCTUnwrap(appState.range(of: "func newSession("))
        let launchEnd = try XCTUnwrap(
            appState.range(of: "refreshWorkspaceActivity(invalidateRoute: true)", range: launch.upperBound..<appState.endIndex)
        )
        XCTAssertTrue(appState[launch.lowerBound..<launchEnd.lowerBound].contains("programBoardWarmUpPending = true"))
    }

    func testSingleRepoColdRouteOpensResponsiveShellAndLoadsWorkInBackground() {
        let project = ProjectResolver.LinkedProject(repoPath: URL(fileURLWithPath: "/repo/client-dashboard"))
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .project(project),
            initialTab: .work,
            hasTerminalTab: true,
            hasSettingsTab: true,
            hasCachedSnapshot: false,
            activityProjectPaths: ["/repo/client-dashboard", "/repo/other"]
        )

        XCTAssertEqual(opening?.showsWorkTab, true)
        XCTAssertEqual(opening?.initialTab, .work)
        XCTAssertEqual(opening?.projectScope, ["/repo/client-dashboard"])
        XCTAssertEqual(opening?.selectedProjectPath, "/repo/client-dashboard")
        XCTAssertEqual(opening?.startsLoading, true)
        XCTAssertEqual(opening?.contentLoadBlocked, true)
        XCTAssertEqual(opening?.reloadsWork, true)
    }

    func testSingleRepoWarmRouteKeepsCachedWorkspaceContentVisibleDuringRefresh() {
        let project = ProjectResolver.LinkedProject(repoPath: URL(fileURLWithPath: "/repo/client-dashboard"))
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .project(project),
            initialTab: .work,
            hasTerminalTab: true,
            hasSettingsTab: true,
            hasCachedSnapshot: true,
            activityProjectPaths: ["/repo/client-dashboard", "/repo/other"]
        )

        XCTAssertEqual(opening?.startsLoading, false)
        XCTAssertEqual(opening?.contentLoadBlocked, false)
        XCTAssertEqual(opening?.reloadsWork, true)
    }

    func testRegistryV2ProjectRouteShowsEveryRegisteredProjectAndKeepsActiveSelection() {
        let active = ProjectResolver.LinkedProject(repoPath: URL(fileURLWithPath: "/repo/active"))
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .project(active),
            initialTab: .work,
            hasTerminalTab: true,
            hasSettingsTab: true,
            hasCachedSnapshot: true,
            activityProjectPaths: ["/repo/first", "/repo/active", "/repo/third"],
            showsRegisteredProjectCatalog: true
        )

        XCTAssertEqual(opening?.projectScope, ["/repo/first", "/repo/active", "/repo/third"])
        XCTAssertEqual(opening?.selectedProjectPath, "/repo/active")
    }

    func testReopeningTheWorkspaceRestoresTheSelectionItClosedWith() {
        typealias Remembered = ProgramBoardOverlayController.RememberedProjectSelection
        let general = Remembered(paths: ["/repo/a", "/repo/b"], contextPath: nil, isGeneralContext: true)

        XCTAssertNil(ProgramBoardOverlayController.reopenedProjectSelection(
            remembered: nil, contextPath: nil, isGeneralContext: true
        ), "the first open uses the route's own selection")
        XCTAssertEqual(ProgramBoardOverlayController.reopenedProjectSelection(
            remembered: general, contextPath: nil, isGeneralContext: true
        ), ["/repo/a", "/repo/b"])
        XCTAssertEqual(ProgramBoardOverlayController.reopenedProjectSelection(
            remembered: Remembered(paths: [], contextPath: nil, isGeneralContext: true),
            contextPath: nil, isGeneralContext: true
        ), [], "closing on All projects reopens on All projects")
        XCTAssertNil(ProgramBoardOverlayController.reopenedProjectSelection(
            remembered: general, contextPath: "/repo/c", isGeneralContext: false
        ), "a context change while closed picks the new project instead")
    }

    func testGeneralTasksRouteOpensOnEveryProjectWithNoFilter() {
        let general = ProjectResolver.LinkedProject(
            repoPath: URL(fileURLWithPath: "/support/relay-runner/general-tasks")
        )
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .project(general),
            initialTab: .work,
            hasTerminalTab: true,
            hasSettingsTab: true,
            hasCachedSnapshot: true,
            activityProjectPaths: ["/support/relay-runner/general-tasks", "/repo/first"],
            showsRegisteredProjectCatalog: true
        )

        XCTAssertEqual(opening?.projectScope, ["/support/relay-runner/general-tasks", "/repo/first"])
        XCTAssertNil(opening?.selectedProjectPath)
    }

    func testRegistryV2RefreshPreservesAVisibleExplicitProjectSelection() {
        let active = ProjectResolver.LinkedProject(repoPath: URL(fileURLWithPath: "/repo/active"))

        XCTAssertEqual(
            ProgramBoardOverlayController.refreshedProjectSelection(
                route: .project(active),
                currentSelection: "/repo/selected",
                projectScope: ["/repo/active", "/repo/selected"]
            ),
            "/repo/selected"
        )
        XCTAssertEqual(
            ProgramBoardOverlayController.refreshedProjectSelection(
                route: .project(active),
                currentSelection: "/repo/removed",
                projectScope: ["/repo/active"]
            ),
            "/repo/active"
        )
    }

    func testRegistryV2RefreshPreservesScopedPathWhileMatchingCanonicalAlias() throws {
        let alias = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("relay-runner-path-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: alias.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
        let active = ProjectResolver.LinkedProject(repoPath: alias)

        XCTAssertEqual(
            ProgramBoardOverlayController.refreshedProjectSelection(
                route: .project(active),
                currentSelection: "/private\(alias.path)",
                projectScope: [alias.path]
            ),
            alias.path
        )
    }

    func testRegistryInvalidationFollowsCommittedContextThroughPendingCancellationAndCommit() {
        let source = "/repo/source"
        let destination = "/repo/destination"
        let paths = [source, destination]
        let route = ProjectResolver.BoardRoute.project(.init(repoPath: URL(fileURLWithPath: destination)))
        let model = ProgramBoardViewModel(fetchDashboard: { _ in .empty() })
        model.setProjectScope(paths, selectedProjectPath: source)

        func refresh(committedContext: String) {
            let selected = ProgramBoardOverlayController.refreshedProjectSelection(
                route: route,
                currentSelection: model.selectedProjectPath,
                projectScope: paths,
                committedContextPath: committedContext,
                preserveProjectSelection: false
            )
            model.setProjectScope(paths, selectedProjectPath: selected)
        }

        // Registry preference has changed, but the source reply is still finishing.
        refresh(committedContext: source)
        XCTAssertEqual(model.selectedProjectPath, source)
        // Clearing the pending switch leaves the registry preference unchanged.
        refresh(committedContext: source)
        XCTAssertEqual(model.selectedProjectPath, source)
        // Only a committed context transition selects the destination board.
        refresh(committedContext: destination)
        XCTAssertEqual(model.selectedProjectPath, destination)
    }

    func testContextAwareRefreshPreservesAllProjectsAndOrdinaryProjectInspection() {
        let committed = "/repo/committed"
        let inspected = "/repo/inspected"
        let route = ProjectResolver.BoardRoute.project(.init(repoPath: URL(fileURLWithPath: inspected)))
        let paths = [committed, inspected]
        let model = ProgramBoardViewModel(fetchDashboard: { _ in .empty() })
        model.setProjectScope(paths, selectedProjectPath: committed)
        model.selectAllProjects()

        for preserveSelection in [true, false] {
            let selected = ProgramBoardOverlayController.refreshedProjectSelection(
                route: route,
                currentSelection: model.selectedProjectPath,
                projectScope: paths,
                committedContextPath: committed,
                preserveProjectSelection: preserveSelection
            )
            model.setProjectScope(paths, selectedProjectPath: selected)
            XCTAssertNil(model.selectedProjectPath)
        }

        model.selectProject(path: inspected)
        XCTAssertEqual(
            ProgramBoardOverlayController.refreshedProjectSelection(
                route: route,
                currentSelection: model.selectedProjectPath,
                projectScope: paths,
                committedContextPath: committed
            ),
            inspected
        )
        XCTAssertEqual(
            ProgramBoardOverlayController.refreshedProjectSelection(
                route: route,
                currentSelection: inspected,
                projectScope: [inspected],
                committedContextPath: committed,
                preserveProjectSelection: false
            ),
            inspected
        )
    }

    func testRefreshKeepsEveryStillRegisteredSelectedProject() {
        let paths = ["/repo/a", "/repo/b", "/repo/c"]
        let route = ProjectResolver.BoardRoute.project(.init(repoPath: URL(fileURLWithPath: "/repo/c")))

        for preserve in [true, false] {
            XCTAssertEqual(
                ProgramBoardOverlayController.refreshedProjectSelections(
                    route: route,
                    currentSelections: ["/repo/a", "/repo/b"],
                    projectScope: paths,
                    preserveProjectSelection: preserve
                ),
                ["/repo/a", "/repo/b"]
            )
        }
        XCTAssertEqual(
            ProgramBoardOverlayController.refreshedProjectSelections(
                route: route,
                currentSelections: ["/repo/a", "/repo/gone"],
                projectScope: paths
            ),
            ["/repo/a"]
        )
        // Nothing selected stays an explicit all-projects view.
        XCTAssertEqual(
            ProgramBoardOverlayController.refreshedProjectSelections(
                route: route,
                currentSelections: [],
                projectScope: paths
            ),
            []
        )
    }

    func testRegistryInvalidationWiresImmediateVisibleWorkspaceScopeRefresh() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Board/ProgramBoardOverlayController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appState.contains("programBoardOverlay.refreshProjectScopeAfterRegistryChange()"))
        XCTAssertTrue(controller.contains("func refreshProjectScopeAfterRegistryChange()"))
        XCTAssertTrue(controller.contains("preserveProjectSelection: false"))
        XCTAssertTrue(controller.contains("committedContextPath: workspace.contextPath"))
        XCTAssertTrue(controller.contains("currentSelections: model.selectedProjectPaths"))
    }

    func testProjectCardSelectionValidatesScopeBeforeCommittedConfirmation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Board/ProgramBoardOverlayController.swift"),
            encoding: .utf8
        )
        let overlayView = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Board/ProgramBoardOverlayView.swift"),
            encoding: .utf8
        )

        // No Workspace control switches the board's context and jumps to Work:
        // project rows filter in place and History picks its own project.
        XCTAssertFalse(controller.contains("projectSelectionHandler"))
        XCTAssertFalse(overlayView.contains("onSelectProject"))
        XCTAssertFalse(appState.contains("programBoardOverlay.setProjectSelectionHandler"))
        let launch = try XCTUnwrap(appState.range(of: "    func newSession("))
        let resolution = try XCTUnwrap(appState.range(of: "Self.prepareSessionContext(workingDirectory: workingDirectory, registry: projectRegistryV2)", range: launch.upperBound..<appState.endIndex))
        let commit = try XCTUnwrap(appState.range(of: "try assistantSessionStore.select(", range: resolution.upperBound..<appState.endIndex))
        let confirm = try XCTUnwrap(appState.range(of: "projectScopeCoordinator.confirm(projectScopeToken)", range: commit.upperBound..<appState.endIndex))
        let helper = try XCTUnwrap(appState.range(of: "    static func prepareSessionContext("))
        let helperEnd = try XCTUnwrap(appState.range(of: "    static func sessionLaunchRequest(", range: helper.upperBound..<appState.endIndex))
        let validation = appState[helper.lowerBound..<helperEnd.lowerBound]
        XCTAssertTrue(validation.contains("registry.scopeToken(matching: requestedProject)"))
        XCTAssertTrue(validation.contains("registry.validateScopeToken(token).isValid"))
        XCTAssertFalse(validation.contains("confirmProject("))
        XCTAssertFalse(validation.contains("projectScopeCoordinator"))
        XCTAssertFalse(appState[launch.lowerBound..<commit.lowerBound].contains("confirmProject(matching:"))
        XCTAssertFalse(appState[launch.lowerBound..<commit.lowerBound].contains("projectScopeCoordinator.confirm("))
        XCTAssertTrue(appState[commit.lowerBound..<confirm.lowerBound].contains("savingPreviousContext: true"))
        XCTAssertTrue(appState[commit.lowerBound..<confirm.lowerBound].contains("activeSessionProjectScopeToken = projectScopeToken"))
        XCTAssertTrue(appState.contains("refreshWorkspaceActivity(invalidateRoute: true)"))
    }

    func testWorkspaceRouteOpensWorkspaceAcrossDiscoveredProjects() {
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .programBoard,
            initialTab: .work,
            hasTerminalTab: true,
            hasSettingsTab: false,
            hasCachedSnapshot: true,
            activityProjectPaths: ["/repo/client-dashboard", "/repo/api"]
        )

        XCTAssertEqual(opening?.showsWorkTab, true)
        XCTAssertEqual(opening?.projectScope, ["/repo/client-dashboard", "/repo/api"])
        XCTAssertNil(opening?.selectedProjectPath)
        XCTAssertEqual(opening?.startsLoading, false)
        XCTAssertEqual(opening?.contentLoadBlocked, false)
        XCTAssertEqual(opening?.reloadsWork, true)
    }

    func testWorkspaceRouteWithoutSnapshotUsesPassiveLoadingUntilBoardDataArrives() {
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .programBoard,
            initialTab: .work,
            hasTerminalTab: true,
            hasSettingsTab: false,
            hasCachedSnapshot: false,
            activityProjectPaths: ["/repo/client-dashboard", "/repo/api"]
        )

        XCTAssertEqual(opening?.showsWorkTab, true)
        XCTAssertEqual(opening?.startsLoading, true)
        XCTAssertEqual(opening?.contentLoadBlocked, true)
        XCTAssertEqual(opening?.reloadsWork, true)
    }

    func testGeneralOpeningDoesNotStartBlockingRevealLoading() {
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .unavailable,
            initialTab: .work,
            hasTerminalTab: true,
            hasSettingsTab: true,
            hasCachedSnapshot: false,
            activityProjectPaths: []
        )

        XCTAssertEqual(opening?.showsWorkTab, true)
        XCTAssertEqual(opening?.initialTab, .work)
        XCTAssertEqual(opening?.projectScope, [])
        XCTAssertNil(opening?.selectedProjectPath)
        XCTAssertEqual(opening?.startsLoading, false)
        XCTAssertEqual(opening?.contentLoadBlocked, false)
        XCTAssertEqual(opening?.reloadsWork, false)
    }

    func testMenuBarClockWritesTheDayDateAndTimeAsTheMenuBarDoes() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T09:49:00Z"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(
            WorkspaceMenuBarClock.text(for: date, locale: Locale(identifier: "en_AU"), timeZone: utc),
            "Sun 1 Nov  9:49\u{202F}am"
        )
        XCTAssertEqual(
            WorkspaceMenuBarClock.text(for: date, locale: Locale(identifier: "en_GB"), timeZone: utc),
            "Sun 1 Nov  09:49"
        )
    }

    func testNotesTabFollowsWorkspaceAndAcceptsSearchFocus() {
        XCTAssertEqual(WorkspaceTab.allCases, [.work, .notes, .terminal, .history, .systemSettings])
        XCTAssertEqual(WorkspaceViewModel.availableTabs(showsWorkTab: true, showsTerminalTab: true, showsSettingsTab: true), [.work, .notes, .terminal, .history, .systemSettings])
        XCTAssertEqual(WorkspaceViewModel.availableTabs(showsWorkTab: false, showsTerminalTab: false, showsSettingsTab: false), [.notes])
        XCTAssertFalse(WorkspaceTab.work.requiresKeyWindow)
        XCTAssertTrue(WorkspaceTab.notes.requiresKeyWindow)
    }

    func testWorkspaceUsesExistingProjectsBoardWithoutAddedContextSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let view = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Board/ProgramBoardOverlayView.swift"),
            encoding: .utf8
        )
        let shell = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Board/WorkspaceOverlayShell.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("ProgramBoardContent("))
        XCTAssertFalse(view.contains("GeneralWorkView("))
        XCTAssertFalse(view.contains("PersonalFileStorageFilesView("))
        XCTAssertFalse(view.contains("workspace.selectedTab == .conversation"))
        XCTAssertFalse(shell.contains("WorkspaceContextMenu("))
    }

    func testNotesOpenWithoutProjectOrUtilityContent() {
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .unavailable,
            initialTab: .work,
            hasTerminalTab: false,
            hasSettingsTab: false,
            hasCachedSnapshot: false,
            activityProjectPaths: []
        )

        XCTAssertEqual(opening?.initialTab, .work)
        XCTAssertEqual(opening?.contentLoadBlocked, false)
    }

    func testUtilityWorkspaceUpgradeDecisionAddsWorkWhenRoutingAppears() {
        let project = ProjectResolver.LinkedProject(repoPath: URL(fileURLWithPath: "/repo"))

        XCTAssertEqual(
            ProgramBoardOverlayController.utilityRouteUpgrade(
                isVisible: true,
                showsWorkTab: false,
                route: .project(project)
            ),
            .workspace
        )
        XCTAssertEqual(
            ProgramBoardOverlayController.utilityRouteUpgrade(
                isVisible: true,
                showsWorkTab: false,
                route: .programBoard
            ),
            .workspace
        )
        XCTAssertEqual(
            ProgramBoardOverlayController.utilityRouteUpgrade(
                isVisible: true,
                showsWorkTab: false,
                route: .unavailable
            ),
            .none
        )
        XCTAssertEqual(
            ProgramBoardOverlayController.utilityRouteUpgrade(
                isVisible: true,
                showsWorkTab: true,
                route: .programBoard
            ),
            .none
        )
    }

    func testSessionControlActionStartsSelectedProjectWhenInactive() {
        let action = ProgramBoardOverlayController.sessionControlAction(
            hasActiveSession: false,
            selectedProjectPath: "/repo/client-dashboard"
        )

        XCTAssertEqual(action, .start("/repo/client-dashboard"))
    }

    func testSessionControlActionStartsDefaultSessionWhenNoProjectSelected() {
        let action = ProgramBoardOverlayController.sessionControlAction(
            hasActiveSession: false,
            selectedProjectPath: nil
        )

        XCTAssertEqual(action, .start(nil))
    }

    func testSessionControlActionEndsActiveSession() {
        let action = ProgramBoardOverlayController.sessionControlAction(
            hasActiveSession: true,
            selectedProjectPath: "/repo/client-dashboard"
        )

        XCTAssertEqual(action, .end)
    }

    func testRegistryV2SessionControlAllowsGeneralWithoutAProject() {
        XCTAssertTrue(ProgramSessionControlPolicy.canStart(
            hasActiveSession: false,
            selectedProjectPath: nil,
            requiresConfirmedProject: true
        ))
        XCTAssertTrue(ProgramSessionControlPolicy.canStart(
            hasActiveSession: false,
            selectedProjectPath: "/repo/selected",
            requiresConfirmedProject: true
        ))
        XCTAssertTrue(ProgramSessionControlPolicy.canStart(
            hasActiveSession: true,
            selectedProjectPath: nil,
            requiresConfirmedProject: true
        ))
        XCTAssertTrue(ProgramSessionControlPolicy.canStart(
            hasActiveSession: false,
            selectedProjectPath: nil,
            requiresConfirmedProject: false
        ))
    }

    func testSessionToolbarPresentationSwitchesBetweenStartAndEnd() {
        XCTAssertEqual(
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: false, provider: .codex),
            ProgramSessionToolbarPresentation(
                title: "Start Codex",
                icon: .squareTerminal,
                help: "Start session"
            )
        )
        XCTAssertEqual(
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: true, provider: .codex),
            ProgramSessionToolbarPresentation(
                title: "End Codex",
                icon: .squareTerminal,
                help: "End session"
            )
        )
        XCTAssertEqual(
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: false, provider: .claude).title,
            "Start Claude"
        )
        XCTAssertEqual(
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: true, provider: .claude).title,
            "End Claude"
        )
    }

    func testNoteToolbarWorksWithoutProjectAndUsesExactActions() {
        XCTAssertTrue(ProgramNoteControlPolicy.canStart(selectedProjectPath: nil))
        XCTAssertTrue(ProgramNoteControlPolicy.canStart(selectedProjectPath: "  "))
        XCTAssertTrue(ProgramNoteControlPolicy.canStart(selectedProjectPath: "/repo/selected"))
        XCTAssertEqual(
            ProgramNoteToolbarPresentation.resolve(phase: .idle),
            ProgramNoteToolbarPresentation(
                title: "Start Notetaker",
                help: "Record new note"
            )
        )
        XCTAssertEqual(
            ProgramNoteToolbarPresentation.resolve(phase: .recording),
            ProgramNoteToolbarPresentation(
                title: "Stop",
                help: "Stop and save"
            )
        )
        XCTAssertEqual(ProgramNoteToolbarPresentation.resolve(phase: .paused).title, "Stop")
    }

    func testNoteCatalogRetryObtainsFreshScopeAndIdentifiesFailedProject() async {
        var token = "stale-scope"
        let fetch: (String, String?, Int, String?) async throws -> RelayProjectNoteListResponse = { _, scope, limit, _ in
            guard scope == "fresh-scope" else { throw OrchestratorClientError.invalidRequest }
            return Self.noteListResponse(noteIDs: ["RR-N1"], limit: limit,
                                         hasMore: false, nextCursor: nil, totalCount: 1)
        }
        let failed = await ProgramBoardOverlayController.fetchProjectNotes(
            repoPaths: ["/repo/relay-runner"], scopeTokenProvider: { _ in token }, fetchPage: fetch
        )
        XCTAssertEqual(
            failed.errorMessage,
            "Could not load notes for relay-runner: Could not build orchestrator request."
        )
        token = "fresh-scope"
        let recovered = await ProgramBoardOverlayController.fetchProjectNotes(
            repoPaths: ["/repo/relay-runner"], scopeTokenProvider: { _ in token }, fetchPage: fetch
        )
        XCTAssertNil(recovered.errorMessage)
        XCTAssertEqual(recovered.notes.map { $0.card.noteID }, ["RR-N1"])
    }

    func testNoteCatalogFailureNamesTheDaemonCause() async {
        let conflict = "materialized .orchestrator was edited manually (added: .DS_Store); use explicit Save/import"
        let body = #"{"error":"\#(conflict)","error_code":"materialization_conflict","retryable":false}"#
        let result = await ProgramBoardOverlayController.fetchProjectNotes(
            repoPaths: [GlobalNoteStore.repositoryPath],
            scopeTokenProvider: { _ in nil },
            fetchPage: { _, _, _, _ in throw OrchestratorClientError.badStatus(409, body) }
        )
        XCTAssertEqual(result.errorMessage, "Could not load your notes: \(conflict).")
        XCTAssertEqual(result.failedProjectPaths, [GlobalNoteStore.repositoryPath])
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testNotetakerStartFailureIsPresentedOnlyWhileNoNoteExists() {
        func snapshot(
            phase: MeetingNoteCoordinatorPhase, noteID: String?, error: String?
        ) -> MeetingNoteCoordinatorSnapshot {
            MeetingNoteCoordinatorSnapshot(
                phase: phase, noteID: noteID, project: nil, liveHypothesisCount: 0,
                durableSegmentCount: 0, syncState: nil, errorMessage: error
            )
        }
        let conflict = "materialized .orchestrator was edited manually (added: .DS_Store); use explicit Save/import"
        XCTAssertEqual(
            ProgramNoteStartFailurePresentation.message(for: snapshot(phase: .error, noteID: nil, error: conflict)),
            "Notetaker could not start: \(conflict)."
        )
        XCTAssertNil(ProgramNoteStartFailurePresentation.message(
            for: snapshot(phase: .error, noteID: "RR-N1", error: conflict)
        ))
        XCTAssertNil(ProgramNoteStartFailurePresentation.message(for: snapshot(phase: .error, noteID: nil, error: "  ")))
        XCTAssertNil(ProgramNoteStartFailurePresentation.message(
            for: snapshot(phase: .preparing, noteID: nil, error: conflict)
        ))
    }

    func testProjectNoteCatalogUsesSupportedPageSizeAndFollowsManagerCursor() async {
        var requests: [(limit: Int, after: String?)] = []
        let firstPageIDs = (1...100).map { "RR-N\($0)" }

        let result = await ProgramBoardOverlayController.fetchProjectNotes(
            repoPaths: ["/repo/relay-runner"],
            scopeTokenProvider: { _ in "confirmed-scope" },
            fetchPage: { repoPath, token, limit, after in
                XCTAssertEqual(repoPath, "/repo/relay-runner")
                XCTAssertEqual(token, "confirmed-scope")
                XCTAssertLessThanOrEqual(limit, 100)
                requests.append((limit, after))
                if after == nil {
                    return Self.noteListResponse(
                        noteIDs: firstPageIDs,
                        limit: limit,
                        hasMore: true,
                        nextCursor: "RR-N100",
                        totalCount: 101
                    )
                }
                XCTAssertEqual(after, "RR-N100")
                return Self.noteListResponse(
                    noteIDs: ["RR-N101"],
                    limit: limit,
                    hasMore: false,
                    nextCursor: nil,
                    totalCount: 101
                )
            }
        )

        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(result.notes.count, 101)
        XCTAssertEqual(result.notes.first?.card.noteID, "RR-N1")
        XCTAssertEqual(result.notes.last?.card.noteID, "RR-N101")
        XCTAssertEqual(requests.map(\.limit), [100, 100])
        XCTAssertNil(requests[0].after)
        XCTAssertEqual(requests[1].after, "RR-N100")
    }

    func testProjectNoteCatalogPreservesArchivedCardHistoryReference() async throws {
        let result = await ProgramBoardOverlayController.fetchProjectNotes(
            repoPaths: ["/repo/relay-runner"],
            scopeTokenProvider: { _ in "confirmed-scope" },
            fetchPage: { _, _, limit, _ in
                Self.noteListResponse(
                    noteIDs: ["RR-N1"],
                    limit: limit,
                    hasMore: false,
                    nextCursor: nil,
                    totalCount: 1,
                    archivedNoteIDs: ["RR-N1"]
                )
            }
        )

        let item = try XCTUnwrap(result.notes.first)
        XCTAssertFalse(item.card.materialized)
        XCTAssertEqual(item.card.archivedAt, "2026-09-20T09:00:00Z")
        XCTAssertEqual(
            item.card.reference.historyReference,
            "abc123:.orchestrator/notes/RR-N1.md"
        )
        XCTAssertEqual(item.recordingLabel, "Archived")
        XCTAssertEqual(item.localSaveLabel, "Archived in history")
    }

    func testWorkspaceLatencyMetricRoundsMilliseconds() {
        let metric = WorkspaceLatencyMetric.measure(
            "command_to_first_motion",
            from: 10,
            to: 10.096
        )

        XCTAssertEqual(metric.name, "command_to_first_motion")
        XCTAssertEqual(metric.milliseconds, 96)
    }

    func testWorkspaceAnimationDurationMetricRoundsMilliseconds() {
        let metric = WorkspaceLatencyMetric.duration("reveal_duration", 0.955)

        XCTAssertEqual(metric.name, "reveal_duration")
        XCTAssertEqual(metric.milliseconds, 955)
    }

    func testProjectPickerHandoffUsesWorkspaceDismissAndRevealAnimations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/relay-runner/Board/ProgramBoardOverlayController.swift"
            ),
            encoding: .utf8
        )
        let appStateSource = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"),
            encoding: .utf8
        )

        let suspendStart = try XCTUnwrap(
            controllerSource.range(of: "func suspendForExternalWindowAnimated(")
        )
        let suspendEnd = try XCTUnwrap(
            controllerSource.range(
                of: "private func resumeAfterExternalWindow(",
                range: suspendStart.upperBound..<controllerSource.endIndex
            )
        )
        let suspendBody = String(
            controllerSource[suspendStart.lowerBound..<suspendEnd.lowerBound]
        )
        let resumeStart = suspendEnd
        let resumeEnd = try XCTUnwrap(
            controllerSource.range(
                of: "private func selectWorkspaceTab(",
                range: resumeStart.upperBound..<controllerSource.endIndex
            )
        )
        let resumeBody = String(
            controllerSource[resumeStart.lowerBound..<resumeEnd.lowerBound]
        )

        XCTAssertTrue(suspendBody.contains("container.animateDismiss("))
        XCTAssertTrue(suspendBody.contains("completion()"))
        XCTAssertTrue(resumeBody.contains("container.prepareForOpening("))
        XCTAssertTrue(resumeBody.contains("container.animateReveal("))
        XCTAssertTrue(appStateSource.contains("suspendWorkspaceForProjectPicker(ready)"))
    }

    func testTicketImagePickerHandoffDismissesAndRestoresTheSameWorkspaceDraft() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/relay-runner/Board/ProgramBoardOverlayController.swift"
            ),
            encoding: .utf8
        )

        let start = try XCTUnwrap(
            controllerSource.range(of: "private func chooseTicketImages(")
        )
        let end = try XCTUnwrap(
            controllerSource.range(
                of: "private func commitCreate(",
                range: start.upperBound..<controllerSource.endIndex
            )
        )
        let body = String(controllerSource[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(controllerSource.contains("onChooseTicketImages:"))
        XCTAssertTrue(body.contains("suspendForExternalWindowAnimated"))
        XCTAssertTrue(body.contains("ProgramTicketImagePicker.run()"))
        XCTAssertTrue(body.contains("completion(urls)"))
        XCTAssertTrue(body.contains("resumeAfterExternalWindow(initialTab: self.lastSelectedTab)"))
    }

    func testEditSaveFailureKeepsDraftVisibleAndSuccessfulSaveAvoidsDuplicateRefresh() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contents = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/relay-runner/Board/ProgramBoardOverlayController.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(contents.range(of: "private func commitEdit("))
        let end = try XCTUnwrap(
            contents.range(of: "private func handleDelete(", range: start.upperBound..<contents.endIndex)
        )
        let body = String(contents[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("model.applyTicket(result.ticket"))
        XCTAssertTrue(body.contains("model.reportEditFailure(message)"))
        XCTAssertTrue(body.contains("return"))
        XCTAssertTrue(body.contains("model.cancelEdit()"))
        XCTAssertFalse(body.contains("checkForUpdates("))
        let logLine = try XCTUnwrap(body.split(separator: "\n").first { $0.contains("NSLog(") })
        XCTAssertFalse(logLine.contains("request.repoPath"))
    }

    func testEscapeDismissalCapturesTheActiveModalBeforeDispatchingAsync() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contents = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/relay-runner/Board/ProgramBoardOverlayController.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(contents.range(of: "private func handle(_ event: NSEvent)"))
        let end = try XCTUnwrap(
            contents.range(of: "deinit {", range: start.upperBound..<contents.endIndex)
        )
        let body = String(contents[start.lowerBound..<end.lowerBound])
        let action = try XCTUnwrap(body.range(of: "let action: () -> Void"))
        let dispatch = try XCTUnwrap(body.range(of: "DispatchQueue.main.async(execute: action)"))

        XCTAssertLessThan(action.lowerBound, dispatch.lowerBound)
        XCTAssertTrue(body.contains("model.selectedTicketDetail != nil"))
        XCTAssertTrue(body.contains("model.spikeFollowupBatch != nil"))
    }

    private static func noteListResponse(
        noteIDs: [String],
        limit: Int,
        hasMore: Bool,
        nextCursor: String?,
        totalCount: Int,
        archivedNoteIDs: Set<String> = []
    ) -> RelayProjectNoteListResponse {
        let sync = RelayProjectNoteSyncState(mode: "local", state: "synced", recovery: nil)
        let notes = noteIDs.map { noteID in
            RelayProjectNoteCard(
                noteID: noteID,
                artifactID: "note-\(noteID)",
                projectID: "relay-runner",
                createdAt: "2026-09-20T08:00:00Z",
                updatedAt: "2026-09-20T08:00:00Z",
                recordingState: .completed,
                segmentCount: 1,
                materialized: !archivedNoteIDs.contains(noteID),
                archivedAt: archivedNoteIDs.contains(noteID) ? "2026-09-20T09:00:00Z" : nil,
                reference: RelayProjectNoteReference(
                    path: ".orchestrator/notes/\(noteID).md",
                    artifactRef: "refs/heads/relay/artifacts",
                    commit: "abc123",
                    revision: "def456",
                    historyReference: "abc123:.orchestrator/notes/\(noteID).md",
                    verified: true,
                    catalogCommit: "abc123"
                )
            )
        }
        return RelayProjectNoteListResponse(
            notes: notes,
            artifactCommit: "abc123",
            limit: limit,
            hasMore: hasMore,
            nextCursor: nextCursor,
            totalCount: totalCount,
            sync: sync
        )
    }
}

private final class LockedScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var scopes: [[String]] = []

    var values: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return scopes
    }

    func append(_ scope: [String]) {
        lock.lock()
        scopes.append(scope)
        lock.unlock()
    }
}
