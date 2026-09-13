import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import relay_runner

final class SettingsAgentCardTests: XCTestCase {
    func testNameFollowsStandardAndCustomVoiceSelection() {
        var voice = TtsConfig()
        XCTAssertEqual(SettingsAgentPresentation.voiceName(voice, customName: nil), "George")
        voice.voice = "af_bella"
        XCTAssertEqual(SettingsAgentPresentation.voiceName(voice, customName: nil), "Bella")
        voice.custom_voice_id = "selected-profile"
        XCTAssertEqual(SettingsAgentPresentation.voiceName(voice, customName: "  My voice  "), "My voice")
        XCTAssertEqual(SettingsAgentPresentation.voiceName(voice, customName: nil), "George")
        voice.custom_voice_id = nil
        XCTAssertEqual(SettingsAgentPresentation.voiceName(voice, customName: "My voice"), "Bella")
    }

    func testSubtitleDescribesForegroundStateWithoutWorkerActivity() {
        let cases: [(OverlayState, String)] = [
            (.idle, "Standing by"), (.recording, "Listening"), (.listening, "Listening"),
            (.processing, "Thinking"), (.preparing, "Preparing response"), (.speaking, "Responding"),
            (.messageWaiting(preview: "Ready"), "Response ready"),
            (.replayWaiting(preview: "Previous"), "Ready to replay"),
            (.paused, "Paused"), (.speechFailed, "Speech unavailable"),
            (.cancelled(.tts), "Cancelled"), (.actionGlow(awaitingConfirmation: nil), "Taking action")
        ]
        for (state, expected) in cases {
            XCTAssertEqual(SettingsAgentPresentation.subtitle(
                state: state, hasActiveSession: true, hasWorkingProgress: false
            ), expected)
        }
        XCTAssertEqual(SettingsAgentPresentation.subtitle(
            state: .idle, hasActiveSession: true, hasWorkingProgress: true
        ), "Working")
        XCTAssertEqual(SettingsAgentPresentation.subtitle(
            state: .idle, hasActiveSession: false, hasWorkingProgress: true
        ), "No active session")
    }

    func testScreenWaitsForCardToLeaveAndCardReturnsAfterward() {
        for theme in [ParticleFieldRenderer.Theme.stt, .tts] {
            let handoff = AgentParticleHandoff()
            handoff.setCardVisible(true, id: UUID())
            XCTAssertNil(handoff.update(theme: theme, reduceMotion: false, now: 10))
            XCTAssertEqual(handoff.cardDeparture, 0)
            XCTAssertNil(handoff.update(theme: theme, reduceMotion: false, now: 10.15))
            XCTAssertEqual(handoff.cardDeparture, 0.5, accuracy: 0.001)
            XCTAssertEqual(handoff.cardBlurRadius, 24, accuracy: 0.001)
            XCTAssertEqual(handoff.overlayDeparture, 1)
            XCTAssertEqual(handoff.update(theme: theme, reduceMotion: false, now: 10.31), theme)
            XCTAssertEqual(handoff.cardDeparture, 1)
            XCTAssertEqual(handoff.overlayDeparture, 1)
            XCTAssertEqual(handoff.update(theme: theme, reduceMotion: false, now: 10.46), theme)
            XCTAssertEqual(handoff.overlayDeparture, 0.5, accuracy: 0.001)
            XCTAssertEqual(handoff.overlayBlurRadius, 24, accuracy: 0.001)
            XCTAssertEqual(handoff.update(theme: theme, reduceMotion: false, now: 10.62), theme)
            XCTAssertEqual(handoff.overlayDeparture, 0)
            XCTAssertEqual(handoff.overlayBlurRadius, 0)

            XCTAssertEqual(handoff.update(theme: nil, reduceMotion: false, now: 11), theme)
            XCTAssertEqual(handoff.overlayDeparture, 0)
            XCTAssertEqual(handoff.update(theme: nil, reduceMotion: false, now: 11.15), theme)
            XCTAssertEqual(handoff.overlayDeparture, 0.5, accuracy: 0.001)
            XCTAssertEqual(handoff.overlayBlurRadius, 24, accuracy: 0.001)
            XCTAssertEqual(handoff.cardDeparture, 1)
            XCTAssertNil(handoff.update(theme: nil, reduceMotion: false, now: 11.31))
            XCTAssertEqual(handoff.overlayDeparture, 1)
            XCTAssertEqual(handoff.cardDeparture, 1)
            XCTAssertNil(handoff.update(theme: nil, reduceMotion: false, now: 11.46))
            XCTAssertEqual(handoff.cardDeparture, 0.5, accuracy: 0.001)
            XCTAssertEqual(handoff.cardBlurRadius, 24, accuracy: 0.001)
            XCTAssertNil(handoff.update(theme: nil, reduceMotion: false, now: 11.62))
            XCTAssertEqual(handoff.cardDeparture, 0)
            XCTAssertEqual(handoff.cardBlurRadius, 0)
        }
    }

