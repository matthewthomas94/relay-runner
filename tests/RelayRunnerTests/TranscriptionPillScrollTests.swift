import AppKit
import XCTest
@testable import relay_runner

@MainActor
final class TranscriptionPillScrollTests: XCTestCase {
    private let longBody = Array(
        repeating: "A long response line that must remain available for manual scrolling.",
        count: 20
    ).joined(separator: "\n")

    func testCommandPillsRemainTextOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let controllerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Overlay/OverlayController.swift"),
            encoding: .utf8
        )
        let pillSource = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Overlay/TranscriptionPill.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(controllerSource.contains("keycap:"))
        XCTAssertFalse(pillSource.contains("TranscriptionPillKeycap"))
        XCTAssertFalse(pillSource.contains("NSHostingView"))
    }

    func testMountedOverlayHitTestingRoutesTitleBodyAndTrailingEdgeScrollToPill() throws {
        let mounted = mountLongPill()
        defer { mounted.close() }

        mounted.panel.ignoresMouseEvents = false
        let bodyLabel = try XCTUnwrap(bodyLabel(in: mounted.pill))
        let bodyContainer = try XCTUnwrap(bodyLabel.superview)
        let initialY = bodyLabel.frame.minY

        let hitPoints = [
            NSPoint(x: mounted.pill.bounds.midX, y: mounted.pill.bounds.maxY - 24),
            mounted.pill.convert(
                NSPoint(x: bodyContainer.bounds.midX, y: bodyContainer.bounds.midY),
                from: bodyContainer
            ),
            NSPoint(x: mounted.pill.bounds.maxX - 30, y: mounted.pill.bounds.midY),
        ]

        for point in hitPoints {
            let windowPoint = mounted.pill.convert(point, to: mounted.root)
            XCTAssertTrue(mounted.root.hitTest(windowPoint) === mounted.pill)
        }

        let event = try makeScrollEvent(deltaY: 1, units: .line)
        let bodyPoint = mounted.pill.convert(hitPoints[1], to: mounted.root)
        mounted.root.hitTest(bodyPoint)?.scrollWheel(with: event)

        XCTAssertGreaterThan(bodyLabel.frame.minY, initialY + 1)
    }

    func testPreciseAndLineDeltasTraverseAndClampFullRange() throws {
        let mounted = mountLongPill()
        defer { mounted.close() }
        let bodyLabel = try XCTUnwrap(bodyLabel(in: mounted.pill))
        let container = try XCTUnwrap(bodyLabel.superview)
        let minY = container.frame.height - bodyLabel.frame.height

        mounted.pill.scrollWheel(with: try makeScrollEvent(deltaY: 8, units: .pixel))
        XCTAssertEqual(bodyLabel.frame.minY, minY + 8, accuracy: 0.01)

        mounted.pill.scrollWheel(with: try makeScrollEvent(deltaY: 1, units: .line))
        XCTAssertGreaterThan(bodyLabel.frame.minY, minY + 9)

        mounted.pill.scrollWheel(with: try makeScrollEvent(deltaY: 10_000, units: .pixel))
        XCTAssertEqual(bodyLabel.frame.minY, 0, accuracy: 0.01)

        mounted.pill.scrollWheel(with: try makeScrollEvent(deltaY: -10_000, units: .pixel))
        XCTAssertEqual(bodyLabel.frame.minY, minY, accuracy: 0.01)
    }

    func testMouseAndNaturalTrackpadDeltasNormalizeInExpectedDirection() {
        XCTAssertEqual(
            TranscriptionPill.manualScrollDelta(
                scrollingDeltaY: 2,
                directionInvertedFromDevice: false,
                hasPreciseScrollingDeltas: false,
                lineHeight: 18
            ),
            36
        )
        XCTAssertEqual(
            TranscriptionPill.manualScrollDelta(
                scrollingDeltaY: -7,
                directionInvertedFromDevice: true,
                hasPreciseScrollingDeltas: true,
                lineHeight: 18
            ),
            7
        )
    }

    func testSelectivePanelInterceptionOnlyClaimsScrollablePillFrame() {
        let frame = NSRect(x: 100, y: 100, width: 460, height: 160)

        XCTAssertFalse(OverlayController.shouldIgnoreMouseEvents(
            at: NSPoint(x: frame.midX, y: frame.midY),
            manualScrollFrame: frame
        ))
        XCTAssertTrue(OverlayController.shouldIgnoreMouseEvents(
            at: NSPoint(x: frame.maxX + 1, y: frame.midY),
            manualScrollFrame: frame
        ))
        XCTAssertTrue(OverlayController.shouldIgnoreMouseEvents(
            at: NSPoint(x: frame.midX, y: frame.midY),
            manualScrollFrame: nil
        ))
    }

    func testManualScrollCancelsPendingTeleprompterAndSurvivesSameMessageTransitions() throws {
        let mounted = mountLongPill()
        defer { mounted.close() }
        let bodyLabel = try XCTUnwrap(bodyLabel(in: mounted.pill))

        mounted.pill.scrollWheel(with: try makeScrollEvent(deltaY: 24, units: .pixel))
        let selectedY = bodyLabel.frame.minY

        mounted.pill.showFull(
            title: "Preparing speech…",
            body: longBody,
            theme: .tts,
            animated: false
        )
        mounted.pill.showFull(
            title: "Playing…",
            body: longBody,
            theme: .tts,
            animated: false
        )
        XCTAssertEqual(bodyLabel.frame.minY, selectedY, accuracy: 0.01)

        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertEqual(bodyLabel.frame.minY, selectedY, accuracy: 0.01)
    }

    func testNewMessageResetsToTopAndNonScrollableStatesPassThrough() throws {
        let mounted = mountLongPill()
        defer { mounted.close() }
        let bodyLabel = try XCTUnwrap(bodyLabel(in: mounted.pill))

        mounted.pill.scrollWheel(with: try makeScrollEvent(deltaY: 40, units: .pixel))
        mounted.pill.showFull(
            title: "Response ready…",
            body: longBody + "\nNew response",
            theme: .tts,
            animated: false
        )
        let container = try XCTUnwrap(bodyLabel.superview)
        XCTAssertEqual(
            bodyLabel.frame.minY,
            container.frame.height - bodyLabel.frame.height,
            accuracy: 0.01
        )

        mounted.pill.showCompact(title: "Thinking…", theme: .tts, animated: false)
        XCTAssertNil(mounted.pill.manualScrollFrameOnScreen())

        mounted.pill.showFull(title: "Response ready…", body: "Short body", theme: .tts, animated: false)
        XCTAssertNil(mounted.pill.manualScrollFrameOnScreen())

        mounted.pill.showFull(title: "Recording", body: longBody, theme: .stt, animated: false)
        XCTAssertNil(mounted.pill.manualScrollFrameOnScreen())
    }

    func testHiddenDetachedAndResizedPillsDoNotLeaveInteractiveFrame() {
        let mounted = mountLongPill()
        XCTAssertNotNil(mounted.pill.manualScrollFrameOnScreen())

        mounted.panel.orderOut(nil)
        XCTAssertNil(mounted.pill.manualScrollFrameOnScreen())

        mounted.panel.orderFrontRegardless()
        mounted.panel.setFrame(
            NSRect(x: 500, y: 300, width: 900, height: 600),
            display: false
        )
        mounted.root.frame = NSRect(origin: .zero, size: mounted.panel.frame.size)
        mounted.pill.showFull(title: "Playing…", body: longBody, theme: .tts, animated: false)
        XCTAssertNotNil(mounted.pill.manualScrollFrameOnScreen())

        mounted.pill.removeFromSuperview()
        XCTAssertNil(mounted.pill.manualScrollFrameOnScreen())
        mounted.close()
    }

    private func mountLongPill() -> (panel: OverlayPanel, root: NSView, pill: TranscriptionPill, close: () -> Void) {
        _ = NSApplication.shared
        let panel = OverlayPanel()
        panel.setFrame(NSRect(x: 100, y: 100, width: 800, height: 500), display: false)
        let root = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        panel.contentView = root
        let pill = TranscriptionPill(frame: .zero)
        root.addSubview(pill)
        pill.showFull(
            title: "Response ready…",
            body: longBody,
            theme: .tts,
            animated: false
        )
        panel.orderFrontRegardless()
        return (panel, root, pill, {
            pill.hide(animated: false)
            panel.orderOut(nil)
        })
    }

    private func bodyLabel(in pill: TranscriptionPill) -> NSTextField? {
        descendants(of: pill)
            .compactMap { $0 as? NSTextField }
            .first { $0.maximumNumberOfLines == 0 }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func makeScrollEvent(
        deltaY: Int32,
        units: CGScrollEventUnit
    ) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ))
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }
}
