import AppKit
import XCTest
@testable import relay_runner

final class WorkspaceDotMatrixTests: XCTestCase {
    func testWorkspaceThemeUsesDesignNavyAndPreservesExistingSpeechThemes() {
        XCTAssertEqual(ParticleFieldRenderer.Theme.stt.baseHue, 0.04, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.stt.baseSaturation, 0.95, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.stt.fieldFraction, 0.32, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.stt.baseHighlight.r, 1.000, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.stt.baseHighlight.g, 0.965, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.stt.baseHighlight.b, 0.900, accuracy: 0.001)

        XCTAssertEqual(ParticleFieldRenderer.Theme.tts.baseHue, 0.68, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.tts.baseSaturation, 0.80, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.tts.fieldFraction, 0.44, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.tts.baseHighlight.r, 0.992, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.tts.baseHighlight.g, 0.918, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.tts.baseHighlight.b, 0.859, accuracy: 0.001)

        XCTAssertEqual(ParticleFieldRenderer.Theme.workspace.baseSaturation, 0, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.workspace.fieldFraction, 1, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.workspace.baseHighlight.r, 10.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.workspace.baseHighlight.g, 15.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(ParticleFieldRenderer.Theme.workspace.baseHighlight.b, 25.0 / 255.0, accuracy: 0.001)
    }

    func testFullBoundsCoverageDoesNotChangeDefaultSpeechFieldSizing() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let host = NSView(frame: bounds)
        host.wantsLayer = true

        let speechRenderer = ParticleFieldRenderer()
        speechRenderer.attach(to: host)
        speechRenderer.layoutInBounds(bounds, backingScale: 1)
        XCTAssertEqual(speechRenderer.renderedParticleFrame.height, 264, accuracy: 0.001)
        XCTAssertEqual(speechRenderer.renderedGradientFrame, bounds)

        let workspaceRenderer = ParticleFieldRenderer(coverage: .fullBounds)
        workspaceRenderer.attach(to: host)
        workspaceRenderer.layoutInBounds(bounds, backingScale: 1)
        XCTAssertEqual(workspaceRenderer.renderedParticleFrame, bounds)
        XCTAssertEqual(workspaceRenderer.renderedGradientFrame, bounds)
    }

    func testWorkspaceMatrixIsStaticWithoutChangingSpeechAnimation() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        host.wantsLayer = true
        let renderer = ParticleFieldRenderer(coverage: .fullBounds)
        renderer.attach(to: host)
        renderer.layoutInBounds(host.bounds, backingScale: 1)

        renderer.transition(to: .workspace, reduceMotion: false)
        XCTAssertFalse(renderer.isAnimationRunning)

        renderer.transition(to: .stt, reduceMotion: false)
        XCTAssertTrue(renderer.isAnimationRunning)

        renderer.transition(to: .stt, reduceMotion: true)
        XCTAssertFalse(renderer.isAnimationRunning)

