import AppKit
import XCTest
@testable import relay_runner

final class CapsLockGestureTests: XCTestCase {
    func testGlobalModifierMonitorRetriesAfterInitialFailureWithoutDuplicates() {
        var globalInstallCount = 0
        var localInstallCount = 0
        var removedMonitorCount = 0
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
                }
            )

            XCTAssertEqual(globalInstallCount, 1)
            XCTAssertEqual(localInstallCount, 1)

            gesture.retryMissingGlobalMonitors()
            XCTAssertEqual(globalInstallCount, 2)

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
}
