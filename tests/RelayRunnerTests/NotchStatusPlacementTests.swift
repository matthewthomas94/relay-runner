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

    func testFallbackPillExpandsLeftFromCenteredCompactTrailingEdge() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080)
        )
        let labelWidth: CGFloat = 72
        let compactPlacement = try XCTUnwrap(
            NotchStatusPlacementPlanner.placement(for: geometry)
        )

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
        XCTAssertEqual(placement.visibleFrame.minX, compactPlacement.visibleFrame.minX - labelWidth)
        XCTAssertEqual(placement.visibleFrame.maxX, compactPlacement.visibleFrame.maxX)
        XCTAssertEqual(placement.glyphScreenX, compactPlacement.glyphScreenX)
        XCTAssertEqual(placement.visibleFrame.maxY, geometry.frame.maxY)
    }

    func testOversizedNotchedLabelTruncatesBeforeMovingTrailingAnchor() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
        )
        let compactPlacement = try XCTUnwrap(
            NotchStatusPlacementPlanner.placement(for: geometry)
        )
        let placement = try XCTUnwrap(
            NotchStatusPlacementPlanner.placement(
                for: geometry,
                activityLabelWidth: NotchStatusPlacementPlanner.maximumActivityLabelWidth
            )
        )

        XCTAssertLessThan(
            placement.activityLabelWidth,
            NotchStatusPlacementPlanner.maximumActivityLabelWidth
        )
        XCTAssertEqual(placement.visibleFrame.minX, 8)
        XCTAssertEqual(placement.visibleFrame.maxX, compactPlacement.visibleFrame.maxX)
        XCTAssertEqual(placement.glyphScreenX, compactPlacement.glyphScreenX)
    }

    @MainActor
    func testMountedPanelFrameAnimationKeepsGlyphAndHitTargetFixedOnScreen() throws {
        _ = NSApplication.shared
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            auxiliaryTopLeftArea: CGRect(x: 0, y: 950, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 848, y: 950, width: 664, height: 32)
        )
        let compactPlacement = try XCTUnwrap(
            NotchStatusPlacementPlanner.placement(for: geometry)
        )
        let expandedPlacement = try XCTUnwrap(
            NotchStatusPlacementPlanner.placement(for: geometry, activityLabelWidth: 180)
        )
        let changedPlacement = try XCTUnwrap(
            NotchStatusPlacementPlanner.placement(for: geometry, activityLabelWidth: 96)
        )

        let panel = NotchStatusPanel()
        panel.setFrame(compactPlacement.visibleFrame, display: false)
        let pillView = NotchStatusPillContentView(
            frame: CGRect(origin: .zero, size: panel.frame.size)
        )
        pillView.autoresizingMask = [.width, .height]
        panel.contentView = pillView
        panel.orderFrontRegardless()
        defer {
            panel.stopFrameAnimation()
            panel.orderOut(nil)
        }

        var glyphClicked = false
        pillView.onGlyphClicked = {
            glyphClicked = true
        }
        apply(
            expandedPlacement,
            label: "Reading worker activity",
            to: pillView
        )

        panel.animateFrame(to: expandedPlacement.visibleFrame, duration: 0.12)
        let expansionSamples = try frameAnimationSamples(panel: panel, pillView: pillView)
        XCTAssertGreaterThan(expansionSamples.count, 2)
        assertAnchored(
            expansionSamples,
            expectedTrailingEdge: compactPlacement.visibleFrame.maxX,
            expectedGlyphX: compactPlacement.glyphScreenX
        )

        panel.animateFrame(to: compactPlacement.visibleFrame, duration: 0.16)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        let interruptedFrame = panel.frame
        apply(
            changedPlacement,
            label: "Worker active",
            to: pillView
        )
        panel.animateFrame(to: changedPlacement.visibleFrame, duration: 0.1)
        XCTAssertEqual(panel.frame, interruptedFrame)
        let retargetedSamples = try frameAnimationSamples(panel: panel, pillView: pillView)
        assertAnchored(
            retargetedSamples,
            expectedTrailingEdge: compactPlacement.visibleFrame.maxX,
            expectedGlyphX: compactPlacement.glyphScreenX
        )

        apply(compactPlacement, label: nil, to: pillView)
        panel.animateFrame(to: compactPlacement.visibleFrame, duration: 0)
        XCTAssertEqual(panel.frame, compactPlacement.visibleFrame)
        let compactGlyphFrame = try XCTUnwrap(pillView.glyphFrameInScreenCoordinates())
        XCTAssertEqual(compactGlyphFrame.minX, compactPlacement.glyphScreenX, accuracy: 0.001)

        let windowPoint = panel.convertPoint(
            fromScreen: CGPoint(x: compactGlyphFrame.midX, y: compactGlyphFrame.midY)
        )
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        pillView.mouseDown(with: click)
        XCTAssertTrue(glyphClicked)
    }

    private struct MountedFrameSample {
        let panelFrame: CGRect
        let glyphFrame: CGRect
        let hoverFrame: CGRect
    }

    @MainActor
    private func apply(
        _ placement: NotchStatusPlacement,
        label: String?,
        to pillView: NotchStatusPillContentView
    ) {
        pillView.apply(
            status: .playing,
            label: label,
            activityLabelWidth: placement.activityLabelWidth,
            leadingSpacerWidth: placement.leadingSpacerWidth,
            notchSpacerWidth: placement.notchSpacerWidth,
            glyphScreenX: placement.glyphScreenX
        )
    }

    @MainActor
    private func frameAnimationSamples(
        panel: NotchStatusPanel,
        pillView: NotchStatusPillContentView
    ) throws -> [MountedFrameSample] {
        var samples: [MountedFrameSample] = []
        let deadline = Date().addingTimeInterval(1)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            samples.append(MountedFrameSample(
                panelFrame: panel.frame,
                glyphFrame: try XCTUnwrap(pillView.glyphFrameInScreenCoordinates()),
                hoverFrame: try XCTUnwrap(pillView.glyphHoverFrameInScreenCoordinates())
            ))
        } while panel.isFrameAnimationRunning && Date() < deadline

        XCTAssertFalse(panel.isFrameAnimationRunning)
        return samples
    }

    private func assertAnchored(
        _ samples: [MountedFrameSample],
        expectedTrailingEdge: CGFloat,
        expectedGlyphX: CGFloat
    ) {
        for sample in samples {
            XCTAssertEqual(sample.panelFrame.maxX, expectedTrailingEdge, accuracy: 0.001)
            XCTAssertEqual(sample.glyphFrame.minX, expectedGlyphX, accuracy: 0.001)
            XCTAssertTrue(sample.hoverFrame.contains(
                CGPoint(x: sample.glyphFrame.midX, y: sample.glyphFrame.midY)
            ))
        }
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
            .font: AppTypography.appKitFont(.notchStatus),
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

    func testVisualLabelAllowlistCoversEveryOverlayState() {
        let prompt = ConfirmationPrompt(
            summary: "Click Send",
            risk: "high",
            requestId: "confirm-1"
        )
        let cases: [(OverlayState, [String])] = [
            (.idle, []),
            (.listening, ["Listening"]),
            (.recording, ["Listening"]),
            (.sent, ["Sending voice"]),
            (.cancelled(.stt), ["Recording cancelled"]),
            (.cancelled(.tts), ["Response cancelled"]),
            (.processing, []),
            (.acknowledgement(text: "Got it", autoDismiss: 2), ["Acknowledged"]),
            (.messageWaiting(preview: "Long response"), ["Response ready"]),
            (.preparing, ["Preparing speech"]),
            (.speaking, ["Playing"]),
            (.paused, []),
            (.sessionPrompt, []),
            (.sessionReady, []),
            (.programStatus(title: "Program", body: "Ready"), []),
            (.actionGlow(awaitingConfirmation: nil), ["Using screen"]),
            (.actionGlow(awaitingConfirmation: prompt), []),
        ]

        for (state, expectedLabels) in cases {
            let presentation = NotchVisualLabelAllowlist.presentation(for: state)
            XCTAssertEqual(presentation.labels, expectedLabels, "\(state)")
            XCTAssertEqual(presentation.hoverLabel, expectedLabels.first, "\(state)")
            XCTAssertEqual(NotchActivityLabelPlanner.labels(for: state), expectedLabels, "\(state)")
        }
    }

    func testBridgeStartupIsTheOnlyVisibleBridgeLifecycleLabel() {
        XCTAssertEqual(
            NotchVisualLabelAllowlist.presentation(for: .idle, bridgeStartingUp: true),
            NotchVisualLabelPresentation(
                labels: ["Starting up..."],
                hoverLabel: "Starting session"
            )
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(
                for: .idle,
                bridgeRecoveryInFlight: true
            ),
            []
        )
        XCTAssertNil(
            NotchActivityLabelPlanner.hoverLabel(
                for: .idle,
                bridgeRecoveryInFlight: true
            )
        )
        XCTAssertTrue(
            NotchActivityLabelPlanner.hasActiveWork(
                state: .idle,
                bridgeRecoveryInFlight: true
            )
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(
                for: .idle,
                hasActivityLabels: true
            ),
            .working
        )
    }

    func testWorkspaceLoadingIsGlyphOnlyAndIdleRemainsStatic() {
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .idle),
            []
        )
        XCTAssertFalse(NotchActivityLabelPlanner.hasActiveWork(state: .idle))
        XCTAssertEqual(
            NotchSessionStatus.resolve(for: .idle, hasActivityLabels: false),
            .notWorking
        )

        XCTAssertTrue(
            NotchActivityLabelPlanner.hasActiveWork(
                state: .idle,
                boardIsLoading: true
            )
        )
        XCTAssertEqual(
            NotchSessionStatus.resolve(
                for: .idle,
                hasActivityLabels: true,
                boardIsLoading: true
            ),
            .working
        )
    }

    func testSuppressedProgressCannotRevealOrExpandOnHover() {
        let progress = "The first pass found 102 SKILL.md files across user and plugin roots."

        XCTAssertEqual(NotchActivityLabelRenderPolicy.workingStatusRevealDuration, 2.0)
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(
                for: .processing,
                foregroundActivity: progress
            ),
            []
        )
        XCTAssertNil(
            NotchActivityLabelPlanner.hoverLabel(
                for: .processing,
                foregroundActivity: progress
            )
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabel(
                status: .working,
                compactLabel: nil,
                workingProgressLabel: nil,
                workingGlyphHovered: false,
                workingStatusRevealActive: true
            ),
            nil
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabelWidth(
                status: .working,
                compactLabel: nil,
                workingProgressLabel: nil,
                workingGlyphHovered: true,
                workingStatusRevealActive: true
            ),
            0
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

    func testAllowedSuppressedAllowedTransitionClearsLabelGeometry() {
        let listening = NotchVisualLabelAllowlist.presentation(for: .recording)
        let processing = NotchVisualLabelAllowlist.presentation(for: .processing)
        let response = NotchVisualLabelAllowlist.presentation(
            for: .messageWaiting(preview: "Ready")
        )

        XCTAssertGreaterThan(
            NotchStatusController.displayedActivityLabelWidth(
                status: .listening,
                compactLabel: listening.labels.first,
                workingProgressLabel: listening.hoverLabel,
                workingGlyphHovered: false,
                workingStatusRevealActive: true
            ),
            0
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabelWidth(
                status: .working,
                compactLabel: processing.labels.first,
                workingProgressLabel: processing.hoverLabel,
                workingGlyphHovered: true,
                workingStatusRevealActive: true
            ),
            0
        )
        XCTAssertGreaterThan(
            NotchStatusController.displayedActivityLabelWidth(
                status: .playing,
                compactLabel: response.labels.first,
                workingProgressLabel: response.hoverLabel,
                workingGlyphHovered: false,
                workingStatusRevealActive: true
            ),
            0
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

    func testNotchGlyphMotionKeepsWorkingLoopAndUsesBoundedAudioEnvelope() throws {
        XCTAssertFalse(NotchSessionStatus.notWorking.animatesGlyphMotion)
        XCTAssertTrue(NotchSessionStatus.working.animatesGlyphMotion)
        XCTAssertFalse(NotchSessionStatus.listening.animatesGlyphMotion)
        XCTAssertFalse(NotchSessionStatus.playing.animatesGlyphMotion)
        XCTAssertEqual(NotchStatusGlyphMotion.duration, 0.6, accuracy: 0.0001)

        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .notWorking, phase: 0.6683), 0)
        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .working, phase: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .working, phase: 0.6683), .pi / 4, accuracy: 0.0001)
        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .working, phase: 1), .pi / 2, accuracy: 0.0001)

        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .listening, phase: 0.5), 0)
        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .playing, phase: 0.5), 0)

        for status in [NotchSessionStatus.listening, .playing] {
            for dot in status.glyph.dots {
                let calm = NotchStatusGlyphMotion.audioReactiveCenter(
                    for: dot,
                    status: status,
                    level: 0
                )
                let peak = NotchStatusGlyphMotion.audioReactiveCenter(
                    for: dot,
                    status: status,
                    level: 1
                )
                XCTAssertEqual(calm, CGPoint(x: dot.x, y: dot.y))
                XCTAssertGreaterThanOrEqual(peak.x - dot.diameter / 2, 0)
                XCTAssertLessThanOrEqual(peak.x + dot.diameter / 2, 24)
                XCTAssertGreaterThanOrEqual(peak.y - dot.diameter / 2, 0)
                XCTAssertLessThanOrEqual(peak.y + dot.diameter / 2, 24)
            }
        }

        let coreDot = try XCTUnwrap(NotchStatusGlyph.neutral.dots.first)
        let rotated = NotchStatusGlyphMotion.transformedCenter(for: coreDot, status: .working, phase: 0.6683)
        XCTAssertEqual(rotated.x, 15.5355, accuracy: 0.0001)
        XCTAssertEqual(rotated.y, 12, accuracy: 0.0001)
    }

    func testNotchAudioEnvelopeNormalizesSmoothsResetsAndHonorsReduceMotion() {
        XCTAssertEqual(NotchAudioLevelPolicy.normalize(rms: 0), 0)
        XCTAssertEqual(
            NotchAudioLevelPolicy.normalize(rms: Darwin.pow(10, -55.0 / 20)),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            NotchAudioLevelPolicy.normalize(rms: Darwin.pow(10, -12.0 / 20)),
            1,
            accuracy: 0.0001
        )
        XCTAssertEqual(NotchAudioLevelPolicy.normalize(rms: 2), 1)

        var smoother = NotchAudioLevelSmoother()
        XCTAssertEqual(smoother.update(0, at: 10), 0)
        let attacked = smoother.update(1, at: 10.05)
        XCTAssertGreaterThan(attacked, 0)
        XCTAssertLessThan(attacked, 1)
        let released = smoother.update(0, at: 10.10)
        XCTAssertGreaterThan(released, 0)
        XCTAssertLessThan(released, attacked)
        smoother.reset()
        XCTAssertEqual(smoother.level, 0)

        XCTAssertEqual(
            NotchAudioLevelPolicy.presentedLevel(1, status: .listening, reduceMotion: true),
            0
        )
        XCTAssertEqual(
            NotchAudioLevelPolicy.presentedLevel(1, status: .playing, reduceMotion: false),
            1
        )
        XCTAssertEqual(
            NotchAudioLevelPolicy.presentedLevel(1, status: .working, reduceMotion: false),
            0
        )
    }

    func testWorkerActivityIsGlyphOnlyAcrossProviders() {
        let now = Date(timeIntervalSince1970: 2_000)
        let runs = [
            RunState(
                ticketId: "RR-94",
                repoPath: "/repo",
                runId: 94,
                state: "Running",
                lastError: nil,
                activity: "Running Swift tests",
                activityAt: now.timeIntervalSince1970,
                providerKey: "codex"
            ),
            RunState(
                ticketId: "RR-95",
                repoPath: "/repo",
                runId: 95,
                state: "Stalled",
                lastError: nil,
                activity: "Waiting",
                activityAt: now.timeIntervalSince1970,
                providerKey: "claude"
            ),
        ]

        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .idle, activeRuns: runs, now: now),
            []
        )
        XCTAssertNil(
            NotchActivityLabelPlanner.hoverLabel(for: .idle, activeRuns: runs, now: now)
        )
        XCTAssertTrue(
            NotchActivityLabelPlanner.hasActiveWork(
                state: .idle,
                activeRuns: runs,
                now: now
            )
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

    func testForegroundAndWorkerActivityRemainGlyphOnly() {
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
            []
        )
        XCTAssertNil(
            NotchActivityLabelPlanner.hoverLabel(
                for: .idle,
                foregroundActivity: "Reading project context",
                activeRuns: [run],
                now: now
            )
        )
        XCTAssertTrue(
            NotchActivityLabelPlanner.hasActiveWork(
                state: .idle,
                foregroundActivity: "Reading project context",
                activeRuns: [run],
                now: now
            )
        )
    }

    func testWorkerActivityAnimatesWhenForegroundActivityIsMissing() {
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
            []
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(
                for: .idle,
                foregroundActivity: "   ",
                activeRuns: [run],
                now: now
            ),
            []
        )
        XCTAssertTrue(
            NotchActivityLabelPlanner.hasActiveWork(
                state: .idle,
                foregroundActivity: "   ",
                activeRuns: [run],
                now: now
            )
        )
    }

    func testHoverDoesNotRevealActiveRunDetails() {
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

        XCTAssertNil(
            NotchActivityLabelPlanner.hoverLabel(
                for: .idle,
                activeRuns: [run],
                tickets: tickets,
                now: now
            )
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

        XCTAssertNil(
            NotchActivityLabelPlanner.hoverLabel(
                for: .idle,
                activeRuns: [staleRun],
                tickets: [ticket(id: "RR-119", title: "Background worker", status: .inProgress)],
                now: now
            )
        )
    }

    func testWaitingDependencyIsGlyphOnly() {
        let tickets = [
            ticket(id: "RR-1", status: .ready, dependsOn: ["RR-0"]),
            ticket(id: "RR-0", status: .backlog),
        ]

        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .idle, tickets: tickets),
            []
        )
        XCTAssertNil(
            NotchActivityLabelPlanner.hoverLabel(for: .idle, tickets: tickets)
        )
        XCTAssertTrue(
            NotchActivityLabelPlanner.hasActiveWork(state: .idle, tickets: tickets)
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
