import AppKit
import SwiftUI
import XCTest
@testable import relay_runner

final class SessionWheelMotionTests: XCTestCase {
    func testTilesConvergeBeforeDiscCollapsesAndHubExitsLast() {
        let duration = SessionWheelPresentation.duration
        let convergence = SessionWheelPresentation(progress: 1 - 0.05 / duration)
        XCTAssertGreaterThan(convergence.segmentConvergence, 0)
        XCTAssertLessThan(convergence.segmentConvergence, 1)
        XCTAssertGreaterThan(convergence.segmentBlur, 0)
        XCTAssertLessThan(convergence.segmentBlur, 48)
        XCTAssertEqual(convergence.segmentVisibility, 1)
        XCTAssertEqual(convergence.discScale, 1)
        XCTAssertGreaterThan(convergence.hubBlur, 0)
        XCTAssertEqual(convergence.hubVisibility, 1, "The centre fades only when the disc contracts")
        for index in 0..<SessionWheelGeometry.slotCount {
            let point = SessionWheelGeometry.position(slot: index, radius: 119)
            let offset = convergence.segmentOffset(index)
            let center = SessionWheelGeometry.center
            XCTAssertGreaterThan(hypot(offset.width, offset.height), 0, "Every tile moves together")
            XCTAssertLessThan(hypot(point.x + offset.width - center.x,
                                    point.y + offset.height - center.y), 119,
                              "Every tile moves toward the centre")
        }

        let collapse = SessionWheelPresentation(progress: 1 - 0.15 / duration)
        XCTAssertEqual(collapse.segmentConvergence, 1)
        XCTAssertGreaterThan(collapse.segmentBlur, convergence.segmentBlur)
        XCTAssertLessThan(collapse.segmentBlur, 48)
        XCTAssertGreaterThan(collapse.segmentVisibility, 0)
        XCTAssertLessThan(collapse.segmentVisibility, 1)
        XCTAssertGreaterThan(collapse.discScale, 0)
        XCTAssertLessThan(collapse.discScale, 1)
        XCTAssertGreaterThan(collapse.hubBlur, 0)
        XCTAssertLessThan(collapse.hubBlur, 24)
        XCTAssertGreaterThan(collapse.hubVisibility, 0)
        XCTAssertLessThan(collapse.hubVisibility, 1)
        let closed = SessionWheelPresentation(progress: 0)
        XCTAssertEqual(closed.discScale, 0)
        XCTAssertEqual(closed.hubVisibility, 0)
        XCTAssertEqual(closed.segmentVisibility, 0)
    }

    func testBlurFitsShorterTimelineWhileFadeRemainsLast() {
        let duration = SessionWheelPresentation.duration
        XCTAssertEqual(duration, 0.2, accuracy: 0.00001)
        let visible = SessionWheelPresentation(progress: 1)
        XCTAssertEqual(visible.hubBlur, 0)
        XCTAssertEqual(visible.segmentBlur, 0)
        XCTAssertEqual(visible.hubVisibility, 1)
        let starting = SessionWheelPresentation(progress: 1 - 0.001 / duration)
        let converged = SessionWheelPresentation(progress: 1 - 0.1 / duration)
        XCTAssertEqual(converged.segmentConvergence, 1)
        XCTAssertEqual(converged.discScale, 1)
        let finishing = SessionWheelPresentation(progress: 1 - 0.199 / duration)
        XCTAssertGreaterThan(starting.hubBlur, 0)
        XCTAssertGreaterThan(converged.hubBlur, starting.hubBlur)
        XCTAssertLessThan(converged.hubBlur, 24)
        XCTAssertEqual(converged.hubVisibility, 1, accuracy: 0.00001)
        XCTAssertGreaterThan(finishing.hubBlur, converged.hubBlur)
        XCTAssertLessThan(finishing.hubBlur, 24)
        XCTAssertLessThan(finishing.hubVisibility, 1)
        XCTAssertEqual(SessionWheelPresentation(progress: 0).hubBlur, 24)
        XCTAssertEqual(SessionWheelPresentation(progress: 0).segmentBlur, 48)
        for frame in [starting, converged, finishing] {
            XCTAssertEqual(frame.segmentBlur / 48, frame.hubBlur / 24, accuracy: 0.00001)
        }
    }