    func testRapidReversalContinuesFromCurrentPositionWithoutLateOverlay() {
        let handoff = AgentParticleHandoff()
        handoff.setCardVisible(true, id: UUID())
        _ = handoff.update(theme: .tts, reduceMotion: false, now: 10)
        _ = handoff.update(theme: .tts, reduceMotion: false, now: 10.15)
        let halfway = handoff.cardDeparture
        let blurRadius = handoff.cardBlurRadius
        XCTAssertNil(handoff.update(theme: nil, reduceMotion: false, now: 10.15))
        XCTAssertEqual(handoff.cardDeparture, halfway)
        XCTAssertEqual(handoff.cardBlurRadius, blurRadius)
        XCTAssertNil(handoff.update(theme: nil, reduceMotion: false, now: 10.5))
        XCTAssertEqual(handoff.cardDeparture, 0)
        XCTAssertEqual(handoff.cardBlurRadius, 0)
    }

    func testThemeChangesDoNotRestartDeparture() {
        let handoff = AgentParticleHandoff()
        handoff.setCardVisible(true, id: UUID())
        _ = handoff.update(theme: .stt, reduceMotion: false, now: 10)
        XCTAssertNil(handoff.update(theme: .tts, reduceMotion: false, now: 10.15))
        XCTAssertEqual(handoff.update(theme: .tts, reduceMotion: false, now: 10.31), .tts)
        _ = handoff.update(theme: .tts, reduceMotion: false, now: 10.46)
        XCTAssertEqual(handoff.overlayDeparture, 0.5, accuracy: 0.001)
        XCTAssertEqual(handoff.update(theme: .stt, reduceMotion: false, now: 10.46), .stt)
        XCTAssertEqual(handoff.overlayDeparture, 0.5, accuracy: 0.001)
        _ = handoff.update(theme: .stt, reduceMotion: false, now: 10.62)
        XCTAssertEqual(handoff.overlayDeparture, 0)
    }

    func testHiddenCardDoesNotDelayOverlayTravelAndReducedMotionIsImmediate() {
        let handoff = AgentParticleHandoff()
        XCTAssertEqual(handoff.update(theme: .tts, reduceMotion: false, now: 10), .tts)
        XCTAssertEqual(handoff.overlayDeparture, 1)
        XCTAssertEqual(handoff.update(theme: .tts, reduceMotion: false, now: 10.15), .tts)
        XCTAssertEqual(handoff.overlayDeparture, 0.5, accuracy: 0.001)
        // Opening Settings during playback must start with an empty card.
        handoff.setCardVisible(true, id: UUID())
        XCTAssertEqual(handoff.update(theme: .tts, reduceMotion: false, now: 10.3), .tts)
        XCTAssertEqual(handoff.cardDeparture, 1)
        XCTAssertNil(handoff.update(theme: nil, reduceMotion: true, now: 11))
        XCTAssertEqual(handoff.cardDeparture, 0)
        XCTAssertEqual(handoff.overlayDeparture, 1)
        XCTAssertEqual(handoff.update(theme: .stt, reduceMotion: true, now: 12), .stt)
        XCTAssertEqual(handoff.cardDeparture, 1)
        XCTAssertEqual(handoff.overlayDeparture, 0)
    }

