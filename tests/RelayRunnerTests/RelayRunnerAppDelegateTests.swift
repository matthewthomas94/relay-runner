import AppKit
import XCTest
@testable import relay_runner

final class RelayRunnerAppDelegateTests: XCTestCase {
    func testDockReopenOpensSettingsForRegularAppAndSuppressesDefaultWindowHandling() {
        let delegate = RelayRunnerAppDelegate()
        var openCount = 0
        delegate.settingsOpener = {
            openCount += 1
        }

        let shouldHandleDefaultReopen = delegate.handleDockReopen(activationPolicy: .regular)

        XCTAssertFalse(shouldHandleDefaultReopen)
        XCTAssertEqual(openCount, 1)
    }

    func testDockReopenFallsThroughWhenSettingsHandlingIsDisabled() {
        let delegate = RelayRunnerAppDelegate()
        delegate.handlesDockReopenWithSettings = false
        var openCount = 0
        delegate.settingsOpener = {
            openCount += 1
        }

        let shouldHandleDefaultReopen = delegate.handleDockReopen(activationPolicy: .regular)

        XCTAssertTrue(shouldHandleDefaultReopen)
        XCTAssertEqual(openCount, 0)
    }

    func testDockReopenFallsThroughForAccessoryApp() {
        let delegate = RelayRunnerAppDelegate()
        var openCount = 0
        delegate.settingsOpener = {
            openCount += 1
        }

        let shouldHandleDefaultReopen = delegate.handleDockReopen(activationPolicy: .accessory)

        XCTAssertTrue(shouldHandleDefaultReopen)
        XCTAssertEqual(openCount, 0)
    }
}
