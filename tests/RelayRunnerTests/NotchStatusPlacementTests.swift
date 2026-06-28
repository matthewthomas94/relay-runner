import XCTest
@testable import relay_runner

final class NotchStatusPlacementTests: XCTestCase {
    func testPlacesContinuousPillAcrossNotchWithoutActivityLabels() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
        )

        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))

        XCTAssertEqual(placement.notchSpacerWidth, 185)
        XCTAssertEqual(placement.activityLabelWidth, 0)
        XCTAssertEqual(placement.leadingSpacerWidth, NotchStatusPlacementPlanner.compactLeadingWingWidth)
        XCTAssertEqual(
            placement.visibleFrame.minX,
            geometry.auxiliaryTopLeftArea.maxX - NotchStatusPlacementPlanner.compactLeadingWingWidth
        )
        XCTAssertEqual(
            placement.visibleFrame.width,
            NotchStatusPlacementPlanner.compactLeadingWingWidth
                + placement.notchSpacerWidth
                + NotchStatusPlacementPlanner.glyphSize.width
        )
        XCTAssertEqual(
            placement.visibleFrame.maxX,
            geometry.auxiliaryTopRightArea.minX + NotchStatusPlacementPlanner.glyphSize.width
        )
        XCTAssertEqual(placement.glyphScreenX, geometry.auxiliaryTopRightArea.minX)
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)
    }

    func testPlacesContinuousPillAcrossNotchWithActivityLabels() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
        )
        let labelWidth: CGFloat = 72

        let placement = try XCTUnwrap(
            NotchStatusPlacementPlanner.placement(for: geometry, activityLabelWidth: labelWidth)
        )

        XCTAssertEqual(placement.notchSpacerWidth, 185)
        XCTAssertEqual(placement.activityLabelWidth, labelWidth)
        XCTAssertEqual(placement.leadingSpacerWidth, 0)
        XCTAssertEqual(
            placement.visibleFrame.minX,
            geometry.auxiliaryTopLeftArea.maxX - labelWidth
        )
        XCTAssertEqual(
            placement.visibleFrame.width,
            labelWidth
                + placement.notchSpacerWidth
                + NotchStatusPlacementPlanner.glyphSize.width
        )
        XCTAssertEqual(placement.glyphScreenX, geometry.auxiliaryTopRightArea.minX)
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)

        let compactPlacement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))
        XCTAssertEqual(compactPlacement.glyphScreenX, placement.glyphScreenX)
    }

    func testCentersFallbackPillWhenDisplayDoesNotReportNotchArea() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
            auxiliaryTopRightArea: .zero
        )

        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))

        XCTAssertEqual(placement.notchSpacerWidth, 0)
        XCTAssertEqual(placement.activityLabelWidth, 0)
        XCTAssertEqual(placement.leadingSpacerWidth, NotchStatusPlacementPlanner.compactLeadingWingWidth)
        XCTAssertEqual(placement.visibleFrame.width, NotchStatusPlacementPlanner.fallbackSurfaceWidth)
        XCTAssertEqual(placement.visibleFrame.midX, geometry.frame.midX)
        XCTAssertEqual(placement.glyphScreenX, placement.visibleFrame.maxX - NotchStatusPlacementPlanner.glyphSize.width)
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)
    }

    func testCentersFallbackPillWithActivityLabelsWhenDisplayDoesNotReportNotchArea() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080)
        )
        let labelWidth: CGFloat = 72

        let placement = try XCTUnwrap(
            NotchStatusPlacementPlanner.placement(for: geometry, activityLabelWidth: labelWidth)
        )

        XCTAssertEqual(placement.notchSpacerWidth, 0)
        XCTAssertEqual(placement.activityLabelWidth, labelWidth)
        XCTAssertEqual(placement.leadingSpacerWidth, 0)
        XCTAssertEqual(
            placement.visibleFrame.width,
            labelWidth + NotchStatusPlacementPlanner.glyphSize.width
        )
        XCTAssertEqual(placement.visibleFrame.midX, geometry.frame.midX)
        XCTAssertEqual(placement.glyphScreenX, placement.visibleFrame.maxX - NotchStatusPlacementPlanner.glyphSize.width)
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)
    }

    func testActivityLabelWidthMatchesUpdatedDesignScale() {
        XCTAssertEqual(NotchStatusPlacementPlanner.activityLabelWidth(for: nil), 0)
        XCTAssertEqual(NotchStatusPlacementPlanner.activityLabelWidth(for: ""), 0)
        XCTAssertEqual(NotchStatusPlacementPlanner.activityLabelWidth(for: "Playing"), 61)
        XCTAssertEqual(NotchStatusPlacementPlanner.activityLabelWidth(for: "Listening"), 72)
        XCTAssertEqual(
            NotchStatusPlacementPlanner.activityLabelWidth(for: "Moving ticket to Done, RR-100 is complete"),
            NotchStatusPlacementPlanner.maximumActivityLabelWidth
        )
    }

    func testActivityLabelsMapVoiceAndActionStatesToConciseCopy() {
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .recording), ["Listening"])
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .sent), ["Sending voice"])
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .speaking), ["Playing"])
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

    func testNotchSessionStatusMapsUserFacingStates() {
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .idle, hasActivityLabels: false),
            .notWorking
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .idle, hasActivityLabels: true),
            .working
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .recording, hasActivityLabels: true),
            .listening
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .listening, hasActivityLabels: false),
            .listening
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .speaking, hasActivityLabels: true),
            .playing
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .messageWaiting(preview: nil), hasActivityLabels: true),
            .playing
        )
    }

    func testNotchGlyphsMatchExportedDotMatrices() {
        XCTAssertEqual(NotchSessionStatus.notWorking.glyph, .neutral)
        XCTAssertEqual(NotchSessionStatus.working.glyph, .neutral)
        XCTAssertEqual(NotchSessionStatus.listening.glyph, .listening)
        XCTAssertEqual(NotchSessionStatus.playing.glyph, .playing)

        XCTAssertEqual(NotchStatusGlyph.neutral.dots.count, 4)
        XCTAssertEqual(NotchStatusGlyph.neutral.dots.map(\.x), [14.5, 9.5, 9.5, 14.5])
        XCTAssertEqual(NotchStatusGlyph.neutral.dots.map(\.y), [9.5, 9.5, 14.5, 14.5])
        XCTAssertTrue(NotchStatusGlyph.neutral.dots.allSatisfy { $0.color == .white })
        XCTAssertTrue(NotchStatusGlyph.neutral.dots.allSatisfy { $0.diameter == 3 })

        XCTAssertEqual(NotchStatusGlyph.listening.dots.count, 12)
        XCTAssertEqual(NotchStatusGlyph.listening.dots.filter { $0.color == .white }.count, 4)
        XCTAssertEqual(NotchStatusGlyph.listening.dots.filter { $0.color == .orange }.count, 8)
        XCTAssertEqual(NotchStatusGlyph.listening.dots.map(\.x), [14.5, 19.5, 14.5, 9.5, 4.5, 9.5, 9.5, 9.5, 4.5, 14.5, 14.5, 19.5])
        XCTAssertEqual(NotchStatusGlyph.listening.dots.map(\.y), [9.5, 9.5, 4.5, 9.5, 9.5, 4.5, 14.5, 19.5, 14.5, 14.5, 19.5, 14.5])

        XCTAssertEqual(NotchStatusGlyph.playing.dots.count, 12)
        XCTAssertEqual(NotchStatusGlyph.playing.dots.filter { $0.color == .white }.count, 4)
        XCTAssertEqual(NotchStatusGlyph.playing.dots.filter { $0.color == .blue }.count, 8)
        XCTAssertEqual(NotchStatusGlyph.playing.dots.map(\.x), NotchStatusGlyph.listening.dots.map(\.x))
        XCTAssertEqual(NotchStatusGlyph.playing.dots.map(\.y), NotchStatusGlyph.listening.dots.map(\.y))
    }

    func testNotchGlyphMotionMatchesAnimatedSVGKeyframes() throws {
        XCTAssertFalse(NotchSessionStatus.notWorking.animatesGlyphMotion)
        XCTAssertTrue(NotchSessionStatus.working.animatesGlyphMotion)
        XCTAssertTrue(NotchSessionStatus.listening.animatesGlyphMotion)
        XCTAssertTrue(NotchSessionStatus.playing.animatesGlyphMotion)
        XCTAssertEqual(NotchStatusGlyphMotion.duration, 0.6, accuracy: 0.0001)

        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .notWorking, phase: 0.6683), 0)
        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .working, phase: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .working, phase: 0.6683), .pi / 4, accuracy: 0.0001)
        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .working, phase: 1), .pi / 2, accuracy: 0.0001)

        let rightDot = try XCTUnwrap(NotchStatusGlyph.listening.dots.first { $0.x == 19.5 && $0.y == 9.5 })
        XCTAssertEqual(NotchStatusGlyphMotion.accentOffset(for: rightDot, status: .listening, phase: 0).x, 0, accuracy: 0.0001)
        XCTAssertEqual(NotchStatusGlyphMotion.accentOffset(for: rightDot, status: .listening, phase: 0.6667).x, 1, accuracy: 0.0001)
        XCTAssertEqual(NotchStatusGlyphMotion.accentOffset(for: rightDot, status: .listening, phase: 1).x, 0, accuracy: 0.0001)

        let topDot = try XCTUnwrap(NotchStatusGlyph.playing.dots.first { $0.x == 14.5 && $0.y == 4.5 })
        XCTAssertEqual(NotchStatusGlyphMotion.accentOffset(for: topDot, status: .playing, phase: 0.6667).y, -1, accuracy: 0.0001)

        let coreDot = try XCTUnwrap(NotchStatusGlyph.neutral.dots.first)
        let rotated = NotchStatusGlyphMotion.transformedCenter(for: coreDot, status: .working, phase: 0.6683)
        XCTAssertEqual(rotated.x, 15.5355, accuracy: 0.0001)
        XCTAssertEqual(rotated.y, 12, accuracy: 0.0001)
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
        XCTAssertEqual(
            NotchActivityLabelPlanner.label(forWorkerActivity: "Moving ticket to Done, RR-100 is complete"),
            "Moving ticket"
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
