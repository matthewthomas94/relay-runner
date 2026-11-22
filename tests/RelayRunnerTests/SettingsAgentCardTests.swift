import AppKit
import CoreImage
import SwiftUI
import XCTest
@testable import relay_runner

final class SettingsAgentCardTests: XCTestCase {
    /// RR-522: four cards in table order, named from the agent definition,
    /// whatever voice is selected.
    func testCardsNameEachAgentFromItsDefinitionInTableOrder() {
        var agents = AgentsConfig()
        agents.puck.work_style = .direct
        agents.george.work_style = .orchestrated
        let cards = SettingsAgentPresentation.cards(
            statuses: SessionAgent.statuses(liveContextIDs: [], activeContextID: nil),
            agents: agents,
            state: .idle,
            hasWorkingProgress: false
        )
        XCTAssertEqual(cards.map(\.name), ["Puck", "Isabella", "George", "Sky"])
        XCTAssertEqual(cards.map(\.workStyle), [.direct, .auto, .orchestrated, .auto])
        let source = try? String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source?.contains("voiceName") ?? true)
    }

    func testStatusLinesForStoppedActiveAndBackgroundAgents() {
        let general = AssistantSessionContext.general
        let live = [SessionAgent.puck, .george].map { agent -> String in
            var context = general
            context.tab = agent.tab
            return context.id
        }
        let statuses = SessionAgent.statuses(liveContextIDs: live, activeContextID: live[1])
        func status(_ state: OverlayState, working: Bool = false) -> [String] {
            SettingsAgentPresentation.cards(
                statuses: statuses, agents: AgentsConfig(), state: state, hasWorkingProgress: working
            ).map(\.status)
        }
        // Puck runs in the background, George is active, Isabella and Sky are stopped.
        XCTAssertEqual(status(.idle), ["Standing by", "Not running", "Standing by", "Not running"])
        XCTAssertEqual(status(.idle, working: true), ["Standing by", "Not running", "Working", "Not running"])
        XCTAssertEqual(status(.speaking), ["Standing by", "Not running", "Responding", "Not running"])
        XCTAssertEqual(status(.processing)[2], "Thinking")
        XCTAssertEqual(
            SettingsAgentPresentation.cards(statuses: statuses, agents: AgentsConfig(), state: .idle, hasWorkingProgress: false)
                .map(\.isActive),
            [false, false, true, false]
        )
        // Nothing running: every card is stopped, even while the overlay listens.
        let stopped = SessionAgent.statuses(liveContextIDs: [], activeContextID: nil)
        XCTAssertEqual(
            SettingsAgentPresentation.cards(statuses: stopped, agents: AgentsConfig(), state: .listening, hasWorkingProgress: false)
                .map(\.status),
            Array(repeating: "Not running", count: 4)
        )
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

    func testOverlayReducedMotionStaysAnchoredWhileFadingAndResizing() throws {
        for theme in [ParticleFieldRenderer.Theme.stt, .tts] {
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            host.wantsLayer = true
            let renderer = ParticleFieldRenderer()
            renderer.attach(to: host)
            renderer.setDeparture(1)
            renderer.transition(to: theme, reduceMotion: true)
            XCTAssertEqual(renderer.renderedParticleFrame.minY, 0, accuracy: 0.001)
            let gradient = try XCTUnwrap(host.layer?.sublayers?.first)
            let particles = try XCTUnwrap(host.layer?.sublayers?.last)
            XCTAssertEqual(gradient.opacity, 0)

            renderer.setDeparture(0.5)
            XCTAssertEqual(renderer.renderedParticleFrame.minY, 0, accuracy: 0.001)
            XCTAssertEqual(particles.opacity, 0.3, accuracy: 0.001)
            XCTAssertEqual(gradient.opacity, 0.3, accuracy: 0.001)
            renderer.setIntensity(0.8)
            XCTAssertEqual(particles.opacity, 0.4, accuracy: 0.001)
            XCTAssertEqual(gradient.opacity, 0.4, accuracy: 0.001)
            renderer.layoutInBounds(CGRect(x: 0, y: 0, width: 1200, height: 900), backingScale: 2)
            XCTAssertEqual(renderer.renderedParticleFrame.minY, 0, accuracy: 0.001)
            renderer.setDeparture(1)
            XCTAssertEqual(renderer.renderedParticleFrame.minY, 0, accuracy: 0.001)
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
                XCTAssertEqual(entranceBlur.value(forKey: kCIInputRadiusKey) as? CGFloat, TranscriptionPill.MotionStyle.exitBlurRadius / 2)
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
                XCTAssertEqual(exitBlur.value(forKey: kCIInputRadiusKey) as? CGFloat, TranscriptionPill.MotionStyle.exitBlurRadius / 2)
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
        XCTAssertEqual(SettingsAgentCardLayout.frameWidth(inWindow: true, availableWidth: 1000), 280)
        XCTAssertEqual(SettingsAgentCardLayout.frameWidth(inWindow: false, availableWidth: 1680), 480)
    }

    /// RR-522: the two-by-two grid fills exactly the frame the single card
    /// filled at the same available width, in the window and the Workspace.
    func testTheGridFillsTheSingleCardsFrame() {
        for (inWindow, available, height, spacing) in [
            (true, 1000.0, 640.0, SettingsAgentCardLayout.spacing),
            (false, 1680.0, 900.0, BoardSurfaceLayout.columnSpacing),
            (false, 1000.0, 700.0, BoardSurfaceLayout.columnSpacing),
        ] as [(Bool, CGFloat, CGFloat, CGFloat)] {
            let single = CGRect(
                x: 0, y: 0,
                width: SettingsAgentCardLayout.frameWidth(inWindow: inWindow, availableWidth: available),
                height: height
            )
            let frames = SettingsAgentCardLayout.gridFrames(in: single.size, spacing: spacing)
            XCTAssertEqual(frames.count, 4)
            XCTAssertEqual(frames.reduce(CGRect.null) { $0.union($1) }, single)
            // Two columns and two rows of equal cards, `spacing` apart.
            XCTAssertEqual(frames[0].minY, frames[1].minY)
            XCTAssertEqual(frames[2].minX, frames[0].minX)
            XCTAssertEqual(frames[1].minX - frames[0].maxX, spacing, accuracy: 0.001)
            XCTAssertEqual(frames[2].minY - frames[0].maxY, spacing, accuracy: 0.001)
            XCTAssertTrue(frames.allSatisfy { $0.size == frames[0].size })
        }
    }

    /// RR-522: every card, in either column, puts the name and status at the
    /// top-left and the picker at the top-right on the same top inset, and
    /// truncates the text before it reaches the picker.
    func testCardContentIsTopLeftTextAndTopRightPicker() throws {
        let inset = SettingsAgentCardLayout.contentInset
        let frames = SettingsAgentCardLayout.gridFrames(in: CGSize(width: 480, height: 900), spacing: 12)
        let pickerSize = CGSize(width: 120, height: SharedActionButtonMetrics.controlHeight)
        var relative: [CGRect] = []
        for card in frames {
            for textWidth in [40.0, 400.0] as [CGFloat] {
                let content = SettingsAgentCardLayout.contentFrames(
                    cardSize: card.size,
                    textSize: CGSize(width: textWidth, height: 40),
                    pickerSize: pickerSize
                )
                XCTAssertEqual(content.text.minX, inset)
                XCTAssertEqual(content.text.minY, inset)
                XCTAssertEqual(content.picker.minY, content.text.minY)
                XCTAssertEqual(content.picker.maxX, card.width - inset)
                XCTAssertEqual(content.picker.size, pickerSize)
                XCTAssertLessThanOrEqual(content.text.maxX, content.picker.minX - SettingsAgentCardLayout.contentGap)
                if textWidth == 400 { relative.append(content.text.union(content.picker)) }
            }
        }
        XCTAssertTrue(relative.allSatisfy { $0 == relative[0] }, "the same layout in both columns")
        // Narrower than the picker, the picker stays inside the card.
        let narrow = SettingsAgentCardLayout.contentFrames(
            cardSize: CGSize(width: 100, height: 300), textSize: CGSize(width: 60, height: 40), pickerSize: pickerSize
        )
        XCTAssertEqual(narrow.picker.minX, inset)
        XCTAssertEqual(narrow.text.width, 0)

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/relay-runner/Settings/SettingsAgentCard.swift"),
            encoding: .utf8
        )
        let card = try XCTUnwrap(source.components(separatedBy: "struct SettingsAgentCard: View {").dropFirst().first)
            .components(separatedBy: "private struct SettingsAgentCardContentLayout").first ?? ""
        XCTAssertFalse(card.contains(".center"), "nothing in the card is centred")
        XCTAssertTrue(card.contains("VStack(alignment: .leading"))
        XCTAssertTrue(card.contains(".multilineTextAlignment(.leading)"))
        XCTAssertTrue(card.contains(".accessibilityElement(children: .contain)"))
        XCTAssertTrue(card.contains(".accessibilityLabel(presentation.name)"))
        XCTAssertTrue(card.contains(".accessibilityValue(presentation.status)"))
    }

    /// RR-522: the picker is built like the Workspace's Add project control
    /// and, unlike it, checks the current style.
    func testWorkStylePickerIsBuiltLikeAddProject() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Settings/SettingsAgentCard.swift"),
            encoding: .utf8
        )
        let picker = try XCTUnwrap(source.components(separatedBy: "struct SettingsAgentWorkStylePicker: View {").dropFirst().first)
        for part in [
            "Button { isPresented.toggle() } label:",
            "Text(title)",
            ".font(AppTypography.font(.programAction))",
            "Rectangle()",
            "LucideImage(.chevronDown, size: 12)",
            "SharedActionButtonSurface(",
            "prominence: .secondary",
            "SettingsDropdownPresenter(isPresented: $isPresented, minWidth: Self.menuMinWidth, alignsTrailing: true)",
            "SettingsMenuOptions(",
            "options: ProjectWorkStyle.allCases.map",
        ] {
            XCTAssertTrue(picker.contains(part), part)
        }
        XCTAssertFalse(picker.contains("showsCheckmarks: false"), "the menu checks the current style")
        XCTAssertEqual(SettingsAgentWorkStylePicker.accessibilityLabel(.isabella), "Isabella's work style")
        XCTAssertEqual(ProjectWorkStyle.allCases.map(\.title), ["Auto", "Direct", "Orchestrated"])
    }

    func testOverlayMotionReversesContinuouslyAndRetainsItsDepartingTheme() {
        let motion = VoiceOverlayMotion()
        XCTAssertEqual(motion.update(theme: .tts, reduceMotion: false, now: 10), .tts)
        _ = motion.update(theme: .tts, reduceMotion: false, now: 10 + VoiceOverlayMotion.travelDuration / 2)
        XCTAssertEqual(motion.overlayDeparture, 0.5, accuracy: 0.001)
        XCTAssertEqual(motion.pillDeparture, motion.overlayDeparture)
        XCTAssertEqual(motion.overlayBlurRadius, TranscriptionPill.MotionStyle.exitBlurRadius / 2, accuracy: 0.001)
        XCTAssertEqual(motion.update(theme: nil, reduceMotion: false, now: 10 + VoiceOverlayMotion.travelDuration / 2), .tts)
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

    func testBlobFillsTheCardAndIdleParticlesGradeWhiteToNavyWithReducedMotion() throws {
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
            XCTAssertTrue(pixels.contains { $0.r > 245 && $0.g > 245 && $0.b > 245 })
            XCTAssertTrue(pixels.contains { $0.b > $0.r + 4 })
            XCTAssertTrue(pixels.allSatisfy { $0.r <= $0.g && $0.g <= $0.b })
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

    @MainActor
    func testHostedOrbRisesInOnlyWhenItBecomesVisible() throws {
        let host = SettingsAgentParticleHostView()
        host.update(theme: .idle, reduceMotion: false)
        XCTAssertFalse(host.showsField)
        XCTAssertNil(host.layer?.filters)
        let window = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 280, height: 640),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { host.stop(); window.close() }
        window.orderFront(nil)
        host.update(theme: .stt, reduceMotion: false)
        XCTAssertTrue(host.showsField)
        let entranceBlur = host.layer?.filters?
            .compactMap { $0 as? CIFilter }
            .first { $0.name == RelayLayerMotion.blurFilterName }
        XCTAssertNotNil(entranceBlur)
        let particles = try XCTUnwrap(host.layer?.sublayers?.last)
        XCTAssertEqual(particles.opacity, 1, accuracy: 0.001)
        XCTAssertTrue(particles.filters?.isEmpty ?? true)

        window.orderOut(nil)
        host.update(theme: .stt, reduceMotion: false)
        XCTAssertFalse(host.showsField)
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
