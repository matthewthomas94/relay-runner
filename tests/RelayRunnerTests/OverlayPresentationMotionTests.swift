import AppKit
import XCTest
@testable import relay_runner

@MainActor
final class OverlayPresentationMotionTests: XCTestCase {
    func testPlaybackAndRecordingEnterAndExitTogetherWithoutWaitingForCard() {
        for recording in [false, true] {
            for showsCard in [false, true] {
                let scene = Scene(showsCard: showsCard)
                defer { scene.stop() }
                if recording {
                    scene.state.updateSTT(isRecording: true, partial: "")
                } else {
                    scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "Response.")
                }
                for time in [0.0, 0.15, 0.31, 0.46, 0.62] {
                    scene.step(time)
                    assertAligned(scene)
                    if time == 0.15 { XCTAssertEqual(scene.pill.alphaValue, 0.5, accuracy: 0.001) }
                }
                XCTAssertEqual(scene.pill.alphaValue, 1)
                scene.state.reset()
                scene.step(1)
                scene.step(1.15)
                assertAligned(scene)
                XCTAssertEqual(scene.pill.alphaValue, 0.5, accuracy: 0.001)
                scene.step(1.31)
                assertAligned(scene)
                XCTAssertEqual(scene.pill.alphaValue, 0)
            }
        }
    }

    func testControlCancellationAndRetainedReplayCannotReopenAnExitingPill() {
        for cancelTime in [0.15, 0.46, 0.7] {
            for replayArrivesFirst in [false, true] {
                let scene = Scene(showsCard: true)
                defer { scene.stop() }
                let original = SpeechPresentation(utteranceID: "response", originalUtteranceID: "response", mode: .newDelivery)
                scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "Response.", presentation: original)
                for time in [0.0, 0.15, 0.31, 0.46, 0.62] where time < cancelTime {
                    scene.step(time)
                }
                scene.step(cancelTime)
                if !replayArrivesFirst {
                    scene.state.setCancelled()
                    scene.step(cancelTime)
                }
                let retained = SpeechPresentation(utteranceID: "response", originalUtteranceID: "response",
                                                  mode: .retainedReplay, stopReason: "user_stop")
                scene.state.handleServiceEvent(source: "tts", newState: "replay_retained", text: "Response.", presentation: retained)
                if replayArrivesFirst { scene.state.setCancelled() }
                scene.step(cancelTime)
                scene.step(cancelTime + 0.15)
                assertAligned(scene)
                scene.step(cancelTime + 0.31)
                assertAligned(scene)
                XCTAssertEqual(scene.pill.alphaValue, 0)
                scene.state.handleServiceEvent(source: "tts", newState: "idle", text: nil, presentation: original)
                scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "Response.", presentation: original)
                scene.step(cancelTime + 0.65)
                XCTAssertEqual(scene.pill.alphaValue, 0)
                XCTAssertTrue(scene.state.replayRetained)

                scene.state.setPlaybackRequested()
                for time in [2.0, 2.31, 2.62] { scene.step(time); assertAligned(scene) }
                XCTAssertEqual(scene.pill.alphaValue, 1)
                XCTAssertEqual(scene.state.state, .preparing)
            }
        }
    }

    func testCancellationInvalidatesPendingPillContentAnimation() {
        let scene = Scene(showsCard: false)
        defer { scene.stop() }
        scene.state.updateSTT(isRecording: true, partial: "")
        scene.step(0)
        scene.step(0.31)
        scene.state.updateSTT(isRecording: true, partial: "A live transcription")
        scene.step(0.32)
        scene.state.setCancelled()
        scene.step(0.34)
        scene.step(0.49)
        assertAligned(scene)
        scene.step(0.65)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        assertAligned(scene)
        XCTAssertEqual(scene.pill.alphaValue, 0)
        XCTAssertLessThan(scene.pill.frame.maxY, 0)
        XCTAssertNil(scene.pill.layer?.animation(forKey: "motionBlurAnim"))
    }

    func testDisabledParticlesAndReducedMotionStillPresentThePill() {
        let scene = Scene(showsCard: true, screenGlow: false)
        defer { scene.stop() }
        scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "Response.")
        scene.step(0)
        scene.step(0.31)
        XCTAssertEqual(scene.pill.alphaValue, 1)
        XCTAssertEqual(scene.particles.opacity, 0)

        let reduced = Scene(showsCard: true)
        defer { reduced.stop() }
        reduced.state.updateSTT(isRecording: true, partial: "")
        reduced.controller.applyPresentation(reduced.state, now: 0, reduceMotion: true)
        assertAligned(reduced)
        XCTAssertEqual(reduced.pill.alphaValue, 1)
        reduced.state.updateSTT(isRecording: true, partial: "Reduced motion transcription")
        reduced.controller.applyPresentation(reduced.state, now: 0.1, reduceMotion: true)
        XCTAssertNil(reduced.pill.layer?.animation(forKey: "motionBlurAnim"))
        reduced.state.setCancelled()
        reduced.controller.applyPresentation(reduced.state, now: 0.2, reduceMotion: true)
        assertAligned(reduced)
        XCTAssertEqual(reduced.pill.alphaValue, 0)
    }

    private func assertAligned(_ scene: Scene, file: StaticString = #filePath, line: UInt = #line) {
        let departure = scene.motion.overlayDeparture
        XCTAssertEqual(scene.motion.pillDeparture, departure, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(scene.pill.alphaValue, 1 - departure, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(CGFloat(scene.particles.opacity), 0.6 * (1 - departure), accuracy: 0.001, file: file, line: line)
        let pillDeparture = (56 - scene.pill.frame.minY) / (scene.pill.frame.height + 76)
        XCTAssertEqual(pillDeparture, departure, accuracy: 0.001, file: file, line: line)
    }

    private final class Scene {
        let state = StateMachine()
        let motion = VoiceOverlayMotion()
        let pill = TranscriptionPill(frame: .zero)
        let renderer = ParticleFieldRenderer()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let particles: CALayer
        let card: SettingsAgentParticleHostView?
        let controller: OverlayController

        init(showsCard: Bool, screenGlow: Bool = true) {
            root.wantsLayer = true
            renderer.attach(to: root)
            particles = root.layer!.sublayers!.last!
            root.addSubview(pill)
            var config = AwarenessConfig()
            config.screen_glow = screenGlow
            controller = OverlayController(config: config, voiceMotion: motion,
                                           pill: pill, particleField: renderer)
            card = showsCard ? SettingsAgentParticleHostView() : nil
            if let card {
                card.frame = root.bounds
                root.addSubview(card)
            }
        }

        func step(_ time: TimeInterval) {
            card?.update(theme: state.state.particleTheme ?? .idle, reduceMotion: true)
            controller.applyPresentation(state, now: time, reduceMotion: false)
        }
        func stop() { card?.stop(); pill.hide(animated: false); renderer.transition(to: nil) }
    }
}
