import AppKit
import XCTest
@testable import relay_runner

final class NotchStatusPlacementTests: XCTestCase {
    func testPillSurfacesUseDarkFigmaStyle() {
        let style = TranscriptionPill.DarkSurfaceStyle.self
        let fill = style.pillFill.usingColorSpace(.sRGB)
        let border = style.border.usingColorSpace(.sRGB)

        XCTAssertEqual(fill?.redComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(fill?.greenComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(fill?.blueComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(fill?.alphaComponent ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(border?.redComponent ?? 0, 17 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.greenComponent ?? 0, 22 / 255, accuracy: 0.001)
        XCTAssertEqual(border?.blueComponent ?? 0, 29 / 255, accuracy: 0.001)
        XCTAssertEqual(style.shadowOpacity, 0.08, accuracy: 0.001)
        XCTAssertEqual(style.shadowRadius, 4, accuracy: 0.001)
    }

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
        XCTAssertEqual(placement.leadingSpacerWidth, NotchStatusPlacementPlanner.compactNotchLeadInWidth)
        XCTAssertEqual(
            placement.visibleFrame.minX,
            geometry.auxiliaryTopLeftArea.maxX - NotchStatusPlacementPlanner.compactNotchLeadInWidth
        )
        XCTAssertEqual(
            placement.visibleFrame.width,
            NotchStatusPlacementPlanner.compactNotchLeadInWidth
                + placement.notchSpacerWidth
                + NotchStatusPlacementPlanner.glyphSize.width
                + NotchStatusPlacementPlanner.compactNotchLeadOutWidth
        )
        XCTAssertEqual(
            placement.visibleFrame.maxX,
            geometry.auxiliaryTopRightArea.minX + NotchStatusPlacementPlanner.glyphSize.width
                + NotchStatusPlacementPlanner.compactNotchLeadOutWidth
        )
        XCTAssertEqual(placement.glyphScreenX, geometry.auxiliaryTopRightArea.minX)
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)
        XCTAssertEqual(placement.visibleFrame.height, 34)
        XCTAssertEqual(
            NotchStatusSurfaceShape.topContactCornerRadius(notchSpacerWidth: placement.notchSpacerWidth),
            NotchStatusSurfaceShape.notchContactCornerRadius
        )
        let contact = try XCTUnwrap(NotchStatusSurfaceShape.topContact(
            activityLabelWidth: placement.activityLabelWidth,
            leadingSpacerWidth: placement.leadingSpacerWidth,
            notchSpacerWidth: placement.notchSpacerWidth,
            boundsWidth: placement.visibleFrame.width,
            boundsHeight: placement.visibleFrame.height
        ))
        XCTAssertEqual(contact.startX, NotchStatusPlacementPlanner.compactNotchLeadInWidth)
        XCTAssertEqual(contact.endX, placement.visibleFrame.width)
        XCTAssertEqual(contact.radius, NotchStatusSurfaceShape.notchContactCornerRadius)
        XCTAssertEqual(
            NotchStatusSurfaceShape.renderedTopShoulderRadius(
                for: contact,
                boundsHeight: placement.visibleFrame.height
            ),
            7.48,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchStatusSurfaceShape.renderedBottomCornerRadius(
                for: contact,
                boundsHeight: placement.visibleFrame.height,
                availableWidth: placement.visibleFrame.width
            ),
            12.92,
            accuracy: 0.001
        )
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
        XCTAssertEqual(placement.leadingSpacerWidth, NotchStatusPlacementPlanner.compactNotchLeadInWidth)
        XCTAssertEqual(
            placement.visibleFrame.minX,
            geometry.auxiliaryTopLeftArea.maxX
                - labelWidth
                - NotchStatusPlacementPlanner.compactNotchLeadInWidth
        )
        XCTAssertEqual(
            placement.visibleFrame.width,
            labelWidth
                + NotchStatusPlacementPlanner.compactNotchLeadInWidth
                + placement.notchSpacerWidth
                + NotchStatusPlacementPlanner.glyphSize.width
                + NotchStatusPlacementPlanner.compactNotchLeadOutWidth
        )
        XCTAssertEqual(placement.glyphScreenX, geometry.auxiliaryTopRightArea.minX)
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)
        let contact = try XCTUnwrap(NotchStatusSurfaceShape.topContact(
            activityLabelWidth: placement.activityLabelWidth,
            leadingSpacerWidth: placement.leadingSpacerWidth,
            notchSpacerWidth: placement.notchSpacerWidth,
            boundsWidth: placement.visibleFrame.width,
            boundsHeight: placement.visibleFrame.height
        ))
        XCTAssertEqual(
            contact.startX,
            NotchStatusPlacementPlanner.compactNotchLeadInWidth
        )
        XCTAssertEqual(contact.endX, placement.visibleFrame.width)
        XCTAssertEqual(contact.radius, NotchStatusSurfaceShape.notchContactCornerRadius)
        XCTAssertEqual(
            NotchStatusSurfaceShape.renderedTopShoulderRadius(
                for: contact,
                boundsHeight: placement.visibleFrame.height
            ),
            7.48,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchStatusSurfaceShape.renderedBottomCornerRadius(
                for: contact,
                boundsHeight: placement.visibleFrame.height,
                availableWidth: placement.visibleFrame.width
            ),
            12.92,
            accuracy: 0.001
        )

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

        XCTAssertEqual(placement.notchSpacerWidth, NotchStatusPlacementPlanner.fallbackNotchSpacerWidth)
        XCTAssertEqual(placement.activityLabelWidth, 0)
        XCTAssertEqual(placement.leadingSpacerWidth, NotchStatusPlacementPlanner.compactNotchLeadInWidth)
        XCTAssertEqual(placement.visibleFrame.width, NotchStatusPlacementPlanner.fallbackSurfaceWidth)
        XCTAssertEqual(placement.visibleFrame.midX, geometry.frame.midX)
        XCTAssertEqual(
            placement.glyphScreenX,
            placement.visibleFrame.maxX
                - NotchStatusPlacementPlanner.glyphSize.width
                - NotchStatusPlacementPlanner.compactNotchLeadOutWidth
        )
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)
        XCTAssertEqual(
            NotchStatusSurfaceShape.topContactCornerRadius(notchSpacerWidth: placement.notchSpacerWidth),
            NotchStatusSurfaceShape.notchContactCornerRadius
        )
        let contact = try XCTUnwrap(NotchStatusSurfaceShape.topContact(
            activityLabelWidth: placement.activityLabelWidth,
            leadingSpacerWidth: placement.leadingSpacerWidth,
            notchSpacerWidth: placement.notchSpacerWidth,
            boundsWidth: placement.visibleFrame.width,
            boundsHeight: placement.visibleFrame.height
        ))
        XCTAssertEqual(contact.startX, NotchStatusPlacementPlanner.compactNotchLeadInWidth)
        XCTAssertEqual(contact.endX, placement.visibleFrame.width)
        XCTAssertEqual(contact.radius, NotchStatusSurfaceShape.notchContactCornerRadius)
        XCTAssertEqual(
            NotchStatusSurfaceShape.renderedTopShoulderRadius(
                for: contact,
                boundsHeight: placement.visibleFrame.height
            ),
            7.48,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchStatusSurfaceShape.renderedBottomCornerRadius(
                for: contact,
                boundsHeight: placement.visibleFrame.height,
                availableWidth: placement.visibleFrame.width
            ),
            12.92,
            accuracy: 0.001
        )
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

        XCTAssertEqual(placement.notchSpacerWidth, NotchStatusPlacementPlanner.fallbackNotchSpacerWidth)
        XCTAssertEqual(placement.activityLabelWidth, labelWidth)
        XCTAssertEqual(placement.leadingSpacerWidth, NotchStatusPlacementPlanner.compactNotchLeadInWidth)
        XCTAssertEqual(
            placement.visibleFrame.width,
            labelWidth + NotchStatusPlacementPlanner.fallbackSurfaceWidth
        )
        XCTAssertEqual(placement.visibleFrame.midX, geometry.frame.midX)
        XCTAssertEqual(
            placement.glyphScreenX,
            placement.visibleFrame.maxX
                - NotchStatusPlacementPlanner.glyphSize.width
                - NotchStatusPlacementPlanner.compactNotchLeadOutWidth
        )
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)
    }

    func testActivityLabelWidthMatchesUpdatedDesignScale() {
        XCTAssertEqual(NotchStatusPlacementPlanner.activityLabelWidth(for: nil), 0)
        XCTAssertEqual(NotchStatusPlacementPlanner.activityLabelWidth(for: ""), 0)
        XCTAssertEqual(
            NotchStatusPlacementPlanner.activityLabelWidth(for: "Playing"),
            expectedActivityLabelWidth(for: "Playing")
        )
        XCTAssertEqual(
            NotchStatusPlacementPlanner.activityLabelWidth(for: "Listening"),
            expectedActivityLabelWidth(for: "Listening")
        )
        XCTAssertGreaterThanOrEqual(
            NotchActivityLabelRenderPolicy.labelTextRect(
                activityLabelWidth: NotchStatusPlacementPlanner.activityLabelWidth(for: "Listening"),
                boundsHeight: NotchStatusPlacementPlanner.glyphSize.height
            ).width,
            expectedActivityTextWidth(for: "Listening")
        )
        let notchedListeningRect = NotchActivityLabelRenderPolicy.labelTextRect(
            activityLabelWidth: NotchStatusPlacementPlanner.activityLabelWidth(for: "Listening"),
            boundsHeight: NotchStatusPlacementPlanner.glyphSize.height,
            isNotched: true
        )
        XCTAssertEqual(
            notchedListeningRect.minX,
            NotchActivityLabelRenderPolicy.notchedTextLeadingInset
        )
        XCTAssertEqual(
            notchedListeningRect.maxX,
            NotchStatusPlacementPlanner.activityLabelWidth(for: "Listening")
                - NotchActivityLabelRenderPolicy.textRightGlyphClearance
        )
        XCTAssertLessThan(
            NotchStatusPlacementPlanner.activityLabelWidth(for: "Moving ticket to Done, RR-100 is complete"),
            NotchStatusPlacementPlanner.maximumActivityLabelWidth
        )
        XCTAssertEqual(
            NotchStatusPlacementPlanner.activityLabelWidth(
                for: "The first pass found 102 SKILL.md files across user, workspace, system, plugin roots, and archived plugin cache roots."
            ),
            NotchStatusPlacementPlanner.maximumActivityLabelWidth
        )
    }

    private func expectedActivityLabelWidth(for label: String) -> CGFloat {
        let textWidth = (label as NSString).size(withAttributes: [
            .font: AppTypography.appKitFont(.status),
        ]).width
        return ceil(textWidth)
            + NotchActivityLabelRenderPolicy.textLeadingInset
            + NotchActivityLabelRenderPolicy.textRightGlyphClearance
            + 8
    }

    private func expectedActivityTextWidth(for label: String) -> CGFloat {
        expectedActivityLabelWidth(for: label)
            - NotchActivityLabelRenderPolicy.textLeadingInset
            - NotchActivityLabelRenderPolicy.textRightGlyphClearance
    }

    func testActivityLabelsMapVoiceAndActionStatesToConciseCopy() {
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .idle), [])
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .idle, bridgeStartingUp: true),
            ["Starting up..."]
        )
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .sessionReady), ["Session ready"])
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

    func testWorkingProgressUsesTimedRevealAndHover() {
        let progress = "The first pass found 102 SKILL.md files across user and plugin roots."

        XCTAssertEqual(NotchActivityLabelRenderPolicy.workingStatusRevealDuration, 2.0)

        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .processing),
            []
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabel(
                status: .working,
                compactLabel: nil,
                workingProgressLabel: progress,
                workingGlyphHovered: false,
                workingStatusRevealActive: false
            ),
            nil
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabel(
                status: .working,
                compactLabel: nil,
                workingProgressLabel: progress,
                workingGlyphHovered: false,
                workingStatusRevealActive: true
            ),
            progress
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabel(
                status: .working,
                compactLabel: nil,
                workingProgressLabel: progress,
                workingGlyphHovered: true,
                workingStatusRevealActive: false
            ),
            progress
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabelWidth(
                status: .working,
                compactLabel: nil,
                workingProgressLabel: progress,
                workingGlyphHovered: false,
                workingStatusRevealActive: false
            ),
            0
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabelWidth(
                status: .working,
                compactLabel: nil,
                workingProgressLabel: progress,
                workingGlyphHovered: true,
                workingStatusRevealActive: false
            ),
            NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth
        )
        let shortProgress = "Running tests"
        let shortProgressWidth = NotchStatusController.displayedActivityLabelWidth(
            status: .working,
            compactLabel: nil,
            workingProgressLabel: shortProgress,
            workingGlyphHovered: true,
            workingStatusRevealActive: false
        )
        XCTAssertEqual(
            shortProgressWidth,
            NotchStatusPlacementPlanner.activityLabelWidth(for: shortProgress)
        )
        XCTAssertLessThan(
            shortProgressWidth,
            NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth
        )

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
            NotchActivityLabelPlanner.labels(
                for: .processing,
                activeRuns: [run],
                now: now
            ),
            ["Running tests"]
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabel(
                status: .working,
                compactLabel: "Running tests",
                workingProgressLabel: progress,
                workingGlyphHovered: false,
                workingStatusRevealActive: true
            ),
            "Running tests"
        )
        XCTAssertNil(
            NotchStatusController.displayedActivityLabel(
                status: .working,
                compactLabel: "Running tests",
                workingProgressLabel: progress,
                workingGlyphHovered: false,
                workingStatusRevealActive: false
            )
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabel(
                status: .working,
                compactLabel: "Running tests",
                workingProgressLabel: progress,
                workingGlyphHovered: true,
                workingStatusRevealActive: false
            ),
            progress
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabel(
                status: .listening,
                compactLabel: "Listening",
                workingProgressLabel: nil,
                workingGlyphHovered: false,
                workingStatusRevealActive: false
            ),
            "Listening"
        )
    }

    func testWorkingPresentationRefreshOnlyAnimatesFirstReveal() {
        let initialReveal = NotchStatusPresentationUpdatePolicy.plan(
            statusChanged: true,
            activityLabelsChanged: false,
            workingProgressChanged: true,
            nextStatus: .working,
            workingRevealWasActive: false,
            workingGlyphHovered: false
        )
        XCTAssertTrue(initialReveal.shouldRestartWorkingReveal)
        XCTAssertTrue(initialReveal.shouldAnimatePlacement)

        let refreshWhileVisible = NotchStatusPresentationUpdatePolicy.plan(
            statusChanged: false,
            activityLabelsChanged: true,
            workingProgressChanged: true,
            nextStatus: .working,
            workingRevealWasActive: true,
            workingGlyphHovered: false
        )
        XCTAssertTrue(refreshWhileVisible.shouldRestartWorkingReveal)
        XCTAssertFalse(refreshWhileVisible.shouldAnimatePlacement)

        let refreshWhileHovered = NotchStatusPresentationUpdatePolicy.plan(
            statusChanged: false,
            activityLabelsChanged: true,
            workingProgressChanged: false,
            nextStatus: .working,
            workingRevealWasActive: false,
            workingGlyphHovered: true
        )
        XCTAssertTrue(refreshWhileHovered.shouldRestartWorkingReveal)
        XCTAssertFalse(refreshWhileHovered.shouldAnimatePlacement)

        let leaveWorking = NotchStatusPresentationUpdatePolicy.plan(
            statusChanged: true,
            activityLabelsChanged: true,
            workingProgressChanged: true,
            nextStatus: .notWorking,
            workingRevealWasActive: true,
            workingGlyphHovered: false
        )
        XCTAssertFalse(leaveWorking.shouldRestartWorkingReveal)
        XCTAssertTrue(leaveWorking.shouldAnimatePlacement)
    }

    func testPlacementContractionDefersContentUntilCurrentAnimationCompletes() {
        XCTAssertTrue(
            NotchActivityLabelRenderPolicy.shouldDeferContentUpdate(
                previousActivityLabelWidth: 180,
                nextActivityLabelWidth: 0,
                animated: true
            )
        )
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldDeferContentUpdate(
                previousActivityLabelWidth: 0,
                nextActivityLabelWidth: 180,
                animated: true
            )
        )
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldDeferContentUpdate(
                previousActivityLabelWidth: 180,
                nextActivityLabelWidth: 0,
                animated: false
            )
        )
        XCTAssertTrue(
            NotchActivityLabelRenderPolicy.shouldApplyDeferredContentUpdate(
                scheduledGeneration: 7,
                currentGeneration: 7
            )
        )
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldApplyDeferredContentUpdate(
                scheduledGeneration: 7,
                currentGeneration: 8
            )
        )
    }

    func testWorkingProgressHoverUsesStableStaticLabelRendering() {
        XCTAssertEqual(NotchStatusPlacementPlanner.maximumActivityLabelWidth, 650)
        XCTAssertEqual(
            NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth,
            325
        )
        XCTAssertEqual(
            NotchActivityLabelRenderPolicy.lineBreakMode(isScrolling: false),
            .byTruncatingTail
        )
        XCTAssertEqual(
            NotchActivityLabelRenderPolicy.lineBreakMode(isScrolling: true),
            .byClipping
        )
        XCTAssertTrue(
            NotchActivityLabelRenderPolicy.shouldAnimatePlacementTransition(
                status: .working,
                oldWorkingGlyphHovered: false,
                newWorkingGlyphHovered: true
            )
        )
        XCTAssertTrue(
            NotchActivityLabelRenderPolicy.shouldAnimatePlacementTransition(
                status: .working,
                oldWorkingGlyphHovered: true,
                newWorkingGlyphHovered: false
            )
        )
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldAnimatePlacementTransition(
                status: .working,
                oldWorkingGlyphHovered: true,
                newWorkingGlyphHovered: true
            )
        )
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldAnimatePlacementTransition(
                status: .playing,
                oldWorkingGlyphHovered: false,
                newWorkingGlyphHovered: true
            )
        )

        let textRect = NotchActivityLabelRenderPolicy.labelTextRect(
            activityLabelWidth: NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth,
            boundsHeight: NotchStatusPlacementPlanner.glyphSize.height
        )
        XCTAssertEqual(textRect.minX, NotchActivityLabelRenderPolicy.textLeadingInset)
        XCTAssertEqual(
            textRect.maxX,
            NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth
                - NotchActivityLabelRenderPolicy.textRightGlyphClearance
        )

        let clippedDuringExpansion = NotchActivityLabelRenderPolicy.labelTextRect(
            activityLabelWidth: NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth,
            boundsHeight: NotchStatusPlacementPlanner.glyphSize.height,
            glyphFrame: NSRect(x: 118, y: 0, width: 30, height: 34)
        )
        XCTAssertEqual(
            clippedDuringExpansion.maxX,
            118 - NotchActivityLabelRenderPolicy.textGlyphGap
        )
        XCTAssertLessThan(clippedDuringExpansion.maxX, 118)

        let unclippedAfterExpansion = NotchActivityLabelRenderPolicy.labelTextRect(
            activityLabelWidth: NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth,
            boundsHeight: NotchStatusPlacementPlanner.glyphSize.height,
            glyphFrame: NSRect(x: 420, y: 0, width: 30, height: 34)
        )
        XCTAssertEqual(unclippedAfterExpansion, textRect)
    }

    func testWorkingProgressScrollStartsAfterHoverDwellWhenTruncated() {
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldScrollLabel(
                status: .working,
                glyphHovered: true,
                hoverDuration: 0.99,
                textWidth: 500,
                availableWidth: 320,
                reduceMotion: false
            )
        )
        XCTAssertTrue(
            NotchActivityLabelRenderPolicy.shouldScrollLabel(
                status: .working,
                glyphHovered: true,
                hoverDuration: 1.0,
                textWidth: 500,
                availableWidth: 320,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldScrollLabel(
                status: .working,
                glyphHovered: true,
                hoverDuration: 1.2,
                textWidth: 300,
                availableWidth: 320,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldScrollLabel(
                status: .working,
                glyphHovered: true,
                hoverDuration: 1.2,
                textWidth: 500,
                availableWidth: 320,
                reduceMotion: true
            )
        )

        XCTAssertEqual(
            NotchActivityLabelRenderPolicy.scrollOffset(
                hoverDuration: 1.0,
                textWidth: 500
            ),
            0
        )
        XCTAssertGreaterThan(
            NotchActivityLabelRenderPolicy.scrollOffset(
                hoverDuration: 1.6,
                textWidth: 500
            ),
            0
        )
        XCTAssertLessThan(
            NotchActivityLabelRenderPolicy.scrollOffset(
                hoverDuration: 10,
                textWidth: 500
            ),
            NotchActivityLabelRenderPolicy.scrollStride(textWidth: 500)
        )
    }

    func testWorkingProgressStreamUpdatesDoNotRestartHoverDwell() {
        let hoverStartedAt: CFTimeInterval = 10
        let progress = "Reading source files while preparing the worker trace."

        XCTAssertEqual(
            NotchActivityLabelRenderPolicy.hoverStartTime(
                current: hoverStartedAt,
                glyphHovered: true,
                labelChanged: true,
                now: 12
            ),
            hoverStartedAt
        )
        XCTAssertEqual(
            NotchActivityLabelRenderPolicy.hoverStartTime(
                current: nil,
                glyphHovered: true,
                labelChanged: true,
                now: 12
            ),
            12
        )
        XCTAssertNil(
            NotchActivityLabelRenderPolicy.hoverStartTime(
                current: hoverStartedAt,
                glyphHovered: false,
                labelChanged: true,
                now: 12
            )
        )

        let offsetBeforeStreamUpdate = NotchActivityLabelRenderPolicy.scrollOffset(
            hoverDuration: 1.2,
            textWidth: 500
        )
        let offsetAfterStreamUpdate = NotchActivityLabelRenderPolicy.scrollOffset(
            hoverDuration: 2.4,
            textWidth: 500
        )
        XCTAssertGreaterThan(offsetAfterStreamUpdate, offsetBeforeStreamUpdate)

        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldAnimateContentPlacementUpdate(
                status: .working,
                workingGlyphHovered: true,
                workingProgressLabel: progress
            )
        )
        XCTAssertFalse(
            NotchActivityLabelRenderPolicy.shouldAnimateContentPlacementUpdate(
                status: .working,
                workingGlyphHovered: true,
                workingProgressLabel: "  \(progress)  "
            )
        )
        XCTAssertTrue(
            NotchActivityLabelRenderPolicy.shouldAnimateContentPlacementUpdate(
                status: .working,
                workingGlyphHovered: false,
                workingProgressLabel: progress
            )
        )
        XCTAssertTrue(
            NotchActivityLabelRenderPolicy.shouldAnimateContentPlacementUpdate(
                status: .working,
                workingGlyphHovered: true,
                workingProgressLabel: nil
            )
        )
        XCTAssertTrue(
            NotchActivityLabelRenderPolicy.shouldAnimateContentPlacementUpdate(
                status: .listening,
                workingGlyphHovered: true,
                workingProgressLabel: progress
            )
        )
    }

    func testWorkingHoverInteractionExtendsAcrossExpandedTraceSurface() {
        let frame = NotchHoverInteractionPolicy.frame(
            glyphFrame: NSRect(x: 118, y: 0, width: 30, height: 34),
            boundsHeight: NotchStatusPlacementPlanner.glyphSize.height,
            activityLabelWidth: NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth,
            leadingSpacerWidth: NotchStatusPlacementPlanner.compactNotchLeadInWidth,
            notchSpacerWidth: 185,
            status: .working,
            glyphHovered: true,
            workingProgressLabel: "Reading source files while preparing the worker trace.",
            hoverSlop: 8
        )

        XCTAssertTrue(frame.contains(CGPoint(x: 40, y: 10)))
        XCTAssertTrue(frame.contains(CGPoint(x: 130, y: 10)))
        XCTAssertGreaterThan(frame.maxX, 148)
    }

    func testHoverInteractionStaysGlyphOnlyWhenNotExpanded() {
        let compactFrame = NotchHoverInteractionPolicy.frame(
            glyphFrame: NSRect(x: 118, y: 0, width: 30, height: 34),
            boundsHeight: NotchStatusPlacementPlanner.glyphSize.height,
            activityLabelWidth: NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth,
            leadingSpacerWidth: NotchStatusPlacementPlanner.compactNotchLeadInWidth,
            notchSpacerWidth: 185,
            status: .working,
            glyphHovered: false,
            workingProgressLabel: "Reading source files while preparing the worker trace.",
            hoverSlop: 8
        )

        XCTAssertFalse(compactFrame.contains(CGPoint(x: 40, y: 10)))
        XCTAssertTrue(compactFrame.contains(CGPoint(x: 130, y: 10)))

        let noProgressFrame = NotchHoverInteractionPolicy.frame(
            glyphFrame: NSRect(x: 118, y: 0, width: 30, height: 34),
            boundsHeight: NotchStatusPlacementPlanner.glyphSize.height,
            activityLabelWidth: NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth,
            leadingSpacerWidth: NotchStatusPlacementPlanner.compactNotchLeadInWidth,
            notchSpacerWidth: 185,
            status: .working,
            glyphHovered: true,
            workingProgressLabel: nil,
            hoverSlop: 8
        )

        XCTAssertFalse(noProgressFrame.contains(CGPoint(x: 40, y: 10)))
        XCTAssertTrue(noProgressFrame.contains(CGPoint(x: 130, y: 10)))
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
            NotchSessionStatus.resolve(
                for: .idle,
                hasActivityLabels: false,
                boardIsLoading: true
            ),
            .working
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(
                for: .recording,
                hasActivityLabels: false,
                boardIsLoading: true
            ),
            .listening
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .processing, hasActivityLabels: false),
            .working
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .sessionReady, hasActivityLabels: false),
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

    func testForegroundActivityTakesPrecedenceOverWorkerActivity() {
        let now = Date(timeIntervalSince1970: 2_000)
        let run = RunState(
            ticketId: "RR-145",
            repoPath: "/repo",
            runId: 218,
            state: "Running",
            lastError: nil,
            activity: "Running Swift tests",
            activityAt: now.timeIntervalSince1970
        )

        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(
                for: .idle,
                foregroundActivity: "Reading project context",
                activeRuns: [run],
                now: now
            ),
            ["Reading project context"]
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.hoverLabel(
                for: .idle,
                foregroundActivity: "Reading project context",
                activeRuns: [run],
                now: now
            ),
            "Reading project context"
        )
    }

    func testWorkerActivityFallsBackWhenForegroundActivityIsIdleOrMissing() {
        let now = Date(timeIntervalSince1970: 2_000)
        let run = RunState(
            ticketId: "RR-145",
            repoPath: "/repo",
            runId: 218,
            state: "Running",
            lastError: nil,
            activity: "Running Swift tests",
            activityAt: now.timeIntervalSince1970
        )

        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(
                for: .idle,
                foregroundActivity: nil,
                activeRuns: [run],
                now: now
            ),
            ["Running tests"]
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(
                for: .idle,
                foregroundActivity: "   ",
                activeRuns: [run],
                now: now
            ),
            ["Running tests"]
        )
    }

    func testHoverActivityLabelIncludesActiveRunDetails() {
        let now = Date(timeIntervalSince1970: 2_000)
        let run = RunState(
            ticketId: "RR-118",
            repoPath: "/repo",
            runId: 157,
            state: "Running",
            lastError: nil,
            activity: "Reading source files",
            activityAt: now.timeIntervalSince1970,
            providerKey: "codex",
            modelAlias: "gpt-5"
        )
        let tickets = [
            ticket(id: "RR-118", title: "Restore hover trace", status: .inProgress),
        ]

        XCTAssertEqual(
            NotchActivityLabelPlanner.hoverLabel(
                for: .idle,
                activeRuns: [run],
                tickets: tickets,
                now: now
            ),
            "RR-118 run 157: Reading source files - Restore hover trace (Codex/gpt-5)"
        )
    }

    func testHoverActivityLabelHandlesNoWorkAndStaleRuns() {
        let now = Date(timeIntervalSince1970: 2_000)

        XCTAssertNil(
            NotchActivityLabelPlanner.hoverLabel(
                for: .idle,
                activeRuns: [],
                tickets: [],
                now: now
            )
        )

        let staleRun = RunState(
            ticketId: "RR-119",
            repoPath: "/repo",
            runId: 158,
            state: "Running",
            lastError: nil,
            activity: "Reading source files",
            activityAt: now.timeIntervalSince1970 - RunState.idleThreshold - 1,
            providerKey: "claude",
            modelAlias: "sonnet"
        )

        XCTAssertEqual(
            NotchActivityLabelPlanner.hoverLabel(
                for: .idle,
                activeRuns: [staleRun],
                tickets: [ticket(id: "RR-119", title: "Background worker", status: .inProgress)],
                now: now
            ),
            "RR-119 run 158: Worker idle - Background worker (Claude/sonnet)"
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
        title: String? = nil,
        status: Ticket.Status,
        dependsOn: [String] = []
    ) -> Ticket {
        Ticket(
            id: id,
            title: title ?? id,
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
