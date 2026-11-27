import SwiftUI
import UIKit
import XCTest
@testable import RelayRemote

final class DesignSystemTests: XCTestCase {
    func testBaiJamjureeIsRegistered() {
        XCTAssertNotNil(UIFont(name: RelayTextStyle.Weight.regular.postScriptName, size: 16))
        XCTAssertNotNil(UIFont(name: RelayTextStyle.Weight.semiBold.postScriptName, size: 16))
        XCTAssertEqual(RelayTextStyle.hero.size, 28)
        XCTAssertEqual(RelayTextStyle.hero.lineHeight, 40)
    }

    func testEveryLucideIconParses() {
        for icon in LucideIcon.allCases {
            XCTAssertFalse(icon.geometry.stroke.isEmpty, icon.rawValue)
        }
    }

    func testStatusGlyphRestingStates() {
        let off = StatusGlyphRenderer.restingDots(.off)
        XCTAssertEqual(off.count, 1)
        XCTAssertEqual(off[0].diameter, 3)
        XCTAssertEqual(off[0].color, StatusGlyphRenderer.grey)
        XCTAssertEqual(StatusGlyphRenderer.restingDots(.ready).count, 4)
        XCTAssertTrue(StatusGlyphRenderer.restingDots(.ready).allSatisfy { $0.color == StatusGlyphRenderer.white })
        XCTAssertTrue(StatusGlyphRenderer.restingDots(.listening).contains { $0.color == StatusGlyphRenderer.orange })
        XCTAssertTrue(StatusGlyphRenderer.restingDots(.playing).contains { $0.color == StatusGlyphRenderer.blue })
    }

    func testReadyHoldsStillAndWorkingSpins() {
        let ready0 = StatusGlyphRenderer.dots(state: .ready, from: nil, progress: 1, time: 0, reduceMotion: false)
        let ready1 = StatusGlyphRenderer.dots(state: .ready, from: nil, progress: 1, time: 0.3, reduceMotion: false)
        XCTAssertEqual(ready0, ready1)
        let working0 = StatusGlyphRenderer.dots(state: .working, from: nil, progress: 1, time: 0, reduceMotion: false)
        let working1 = StatusGlyphRenderer.dots(state: .working, from: nil, progress: 1, time: 0.3, reduceMotion: false)
        XCTAssertNotEqual(working0.map(\.center), working1.map(\.center))
        let still = StatusGlyphRenderer.dots(state: .working, from: nil, progress: 1, time: 0.3, reduceMotion: true)
        XCTAssertEqual(still.map(\.center), StatusGlyphRenderer.restingDots(.working).map(\.center))
    }

