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
                for time in [0.0, VoiceOverlayMotion.travelDuration / 2, 0.31, 0.46, 0.62] {
                    scene.step(time)
                    assertAligned(scene)
                    if time == VoiceOverlayMotion.travelDuration / 2 { XCTAssertEqual(scene.pill.alphaValue, 0.5, accuracy: 0.001) }
                }
                XCTAssertEqual(scene.pill.alphaValue, 1)
                scene.state.reset()
                scene.step(1)
                scene.step(1 + VoiceOverlayMotion.travelDuration / 2)
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
        XCTAssertEqual(scene.pill.frame.minY, 56, accuracy: 0.001)
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
        assertAligned(reduced, reduceMotion: true)
        XCTAssertEqual(reduced.pill.alphaValue, 1)
        reduced.state.updateSTT(isRecording: true, partial: "Reduced motion transcription")
        reduced.controller.applyPresentation(reduced.state, now: 0.1, reduceMotion: true)
        XCTAssertNil(reduced.pill.layer?.animation(forKey: "motionBlurAnim"))
        reduced.state.setCancelled()
        reduced.controller.applyPresentation(reduced.state, now: 0.2, reduceMotion: true)
        assertAligned(reduced, reduceMotion: true)
        XCTAssertEqual(reduced.pill.alphaValue, 0)
    }

    func testQueuedReplyKeepsOverlayUpWhileOnlyTheFinishedCardLeaves() {
        for cancels in [false, true] {
            let scene = Scene(showsCard: true)
            defer { scene.stop() }
            scene.controller.setReplyStackDepth(1, now: 0)
            scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "First reply.")
            for time in [0.0, 0.31, 0.62] { scene.step(time) }
            XCTAssertEqual(scene.pill.alphaValue, 1)

            if cancels {
                scene.state.setCancelled()
            } else {
                scene.state.handleServiceEvent(source: "tts", newState: "idle", text: nil)
            }
            // The polled badge drops just after the bridge advances the queue.
            scene.step(1.0)
            scene.controller.setReplyStackDepth(0, now: 1.2)
            XCTAssertTrue(scene.pill.isFrontCardDismissed)
            for time in [1.15, 1.31, 1.6] {
                scene.step(time)
                XCTAssertEqual(scene.pill.alphaValue, 1)
            }

            scene.state.handleServiceEvent(source: "tts", newState: "message_waiting", text: "Second reply.")
            scene.step(1.7)
            XCTAssertFalse(scene.pill.isFrontCardDismissed)
            XCTAssertEqual(scene.pill.alphaValue, 1)
        }
    }

    func testWheelStopDismissesPillAndParticlesEvenWithQueuedReplies() {
        for phase in ["preparing", "speaking"] {
            for depth in [0, 1] {
                let scene = Scene(showsCard: true)
                defer { scene.stop() }
                scene.controller.setReplyStackDepth(depth, now: 0)
                let active = SpeechPresentation(utteranceID: "reply", originalUtteranceID: "reply",
                                                mode: .newDelivery, sessionKey: "a")
                scene.state.handleServiceEvent(source: "tts", newState: phase,
                                               text: "Response.", presentation: active)
                for time in [0.0, 0.31, 0.62] { scene.step(time) }

                let stopped = SpeechPresentation(utteranceID: "reply", originalUtteranceID: "reply",
                                                 mode: .newDelivery, stopReason: "wheel_stop", sessionKey: "a")
                scene.state.handleServiceEvent(source: "tts", newState: "idle", text: nil, presentation: stopped)
                scene.step(1)
                scene.step(1.31)
                assertAligned(scene)
                XCTAssertEqual(scene.pill.alphaValue, 0)
                XCTAssertEqual(scene.particles.opacity, 0)
                XCTAssertFalse(scene.pill.isFrontCardDismissed)

                // Late updates from the stopped attempt cannot restore its UI.
                scene.state.handleServiceEvent(source: "tts", newState: phase,
                                               text: "Response.", presentation: active)
                scene.step(1.4)
                XCTAssertEqual(scene.pill.alphaValue, 0)

                let replay = SpeechPresentation(utteranceID: "replay", originalUtteranceID: "reply",
                                                replayOf: "reply", mode: .explicitReplay, sessionKey: "a")
                scene.state.handleServiceEvent(source: "tts", newState: "preparing",
                                               text: "Response.", presentation: replay)
                for time in [2.0, 2.31, 2.62] { scene.step(time) }
                XCTAssertEqual(scene.pill.alphaValue, 1, "An explicit replay can show the UI again")
            }
        }
    }

    func testReplyQueueHoldExpiresWhenNoReplyComesForward() {
        let scene = Scene(showsCard: true)
        defer { scene.stop() }
        scene.controller.setReplyStackDepth(1, now: 0)
        scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "First reply.")
        for time in [0.0, 0.31, 0.62] { scene.step(time) }
        scene.state.handleServiceEvent(source: "tts", newState: "idle", text: nil)
        scene.step(1.0)
        scene.step(5.9)
        XCTAssertEqual(scene.pill.alphaValue, 1)
        scene.step(6.0)
        scene.step(6.31)
        XCTAssertEqual(scene.pill.alphaValue, 0)
        XCTAssertFalse(scene.pill.isFrontCardDismissed)
    }

    func testOptionPlaybackOfQueuedReplyShowsThePlayingCard() {
        for depth in [0, 1] {
            for waitsAt in [1.1, 3.0, 9.0] {
                let scene = Scene(showsCard: true)
                defer { scene.stop() }
                scene.controller.setReplyStackDepth(depth, now: 0)
                let handoff = SpeechPresentation(utteranceID: "handoff", originalUtteranceID: "handoff", mode: .newDelivery)
                scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "On it.", presentation: handoff)
                for time in [0.0, 0.31, 0.62] { scene.step(time) }
                scene.state.handleServiceEvent(source: "tts", newState: "idle", text: nil, presentation: handoff)
                scene.step(1.0)

                let reply = SpeechPresentation(utteranceID: "reply", originalUtteranceID: "reply", mode: .newDelivery)
                scene.state.handleServiceEvent(source: "tts", newState: "message_waiting", text: "Here is the reply.", presentation: reply)
                for time in [waitsAt, waitsAt + 0.31, waitsAt + 0.62] { scene.step(time) }
                XCTAssertEqual(scene.pill.alphaValue, 1, "depth \(depth) waits \(waitsAt)")

                let played = waitsAt + 40
                scene.state.setPlaybackRequested()
                scene.step(played)
                scene.state.handleServiceEvent(source: "tts", newState: "preparing", text: "Here is the reply.", presentation: reply)
                scene.step(played + 0.05)
                scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "Here is the reply.", presentation: reply)
                for time in [played + 0.1, played + 0.41, played + 0.72] { scene.step(time) }
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))

                XCTAssertEqual(scene.state.state, .speaking, "depth \(depth) waits \(waitsAt)")
                XCTAssertEqual(scene.pill.alphaValue, 1, "depth \(depth) waits \(waitsAt)")
                XCTAssertFalse(scene.pill.isFrontCardDismissed, "depth \(depth) waits \(waitsAt)")
                XCTAssertEqual(scene.frontCardAlpha, 1, "depth \(depth) waits \(waitsAt)")
            }
        }
    }

    func testReplyWithoutQueueStillLeavesTogether() {
        let scene = Scene(showsCard: true)
        defer { scene.stop() }
        scene.state.handleServiceEvent(source: "tts", newState: "speaking", text: "Only reply.")
        for time in [0.0, 0.31, 0.62] { scene.step(time) }
        scene.state.handleServiceEvent(source: "tts", newState: "idle", text: nil)
        scene.step(1.0)
        scene.step(1.31)
        XCTAssertEqual(scene.pill.alphaValue, 0)
        XCTAssertFalse(scene.pill.isFrontCardDismissed)
    }

    /// Set RELAY_WHEEL_RENDER_DIR to export the previewed particle field for visual QA.
    func testWheelIntensityPreviewShowsPlaybackParticlesWithoutTouchingState() throws {
        let scene = Scene(showsCard: false)
        defer { scene.stop() }
        let half = VoiceOverlayMotion.travelDuration / 2
        scene.controller.setParticlePreview(true)
        scene.step(0)
        scene.step(half)
        XCTAssertEqual(scene.motion.overlayDeparture, 0.5, accuracy: 0.001)
        scene.controller.setParticlePreview(true)
        scene.step(half)
        XCTAssertEqual(scene.motion.overlayDeparture, 0.5, accuracy: 0.001, "Repeats never restart the entrance")
        scene.step(1)
        XCTAssertEqual(scene.motion.overlayDeparture, 0)
        XCTAssertEqual(CGFloat(scene.particles.opacity), 0.6, accuracy: 0.001)
        XCTAssertEqual(scene.theme, OverlayController.particlePreviewTheme)
        XCTAssertEqual(scene.theme, OverlayState.speaking.particleTheme)
        XCTAssertEqual(scene.pill.alphaValue, 0, "No reply pill")
        XCTAssertEqual(scene.state.state, .idle)
        if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
            scene.renderer.renderFrame(at: CACurrentMediaTime() + 1)
            let image = try XCTUnwrap(scene.particles.contents.map { $0 as! CGImage })
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: url.appendingPathComponent("overlay-intensity-preview.png"))
        }

        // A real recording keeps its own field and pill during the preview.
        scene.state.updateSTT(isRecording: true, partial: "")
        scene.step(1.1)
        scene.step(2)
        XCTAssertEqual(scene.theme, .stt)
        XCTAssertEqual(scene.pill.alphaValue, 1)
        scene.state.reset()
        scene.step(2.1)
        scene.step(3)
        XCTAssertEqual(scene.theme, OverlayController.particlePreviewTheme, "The preview resumes once idle")
        XCTAssertEqual(scene.pill.alphaValue, 0)

        scene.controller.setParticlePreview(false)
        scene.step(3.1)
        scene.step(3.1 + half)
        XCTAssertEqual(scene.motion.overlayDeparture, 0.5, accuracy: 0.05, "Ending animates away")
        scene.step(4)
        XCTAssertEqual(scene.motion.overlayDeparture, 1)
        XCTAssertEqual(scene.particles.opacity, 0)
        XCTAssertNil(scene.theme)
        XCTAssertEqual(scene.state.state, .idle)

        let disabled = Scene(showsCard: false, screenGlow: false)
        defer { disabled.stop() }
        disabled.controller.setParticlePreview(true)
        disabled.step(0)
        disabled.step(1)
        XCTAssertEqual(disabled.particles.opacity, 0, "The disabled particle field stays off")

        let reduced = Scene(showsCard: false)
        defer { reduced.stop() }
        reduced.controller.setParticlePreview(true)
        reduced.controller.applyPresentation(reduced.state, now: 0, reduceMotion: true)
        XCTAssertEqual(reduced.motion.overlayDeparture, 0, "Reduce Motion appears without travel")
        reduced.controller.setParticlePreview(false)
        reduced.controller.applyPresentation(reduced.state, now: 0.01, reduceMotion: true)
        XCTAssertEqual(reduced.motion.overlayDeparture, 1)
    }

    private func assertAligned(_ scene: Scene, reduceMotion: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let departure = scene.motion.overlayDeparture
        XCTAssertEqual(scene.motion.pillDeparture, departure, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(scene.pill.alphaValue, 1 - departure, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(CGFloat(scene.particles.opacity), 0.6 * (1 - departure), accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(scene.pill.frame.minY, 56, accuracy: 0.001, file: file, line: line)
        let scale = reduceMotion ? 1 : 1 - (1 - RelayMotion.Style.surface.hiddenScale) * departure
        XCTAssertEqual(scene.pill.layer?.transform.m11 ?? 0, scale, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(scene.particles.transform.m11, scale, accuracy: 0.001, file: file, line: line)
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
        var frontCardAlpha: CGFloat {
            (Mirror(reflecting: pill).children.first { $0.label == "surfaceContainerView" }?.value as? NSView)?.alphaValue ?? -1
        }
        func stop() { card?.stop(); pill.hide(animated: false); renderer.transition(to: nil) }
        var theme: ParticleFieldRenderer.Theme? {
            Mirror(reflecting: renderer).children.first { $0.label == "currentTheme" }?.value as? ParticleFieldRenderer.Theme
        }
    }
}
