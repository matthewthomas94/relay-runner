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
                title: "Start session",
                systemName: "play.fill",
                help: "Start a Relay Runner voice session"
            )
        )
        XCTAssertEqual(
            ProgramSessionToolbarPresentation.resolve(hasActiveSession: true),
            ProgramSessionToolbarPresentation(
                title: "End session",
                systemName: "stop.fill",
                help: "End the active Relay Runner voice session"
            )
        )
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
}
