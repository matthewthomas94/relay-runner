import AppKit
import XCTest
@testable import relay_runner

/// RR-440: the overlay field animates for whole agent turns, so each frame
/// must stay cheap without changing what the user sees.
@MainActor
final class ParticleFieldRenderCostTests: XCTestCase {
    func testStampedScreenFieldMatchesCoreGraphicsEllipses() throws {
        for scale: CGFloat in [1, 2] {
            for theme in [ParticleFieldRenderer.Theme.stt, .tts] {
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
                host.wantsLayer = true
                let renderer = ParticleFieldRenderer()
                renderer.attach(to: host)
                renderer.layoutInBounds(host.bounds, backingScale: scale)
                renderer.transition(to: theme)
                defer { renderer.transition(to: nil) }

                for time in [0.0, 0.37, 1.9] {
                    renderer.drawsDotsWithCoreGraphics = true
                    renderer.renderFrame(at: time)
                    let reference = try pixelData(renderer)
                    renderer.drawsDotsWithCoreGraphics = false
                    renderer.renderFrame(at: time)
                    let stamped = try pixelData(renderer)

                    XCTAssertEqual(reference.count, stamped.count)
                    var largest = 0
                    var differing = 0
                    var visible = 0
                    for index in reference.indices {
                        let difference = abs(Int(reference[index]) - Int(stamped[index]))
                        largest = max(largest, difference)
                        if difference > 0 { differing += 1 }
                        if index % 4 == 3, reference[index] > 0 { visible += 1 }
                    }
                    XCTAssertGreaterThan(visible, 1_000, "scale \(scale) \(theme) drew dots")
                    XCTAssertLessThanOrEqual(largest, 8, "scale \(scale) \(theme) t=\(time)")
                    XCTAssertLessThan(Double(differing) / Double(reference.count), 0.05)
                }
            }
        }
    }

    func testScreenFieldRendersInItsWindowColourSpace() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let space = try XCTUnwrap(NSColorSpace.displayP3.cgColorSpace)
        window.colorSpace = .displayP3
        let host = NSView(frame: window.contentLayoutRect)
        host.wantsLayer = true
        window.contentView = host
        let renderer = ParticleFieldRenderer()
        renderer.attach(to: host)
        renderer.layoutInBounds(host.bounds, backingScale: 2)
        renderer.transition(to: .tts, reduceMotion: true)
        defer { renderer.transition(to: nil) }

        // A matching bitmap lets Core Animation commit frames without
        // colour-converting every pixel on the main thread.
        XCTAssertEqual(try XCTUnwrap(renderer.renderedParticleImage).colorSpace, space)
    }

    func testUnchangedPresentationDoesNotTouchTheLayerEachTick() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        host.wantsLayer = true
        let renderer = ParticleFieldRenderer()
        renderer.attach(to: host)
        renderer.transition(to: .tts, reduceMotion: true)
        defer { renderer.transition(to: nil) }
        renderer.setDeparture(0)
        let particles = try XCTUnwrap(host.layer?.sublayers?.last)
        XCTAssertEqual(particles.opacity, 0.6, accuracy: 0.001)

        particles.opacity = 0.25
        renderer.setDeparture(0)
        XCTAssertEqual(particles.opacity, 0.25, accuracy: 0.001, "Same inputs skip the transaction")

        renderer.setDeparture(0.5)
        XCTAssertEqual(particles.opacity, 0.3, accuracy: 0.001, "Changed inputs still apply")
    }

    private func pixelData(_ renderer: ParticleFieldRenderer) throws -> [UInt8] {
        let image = try XCTUnwrap(renderer.renderedParticleImage)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        return [UInt8](data)
    }
}
