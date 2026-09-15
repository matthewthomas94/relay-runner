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

    func testOverlayBlurAndFadeRemoveFiltersAtRest() throws {
        for coverage in [ParticleFieldRenderer.Coverage.lowerScreen] {
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

    func testCardSizingMatchesDesignAndKeepsNarrowSettingsUsable() {
        XCTAssertEqual(SettingsAgentCardLayout.width(availableWidth: 1680), 480)
        XCTAssertEqual(SettingsAgentCardLayout.width(availableWidth: 2400), 480)
        let cardWidth = SettingsAgentCardLayout.width(availableWidth: 1000)
        XCTAssertGreaterThanOrEqual(cardWidth, 220)
        XCTAssertGreaterThan(1000 - cardWidth - SettingsAgentCardLayout.spacing - 190, 500)
    }

    func testOverlayMotionReversesContinuouslyAndRetainsItsDepartingTheme() {
        let motion = VoiceOverlayMotion()
        XCTAssertEqual(motion.update(theme: .tts, reduceMotion: false, now: 10), .tts)
        _ = motion.update(theme: .tts, reduceMotion: false, now: 10.15)
        XCTAssertEqual(motion.overlayDeparture, 0.5, accuracy: 0.001)
        XCTAssertEqual(motion.pillDeparture, motion.overlayDeparture)
        XCTAssertEqual(motion.overlayBlurRadius, 24, accuracy: 0.001)
        XCTAssertEqual(motion.update(theme: nil, reduceMotion: false, now: 10.15), .tts)
        XCTAssertEqual(motion.overlayDeparture, 0.5, accuracy: 0.001)
        _ = motion.update(theme: nil, reduceMotion: false, now: 10.2)
        let departure = motion.overlayDeparture
        XCTAssertEqual(motion.update(theme: .stt, reduceMotion: false, now: 10.2), .stt)
        XCTAssertEqual(motion.overlayDeparture, departure)
        _ = motion.update(theme: .stt, reduceMotion: false, now: 10.5)
        XCTAssertEqual(motion.overlayDeparture, 0)
        XCTAssertEqual(motion.pillDeparture, 0)
        XCTAssertNil(motion.update(theme: nil, reduceMotion: true, now: 11))
        XCTAssertEqual(motion.overlayDeparture, 1)
        motion.reset()
        XCTAssertEqual(motion.pillDeparture, 1)
    }

    func testBlobFillsTheCardAndIdleParticlesStayWhiteWithReducedMotion() throws {
        for size in [CGSize(width: 220, height: 480), CGSize(width: 480, height: 683)] {
            let host = NSView(frame: CGRect(origin: .zero, size: size))
            host.wantsLayer = true
            let renderer = ParticleFieldRenderer(coverage: .agentOrb)
            renderer.attach(to: host)
            renderer.layoutInBounds(host.bounds, backingScale: 1)
            renderer.transition(to: .idle, reduceMotion: true)
            defer { renderer.transition(to: nil) }
            let image = try XCTUnwrap(renderer.renderedParticleImage)
            let pixels = try pixelSamples(image)
            XCTAssertGreaterThan(pixels.count, 500)
            let minX = try XCTUnwrap(pixels.map(\.x).min())
            let maxX = try XCTUnwrap(pixels.map(\.x).max())
            let minY = try XCTUnwrap(pixels.map(\.y).min())
            let maxY = try XCTUnwrap(pixels.map(\.y).max())
            XCTAssertEqual(Double(minX + maxX) / 2, size.width / 2, accuracy: 8)
            XCTAssertEqual(Double(minY + maxY) / 2, size.height / 2, accuracy: 8)
            XCTAssertGreaterThan(Double(maxX - minX), size.width * 0.72)
            XCTAssertLessThan(Double(maxX - minX), size.width * 0.95)
            XCTAssertLessThan(Double(maxY), size.height - 120)
            XCTAssertTrue(pixels.allSatisfy { $0.r == $0.g && $0.g == $0.b })
            XCTAssertFalse(renderer.isAnimationRunning)
            let frame = try XCTUnwrap(image.dataProvider?.data) as Data
            renderer.renderFrame(at: 100)
            XCTAssertEqual(try XCTUnwrap(renderer.renderedParticleImage?.dataProvider?.data) as Data, frame)
        }
    }

    func testActiveBlobHasAWhiteCoreBlendingThroughPastelsToTheStateColour() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 683))
        host.wantsLayer = true
        let renderer = ParticleFieldRenderer(coverage: .agentOrb)
        renderer.attach(to: host)
        renderer.layoutInBounds(host.bounds, backingScale: 1)
        defer { renderer.transition(to: nil) }
        for theme in [ParticleFieldRenderer.Theme.stt, .tts] {
            renderer.transition(to: theme, reduceMotion: true)
            let pixels = try pixelSamples(XCTUnwrap(renderer.renderedParticleImage))
            let red = pixels.reduce(0) { $0 + $1.r }
            let blue = pixels.reduce(0) { $0 + $1.b }
            if theme == .stt { XCTAssertGreaterThan(red, blue) }
            else { XCTAssertGreaterThan(blue, red) }
            let white = pixels.filter { min($0.r, $0.g, $0.b) > 245 }
            let rim = pixels.filter { max($0.r, $0.g, $0.b) - min($0.r, $0.g, $0.b) > 80 }
            let pastels = pixels.filter {
                let minimum = min($0.r, $0.g, $0.b)
                let maximum = max($0.r, $0.g, $0.b)
                return minimum > 100 && maximum - minimum > 20 && maximum - minimum < 80
            }
            XCTAssertGreaterThan(white.count, pixels.count / 8)
            XCTAssertGreaterThan(rim.count, 100)
            XCTAssertGreaterThan(pastels.count, 100)
            func meanDistanceFromCentre(_ samples: [Pixel]) -> Double {
                samples.reduce(0.0) { $0 + hypot(Double($1.x) - 240, Double($1.y) - 341.5) }
                    / Double(samples.count)
            }
            XCTAssertLessThan(meanDistanceFromCentre(white), meanDistanceFromCentre(rim))
        }
    }

    func testBlobDeformsWhileRemainingCentredAndClearOfTheCardEdges() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 683))
        host.wantsLayer = true
        let renderer = ParticleFieldRenderer(coverage: .agentOrb)
        renderer.attach(to: host)
        renderer.layoutInBounds(host.bounds, backingScale: 1)
        renderer.transition(to: .idle, now: 10)
        defer { renderer.transition(to: nil) }
        var profiles: [[Double]] = []
        for second in stride(from: 0, through: 60, by: 2) {
            renderer.renderFrame(at: 10 + Double(second))
            let pixels = try pixelSamples(XCTUnwrap(renderer.renderedParticleImage))
            let minX = try XCTUnwrap(pixels.map(\.x).min())
            let maxX = try XCTUnwrap(pixels.map(\.x).max())
            let minY = try XCTUnwrap(pixels.map(\.y).min())
            let maxY = try XCTUnwrap(pixels.map(\.y).max())
            XCTAssertGreaterThan(minX, 8)
            XCTAssertLessThan(maxX, 472)
            XCTAssertGreaterThan(minY, 120)
            XCTAssertLessThan(maxY, 563)
            XCTAssertEqual(Double(minX + maxX) / 2, 240, accuracy: 16)
            XCTAssertEqual(Double(minY + maxY) / 2, 341.5, accuracy: 16)
            var quadrants = [Double](repeating: 0, count: 4)
            for pixel in pixels {
                quadrants[(pixel.x < 240 ? 0 : 1) + (pixel.y < 342 ? 0 : 2)] += 1
            }
            profiles.append(quadrants.map { $0 / Double(pixels.count) })
        }
        // The tighter motion still redistributes the silhouette while the
        // larger lobes remain close together.
        let first = try XCTUnwrap(profiles.first)
        XCTAssertTrue(profiles.contains { profile in
            zip(first, profile).reduce(0.0) { $0 + abs($1.0 - $1.1) } > 0.1
        })
    }

    func testBlobColourChangesContinueFromTheDisplayedFrameWithoutRestartingItsShape() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 640))
        host.wantsLayer = true
        let renderer = ParticleFieldRenderer(coverage: .agentOrb)
        renderer.attach(to: host)
        renderer.layoutInBounds(host.bounds, backingScale: 1)
        renderer.transition(to: .idle, now: 10)
        defer { renderer.transition(to: nil) }
        func pixels() throws -> Data {
            let image = try XCTUnwrap(renderer.renderedParticleImage)
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        let first = try pixels()
        renderer.renderFrame(at: 11)
        let deformed = try pixels()
        XCTAssertNotEqual(first, deformed)
        renderer.transition(to: .tts, now: 11)
        renderer.renderFrame(at: 11)
        XCTAssertEqual(try pixels(), deformed)
        renderer.renderFrame(at: 11.15)
        let midway = try pixels()
        renderer.transition(to: .stt, now: 11.15)
        renderer.renderFrame(at: 11.15)
        XCTAssertEqual(try pixels(), midway)
        renderer.renderFrame(at: 11.5)
        XCTAssertNotEqual(try pixels(), midway)
        XCTAssertEqual(renderer.renderedParticleFrame, host.bounds)
    }

    @MainActor
    func testHostedOrbStaysVisibleAcrossStatesAndStopsWhenHidden() throws {
        let host = SettingsAgentParticleHostView()
        host.update(theme: .idle, reduceMotion: false)
        XCTAssertFalse(host.isAnimationRunning)
        XCTAssertNil(host.hitTest(.zero))
        let window = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 280, height: 640),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { host.stop(); window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        for theme in [ParticleFieldRenderer.Theme.idle, .stt, .tts, .idle] {
            host.update(theme: theme, reduceMotion: false)
            XCTAssertTrue(host.isAnimationRunning)
            let particles = try XCTUnwrap(host.layer?.sublayers?.last)
            XCTAssertEqual(particles.frame, host.bounds)
            XCTAssertEqual(particles.opacity, 1, accuracy: 0.001)
            XCTAssertTrue(particles.filters?.isEmpty ?? true)
        }
        host.update(theme: .stt, reduceMotion: true)
        XCTAssertFalse(host.isAnimationRunning)
        window.orderOut(nil)
        host.update(theme: .idle, reduceMotion: false)
        XCTAssertFalse(host.isAnimationRunning)
    }

    private struct Pixel {
        let x: Int, y: Int, r: Int, g: Int, b: Int
    }

    private func pixelSamples(_ image: CGImage) throws -> [Pixel] {
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        var result: [Pixel] = []
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * image.bytesPerRow + x * 4
                if data[offset + 3] > 16 {
                    // CGImage scanlines run top-down; compare in AppKit coordinates.
                    result.append(Pixel(x: x, y: image.height - 1 - y, r: Int(data[offset]),
                                        g: Int(data[offset + 1]), b: Int(data[offset + 2])))
                }
            }
        }
        return result
    }
}
