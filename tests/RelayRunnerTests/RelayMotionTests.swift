import AppKit
import XCTest
@testable import relay_runner

final class RelayMotionTests: XCTestCase {
    func testCurvesStartAndEndAtRestAndEaseInTheExpectedDirection() {
        for curve in [RelayMotion.enterCurve, RelayMotion.exitCurve, RelayMotion.changeCurve] {
            XCTAssertEqual(curve.progress(0), 0)
            XCTAssertEqual(curve.progress(1), 1)
            XCTAssertEqual(curve.progress(-1), 0)
            XCTAssertEqual(curve.progress(2), 1)
        }
        // Entrances and changes decelerate; exits accelerate.
        XCTAssertGreaterThan(RelayMotion.enterCurve.progress(0.5), 0.8)
        XCTAssertGreaterThan(RelayMotion.changeCurve.progress(0.5), 0.7)
        XCTAssertLessThan(RelayMotion.exitCurve.progress(0.5), 0.5)
        XCTAssertLessThan(RelayMotion.exitDuration, RelayMotion.enterDuration)
    }

    func testHiddenContentContractsAndBlursWithoutMoving() {
        for style in [RelayMotion.Style.element, .surface, .text] {
            XCTAssertGreaterThanOrEqual(style.hiddenScale, 0.9)
            XCTAssertLessThan(style.scale(hidden: true, reduceMotion: false), 1)
            XCTAssertEqual(style.scale(hidden: false, reduceMotion: false), 1)
            XCTAssertGreaterThan(style.blur(hidden: true, reduceMotion: false), 0)
            XCTAssertEqual(style.blur(hidden: false, reduceMotion: false), 0)
        }
    }

    func testReduceMotionKeepsOnlyTheFade() {
        for style in [RelayMotion.Style.element, .surface, .text] {
            XCTAssertEqual(style.scale(hidden: true, reduceMotion: true), 1)
            XCTAssertEqual(style.blur(hidden: true, reduceMotion: true), 0)
        }
    }

    func testSharedDurationsAreTwentyFivePercentShorter() {
        XCTAssertEqual(RelayMotion.enterDuration, 0.255, accuracy: 0.0001)
        XCTAssertEqual(RelayMotion.exitDuration, 0.15, accuracy: 0.0001)
        XCTAssertEqual(RelayMotion.changeDuration, 0.225, accuracy: 0.0001)
        XCTAssertEqual(RelayMotion.hoverDuration, 0.1125, accuracy: 0.0001)
        XCTAssertEqual(RelayMotion.replacementGap, 0.075, accuracy: 0.0001)
    }

    func testLayerPreparationAddsOneNamedBlurAndKeepsExistingFilters() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        view.wantsLayer = true
        let existing = try XCTUnwrap(CIFilter(name: "CIGaussianBlur"))
        existing.name = "existing"
        view.layer?.filters = [existing]

        RelayLayerMotion.prepare(view)
        RelayLayerMotion.prepare(view)

        let names = (view.layer?.filters ?? []).compactMap { ($0 as? CIFilter)?.name }
        XCTAssertEqual(names, ["existing", RelayLayerMotion.blurFilterName])
        XCTAssertTrue(view.layerUsesCoreImageFilters)
    }

    func testScalePreservesTheCenterForCornerAndCenterAnchoredLayers() {
        for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
            let parent = CALayer()
            let child = CALayer()
            child.bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
            child.anchorPoint = anchor
            child.position = CGPoint(x: 160, y: 180)
            parent.addSublayer(child)
            let center = CGPoint(x: 150, y: 100)
            let resting = child.convert(center, to: parent)
            child.transform = RelayLayerMotion.centeredScale(0.96, on: child)
            let contracted = child.convert(center, to: parent)
            XCTAssertEqual(contracted.x, resting.x, accuracy: 0.001)
            XCTAssertEqual(contracted.y, resting.y, accuracy: 0.001)
            XCTAssertEqual(child.frame.width, 288, accuracy: 0.001)
            XCTAssertEqual(child.frame.height, 192, accuracy: 0.001)
        }
    }

    func testReplacementsWaitForTheOutgoingExitAndABeat() {
        XCTAssertGreaterThan(RelayMotion.replacementGap, 0)
        XCTAssertEqual(
            RelayMotion.replacementDelay,
            RelayMotion.exitDuration + RelayMotion.replacementGap,
            accuracy: 0.0001
        )
    }

    @MainActor
    func testCrossfadeLetsTheOldCopyLeaveBeforeTheNewOneArrives() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 160, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let label = NSTextField(labelWithString: "Listening")
        label.frame = NSRect(x: 10, y: 10, width: 120, height: 20)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        RelayLayerMotion.crossfade(label) { label.stringValue = "Sending voice" }
        let snapshot = try XCTUnwrap(window.contentView?.subviews.first { $0 !== label })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(label.alphaValue, 0, "the new copy waits while the old one leaves")

        RunLoop.main.run(until: Date().addingTimeInterval(
            RelayMotion.replacementDelay + RelayMotion.enterDuration + 0.3
        ))
        XCTAssertEqual(label.alphaValue, 1, accuracy: 0.01)
        XCTAssertNil(snapshot.superview)
    }

    @MainActor
    func testLeavingCancelsAnEntranceStillWaitingForItsDelay() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 80, height: 40),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()

        RelayLayerMotion.animateIn(view, delay: 0.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        RelayLayerMotion.animateOut(view)
        RunLoop.main.run(until: Date().addingTimeInterval(
            0.2 + RelayMotion.enterDuration + 0.3
        ))

        XCTAssertEqual(view.alphaValue, 0)
        XCTAssertTrue(view.isHidden)
    }

    @MainActor
    func testWindowPresentAndDismissRestoreTheRestingFrameAndSurviveAQuickReopen() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let resting = window.frame

        RelayWindowMotion.present(window, makeKey: false)
        XCTAssertEqual(window.frame, resting, "Presentation scales content without relocating the window")
        RunLoop.main.run(until: Date().addingTimeInterval(RelayMotion.enterDuration + 0.25))
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(window.frame, resting)

        var dismissed = false
        RelayWindowMotion.dismiss(window) { dismissed = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(window.frame, resting, "Dismissal keeps the same window frame")
        RelayWindowMotion.present(window, makeKey: false)
        RunLoop.main.run(until: Date().addingTimeInterval(RelayMotion.enterDuration + 0.3))

        XCTAssertTrue(window.isVisible, "a re-presented window must not be ordered out by the stale dismissal")
        XCTAssertFalse(dismissed)
        XCTAssertEqual(window.alphaValue, 1, accuracy: 0.01)
        XCTAssertEqual(window.frame.origin.y, resting.origin.y, accuracy: 0.5)

        RelayWindowMotion.dismiss(window) { dismissed = true }
        RunLoop.main.run(until: Date().addingTimeInterval(RelayMotion.exitDuration + 0.3))
        XCTAssertTrue(dismissed)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, resting, "the window rests where it was for next time")
        XCTAssertEqual(window.alphaValue, 1)
    }
}