    func testOverlayEntranceAndExitCanReverseWithoutJumping() {
        for theme in [ParticleFieldRenderer.Theme.stt, .tts] {
            let handoff = AgentParticleHandoff()
            _ = handoff.update(theme: theme, reduceMotion: false, now: 10)
            _ = handoff.update(theme: theme, reduceMotion: false, now: 10.15)
            let entranceBlurRadius = handoff.overlayBlurRadius
            handoff.setCardVisible(true, id: UUID())
            XCTAssertEqual(handoff.update(theme: nil, reduceMotion: false, now: 10.15), theme)
            XCTAssertEqual(handoff.overlayDeparture, 0.5, accuracy: 0.001)
            XCTAssertEqual(handoff.overlayBlurRadius, entranceBlurRadius)
            XCTAssertEqual(handoff.cardDeparture, 1)
            _ = handoff.update(theme: nil, reduceMotion: false, now: 10.3)
            let departure = handoff.overlayDeparture
            let exitBlurRadius = handoff.overlayBlurRadius
            XCTAssertGreaterThan(departure, 0.5)
            XCTAssertGreaterThan(exitBlurRadius, entranceBlurRadius)
            XCTAssertEqual(handoff.update(theme: theme, reduceMotion: false, now: 10.3), theme)
            XCTAssertEqual(handoff.overlayDeparture, departure)
            XCTAssertEqual(handoff.overlayBlurRadius, exitBlurRadius)
            _ = handoff.update(theme: theme, reduceMotion: false, now: 10.73)
            XCTAssertEqual(handoff.overlayDeparture, 0)
            XCTAssertEqual(handoff.overlayBlurRadius, 0)
            XCTAssertEqual(handoff.cardDeparture, 1)
        }
    }

    func testOverlayTranslationSurvivesResizeAndKeepsExitPixelsVisible() throws {
        for theme in [ParticleFieldRenderer.Theme.stt, .tts] {
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            host.wantsLayer = true
            let renderer = ParticleFieldRenderer()
            renderer.attach(to: host)
            renderer.setDeparture(1)
            renderer.transition(to: theme, reduceMotion: true)
            XCTAssertEqual(renderer.renderedParticleFrame.maxY, 0, accuracy: 0.001)
            let gradient = try XCTUnwrap(host.layer?.sublayers?.first)
            let particles = try XCTUnwrap(host.layer?.sublayers?.last)
            XCTAssertEqual(gradient.opacity, 0)

            renderer.setDeparture(0.5)
            XCTAssertEqual(renderer.renderedParticleFrame.minY, -132, accuracy: 0.001)
            XCTAssertEqual(particles.opacity, 0.3, accuracy: 0.001)
            XCTAssertEqual(gradient.opacity, 0.3, accuracy: 0.001)
            renderer.setIntensity(0.8)
            XCTAssertEqual(particles.opacity, 0.4, accuracy: 0.001)
            XCTAssertEqual(gradient.opacity, 0.4, accuracy: 0.001)
            renderer.layoutInBounds(CGRect(x: 0, y: 0, width: 1200, height: 900), backingScale: 2)
            XCTAssertEqual(renderer.renderedParticleFrame.minY, -198, accuracy: 0.001)
            renderer.setDeparture(1)
            XCTAssertEqual(renderer.renderedParticleFrame.maxY, 0, accuracy: 0.001)
            renderer.transition(to: nil)
            XCTAssertEqual(particles.opacity, 0)
            XCTAssertEqual(gradient.opacity, 0)
            XCTAssertFalse(renderer.isAnimationRunning)
        }
    }

