import AppKit
import XCTest
@testable import relay_runner

final class CapsLockGestureTests: XCTestCase {
    func testGlobalModifierMonitorRetriesAfterInitialFailureWithoutDuplicates() {
        var globalInstallCount = 0
        var localInstallCount = 0
        var removedMonitorCount = 0
        var diagnostics: [String] = []
        var recoveredGlobalHandler: ((NSEvent) -> Void)?
        let globalToken = NSObject()
        let localToken = NSObject()

        do {
            let gesture = CapsLockGesture(
                globalMonitorInstaller: { _, handler in
                    globalInstallCount += 1
                    guard globalInstallCount > 1 else { return nil }
                    recoveredGlobalHandler = handler
                    return globalToken
                },
                localMonitorInstaller: { _, _ in
                    localInstallCount += 1
                    return localToken
                },
                monitorRemover: { _ in
                    removedMonitorCount += 1
                },
                diagnosticLogger: { diagnostics.append($0) }
            )

            XCTAssertEqual(globalInstallCount, 1)
            XCTAssertEqual(localInstallCount, 1)

            gesture.retryMissingGlobalMonitors()
            XCTAssertEqual(globalInstallCount, 2)
            XCTAssertTrue(diagnostics.contains { $0.contains("global monitor recovered") })
            XCTAssertTrue(diagnostics.contains {
                $0.contains("identity=modifier-global") && $0.contains("generation=")
            })

            recoveredGlobalHandler?(modifierEvent(flags: [.option], keyCode: 58))
            recoveredGlobalHandler?(modifierEvent(flags: [], keyCode: 58))
            recoveredGlobalHandler?(modifierEvent(flags: [.option], keyCode: 58))
            recoveredGlobalHandler?(modifierEvent(flags: [], keyCode: 58))
            guard case .play? = gesture.poll(currentSegment: "") else {
                return XCTFail("Recovered global monitor did not deliver double-tap Option")
            }

            gesture.retryMissingGlobalMonitors()
            XCTAssertEqual(globalInstallCount, 2)
        }

        XCTAssertEqual(removedMonitorCount, 2)
        XCTAssertTrue(diagnostics.contains { $0.contains("monitors stopped count=2") })
    }

    func testForegroundModifierDownUpEmitsExactlyOnePlay() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )

        sendDoubleTap(.option, keyCode: 58, to: localHandler)

        guard case .play? = gesture.poll(currentSegment: "") else {
            return XCTFail("Foreground local monitor did not emit play")
        }
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    func testControlStopThenOptionReplayPreservesGestureOrdering() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )

        sendDoubleTap(.control, keyCode: 59, to: localHandler)
        guard case .cancel? = gesture.poll(currentSegment: "") else {
            return XCTFail("Double-tap Control did not emit stop")
        }
        XCTAssertNil(gesture.poll(currentSegment: ""))

        sendDoubleTap(.option, keyCode: 58, to: localHandler)
        guard case .play? = gesture.poll(currentSegment: "") else {
            return XCTFail("First Option gesture after stop did not emit replay")
        }
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    func testConfirmationConsumesOptionDoubleTapWithoutPlayback() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )
        let stateMachine = StateMachine()
        stateMachine.setActionGlow(awaitingConfirmation: ConfirmationPrompt(
            summary: "Confirm test action",
            risk: "medium",
            requestId: "confirmation-1"
        ))
        var confirmations: [Bool] = []
        gesture.stateMachine = stateMachine
        gesture.confirmationResolver = { confirmations.append($0) }

        sendDoubleTap(.option, keyCode: 58, to: localHandler)

        XCTAssertEqual(confirmations, [true])
        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    func testOptionModifiedTypingDoesNotEmitPlayback() {
        var localHandler: ((NSEvent) -> NSEvent?)?
        let gesture = CapsLockGesture(
            globalMonitorInstaller: { _, _ in NSObject() },
            localMonitorInstaller: { _, handler in
                localHandler = handler
                return NSObject()
            },
            monitorRemover: { _ in }
        )

        for keyCode: UInt16 in [0, 1] {
            _ = localHandler?(modifierEvent(flags: [.option], keyCode: 58))
            _ = localHandler?(keyDownEvent(flags: [.option], keyCode: keyCode))
            _ = localHandler?(modifierEvent(flags: [], keyCode: 58))
        }

        XCTAssertNil(gesture.poll(currentSegment: ""))
    }

    private func sendDoubleTap(
        _ modifier: NSEvent.ModifierFlags,
        keyCode: UInt16,
        to handler: ((NSEvent) -> NSEvent?)?
    ) {
        _ = handler?(modifierEvent(flags: modifier, keyCode: keyCode))
        _ = handler?(modifierEvent(flags: [], keyCode: keyCode))
        _ = handler?(modifierEvent(flags: modifier, keyCode: keyCode))
        _ = handler?(modifierEvent(flags: [], keyCode: keyCode))
    }

    private func modifierEvent(
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func keyDownEvent(
        flags: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}