    func testOpeningExpandsAndRevealsHubBeforeTilesSpreadAndSharpen() {
        let duration = SessionWheelPresentation.duration
        let expansion = SessionWheelPresentation(progress: 0.05 / duration)
        XCTAssertGreaterThan(expansion.discScale, 0)
        XCTAssertLessThan(expansion.discScale, 1)
        XCTAssertGreaterThan(expansion.hubVisibility, 0)
        XCTAssertLessThan(expansion.hubVisibility, 1)
        XCTAssertGreaterThan(expansion.hubBlur, 0)
        XCTAssertLessThan(expansion.hubBlur, 24)
        XCTAssertGreaterThan(expansion.segmentBlur, 0)
        XCTAssertLessThan(expansion.segmentBlur, 48)
        XCTAssertEqual(expansion.segmentConvergence, 1)
        XCTAssertGreaterThan(expansion.segmentVisibility, 0)
        XCTAssertLessThan(expansion.segmentVisibility, 1)

        let reveal = SessionWheelPresentation(progress: 0.15 / duration)
        let laterReveal = SessionWheelPresentation(progress: 1)
        XCTAssertGreaterThan(reveal.segmentBlur, laterReveal.segmentBlur)
        XCTAssertGreaterThan(reveal.segmentConvergence, laterReveal.segmentConvergence)
        XCTAssertEqual(reveal.segmentVisibility, 1)
        XCTAssertEqual(reveal.discScale, 1)
        XCTAssertEqual(reveal.hubVisibility, 1)
        XCTAssertGreaterThan(reveal.hubBlur, laterReveal.hubBlur)
        XCTAssertEqual(laterReveal.hubBlur, 0, accuracy: 0.00001)
        XCTAssertEqual(SessionWheelPresentation(progress: 1).hubVisibility, 1)
        XCTAssertEqual(SessionWheelPresentation(progress: 1).hubBlur, 0)
        XCTAssertEqual(SessionWheelPresentation(progress: 1).segmentVisibility, 1)
        XCTAssertEqual(SessionWheelPresentation(progress: 1).segmentBlur, 0)
        for index in 0..<6 {
            XCTAssertEqual(SessionWheelPresentation(progress: 1).segmentOffset(index), .zero)
        }
    }

    func testReduceMotionOnlyFadesTheWholeWheel() {
        for progress in [0.0, 0.2, 0.5, 1.0] {
            let frame = SessionWheelPresentation(progress: progress, reduceMotion: true)
            XCTAssertEqual(frame.opacity, progress)
            XCTAssertEqual(frame.discScale, 1)
            XCTAssertEqual(frame.hubVisibility, 1)
            XCTAssertEqual(frame.hubBlur, 0)
            XCTAssertEqual(frame.segmentVisibility, 1)
            XCTAssertEqual(frame.segmentBlur, 0)
            for index in 0..<6 { XCTAssertEqual(frame.segmentOffset(index), .zero) }
        }
        let motion = SessionWheelMotion()
        XCTAssertEqual(motion.setVisible(true, reduceMotion: true, at: 0), 0.12)
    }

    func testReversalsContinueFromThePresentedFrameAtTheSameSpeed() {
        let motion = SessionWheelMotion()
        let duration = motion.setVisible(true, reduceMotion: false, at: 10)
        let opening = motion.progress(at: 10.19)
        let displayed = SessionWheelPresentation(progress: opening)
        XCTAssertGreaterThan(displayed.segmentConvergence, 0)
        XCTAssertLessThan(displayed.segmentConvergence, 1)
        let closeDuration = motion.setVisible(false, reduceMotion: false, at: 10.19)
        XCTAssertEqual(SessionWheelPresentation(progress: motion.progress(at: 10.19)), displayed)
        XCTAssertEqual(closeDuration, 0.19, accuracy: 0.00001)
        let closing = motion.progress(at: 10.22)
        let reopenDuration = motion.setVisible(true, reduceMotion: false, at: 10.22)
        XCTAssertEqual(motion.progress(at: 10.22), closing)
        XCTAssertEqual(reopenDuration, duration - 0.16, accuracy: 0.00001)
        XCTAssertEqual(motion.progress(at: 11), 1)
        motion.finish()
        XCTAssertFalse(motion.isAnimating)
        XCTAssertEqual(motion.progress(at: 12), 1)
    }