    func testCardAndOverlayBlurAndFadeTogetherAndRemoveFiltersAtRest() throws {
        for coverage in [ParticleFieldRenderer.Coverage.agentCard, .lowerScreen] {
            for theme in [ParticleFieldRenderer.Theme.stt, .tts] {
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 640))
                host.wantsLayer = true
                let renderer = ParticleFieldRenderer(coverage: coverage)
                renderer.attach(to: host)
                renderer.transition(to: theme)
                defer { renderer.transition(to: nil) }
                let particles = try XCTUnwrap(host.layer?.sublayers?.last)

                renderer.setDeparture(0.5, blurRadius: TranscriptionPill.MotionStyle.entranceBlurRadius / 2)
                let entranceBlur = try XCTUnwrap(particles.filters?.first as? CIFilter)
                XCTAssertEqual(entranceBlur.name, "motionBlur")
                XCTAssertEqual(entranceBlur.value(forKey: kCIInputRadiusKey) as? CGFloat, 24)
                XCTAssertEqual(particles.opacity, 0.3, accuracy: 0.001)
                XCTAssertNil(host.layer?.filters)

                renderer.transition(to: theme, reduceMotion: true)
                XCTAssertTrue(particles.filters?.isEmpty ?? true)
                renderer.transition(to: theme)
                renderer.setDeparture(0, blurRadius: 0)
                XCTAssertEqual(particles.opacity, 0.6, accuracy: 0.001)
                XCTAssertTrue(particles.filters?.isEmpty ?? true)

                renderer.setDeparture(0.5, blurRadius: TranscriptionPill.MotionStyle.exitBlurRadius / 2)
                let exitBlur = try XCTUnwrap(particles.filters?.first as? CIFilter)
                XCTAssertEqual(exitBlur.value(forKey: kCIInputRadiusKey) as? CGFloat, 24)
                XCTAssertEqual(particles.opacity, 0.3, accuracy: 0.001)
                renderer.setDeparture(1, blurRadius: TranscriptionPill.MotionStyle.exitBlurRadius)
                XCTAssertEqual(particles.opacity, 0)
                XCTAssertTrue(particles.filters?.isEmpty ?? true)
            }
        }
    }

    func testClosingLastCardCompletesHandoffAndResetRestoresHome() {
        let handoff = AgentParticleHandoff()
        let first = UUID(), second = UUID()
        handoff.setCardVisible(true, id: first)
        handoff.setCardVisible(true, id: second)
        _ = handoff.update(theme: .tts, reduceMotion: false, now: 10)
        handoff.setCardVisible(false, id: first)
        XCTAssertNil(handoff.update(theme: .tts, reduceMotion: false, now: 10.1))
        handoff.setCardVisible(false, id: second)
        XCTAssertEqual(handoff.update(theme: .tts, reduceMotion: false, now: 10.1), .tts)
        handoff.reset()
        XCTAssertEqual(handoff.cardDeparture, 0)
        XCTAssertEqual(handoff.overlayDeparture, 1)
    }

    func testCardSizingMatchesDesignAndKeepsNarrowSettingsUsable() {
        XCTAssertEqual(SettingsAgentCardLayout.width(availableWidth: 1680), 480)
        XCTAssertEqual(SettingsAgentCardLayout.width(availableWidth: 2400), 480)
        let cardWidth = SettingsAgentCardLayout.width(availableWidth: 1000)
        XCTAssertGreaterThanOrEqual(cardWidth, 220)
        XCTAssertGreaterThan(1000 - cardWidth - SettingsAgentCardLayout.spacing - 190, 500)
    }

    func testCardParticlesRenderAcrossTheCardAndStopWhenHidden() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 683))
        host.wantsLayer = true
        let renderer = ParticleFieldRenderer(coverage: .agentCard)
        renderer.attach(to: host)
        renderer.layoutInBounds(host.bounds, backingScale: 1)
        renderer.setIntensity(1)
        renderer.transition(to: .tts, reduceMotion: true)
        let image = try XCTUnwrap(renderer.renderedParticleImage)
        XCTAssertEqual(image.width, 480)
        XCTAssertEqual(image.height, 683)
        XCTAssertFalse(renderer.isAnimationRunning)
        renderer.transition(to: .tts)
        XCTAssertTrue(renderer.isAnimationRunning)
        renderer.transition(to: nil)
        XCTAssertFalse(renderer.isAnimationRunning)

        let cardHost = SettingsAgentParticleHostView(handoff: AgentParticleHandoff())
        cardHost.update(departure: 0, reduceMotion: false)
        XCTAssertFalse(cardHost.isAnimationRunning)
        XCTAssertNil(cardHost.hitTest(.zero))
    }

    @MainActor
    func testHostedParticlesFollowWindowVisibilityAndDeparture() throws {
        let handoff = AgentParticleHandoff()
        let host = SettingsAgentParticleHostView(handoff: handoff)
        let window = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 280, height: 640),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { host.stop(); window.close() }
        window.orderFront(nil)
        host.update(departure: 0, reduceMotion: false)
        XCTAssertTrue(host.isAnimationRunning)
        XCTAssertNil(handoff.update(theme: .tts, reduceMotion: false, now: 10))

        host.update(departure: 1, reduceMotion: false)
        XCTAssertFalse(host.isAnimationRunning)
        host.update(departure: 0.5, blurRadius: 32, reduceMotion: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.isAnimationRunning)
        let particles = try XCTUnwrap(host.layer?.sublayers?.last)
        XCTAssertEqual(particles.frame.minY, -host.bounds.height / 2, accuracy: 0.001)
        XCTAssertEqual(particles.opacity, 0.3, accuracy: 0.001)
        let blur = try XCTUnwrap(particles.filters?.first as? CIFilter)
        XCTAssertEqual(blur.value(forKey: kCIInputRadiusKey) as? CGFloat, 32)

        window.orderOut(nil)
        host.update(departure: 0, reduceMotion: false)
        XCTAssertFalse(host.isAnimationRunning)
        XCTAssertEqual(handoff.update(theme: .tts, reduceMotion: false, now: 10.1), .tts)
    }
}
