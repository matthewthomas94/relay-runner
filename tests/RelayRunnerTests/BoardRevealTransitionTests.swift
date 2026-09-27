import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import relay_runner

final class BoardRevealTransitionTests: XCTestCase {
    func testWorkspaceHostingViewAcceptsTheFirstMouseClick() {
        let hostingView = BoardOverlayHostingView(rootView: EmptyView())

        XCTAssertTrue(hostingView.acceptsFirstMouse(for: nil))
    }

    func testRevealPlanStartsAsCenteredCompactNotchOnExternalDisplay() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

        let plan = BoardRevealTransitionPlanner.plan(for: screen, notchPlacement: nil)

        XCTAssertEqual(plan.compactFrame.width, BoardRevealTransitionPlanner.minimumCompactWidth)
        XCTAssertEqual(plan.compactFrame.height, NotchStatusPlacementPlanner.glyphSize.height)
        XCTAssertEqual(plan.compactFrame.midX, screen.width / 2)
        XCTAssertEqual(plan.fullWidthFrame, CGRect(x: 0, y: 0, width: 1512, height: 34))
        XCTAssertEqual(
            plan.expandedFrame,
            CGRect(x: 0, y: 0, width: 1512, height: ProgramBoardBackdropStyle.backdropHeight)
        )
        XCTAssertEqual(
            BoardRevealTransitionPlanner.expandedSurfaceHeight,
            ProgramBoardBackdropStyle.backdropHeight
        )
        XCTAssertEqual(
            BoardRevealTransitionPlanner.expandedSurfaceCornerRadius,
            ProgramBoardBackdropStyle.bottomCornerRadius
        )
        XCTAssertEqual(plan.glyphFrame.maxX, plan.compactFrame.maxX)
        XCTAssertEqual(plan.compactLeadingSpacerWidth, 0)
        XCTAssertEqual(plan.compactNotchSpacerWidth, 0)
    }

    func testRevealPlanUsesNotchPlacementWhenAvailable() throws {
        let geometry = NotchStatusDisplayGeometry(
            frame: CGRect(x: 100, y: 50, width: 1512, height: 982),
            visibleFrame: CGRect(x: 100, y: 50, width: 1512, height: 944),
            auxiliaryTopLeftArea: CGRect(x: 100, y: 1000, width: 663, height: 32),
            auxiliaryTopRightArea: CGRect(x: 948, y: 1000, width: 664, height: 32)
        )
        let placement = try XCTUnwrap(NotchStatusPlacementPlanner.placement(for: geometry))

        let plan = BoardRevealTransitionPlanner.plan(for: geometry.frame, notchPlacement: placement)

        XCTAssertGreaterThanOrEqual(plan.compactFrame.width, placement.visibleFrame.width)
        XCTAssertEqual(plan.compactFrame.midX, placement.visibleFrame.midX - geometry.frame.minX)
        XCTAssertEqual(plan.glyphFrame.minX, placement.glyphScreenX - geometry.frame.minX)
        XCTAssertEqual(plan.fullWidthFrame.maxX, geometry.frame.width)
        XCTAssertEqual(plan.compactLeadingSpacerWidth, placement.leadingSpacerWidth)
        XCTAssertEqual(plan.compactNotchSpacerWidth, placement.notchSpacerWidth)
    }

    func testRevealPlanClampsExpandedHeightOnShortScreens() {
        let screen = CGRect(x: 0, y: 0, width: 960, height: 420)

        let plan = BoardRevealTransitionPlanner.plan(for: screen, notchPlacement: nil)

        XCTAssertEqual(
            plan.expandedFrame.height,
            screen.height - BoardRevealTransitionPlanner.bottomScreenMargin
        )
        XCTAssertGreaterThan(plan.expandedFrame.height, NotchStatusPlacementPlanner.glyphSize.height)
    }

    func testWorkspaceFirstMotionBudgetIsSeparateFromRevealDuration() {
        XCTAssertEqual(BoardRevealTransitionTiming.firstMotionBudget, 0.10)
        XCTAssertEqual(BoardRevealTransitionTiming.expandToFullWidthDuration, 0.24)
        XCTAssertEqual(BoardRevealTransitionTiming.expandDuration, 0.34)
        XCTAssertEqual(BoardRevealTransitionTiming.contentRevealDuration, 0.38)
        XCTAssertEqual(BoardRevealTransitionTiming.revealAnimationDuration, 0.96, accuracy: 0.001)
        XCTAssertGreaterThan(BoardRevealTransitionTiming.revealAnimationDuration, 0.30)
    }

    func testEasedValueSnapsWithoutAnimationAndEasesOutWhenAnimated() {
        var value = BoardRevealEasedValue(0, duration: 0.3, curve: RelayMotion.changeCurve)

        value.set(1, animated: false, now: 10)
        XCTAssertEqual(value.value, 1)
        XCTAssertFalse(value.isAnimating)

        value.set(0, animated: true, now: 20)
        XCTAssertTrue(value.isAnimating)
        XCTAssertEqual(value.value, 1)

        value.advance(to: 20.15)
        XCTAssertLessThan(value.value, 0.5, "An ease-out settles more than halfway by the midpoint")
        XCTAssertGreaterThan(value.value, 0)
        XCTAssertTrue(value.isAnimating)

        value.advance(to: 20.31)
        XCTAssertEqual(value.value, 0)
        XCTAssertFalse(value.isAnimating)
    }

    func testEasedValueRetargetsFromItsCurrentValue() {
        var value = BoardRevealEasedValue(0, duration: 0.2, curve: RelayMotion.changeCurve)
        value.set(1, animated: true, now: 0)
        value.advance(to: 0.1)
        let interrupted = value.value

        value.set(0, animated: true, now: 0.1)
        XCTAssertEqual(value.value, interrupted)
        value.advance(to: 0.1)
        XCTAssertEqual(value.value, interrupted, accuracy: 0.0001)
        value.advance(to: 0.31)
        XCTAssertEqual(value.value, 0)
        XCTAssertFalse(value.isAnimating)
    }

    func testWorkspaceContentRisesSharpensAndSinksWithoutKeepingItsBlur() throws {
        let frame = CGRect(x: 0, y: 0, width: 1_200, height: 700)
        let panel = BoardOverlayPanel()
        panel.setFrame(frame, display: false)
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        let container = BoardRevealContainerView(
            frame: CGRect(origin: .zero, size: frame.size),
            contentView: content,
            displayGeometry: NotchStatusDisplayGeometry(screenFrame: frame),
            startsLoading: true
        )
        panel.contentView = container
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        container.layoutSubtreeIfNeeded()

        let contentContainer = try XCTUnwrap(content.superview)
        let contentLayer = try XCTUnwrap(contentContainer.layer)
        let rootLayer = try XCTUnwrap(container.superview?.layer ?? container.layer)
        // The centre is unaffected by the layer's own geometry flip, which
        // AppKit manages once the window displays.
        func contentCenter() -> CGPoint {
            contentLayer.convert(
                CGPoint(x: contentLayer.bounds.midX, y: contentLayer.bounds.midY),
                to: rootLayer
            )
        }
        func yOffsetAnimation() -> (from: Double, to: Double)? {
            guard let animation = contentLayer.animation(forKey: "boardRevealContentYOffset") as? CABasicAnimation,
                  let from = animation.fromValue as? NSNumber,
                  let to = animation.toValue as? NSNumber else { return nil }
            return (from.doubleValue, to.doubleValue)
        }
        let reduceMotion = RelayLayerMotion.reduceMotion

        let expanded = expectation(description: "Surface expanded while loading")
        container.animateReveal { expanded.fulfill() }
        wait(for: [expanded], timeout: 5)
        XCTAssertTrue(contentContainer.isHidden, "Content waits for loading to finish")

        container.setLoading(false)
        XCTAssertFalse(contentContainer.isHidden)
        XCTAssertEqual(hasRelayBlurFilter(contentLayer), !reduceMotion, "Content sharpens as it arrives")
        let rise = try XCTUnwrap(yOffsetAnimation())
        XCTAssertEqual(rise.to, 0)
        // The content waits for the loading label to finish leaving.
        waitForAnimations(RelayMotion.replacementDelay + BoardRevealTransitionTiming.contentRevealDuration + 0.25)

        let restingCenter = contentCenter()
        XCTAssertEqual(contentContainer.alphaValue, 1, accuracy: 0.01)
        XCTAssertFalse(hasRelayBlurFilter(contentLayer), "The settled Workspace renders without a blur pass")

        let dismissed = expectation(description: "Workspace dismissed")
        container.animateDismiss { dismissed.fulfill() }
        wait(for: [dismissed], timeout: 5)

        XCTAssertTrue(contentContainer.isHidden)
        XCTAssertFalse(hasRelayBlurFilter(contentLayer))
        let sink = try XCTUnwrap(yOffsetAnimation())
        XCTAssertEqual(sink.from, 0)
        XCTAssertEqual(sink.to, rise.from, "Content leaves to the offset it arrived from")
        let sunkCenter = contentCenter()
        if reduceMotion {
            XCTAssertEqual(rise.from, 0)
            XCTAssertEqual(sunkCenter.y, restingCenter.y, accuracy: 0.5)
        } else {
            XCTAssertGreaterThan(rise.from, 0)
            let sitsBelowOnScreen = rootLayer.isGeometryFlipped
                ? sunkCenter.y > restingCenter.y
                : sunkCenter.y < restingCenter.y
            XCTAssertTrue(sitsBelowOnScreen, "The hidden offset is below on screen: content rises in and sinks out")
        }
    }

    func testWorkspaceFirstMotionBudgetIsSeparateFromDismissDuration() {
        XCTAssertEqual(BoardRevealTransitionTiming.firstMotionBudget, 0.10)
        XCTAssertEqual(BoardRevealTransitionTiming.contentHideDuration, 0.22)
        XCTAssertEqual(BoardRevealTransitionTiming.dismissToFullWidthDuration, 0.24)
        XCTAssertEqual(BoardRevealTransitionTiming.compactDuration, 0.22)
        XCTAssertEqual(BoardRevealTransitionTiming.dismissAnimationDuration, 0.68, accuracy: 0.001)
        XCTAssertGreaterThan(BoardRevealTransitionTiming.dismissAnimationDuration, 0.25)
    }

    private func hasRelayBlurFilter(_ layer: CALayer) -> Bool {
        layer.filters?.contains { ($0 as? CIFilter)?.name == RelayLayerMotion.blurFilterName } ?? false
    }

    private func waitForAnimations(_ duration: TimeInterval) {
        let settled = expectation(description: "Animations settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { settled.fulfill() }
        wait(for: [settled], timeout: duration + 2)
    }
}
