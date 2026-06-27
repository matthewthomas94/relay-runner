import XCTest
@testable import relay_runner

final class NotchStatusPlacementTests: XCTestCase {
    func testPlacesSurfaceToRightOfNotchAndBelowMenuBarArea() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxiliaryTopRightArea: CGRect(x: 800, y: 944, width: 712, height: 38)
        )

        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))

        XCTAssertEqual(placement.visibleFrame.size, NotchStatusPlacementPlanner.surfaceSize)
        XCTAssertGreaterThanOrEqual(placement.visibleFrame.minX, geometry.auxiliaryTopRightArea.minX)
        XCTAssertLessThanOrEqual(placement.visibleFrame.maxX, geometry.auxiliaryTopRightArea.maxX)
        XCTAssertLessThanOrEqual(placement.visibleFrame.maxY, geometry.auxiliaryTopRightArea.minY)
        XCTAssertLessThan(placement.retractedFrame.minX, placement.visibleFrame.minX)
    }

    func testPlacesActivityCapsuleToLeftOfNotchAndBelowMenuBarArea() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 712, height: 38),
            auxiliaryTopRightArea: CGRect(x: 800, y: 944, width: 712, height: 38)
        )

        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))
        let activityVisible = try XCTUnwrap(placement.activityVisibleFrame)
        let activityRetracted = try XCTUnwrap(placement.activityRetractedFrame)

        XCTAssertEqual(activityVisible.size, NotchStatusPlacementPlanner.activitySurfaceSize)
        XCTAssertLessThanOrEqual(activityVisible.maxX, geometry.auxiliaryTopLeftArea.maxX)
        XCTAssertGreaterThanOrEqual(activityVisible.minX, geometry.frame.minX)
        XCTAssertLessThanOrEqual(activityVisible.maxY, geometry.auxiliaryTopLeftArea.minY)
        XCTAssertGreaterThan(activityRetracted.minX, activityVisible.minX)
    }

    func testHidesSurfaceWhenDisplayDoesNotReportNotchArea() {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            auxiliaryTopRightArea: .zero
        )

        XCTAssertNil(NotchStatusPlacementPlanner.placement(for: geometry))
    }

    func testHidesSurfaceWhenNotchRightAreaCannotFitIcon() {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240),
            auxiliaryTopRightArea: CGRect(x: 300, y: 216, width: 20, height: 24)
        )

        XCTAssertNil(NotchStatusPlacementPlanner.placement(for: geometry))
    }

    func testHidesActivityCapsuleWhenLeftNotchAreaCannotFitFixedWidth() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 90, height: 38),
            auxiliaryTopRightArea: CGRect(x: 800, y: 944, width: 712, height: 38)
        )

        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))

        XCTAssertNil(placement.activityVisibleFrame)
        XCTAssertNil(placement.activityRetractedFrame)
    }

    func testActivityLabelsMapVoiceAndActionStatesToConciseCopy() {
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .recording), ["Listening"])
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .sent), ["Sending voice"])
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .speaking), ["Speaking response"])
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .messageWaiting(preview: "Long response")), ["Response ready"])
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .actionGlow(awaitingConfirmation: nil)),
            ["Using screen"]
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(
                for: .actionGlow(
                    awaitingConfirmation: ConfirmationPrompt(
                        summary: "Click Send",
                        risk: "high",
                        requestId: "confirm-1"
                    )
                )
            ),
            ["Awaiting approval"]
        )
    }

    func testActivityLabelsNormalizeWorkerActivityWithoutProviderSpecificCopy() {
        let now = Date(timeIntervalSince1970: 2_000)
        let run = RunState(
            ticketId: "RR-94",
            repoPath: "/repo",
            runId: 94,
            state: "Running",
            lastError: nil,
            activity: "Running Swift tests",
            activityAt: now.timeIntervalSince1970
        )

        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .idle, activeRuns: [run], now: now),
            ["Running tests"]
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.label(forWorkerActivity: "rm -rf /tmp/build"),
            "Worker running"
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.label(forWorkerActivity: "Editing NotchStatusController.swift"),
            "Editing files"
        )
    }

    func testActivityLabelsIncludeWaitingDependencyWhenReadyWorkIsBlocked() {
        let tickets = [
            ticket(id: "RR-1", status: .ready, dependsOn: ["RR-0"]),
            ticket(id: "RR-0", status: .backlog),
        ]

        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .idle, tickets: tickets),
            ["Waiting dependency"]
        )
    }

    func testReducedMotionPolicyDisablesPanelAnimationDurations() {
        XCTAssertEqual(NotchStatusAnimationPolicy.duration(0.22, reduceMotion: true), 0)
        XCTAssertEqual(NotchStatusAnimationPolicy.duration(0.22, reduceMotion: false), 0.22)
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
}