    func testGreyDotSplitsIntoFour() {
        let start = StatusGlyphRenderer.dots(state: .ready, from: .off, progress: 0, time: 0, reduceMotion: false)
        // At the start the four new dots sit on the grey dot, invisible, and the grey dot is whole.
        let visible = start.filter { $0.alpha > 0.01 }
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible[0].center, StatusGlyphRenderer.center)
        XCTAssertTrue(start.filter { $0.alpha < 0.01 }.allSatisfy { $0.center == StatusGlyphRenderer.center })
        let middle = StatusGlyphRenderer.dots(state: .ready, from: .off, progress: 0.5, time: 0, reduceMotion: false)
        XCTAssertEqual(middle.count, 5)
        let end = StatusGlyphRenderer.dots(state: .ready, from: .off, progress: 1, time: 0, reduceMotion: false)
        XCTAssertEqual(end, StatusGlyphRenderer.restingDots(.ready))
    }

    func testOrbEdgeColours() {
        XCTAssertEqual(AgentOrbEngine.rim(.idle), SIMD3(17.0 / 255, 22.0 / 255, 29.0 / 255))
        let listening = AgentOrbEngine.rim(.listening)
        XCTAssertGreaterThan(listening.x, listening.z, "orange")
        let playing = AgentOrbEngine.rim(.playing)
        XCTAssertGreaterThan(playing.z, playing.x, "blue-purple")
        let dots = AgentOrbEngine.grid(rim: AgentOrbEngine.rim(.idle), motion: .of(.idle), phase: 0,
                                       size: AgentOrb.size)
        XCTAssertFalse(dots.isEmpty)
        XCTAssertTrue(dots.allSatisfy { $0.x >= 0 && $0.x <= 168 && $0.y >= 0 && $0.y <= 112 })
        XCTAssertTrue(dots.contains { $0.rgb == SIMD3(repeating: 1) }, "a white core")
    }

    func testHeaderOrbHasFewerDotsNoBiggerThanTheGlyphs() {
        let header = AgentOrbEngine.grid(rim: AgentOrbEngine.rim(.idle), motion: .of(.idle), phase: 9.2,
                                         size: AgentOrb.headerSize, step: AgentOrb.headerStep)
        let biggest = header.map { $0.radius * 2 }.max() ?? 0
        XCTAssertEqual(biggest, 3, accuracy: 0.01, "the biggest dot matches the status glyph's 3 pt dots")
        XCTAssertLessThan(header.count, 90, "a coarse grid, not the full orb shrunk")
    }

    func testDotFieldStaysInItsCoverage() {
        let size = CGSize(width: 402, height: 874)
        for style in [DotFieldStyle.listening, .playback] {
            let dots = DotFieldCache.build(style: style, size: size)
            XCTAssertFalse(dots.isEmpty)
            let top = dots.map(\.y).min() ?? 0
            XCTAssertGreaterThanOrEqual(top, size.height * (1 - style.coverage) - DotFieldCache.spacing)
        }
        XCTAssertEqual(DotField.revealFactor(0, verticalT: 0), 0)
        XCTAssertEqual(DotField.revealFactor(1, verticalT: 1), 1)
        XCTAssertGreaterThan(DotField.revealFactor(0.4, verticalT: 0), DotField.revealFactor(0.4, verticalT: 0.6),
                             "the field rises from the bottom")
    }

    func testHeroCursorPulsesBetweenHalfAndFull() {
        let samples = stride(from: 0.0, to: 0.8, by: 0.01).map { HeroCursor.opacity(at: $0, reduceMotion: false) }
        XCTAssertEqual(samples.max() ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(samples.min() ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(HeroCursor.opacity(at: 0.1, reduceMotion: false),
                       HeroCursor.opacity(at: 0.9, reduceMotion: false), accuracy: 0.0001)
    }

    /// The hero's first line stays at y 300 however many lines follow it.
    @MainActor
    func testHeroFirstLineStaysPutAsTextGrows() throws {
        let tops = try (1...3).map { count -> Int in
            let lines = ["MMMMMMMM", "second line", "third line"].prefix(count).joined(separator: "\n")
            return try firstInkRow(of: OnboardingHeroLayout(hero: HeroText(lines)))
        }
        XCTAssertEqual(Set(tops).count, 1, "first-line tops \(tops)")
        XCTAssertTrue((300..<340).contains(tops[0]), "first-line top \(tops[0])")
    }

    /// Renders `view` in a 402 × 874 window and returns the first row, in
    /// points, with white ink in the left half of the screen. The hero's
    /// first line is centred, so its left half holds no cursor.
    @MainActor
    private func firstInkRow(of view: some View) throws -> Int {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for row in 100..<600 {
            for column in 0..<(width / 2) where pixels[(row * width + column) * 4] > 128 {
                return row
            }
        }
        XCTFail("no hero ink found")
        return -1
    }
}

final class AppGlowStateTests: XCTestCase {
    func testStateToGlowMapping() {
        XCTAssertEqual(AppGlowState.resolve(listening: false, playing: false), .none)
        XCTAssertEqual(AppGlowState.resolve(listening: true, playing: false), .listening)
        XCTAssertEqual(AppGlowState.resolve(listening: false, playing: true), .playing)
        XCTAssertEqual(AppGlowState.resolve(listening: true, playing: true), .listening)
        XCTAssertNil(AppGlowState.none.style)
        XCTAssertEqual(AppGlowState.listening.style?.coverage, 0.32)
        XCTAssertEqual(AppGlowState.playing.style?.coverage, 0.44)
    }
}
