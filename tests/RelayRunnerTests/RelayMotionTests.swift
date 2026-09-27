import AppKit
import XCTest
@testable import relay_runner

final class RelayMotionTests: XCTestCase {
    func testCurvesStartAndEndAtRestAndEaseInTheExpectedDirection() {
        for curve in [RelayMotion.enterCurve, RelayMotion.exitCurve, RelayMotion.changeCurve] {
            XCTAssertEqual(curve.progress(0), 0)
            XCTAssertEqual(curve.progress(1), 1)
            XCTAssertEqual(curve.progress(-1), 0)
            XCTAssertEqual(curve.progress(2), 1)
        }
        // Entrances and changes decelerate; exits accelerate.
        XCTAssertGreaterThan(RelayMotion.enterCurve.progress(0.5), 0.8)
        XCTAssertGreaterThan(RelayMotion.changeCurve.progress(0.5), 0.7)
        XCTAssertLessThan(RelayMotion.exitCurve.progress(0.5), 0.5)
        XCTAssertLessThan(RelayMotion.exitDuration, RelayMotion.enterDuration)
    }

    func testHiddenElementsSitBelowAndTextSitsTrailing() {
        XCTAssertEqual(
            RelayMotion.Style.element.offset(hidden: true, reduceMotion: false),
            CGSize(width: 0, height: RelayMotion.Style.element.distance)
        )
        XCTAssertEqual(
            RelayMotion.Style.surface.offset(hidden: true, reduceMotion: false),
            CGSize(width: 0, height: RelayMotion.Style.surface.distance)
        )
        XCTAssertEqual(
            RelayMotion.Style.text.offset(hidden: true, reduceMotion: false),
            CGSize(width: RelayMotion.Style.text.distance, height: 0)
        )
        XCTAssertEqual(RelayMotion.Style.text.offset(hidden: false, reduceMotion: false), .zero)
        XCTAssertGreaterThan(RelayMotion.Style.text.blur(hidden: true, reduceMotion: false), 0)
        XCTAssertEqual(RelayMotion.Style.text.blur(hidden: false, reduceMotion: false), 0)
    }

    func testReduceMotionKeepsOnlyTheFade() {
        for style in [RelayMotion.Style.element, .surface, .text] {
            XCTAssertEqual(style.offset(hidden: true, reduceMotion: true), .zero)
            XCTAssertEqual(style.blur(hidden: true, reduceMotion: true), 0)
        }
    }

    func testLayerPreparationAddsOneNamedBlurAndKeepsExistingFilters() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        view.wantsLayer = true
        let existing = try XCTUnwrap(CIFilter(name: "CIGaussianBlur"))
        existing.name = "existing"
        view.layer?.filters = [existing]

        RelayLayerMotion.prepare(view)
        RelayLayerMotion.prepare(view)

        let names = (view.layer?.filters ?? []).compactMap { ($0 as? CIFilter)?.name }
        XCTAssertEqual(names, ["existing", RelayLayerMotion.blurFilterName])
        XCTAssertTrue(view.layerUsesCoreImageFilters)
    }

    func testVerticalTravelReadsAsBelowOnScreenForFlippedAndUnflippedParents() {
        final class FlippedView: NSView {
            override var isFlipped: Bool { true }
        }
        let child = NSView(frame: .zero)
        let unflipped = NSView(frame: .zero)
        unflipped.addSubview(child)
        let expected: (CGFloat) -> CGFloat = { sign in
            RelayLayerMotion.reduceMotion ? 0 : sign * RelayMotion.Style.element.distance
        }
        XCTAssertEqual(RelayLayerMotion.hiddenTranslation(for: child, style: .element).height, expected(-1))

        let flipped = FlippedView(frame: .zero)
        flipped.addSubview(child)
        XCTAssertEqual(RelayLayerMotion.hiddenTranslation(for: child, style: .element).height, expected(1))
    }
}
