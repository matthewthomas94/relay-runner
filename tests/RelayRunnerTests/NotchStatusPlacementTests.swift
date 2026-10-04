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
                hoverLabel: "Starting session",
                pinsLabel: true
            )
        )
        XCTAssertEqual(
            NotchStatusController.displayedActivityLabel(
                status: .working,
                compactLabel: "Starting up...",
                workingProgressLabel: "Starting session",
                workingGlyphHovered: false,
                workingStatusRevealActive: false,
                workingLabelPinned: true
            ),
            "Starting up...",
            "startup copy stays up for the whole startup, not just its reveal"
        )
        XCTAssertFalse(NotchVisualLabelAllowlist.presentation(for: .sent).pinsLabel)
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

    func testWorkspaceFirstLoadPinsCheckingForUpdatesBelowStateCopy() {
        XCTAssertEqual(
            NotchVisualLabelAllowlist.presentation(for: .idle, boardContentLoading: true),
            NotchVisualLabelPresentation(
                labels: ["Checking for updates"],
                hoverLabel: "Checking for updates",
                pinsLabel: true
            )
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.hoverLabel(for: .idle, boardContentLoading: true),
            "Checking for updates"
        )
        XCTAssertEqual(
            NotchActivityLabelPlanner.labels(for: .listening, boardContentLoading: true),
            ["Listening"],
            "voice state copy outranks the Workspace load"
        )
        XCTAssertEqual(
            NotchVisualLabelAllowlist.presentation(
                for: .idle,
                bridgeStartingUp: true,
                boardContentLoading: true
            ).labels,
            ["Starting up..."],
            "session startup outranks the Workspace load"
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

    func testWorkingPresentationAnimatesVisibleCopyChangesButNotProgressRefreshes() {
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

        let copyChangeWhileVisible = NotchStatusPresentationUpdatePolicy.plan(
            statusChanged: false,
            activityLabelsChanged: true,
            workingProgressChanged: true,
            nextStatus: .working,
            workingRevealWasActive: true,
            workingGlyphHovered: false
        )
        XCTAssertTrue(copyChangeWhileVisible.shouldRestartWorkingReveal)
        XCTAssertTrue(copyChangeWhileVisible.shouldAnimatePlacement)

        let progressRefreshWhileVisible = NotchStatusPresentationUpdatePolicy.plan(
            statusChanged: false,
            activityLabelsChanged: false,
            workingProgressChanged: true,
            nextStatus: .working,
            workingRevealWasActive: true,
            workingGlyphHovered: false
        )
        XCTAssertTrue(progressRefreshWhileVisible.shouldRestartWorkingReveal)
        XCTAssertFalse(progressRefreshWhileVisible.shouldAnimatePlacement)

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

    func testLabelChangesSwapHorizontallyThroughABlurOneAtATime() {
        var motion = NotchContentMotion()
        motion.labelChanged(from: nil, width: 0, to: "Listening", now: 10)
        XCTAssertTrue(motion.departingLabels.isEmpty)

        let arriving = motion.arrivalAppearance(now: 10, reduceMotion: false)
        XCTAssertEqual(arriving.alpha, 0)
        XCTAssertEqual(NotchContentMotion.labelStyle.axis, .horizontal, "status copy is the one horizontal slide")
        XCTAssertEqual(RelayMotion.Style.text.axis, .vertical)
        XCTAssertEqual(arriving.offset, NotchContentMotion.labelStyle.distance)
        XCTAssertEqual(arriving.blur, NotchContentMotion.labelStyle.blurRadius)
        XCTAssertEqual(
            motion.arrivalAppearance(now: 10 + RelayMotion.enterDuration + 0.001, reduceMotion: false),
            .resting
        )

        motion.labelChanged(from: "Listening", width: 80, to: "Sending voice", now: 11)
        let departing = try! XCTUnwrap(motion.departingLabels.first)
        XCTAssertEqual(departing.text, "Listening")
        XCTAssertEqual(departing.width, 80)
        let midway = motion.departureAppearance(
            of: departing,
            now: 11 + RelayMotion.exitDuration / 2,
            reduceMotion: false
        )
        XCTAssertGreaterThan(midway.alpha, 0)
        XCTAssertLessThan(midway.alpha, 1)
        XCTAssertGreaterThan(midway.offset, 0)
        XCTAssertGreaterThan(midway.blur, 0)
        XCTAssertTrue(motion.isAnimating(now: 11.1))

        // The replacement waits until the outgoing label has gone.
        XCTAssertEqual(
            motion.arrivalAppearance(now: 11 + RelayMotion.exitDuration / 2, reduceMotion: false).alpha,
            0
        )
        XCTAssertEqual(
            motion.departureAppearance(of: departing, now: 11 + RelayMotion.replacementDelay, reduceMotion: false).alpha,
            0,
            accuracy: 0.001
        )
        let arrivingAfterExit = motion.arrivalAppearance(
            now: 11 + RelayMotion.replacementDelay + RelayMotion.enterDuration / 2,
            reduceMotion: false
        )
        XCTAssertGreaterThan(arrivingAfterExit.alpha, 0)

        let settled = 11 + RelayMotion.replacementDelay + RelayMotion.enterDuration + 0.001
        XCTAssertEqual(motion.arrivalAppearance(now: settled, reduceMotion: false), .resting)
        motion.prune(now: settled)
        XCTAssertTrue(motion.departingLabels.isEmpty)
        XCTAssertFalse(motion.isAnimating(now: settled))
    }

    func testReducedMotionLabelTransitionsOnlyFade() {
        var motion = NotchContentMotion()
        motion.labelChanged(from: "Listening", width: 80, to: "Playing", now: 0)
        XCTAssertEqual(motion.arrivalAppearance(now: 0.1, reduceMotion: true).alpha, 0)
        let arriving = motion.arrivalAppearance(now: RelayMotion.replacementDelay + 0.1, reduceMotion: true)
        XCTAssertGreaterThan(arriving.alpha, 0)
        XCTAssertEqual(arriving.offset, 0)
        XCTAssertEqual(arriving.blur, 0)
        let departing = motion.departureAppearance(
            of: motion.departingLabels[0],
            now: 0.1,
            reduceMotion: true
        )
        XCTAssertLessThan(departing.alpha, 1)
        XCTAssertEqual(departing.offset, 0)
        XCTAssertEqual(departing.blur, 0)
        XCTAssertEqual(motion.presenceBlur(now: 0, reduceMotion: true), 0)
    }

    func testSurfacePresenceSharpensCopyOnShowAndBlursItOnHide() {
        var motion = NotchContentMotion()
        XCTAssertEqual(motion.presenceBlur(now: 0, reduceMotion: false), 0)
        motion.setPresence(visible: true, duration: 0.34, now: 1)
        XCTAssertEqual(motion.presenceBlur(now: 1, reduceMotion: false), RelayMotion.Style.text.blurRadius)
        XCTAssertEqual(motion.presenceBlur(now: 1.341, reduceMotion: false), 0)
        motion.setPresence(visible: false, duration: 0.24, now: 2)
        XCTAssertEqual(motion.presenceBlur(now: 2, reduceMotion: false), 0)
        XCTAssertEqual(motion.presenceBlur(now: 2.241, reduceMotion: false), RelayMotion.Style.text.blurRadius)
    }

    func testGlyphChangesGrowAccentDotsFromTheCoreAndBlendColours() {
        var motion = NotchContentMotion()
        motion.glyphChanged(from: .neutral, now: 0)
        let identity: (CGPoint) -> CGPoint = { $0 }

        let start = motion.glyphDots(target: .listening, now: 0, reduceMotion: false, center: identity)
        XCTAssertEqual(start.count, NotchStatusGlyph.listening.dots.count)
        let emerging = start.filter { $0.alpha == 0 }
        XCTAssertEqual(emerging.count, 8)
        for dot in emerging {
            XCTAssertTrue(NotchContentMotion.isCore(dot.center), "accent dots start inside the core")
        }

        let settled = motion.glyphDots(
            target: .listening,
            now: NotchContentMotion.glyphChangeDuration + 0.001,
            reduceMotion: false,
            center: identity
        )
        XCTAssertEqual(settled.map(\.center), NotchStatusGlyph.listening.dots.map { CGPoint(x: $0.x, y: $0.y) })
        XCTAssertTrue(settled.allSatisfy { $0.alpha == 1 && $0.softness == 0 })

        motion.glyphChanged(from: .listening, now: 10)
        let blending = motion.glyphDots(
            target: .playing,
            now: 10 + RelayMotion.changeDuration / 2,
            reduceMotion: false,
            center: identity
        )
        let accent = try! XCTUnwrap(blending.first { $0.center == CGPoint(x: 19.5, y: 9.5) })
        XCTAssertNotEqual(accent.color, NotchStatusDotColor.orange.rgb)
        XCTAssertNotEqual(accent.color, NotchStatusDotColor.blue.rgb)

        motion.glyphChanged(from: .playing, now: 20)
        let retracting = motion.glyphDots(target: .neutral, now: 20, reduceMotion: false, center: identity)
        XCTAssertEqual(retracting.count, NotchStatusGlyph.playing.dots.count)
        let retracted = motion.glyphDots(
            target: .neutral,
            now: 20 + RelayMotion.exitDuration + 0.001,
            reduceMotion: false,
            center: identity
        )
        XCTAssertEqual(retracted.filter { $0.alpha > 0 }.count, NotchStatusGlyph.neutral.dots.count)
    }

    func testStoppingGlyphMotionFinishesItsCycleAtRest() {
        var motion = NotchContentMotion()
        let now = NotchStatusGlyphMotion.duration * 10.25
        motion.statusChanged(from: .working, to: .notWorking, now: now, reduceMotion: false)
        XCTAssertEqual(motion.motionStatus(for: .notWorking, now: now), .working)
        XCTAssertEqual(
            motion.settleDeadline,
            NotchStatusGlyphMotion.duration * 11,
            accuracy: 0.0001
        )
        XCTAssertEqual(motion.motionStatus(for: .notWorking, now: motion.settleDeadline), .notWorking)

        motion.statusChanged(from: .working, to: .notWorking, now: now, reduceMotion: true)
        XCTAssertEqual(motion.motionStatus(for: .notWorking, now: now), .notWorking)

        motion.statusChanged(from: .listening, to: .playing, now: now, reduceMotion: false)
        XCTAssertNil(motion.settlingStatus)
    }

    func testHoverDiscEasesInAndOut() {
        var motion = NotchContentMotion()
        XCTAssertEqual(motion.hoverAmount(now: 0), 0)
        motion.hoverChanged(to: true, now: 1)
        XCTAssertEqual(motion.hoverAmount(now: 1), 0)
        XCTAssertEqual(motion.hoverAmount(now: 1 + RelayMotion.hoverDuration + 0.001), 1)
        motion.hoverChanged(to: false, now: 2)
        XCTAssertEqual(motion.hoverAmount(now: 2), 1)
        XCTAssertEqual(motion.hoverAmount(now: 2 + RelayMotion.hoverDuration + 0.001), 0)
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
        for outcome in [OverlayState.speechFailed, .cancelled(.stt), .cancelled(.tts)] {
            XCTAssertEqual(
                NotchSessionStatus.resolve(for: outcome, hasActivityLabels: true),
                .notWorking,
                "\(outcome) is an outcome, so its glyph rests and its label stays visible"
            )
            XCTAssertEqual(
                NotchStatusController.displayedActivityLabel(
                    status: .notWorking,
                    compactLabel: NotchVisualLabelAllowlist.presentation(for: outcome).labels.first,
                    workingProgressLabel: nil,
                    workingGlyphHovered: false,
                    workingStatusRevealActive: false
                ),
                NotchVisualLabelAllowlist.presentation(for: outcome).labels.first
            )
        }
    }

    func testNotchGlyphsMatchExportedDotMatrices() {
        XCTAssertEqual(NotchSessionStatus.notWorking.glyph, .neutral)
        XCTAssertEqual(NotchSessionStatus.working.glyph, .neutral)
        XCTAssertEqual(NotchSessionStatus.listening.glyph, .listening)
        XCTAssertEqual(NotchSessionStatus.paused.glyph, .paused)
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

        XCTAssertEqual(NotchStatusGlyph.paused.dots.count, 12)
        XCTAssertTrue(NotchStatusGlyph.paused.dots.allSatisfy { $0.color == .white })
        XCTAssertEqual(NotchStatusGlyph.paused.dots.map(\.x), NotchStatusGlyph.listening.dots.map(\.x))
        XCTAssertEqual(NotchStatusGlyph.paused.dots.map(\.y), NotchStatusGlyph.listening.dots.map(\.y))

        XCTAssertEqual(NotchStatusGlyph.playing.dots.count, 12)
        XCTAssertEqual(NotchStatusGlyph.playing.dots.filter { $0.color == .white }.count, 4)
        XCTAssertEqual(NotchStatusGlyph.playing.dots.filter { $0.color == .blue }.count, 8)
        XCTAssertEqual(NotchStatusGlyph.playing.dots.map(\.x), NotchStatusGlyph.listening.dots.map(\.x))
        XCTAssertEqual(NotchStatusGlyph.playing.dots.map(\.y), NotchStatusGlyph.listening.dots.map(\.y))
    }

    func testNotchGlyphMotionMatchesAnimatedSVGKeyframesForBothActiveStates() throws {
        XCTAssertFalse(NotchSessionStatus.notWorking.animatesGlyphMotion)
        XCTAssertTrue(NotchSessionStatus.working.animatesGlyphMotion)
        XCTAssertTrue(NotchSessionStatus.listening.animatesGlyphMotion)
        XCTAssertFalse(NotchSessionStatus.paused.animatesGlyphMotion)
        XCTAssertTrue(NotchSessionStatus.playing.animatesGlyphMotion)
        XCTAssertTrue(NotchSessionStatus.listening.usesGlyphShimmer)
        XCTAssertTrue(NotchSessionStatus.playing.usesGlyphShimmer)
        XCTAssertFalse(NotchSessionStatus.working.usesGlyphShimmer)
        XCTAssertFalse(NotchSessionStatus.paused.usesGlyphShimmer)
        XCTAssertEqual(NotchStatusGlyphMotion.duration, 0.6, accuracy: 0.0001)

        XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: .notWorking, phase: 0.6683), 0)
        for status in [NotchSessionStatus.working, .listening, .playing] {
            XCTAssertEqual(NotchStatusGlyphMotion.coreRotation(for: status, phase: 0), 0, accuracy: 0.0001)
            XCTAssertEqual(
                NotchStatusGlyphMotion.coreRotation(for: status, phase: 0.6683),
                .pi / 4,
                accuracy: 0.0001
            )
            XCTAssertEqual(
                NotchStatusGlyphMotion.coreRotation(for: status, phase: 1),
                .pi / 2,
                accuracy: 0.0001
            )
        }

        for status in [NotchSessionStatus.listening, .playing] {
            let rightDot = try XCTUnwrap(status.glyph.dots.first { $0.x == 19.5 && $0.y == 9.5 })
            XCTAssertEqual(NotchStatusGlyphMotion.accentOffset(for: rightDot, status: status, phase: 0).x, 0, accuracy: 0.0001)
            XCTAssertEqual(NotchStatusGlyphMotion.accentOffset(for: rightDot, status: status, phase: 0.6667).x, 1, accuracy: 0.0001)
            XCTAssertEqual(NotchStatusGlyphMotion.accentOffset(for: rightDot, status: status, phase: 1).x, 0, accuracy: 0.0001)

            let topDot = try XCTUnwrap(status.glyph.dots.first { $0.x == 14.5 && $0.y == 4.5 })
            XCTAssertEqual(NotchStatusGlyphMotion.accentOffset(for: topDot, status: status, phase: 0.6667).y, -1, accuracy: 0.0001)

            for dot in status.glyph.dots where dot.color != .white {
                let center = NotchStatusGlyphMotion.transformedCenter(
                    for: dot,
                    status: status,
                    phase: 0.6667
                )
                XCTAssertGreaterThanOrEqual(center.x - dot.diameter / 2, 0)
                XCTAssertLessThanOrEqual(center.x + dot.diameter / 2, 24)
                XCTAssertGreaterThanOrEqual(center.y - dot.diameter / 2, 0)
                XCTAssertLessThanOrEqual(center.y + dot.diameter / 2, 24)
            }
        }

        let coreDot = try XCTUnwrap(NotchStatusGlyph.neutral.dots.first)
        for status in [NotchSessionStatus.working, .listening, .playing] {
            let rotated = NotchStatusGlyphMotion.transformedCenter(for: coreDot, status: status, phase: 0.6683)
            XCTAssertEqual(rotated.x, 15.5355, accuracy: 0.0001)
            XCTAssertEqual(rotated.y, 12, accuracy: 0.0001)
        }
    }

    func testNotchGlyphMotionHonorsReduceMotionWithoutChangingStateArtwork() {
        for status in [NotchSessionStatus.listening, .playing] {
            XCTAssertTrue(NotchStatusGlyphMotion.shouldAnimate(status: status, reduceMotion: false))
            XCTAssertFalse(NotchStatusGlyphMotion.shouldAnimate(status: status, reduceMotion: true))
        }
        XCTAssertTrue(NotchStatusGlyphMotion.shouldAnimate(status: .working, reduceMotion: false))
        XCTAssertFalse(NotchStatusGlyphMotion.shouldAnimate(status: .notWorking, reduceMotion: false))
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

final class NotchBlurredTextRendererTests: XCTestCase {
    private final class FlippedCanvas: NSView {
        var blur: CGFloat = 0
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setFill()
            bounds.fill()
            NotchBlurredTextRenderer.shared.draw(
                "TTTT",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 18, weight: .bold),
                    .foregroundColor: NSColor.white,
                ],
                in: NSRect(x: 20, y: 12, width: 80, height: 24),
                blur: blur,
                alpha: 1,
                scale: 2
            )
        }
    }

    private struct Coverage {
        let centroid: CGPoint
        let litPixels: Int
        let peak: CGFloat
    }

    private func coverage(blur: CGFloat) throws -> Coverage {
        let canvas = FlippedCanvas(frame: NSRect(x: 0, y: 0, width: 120, height: 48))
        canvas.blur = blur
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var total: CGFloat = 0
        var lit = 0
        var peak: CGFloat = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let white = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0
                guard white > 0.02 else { continue }
                lit += 1
                peak = max(peak, white)
                sumX += CGFloat(x) * white
                sumY += CGFloat(y) * white
                total += white
            }
        }
        let scale = CGFloat(rep.pixelsWide) / canvas.bounds.width
        return Coverage(
            centroid: CGPoint(x: sumX / total / scale, y: sumY / total / scale),
            litPixels: lit,
            peak: peak
        )
    }

    func testBlurredCopyDrawsUprightInPlaceAndSofter() throws {
        let crisp = try coverage(blur: 0)
        let blurred = try coverage(blur: 3)

        XCTAssertGreaterThan(crisp.litPixels, 0)
        // Same place and orientation: a "T" is top-heavy, so an upside-down
        // render would move the centroid by several points.
        XCTAssertEqual(blurred.centroid.x, crisp.centroid.x, accuracy: 1)
        XCTAssertEqual(blurred.centroid.y, crisp.centroid.y, accuracy: 1)
        // Softer: the ink spreads over more pixels at a lower peak.
        XCTAssertGreaterThan(blurred.litPixels, crisp.litPixels)
        XCTAssertLessThan(blurred.peak, crisp.peak)
    }
}