        renderer.transition(to: nil)
        XCTAssertFalse(renderer.isAnimationRunning)
    }

    func testWorkspaceHostNeverInterceptsPointerInput() {
        let host = WorkspaceDotMatrixHostView(reduceMotion: true)
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        host.layoutSubtreeIfNeeded()

        XCTAssertNil(host.hitTest(NSPoint(x: 40, y: 40)))
        XCTAssertFalse(host.isAnimationRunning)

        host.update(reduceMotion: false)
        XCTAssertFalse(host.isAnimationRunning)
        host.stop()
        XCTAssertFalse(host.isAnimationRunning)
    }

    func testStaticWorkspaceMatrixRendersOpaqueDesignPixelsAfterFirstLayout() throws {
        let host = WorkspaceDotMatrixHostView(reduceMotion: false)
        host.frame = CGRect(x: 0, y: 0, width: 160, height: 120)
        host.layoutSubtreeIfNeeded()

        let image = try XCTUnwrap(host.renderedParticleImage)
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var designPixelCount = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[offset] == 10,
               pixels[offset + 1] == 15,
               pixels[offset + 2] == 25,
               pixels[offset + 3] == 255 {
                designPixelCount += 1
            }
        }
        XCTAssertGreaterThan(designPixelCount, 100)
        XCTAssertFalse(host.isAnimationRunning)
    }

    func testPresentationCoversEveryWorkspaceModalBelowModalContent() {
        let none = presentation()
        let modalPresentations = [
            presentation(showsTicketDetail: true),
            presentation(showsCreateTicket: true),
            presentation(showsEditTicket: true),
            presentation(showsSpikeFollowup: true),
            presentation(showsHistory: true),
        ]

        XCTAssertFalse(none.isVisible)
        XCTAssertTrue(modalPresentations.allSatisfy(\.isVisible))
        XCTAssertEqual(ProgramWorkspaceDotMatrixStyle.backgroundBlurRadius, 6)
        XCTAssertEqual(ProgramWorkspaceDotMatrixStyle.intensity, 1)
        XCTAssertFalse(modalPresentations[0].allowsHitTesting)
        XCTAssertLessThan(modalPresentations[0].layerZIndex, modalPresentations[0].modalContentZIndex)
        XCTAssertEqual(modalPresentations[0].surfaceHeight, ProgramBoardBackdropStyle.backdropHeight)
        XCTAssertEqual(modalPresentations.map(\.modalKind), [
            .ticketDetail,
            .createTicket,
            .editTicket,
            .spikeFollowup,
            .history,
        ])

        let shortScreen = presentation(showsCreateTicket: true, viewportHeight: 320)
        XCTAssertEqual(shortScreen.surfaceHeight, 320)
        XCTAssertEqual(
            ProgramBoardBackdropStyle.bottomCornerRadius,
            BoardRevealTransitionPlanner.expandedSurfaceCornerRadius
        )
    }

    func testModalBackdropBlursBoardWithoutMaterialTintAndModalLayerOwnsBackgroundDismissal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Board/ProgramBoardOverlayView.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)
        let backdropStart = try XCTUnwrap(contents.range(of: "private struct ProgramWorkspaceDotMatrixLayer: View"))
        let backdropEnd = try XCTUnwrap(
            contents.range(of: "private struct ProgramWorkspaceDotMatrixView", range: backdropStart.upperBound..<contents.endIndex)
        )
        let backdrop = String(contents[backdropStart.lowerBound..<backdropEnd.lowerBound])

        XCTAssertFalse(backdrop.contains("Material"))
        XCTAssertTrue(contents.contains(".blur(radius: backgroundBlurRadius)"))
        XCTAssertTrue(backdrop.contains(".allowsHitTesting(presentation.allowsHitTesting)"))

        let modalStart = try XCTUnwrap(contents.range(of: "private struct ProgramBoardModalLayer<Content: View>"))
        let modalEnd = try XCTUnwrap(
            contents.range(of: "private struct ProgramColumnFramesKey", range: modalStart.upperBound..<contents.endIndex)
        )
        let modalLayer = String(contents[modalStart.lowerBound..<modalEnd.lowerBound])
        XCTAssertTrue(modalLayer.contains("ProgramWorkspaceModalClickCatcher(onDismiss: onDismiss)"))
        XCTAssertTrue(contents.contains(".allowsHitTesting(!dotMatrixPresentation.isVisible)"))
    }

    func testModalMotionIsCriticallyDampedAndReducedMotionIsStatic() {
        XCTAssertEqual(ProgramWorkspaceModalMotion.response, 0.34, accuracy: 0.001)
        XCTAssertEqual(ProgramWorkspaceModalMotion.dampingFraction, 1, accuracy: 0.001)
        XCTAssertNotNil(ProgramWorkspaceModalMotion.animation(reduceMotion: false))
        XCTAssertNil(ProgramWorkspaceModalMotion.animation(reduceMotion: true))
    }

    func testModalBackdropHitViewConsumesFullClickBeforeDismissingOnce() throws {
        var dismissCount = 0
        let hitView = WorkspaceModalBackdropHitView {
            dismissCount += 1
        }
        hitView.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 80, y: 60),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        XCTAssertTrue(hitView.hitTest(CGPoint(x: 80, y: 60)) === hitView)
        XCTAssertNil(hitView.hitTest(CGPoint(x: 220, y: 60)))
        XCTAssertTrue(hitView.acceptsFirstMouse(for: event))
        hitView.mouseDown(with: event)
        XCTAssertEqual(dismissCount, 0)
        hitView.mouseUp(with: event)
        XCTAssertEqual(dismissCount, 1)
    }

    private func presentation(
        showsTicketDetail: Bool = false,
        showsCreateTicket: Bool = false,
        showsEditTicket: Bool = false,
        showsSpikeFollowup: Bool = false,
        showsHistory: Bool = false,
        viewportHeight: CGFloat = ProgramBoardBackdropStyle.backdropHeight + 100
    ) -> ProgramWorkspaceDotMatrixPresentation {
        ProgramWorkspaceDotMatrixPresentation.resolve(
            showsTicketDetail: showsTicketDetail,
            showsCreateTicket: showsCreateTicket,
            showsEditTicket: showsEditTicket,
            showsSpikeFollowup: showsSpikeFollowup,
            showsHistory: showsHistory,
            viewportHeight: viewportHeight
        )
    }
}
