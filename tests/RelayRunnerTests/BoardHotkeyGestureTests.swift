import AppKit
import XCTest
@testable import relay_runner

final class BoardHotkeyGestureTests: XCTestCase {
    func testDoubleTapShiftWithinWindowToggles() {
        var gesture = BoardHotkeyGesture(doubleTapWindow: 0.45)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertFalse(tapShift(&gesture, downAt: start, upAt: start.addingTimeInterval(0.05)))
        XCTAssertTrue(tapShift(
            &gesture,
            downAt: start.addingTimeInterval(0.25),
            upAt: start.addingTimeInterval(0.30)
        ))
    }

    func testSingleShiftTapDoesNotToggle() {
        var gesture = BoardHotkeyGesture(doubleTapWindow: 0.45)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertFalse(tapShift(&gesture, downAt: start, upAt: start.addingTimeInterval(0.05)))
    }

    func testShiftTapsOutsideWindowDoNotToggle() {
        var gesture = BoardHotkeyGesture(doubleTapWindow: 0.45)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertFalse(tapShift(&gesture, downAt: start, upAt: start.addingTimeInterval(0.05)))
        XCTAssertFalse(tapShift(
            &gesture,
            downAt: start.addingTimeInterval(0.65),
            upAt: start.addingTimeInterval(0.70)
        ))
    }

    func testKeyDownWhileShiftIsHeldCancelsTap() {
        var gesture = BoardHotkeyGesture(doubleTapWindow: 0.45)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertFalse(gesture.handleFlagsChanged(.shift, at: start))
        gesture.handleKeyDown()
        XCTAssertFalse(gesture.handleFlagsChanged([], at: start.addingTimeInterval(0.05)))
        XCTAssertFalse(tapShift(
            &gesture,
            downAt: start.addingTimeInterval(0.25),
            upAt: start.addingTimeInterval(0.30)
        ))
    }

    func testKeyDownBetweenShiftTapsClearsPendingTap() {
        var gesture = BoardHotkeyGesture(doubleTapWindow: 0.45)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertFalse(tapShift(&gesture, downAt: start, upAt: start.addingTimeInterval(0.05)))
        gesture.handleKeyDown()
        XCTAssertFalse(tapShift(
            &gesture,
            downAt: start.addingTimeInterval(0.25),
            upAt: start.addingTimeInterval(0.30)
        ))
    }

    func testOptionControlAndOldBoardChordDoNotToggle() {
        var gesture = BoardHotkeyGesture(doubleTapWindow: 0.45)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertFalse(gesture.handleFlagsChanged(.option, at: start))
        XCTAssertFalse(gesture.handleFlagsChanged([], at: start.addingTimeInterval(0.05)))
        XCTAssertFalse(gesture.handleFlagsChanged(.option, at: start.addingTimeInterval(0.20)))
        XCTAssertFalse(gesture.handleFlagsChanged([], at: start.addingTimeInterval(0.25)))

        XCTAssertFalse(gesture.handleFlagsChanged([.control, .option, .command], at: start.addingTimeInterval(0.30)))
        XCTAssertFalse(gesture.handleFlagsChanged([], at: start.addingTimeInterval(0.35)))
        XCTAssertFalse(gesture.handleFlagsChanged([.control, .option, .command], at: start.addingTimeInterval(0.45)))
        XCTAssertFalse(gesture.handleFlagsChanged([], at: start.addingTimeInterval(0.50)))
    }

    private func tapShift(_ gesture: inout BoardHotkeyGesture, downAt: Date, upAt: Date) -> Bool {
        XCTAssertFalse(gesture.handleFlagsChanged(.shift, at: downAt))
        return gesture.handleFlagsChanged([], at: upAt)
    }
}
