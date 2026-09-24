import AppKit
import XCTest
@testable import relay_runner

final class NoteOptionGestureTests: XCTestCase {
    func testLocalAndGlobalRoutesToggleOncePerCleanDoubleTapAndStopRemovesBoth() {
        var local: ((NSEvent) -> NSEvent?)?
        var global: ((NSEvent) -> Void)?
        var removed = 0
        var toggles = 0
        let gesture = NoteOptionGesture(
            globalInstaller: { _, handler in global = handler; return NSObject() },
            localInstaller: { _, handler in local = handler; return NSObject() },
            remover: { _ in removed += 1 },
            onToggle: { toggles += 1 }
        )
        sendDoubleTap { _ = local?($0) }
        XCTAssertEqual(toggles, 1)
        sendDoubleTap { global?($0) }
        XCTAssertEqual(toggles, 2)
        gesture.stop()
        sendDoubleTap { global?($0) }
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(removed, 2)
    }

    func testSingleHoldShortcutAndStaleTapDoNotToggle() {
        var recognizer = NoteOptionDoubleTap()
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option], 0)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [], 0.7)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option], 1.0)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [], 1.1)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option], 1.8)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [], 1.9)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option], 2.0)))
        XCTAssertFalse(recognizer.handle(event(.keyDown, [.option], 2.1, keyCode: 0)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [], 2.2)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option], 2.3)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [], 2.4)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option], 2.5)))
        XCTAssertTrue(recognizer.handle(event(.flagsChanged, [], 2.6)))
    }

    func testResetDiscardsPartialTapAndCapsLockDoesNotBlockGesture() {
        var recognizer = NoteOptionDoubleTap()
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option], 0)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [], 0.1)))
        recognizer.reset()
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option, .capsLock], 0.2)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.capsLock], 0.3)))
        XCTAssertFalse(recognizer.handle(event(.flagsChanged, [.option, .capsLock], 0.4)))
        XCTAssertTrue(recognizer.handle(event(.flagsChanged, [.capsLock], 0.5)))
    }

    private func sendDoubleTap(_ send: (NSEvent) -> Void) {
        send(event(.flagsChanged, [.option], 1))
        send(event(.flagsChanged, [], 1.1))
        send(event(.flagsChanged, [.option], 1.2))
        send(event(.flagsChanged, [], 1.3))
    }

    private func event(
        _ type: NSEvent.EventType,
        _ flags: NSEvent.ModifierFlags,
        _ timestamp: TimeInterval,
        keyCode: UInt16 = 58
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
