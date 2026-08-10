import AppKit
import XCTest
@testable import relay_runner

final class WorkspaceDotMatrixTests: XCTestCase {
    func testWorkspaceThemeIsNeutralAndPreservesExistingSpeechThemes() {
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
        XCTAssertEqual(
            ParticleFieldRenderer.Theme.workspace.baseHighlight.r,
            ParticleFieldRenderer.Theme.workspace.baseHighlight.g,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ParticleFieldRenderer.Theme.workspace.baseHighlight.g,
            ParticleFieldRenderer.Theme.workspace.baseHighlight.b,
            accuracy: 0.001
        )
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

    func testWorkspaceAnimationStopsForReduceMotionAndWhenHidden() {
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        host.wantsLayer = true
        let renderer = ParticleFieldRenderer(coverage: .fullBounds)
        renderer.attach(to: host)
        renderer.layoutInBounds(host.bounds, backingScale: 1)

        renderer.transition(to: .workspace, reduceMotion: false)
        XCTAssertTrue(renderer.isAnimationRunning)

        renderer.transition(to: .workspace, reduceMotion: true)
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
        XCTAssertTrue(host.isAnimationRunning)
        host.stop()
        XCTAssertFalse(host.isAnimationRunning)
    }

    func testPresentationCoversLoadingAndEveryWorkspaceModalBelowModalContent() {
        let none = presentation()
        let loading = presentation(isLoading: true)
        let modalPresentations = [
            presentation(showsTicketDetail: true),
            presentation(showsCreateTicket: true),
            presentation(showsEditTicket: true),
            presentation(showsSpikeFollowup: true),
        ]

        XCTAssertFalse(none.isVisible)
        XCTAssertTrue(loading.isVisible)
        XCTAssertTrue(modalPresentations.allSatisfy(\.isVisible))
        XCTAssertFalse(loading.allowsHitTesting)
        XCTAssertLessThan(loading.layerZIndex, loading.modalContentZIndex)
        XCTAssertEqual(loading.surfaceHeight, ProgramBoardBackdropStyle.backdropHeight)

        let shortScreen = presentation(isLoading: true, viewportHeight: 320)
        XCTAssertEqual(shortScreen.surfaceHeight, 320)
        XCTAssertEqual(
            ProgramBoardBackdropStyle.bottomCornerRadius,
            BoardRevealTransitionPlanner.expandedSurfaceCornerRadius
        )
    }

    func testWorkspaceLoadingStateTearsDownAndResetsOnOpen() {
        let model = ProgramBoardViewModel()

        model.setWorkspaceLoading(true)
        XCTAssertTrue(model.workspaceLoadingActive)

        model.setWorkspaceLoading(false)
        XCTAssertFalse(model.workspaceLoadingActive)

        model.setWorkspaceLoading(true)
        model.prepareForOpening()
        XCTAssertFalse(model.workspaceLoadingActive)
    }

    private func presentation(
        isLoading: Bool = false,
        showsTicketDetail: Bool = false,
        showsCreateTicket: Bool = false,
        showsEditTicket: Bool = false,
        showsSpikeFollowup: Bool = false,
        viewportHeight: CGFloat = ProgramBoardBackdropStyle.backdropHeight + 100
    ) -> ProgramWorkspaceDotMatrixPresentation {
        ProgramWorkspaceDotMatrixPresentation.resolve(
            isLoading: isLoading,
            showsTicketDetail: showsTicketDetail,
            showsCreateTicket: showsCreateTicket,
            showsEditTicket: showsEditTicket,
            showsSpikeFollowup: showsSpikeFollowup,
            viewportHeight: viewportHeight
        )
    }
}