    @MainActor
    func testMenuKeepsOutgoingContentUntilCollapsedThenExpandsOnlyTheNewPage() async throws {
        let model = SessionWheelModel()
        model.projects = (0..<13).map {
            .init(id: "\($0)", name: "Project \($0)", path: "/projects/\($0)")
        }
        let menus = SessionWheelMenuMotion()
        let sessions = SessionWheelMenu(model)
        await menus.update(to: sessions, reduceMotion: false)
        model.showProjects(at: SessionWheelGeometry.center)
        let firstPage = SessionWheelMenu(model)
        let change = Task { await menus.update(to: firstPage, reduceMotion: false) }
        try await Task.sleep(for: .milliseconds(125))
        XCTAssertEqual(menus.displayed, sessions, "Live model changes must not replace outgoing tiles")
        XCTAssertFalse(menus.motion.isPresented)
        let progress = menus.motion.progress(at: ProcessInfo.processInfo.systemUptime)
        XCTAssertGreaterThan(progress, 0)
        XCTAssertLessThan(progress, 1)
        try await Task.sleep(for: .milliseconds(125))
        XCTAssertEqual(menus.displayed, firstPage)
        XCTAssertTrue(menus.motion.isPresented)
        XCTAssertLessThan(menus.motion.progress(at: ProcessInfo.processInfo.systemUptime), 0.5)
        await change.value
        XCTAssertFalse(menus.motion.isAnimating)
        XCTAssertEqual(menus.motion.progress(at: ProcessInfo.processInfo.systemUptime), 1)

        model.turnPage(1, at: SessionWheelGeometry.center)
        let secondPage = SessionWheelMenu(model)
        let next = Task { await menus.update(to: secondPage, reduceMotion: false) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(menus.displayed, firstPage)
        next.cancel()
        await next.value
        // Back during contraction reverses the same page, without a stale later swap.
        let before = menus.motion.progress(at: ProcessInfo.processInfo.systemUptime)
        let back = Task { await menus.update(to: firstPage, reduceMotion: false) }
        await Task.yield()
        XCTAssertEqual(menus.displayed, firstPage)
        XCTAssertEqual(menus.motion.progress(at: ProcessInfo.processInfo.systemUptime), before, accuracy: 0.05)
        await back.value
        try await Task.sleep(for: .seconds(SessionWheelPresentation.duration))
        XCTAssertEqual(menus.displayed, firstPage)
        XCTAssertEqual(menus.motion.progress(at: ProcessInfo.processInfo.systemUptime), 1)
        XCTAssertFalse(menus.motion.isAnimating)
    }

    @MainActor
    func testMenuRefreshDuringExpansionDoesNotRestartOrContractTheNewPage() async throws {
        let model = SessionWheelModel()
        let menus = SessionWheelMenuMotion()
        await menus.update(to: SessionWheelMenu(model), reduceMotion: true)
        model.refresh(sessions: [.init(id: "a", name: "First")])
        let change = Task { await menus.update(to: SessionWheelMenu(model), reduceMotion: true) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(menus.displayed?.sessions[0]?.name, "First")
        XCTAssertTrue(menus.motion.isPresented)
        change.cancel()
        await change.value
        model.refresh(sessions: [.init(id: "a", name: "Updated", unreadCount: 2)])
        await menus.update(to: SessionWheelMenu(model), reduceMotion: true)
        XCTAssertEqual(menus.displayed?.sessions[0]?.name, "Updated")
        XCTAssertEqual(menus.displayed?.sessions[0]?.unreadCount, 2)
        XCTAssertFalse(menus.motion.isAnimating)
        let frame = SessionWheelPresentation(progress: menus.motion.progress(at: ProcessInfo.processInfo.systemUptime),
                                             reduceMotion: true)
        XCTAssertEqual(frame.discScale, 1)
        XCTAssertEqual(frame.segmentBlur, 0)
        XCTAssertEqual(frame.opacity, 1)
    }

    @MainActor
    func testHostedMenuChangesDriveOneTimelineAndCancelWhenGoingBack() async throws {
        _ = NSApplication.shared
        let model = SessionWheelModel()
        model.projects = [.init(id: "p", name: "Project", path: "/projects/p")]
        let menus = SessionWheelMenuMotion()
        let view = SessionWheelView(model: model, selectSlot: { _, _ in }, performAction: { _, _ in },
                                    selectCenter: {}, back: {}, dismiss: {}, menuMotion: menus)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 528, height: 528),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(menus.displayed?.pickingProject, false)
        model.showProjects(at: SessionWheelGeometry.center)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(menus.displayed?.pickingProject, false)
        XCTAssertTrue(menus.motion.isAnimating)
        XCTAssertFalse(menus.motion.isPresented)
        XCTAssertTrue(model.back(at: SessionWheelGeometry.center))
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(menus.displayed?.pickingProject, false)
        XCTAssertFalse(menus.motion.isAnimating)
        XCTAssertEqual(menus.motion.progress(at: ProcessInfo.processInfo.systemUptime), 1)
        model.showProjects(at: SessionWheelGeometry.center)
        try await Task.sleep(for: .seconds(SessionWheelPresentation.duration + 0.05))
        XCTAssertEqual(menus.displayed?.pickingProject, true)
        XCTAssertTrue(menus.motion.isPresented)
        XCTAssertTrue(menus.motion.isAnimating)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(menus.motion.isAnimating)
        XCTAssertEqual(menus.displayed?.projects.first?.id, "p")
    }

    @MainActor
    func testRealMenuFramesKeepTheBlackDiscAndCentreWhileTilesContractAndExpand() throws {
        let model = SessionWheelModel()
        model.isWorkspaceVisible = true
        model.refresh(sessions: (0..<6).map { .init(id: "\($0)", name: "Session \($0)") })
        model.projects = (0..<6).map {
            .init(id: "p\($0)", name: "Project \($0)", path: "/projects/\($0)")
        }
        let sessions = SessionWheelMenu(model)
        model.showProjects(at: SessionWheelGeometry.center)
        let projects = SessionWheelMenu(model)
        let wheel = SessionWheelView(model: model, selectSlot: { _, _ in }, performAction: { _, _ in },
                                     selectCenter: {}, back: {}, dismiss: {})
        var reference: NSBitmapImageRep?
        let legMilliseconds = Int((SessionWheelPresentation.duration * 1000).rounded())
        for milliseconds in stride(from: 0, through: 2 * legMilliseconds, by: 25) {
            let outgoing = milliseconds < legMilliseconds
            let progress = abs(Double(milliseconds - legMilliseconds)) / Double(legMilliseconds)
            let frame = SessionWheelPresentation(progress: progress)
            let view = wheel.wheel(menu: outgoing ? sessions : projects, tiles: frame)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            let bitmap = try renderBitmap(view)
            if reference == nil { reference = bitmap }
            for point in [(264, 264), (285, 285), (264, 88), (440, 264)] {
                let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
                let expected = try XCTUnwrap(reference?.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.01)
                XCTAssertEqual(color.alphaComponent, expected.alphaComponent, accuracy: 0.01)
            }
            if milliseconds == legMilliseconds {
                // The menu swaps with only its permanent background and centre visible.
                for slot in 0..<6 {
                    let point = SessionWheelGeometry.position(slot: slot, radius: 119)
                    let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(color.redComponent, 0, accuracy: 0.01)
                    XCTAssertEqual(color.alphaComponent, 1)
                }
            }
            if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("menu-\(String(format: "%03d", milliseconds)).png"))
            }
        }
    }

    @MainActor
    func testContentTransitionsConvergeThenCollapseLikeTheWheelAndReduceMotionKeepsTheirPosition() throws {
        let progress = 1 - SessionWheelPresentation.segmentDuration / SessionWheelPresentation.duration
        for slot in 0..<6 {
            let point = SessionWheelGeometry.position(slot: slot, radius: 119)
            func render(_ progress: Double, reduced: Bool = false, name: String)
                throws -> (center: CGPoint, peak: CGFloat, alpha: CGFloat) {
                let view = Circle().fill(.white).frame(width: 20, height: 20)
                    .position(point).frame(width: 528, height: 528)
                    .modifier(SessionWheelContentEffect(progress: progress, slot: slot, reduceMotion: reduced))
                let bitmap = try renderBitmap(view)
                var alpha: CGFloat = 0
                var weighted = CGPoint.zero
                var peak: CGFloat = 0
                for y in stride(from: 0, to: 528, by: 4) {
                    for x in stride(from: 0, to: 528, by: 4) {
                        let sample = try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent
                        alpha += sample
                        weighted.x += CGFloat(x) * sample
                        weighted.y += CGFloat(y) * sample
                        peak = max(peak, sample)
                    }
                }
                if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: url.appendingPathComponent("content-\(slot)-\(name).png"))
                }
                return (alpha > 0 ? CGPoint(x: weighted.x / alpha, y: weighted.y / alpha) : .zero,
                        peak, alpha)
            }
            let visible = try render(1, name: "visible")
            let converging = try render(progress, name: "converging")
            let collapsing = try render(1 - 0.15 / SessionWheelPresentation.duration, name: "collapsing")
            let reduced = try render(progress, reduced: true, name: "reduced")
            let hidden = try render(0, name: "hidden")
            XCTAssertLessThan(hypot(converging.center.x - 264, converging.center.y - 264),
                              hypot(visible.center.x - 264, visible.center.y - 264) - 10)
            let travel = hypot(converging.center.x - visible.center.x, converging.center.y - visible.center.y)
            XCTAssertGreaterThan(travel, 16.5)
            XCTAssertLessThan(travel, 21, "Convergence uses 67% of the original travel, about 17–20 points")
            XCTAssertLessThan(converging.peak, visible.peak * 0.5, "The moving content visibly blurs")
            XCTAssertGreaterThan(converging.alpha, visible.alpha * 0.8,
                                 "Keep the tile visible, as in wheel dismissal, until convergence finishes")
            XCTAssertLessThan(hypot(collapsing.center.x - 264, collapsing.center.y - 264),
                              hypot(converging.center.x - 264, converging.center.y - 264) * 0.75,
                              "Page tiles must collapse to the wheel centre, not linger near their slot")
            XCTAssertLessThan(collapsing.alpha, converging.alpha * 0.4)
            XCTAssertEqual(reduced.center.x, visible.center.x, accuracy: 1)
            XCTAssertEqual(reduced.center.y, visible.center.y, accuracy: 1)
            XCTAssertEqual(reduced.peak, visible.peak * progress, accuracy: 0.01)
            XCTAssertEqual(hidden.alpha, 0)
        }
    }

    @MainActor
    func testTransitionFramesRenderAndEndCompletelyTransparent() throws {
        let model = SessionWheelModel()
        model.isWorkspaceVisible = true
        model.refresh(sessions: ["General Tasks", "Hidpress Web", "Relay Runner",
                                "ESP32 Bridge", "Voice Notes", "More projects"].enumerated().map {
            .init(id: "\($0.offset)", name: $0.element)
        })
        let duration = SessionWheelPresentation.duration
        for elapsed in [0.0, 0.025, 0.05, 0.075, 0.1, 0.125, 0.15, 0.175, duration] {
            let presentation = SessionWheelPresentation(progress: 1 - elapsed / duration)
            let view = SessionWheelView(model: model, selectSlot: { _, _ in }, performAction: { _, _ in },
                selectCenter: {}, back: {}, dismiss: {},
                presentation: presentation)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            let bitmap = try renderBitmap(view)
            XCTAssertEqual(bitmap.pixelsWide, 528)
            if elapsed == 0 {
                let center = try XCTUnwrap(bitmap.colorAt(x: 264, y: 264)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(center.redComponent, 0.8,
                                     "The centre glyph must be sharp when fully presented: \(presentation)")
            }
            if elapsed == duration {
                for y in stride(from: 0, to: 528, by: 4) {
                    for x in stride(from: 0, to: 528, by: 4) {
                        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0)
                    }
                }
            } else {
                XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 264, y: 264)).alphaComponent, 0.9)
            }
            if let directory = ProcessInfo.processInfo.environment["RELAY_WHEEL_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: url.appendingPathComponent("transition-\(Int((elapsed * 1000).rounded())).png"))
            }
        }
    }

    @MainActor
    private func renderBitmap<Content: View>(_ view: Content) throws -> NSBitmapImageRep {
        var image: CGImage?
        ImageRenderer(content: view).render { size, draw in
            guard let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            // Fully transparent frames must not inherit pixels from a reused render buffer.
            context.clear(CGRect(origin: .zero, size: size))
            draw(context)
            image = context.makeImage()
        }
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image))
    }

    @MainActor
    func testClosingPanelSurvivesUntilCompletionAndQuickReopenReusesIt() async throws {
        let controller = SessionWheelController()
        controller.toggle()
        defer { controller.dismiss() }
        let panel = try XCTUnwrap(NSApp.windows.first {
            String(describing: type(of: $0)) == "SessionWheelPanel" && $0.isVisible
        })
        try await Task.sleep(for: .seconds(SessionWheelPresentation.duration + 0.05))
        controller.dismiss()
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(panel.isVisible, "The panel must remain while its layers animate out")
        XCTAssertTrue(panel.ignoresMouseEvents)
        try await Task.sleep(for: .milliseconds(40))
        controller.toggle()
        XCTAssertTrue(controller.isVisible)
        XCTAssertFalse(panel.ignoresMouseEvents)
        try await Task.sleep(for: .seconds(SessionWheelPresentation.duration + 0.05))
        XCTAssertTrue(panel.isVisible, "The canceled dismissal must not hide a reopened wheel")
        XCTAssertEqual(NSApp.windows.filter {
            String(describing: type(of: $0)) == "SessionWheelPanel" && $0.isVisible
        }.count, 1)
        controller.dismiss()
        try await Task.sleep(for: .seconds(SessionWheelPresentation.duration + 0.05))
        XCTAssertFalse(panel.isVisible)
    }
}
