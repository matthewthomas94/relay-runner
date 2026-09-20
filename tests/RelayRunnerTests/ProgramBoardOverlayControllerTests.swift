import XCTest
@testable import relay_runner

final class ProgramBoardOverlayControllerTests: XCTestCase {
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
    }

    func testProjectCardSelectionPersistsTheRegistryPreference() throws {
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

        XCTAssertTrue(controller.contains("func setProjectSelectionHandler("))
        XCTAssertTrue(controller.contains("projectSelectionHandler?(repoPath)"))
        XCTAssertTrue(overlayView.contains("onSelectProject: onSelectProject"))
        XCTAssertTrue(appState.contains("programBoardOverlay.setProjectSelectionHandler"))
        XCTAssertTrue(appState.contains("projectRegistryV2.confirmProject(matching: repoPath)"))
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

    func testUtilityOnlyOpeningDoesNotStartBlockingRevealLoading() {
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .unavailable,
            initialTab: .work,
            hasTerminalTab: true,
            hasSettingsTab: true,
            hasCachedSnapshot: false,
            activityProjectPaths: []
        )

        XCTAssertEqual(opening?.showsWorkTab, false)
        XCTAssertEqual(opening?.initialTab, .terminal)
        XCTAssertEqual(opening?.projectScope, [])
        XCTAssertNil(opening?.selectedProjectPath)
        XCTAssertEqual(opening?.startsLoading, false)
        XCTAssertEqual(opening?.contentLoadBlocked, false)
        XCTAssertEqual(opening?.reloadsWork, false)
    }

    func testUnavailableRouteWithoutUtilityContentReturnsNil() {
        let opening = ProgramBoardOverlayController.workspaceOpening(
            route: .unavailable,
            initialTab: .work,
            hasTerminalTab: false,
            hasSettingsTab: false,
            hasCachedSnapshot: false,
            activityProjectPaths: []
        )

        XCTAssertNil(opening)
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

    func testRegistryV2SessionControlRequiresAnExplicitProjectButStillAllowsEnd() {
        XCTAssertFalse(ProgramSessionControlPolicy.canStart(
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
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: false),
            ProgramSessionToolbarPresentation(
                title: "Start Session",
                systemName: "play.fill",
                help: "Start a Relay Runner voice session"
            )
        )
        XCTAssertEqual(
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: true),
            ProgramSessionToolbarPresentation(
                title: "End Session",
                systemName: "stop.fill",
                help: "End the active Relay Runner voice session"
            )
        )
    }

    func testNoteToolbarRequiresSelectedProjectAndUsesExactActions() {
        XCTAssertFalse(ProgramNoteControlPolicy.canStart(selectedProjectPath: nil))
        XCTAssertFalse(ProgramNoteControlPolicy.canStart(selectedProjectPath: "  "))
        XCTAssertTrue(ProgramNoteControlPolicy.canStart(selectedProjectPath: "/repo/selected"))
        XCTAssertEqual(
            ProgramNoteToolbarPresentation.resolve(phase: .idle),
            ProgramNoteToolbarPresentation(
                title: "Start Note Taker",
                systemName: "waveform",
                help: "Record a note for the selected project"
            )
        )
        XCTAssertEqual(
            ProgramNoteToolbarPresentation.resolve(phase: .recording),
            ProgramNoteToolbarPresentation(
                title: "Stop",
                systemName: "stop.fill",
                help: "Stop and save the active note"
            )
        )
        XCTAssertEqual(ProgramNoteToolbarPresentation.resolve(phase: .paused).title, "Stop")
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
        totalCount: Int
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
                materialized: true,
                archivedAt: nil,
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
