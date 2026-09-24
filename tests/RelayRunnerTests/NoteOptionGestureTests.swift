import AppKit
import XCTest
@testable import relay_runner

final class NoteOptionGestureTests: XCTestCase {
    func testLocalAndGlobalRoutesToggleOncePerCleanDoubleTapAndStopRemovesBoth() {
        var local: ((NSEvent) -> NSEvent?)?
        var global: ((NSEvent) -> Void)?
        var removed = 0
        var toggles = 0
        var workspaceToggles = 0
        let gesture = NoteOptionGesture(
            globalInstaller: { _, handler in global = handler; return NSObject() },
            localInstaller: { _, handler in local = handler; return NSObject() },
            remover: { _ in removed += 1 },
            onToggle: { toggles += 1 },
            onWorkspaceToggle: { workspaceToggles += 1 }
        )
        sendDoubleTap { _ = local?($0) }
        XCTAssertEqual(toggles, 1)
        sendDoubleTap { global?($0) }
        XCTAssertEqual(toggles, 2)
        sendShiftDoubleTap { _ = local?($0) }
        XCTAssertEqual(workspaceToggles, 1)
        sendShiftDoubleTap { global?($0) }
        XCTAssertEqual(workspaceToggles, 2)
        XCTAssertEqual(toggles, 2)
        gesture.stop()
        sendDoubleTap { global?($0) }
        sendShiftDoubleTap { global?($0) }
        XCTAssertEqual(toggles, 2)
        XCTAssertEqual(workspaceToggles, 2)
        XCTAssertEqual(removed, 2)
    }

    func testWorkspaceSurvivesStopFailureAndRecoveryWhileOptionRemainsGated() {
        var global: ((NSEvent) -> Void)?
        var optionToggles = 0
        var workspaceToggles = 0
        let gesture = NoteOptionGesture(
            globalInstaller: { _, handler in global = handler; return NSObject() },
            localInstaller: { _, _ in NSObject() },
            remover: { _ in },
            onToggle: { optionToggles += 1 },
            onWorkspaceToggle: { workspaceToggles += 1 }
        )

        sendDoubleTap { global?($0) } // recording
        XCTAssertEqual(optionToggles, 1)
        gesture.setOptionEnabled(false) // stopping, then failed save and interrupted recovery
        sendDoubleTap(startingAt: 2) { global?($0) }
        sendShiftDoubleTap(startingAt: 3) { global?($0) }
        sendShiftDoubleTap(startingAt: 4) { global?($0) }
        XCTAssertEqual(optionToggles, 1)
        XCTAssertEqual(workspaceToggles, 2)

        gesture.setOptionEnabled(true) // recovered paused note
        sendDoubleTap(startingAt: 5) { global?($0) }
        XCTAssertEqual(optionToggles, 2)
        gesture.stop() // saved note or voice session takeover
        sendShiftDoubleTap(startingAt: 6) { global?($0) }
        XCTAssertEqual(workspaceToggles, 2)
    }

    func testDisablingOptionDiscardsPartialTapWithoutDisablingShift() {
        var global: ((NSEvent) -> Void)?
        var optionToggles = 0
        var workspaceToggles = 0
        let gesture = NoteOptionGesture(
            globalInstaller: { _, handler in global = handler; return NSObject() },
            localInstaller: { _, _ in NSObject() },
            remover: { _ in },
            onToggle: { optionToggles += 1 },
            onWorkspaceToggle: { workspaceToggles += 1 }
        )

        global?(event(.flagsChanged, [.option], 0))
        global?(event(.flagsChanged, [], 0.1))
        gesture.setOptionEnabled(false)
        gesture.setOptionEnabled(true)
        global?(event(.flagsChanged, [.option], 0.2))
        global?(event(.flagsChanged, [], 0.3))
        XCTAssertEqual(optionToggles, 0)
        sendShiftDoubleTap { global?($0) }
        XCTAssertEqual(workspaceToggles, 1)
        gesture.stop()
    }

    func testShiftDoubleTapAcceptsEitherKeyAndCapsLockWithoutOptionToggle() {
        var shift = NoteShiftDoubleTap()
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift, .capsLock], 0, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.capsLock], 0.05, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift, .capsLock], 0.2, keyCode: 60)))
        XCTAssertTrue(shift.handle(event(.flagsChanged, [.capsLock], 0.25, keyCode: 60)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 0.4, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 0.45, keyCode: 56)))
    }

    func testShiftHoldChordTypingAndStaleTapDoNotToggle() {
        var shift = NoteShiftDoubleTap()
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 0, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 0.6, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 0.7, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 0.75, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift, .option], 0.9, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.option], 0.95, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 1.1, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 1.15, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 1.8, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 1.85, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 2, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.keyDown, [.shift], 2.05, keyCode: 0)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 2.1, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 2.2, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 2.25, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 2.3, keyCode: 56)))
        XCTAssertTrue(shift.handle(event(.flagsChanged, [], 2.35, keyCode: 56)))
    }

    func testShiftTapDoesNotCarryAcrossMonitorReset() {
        var shift = NoteShiftDoubleTap()
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 0, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 0.05, keyCode: 56)))
        shift.reset()
        XCTAssertFalse(shift.handle(event(.flagsChanged, [.shift], 0.2, keyCode: 56)))
        XCTAssertFalse(shift.handle(event(.flagsChanged, [], 0.25, keyCode: 56)))
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

    private func sendDoubleTap(
        startingAt start: TimeInterval = 1,
        _ send: (NSEvent) -> Void
    ) {
        send(event(.flagsChanged, [.option], start))
        send(event(.flagsChanged, [], start + 0.1))
        send(event(.flagsChanged, [.option], start + 0.2))
        send(event(.flagsChanged, [], start + 0.3))
    }

    private func sendShiftDoubleTap(
        startingAt start: TimeInterval = 1,
        _ send: (NSEvent) -> Void
    ) {
        send(event(.flagsChanged, [.shift], start, keyCode: 56))
        send(event(.flagsChanged, [], start + 0.1, keyCode: 56))
        send(event(.flagsChanged, [.shift], start + 0.2, keyCode: 56))
        send(event(.flagsChanged, [], start + 0.3, keyCode: 56))
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
