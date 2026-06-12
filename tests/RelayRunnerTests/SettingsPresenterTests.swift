import AppKit
import XCTest
@testable import relay_runner

final class SettingsPresenterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SettingsPresenter.register(openSettings: nil)
    }

    override func tearDown() {
        SettingsPresenter.register(openSettings: nil)
        super.tearDown()
    }

    func testRegisteredOpenSettingsBypassesLegacySelectors() {
        var openedSettings = false
        var sentSelectors: [String] = []
        var activated = false
        SettingsPresenter.register {
            openedSettings = true
        }

        SettingsPresenter.open(
            sendAction: { selector in
                sentSelectors.append(NSStringFromSelector(selector))
                return true
            },
            activateWindows: {
                activated = true
            },
            scheduleActivation: { activation in
                activation()
            }
        )

        XCTAssertTrue(openedSettings)
        XCTAssertEqual(sentSelectors, [])
        XCTAssertTrue(activated)
    }

    func testFallsBackToPreferencesSelectorWhenSettingsSelectorIsUnavailable() {
        var sentSelectors: [String] = []
        var activated = false

        SettingsPresenter.open(
            sendAction: { selector in
                sentSelectors.append(NSStringFromSelector(selector))
                return false
            },
            activateWindows: {
                activated = true
            },
            scheduleActivation: { activation in
                activation()
            }
        )

        XCTAssertEqual(sentSelectors, ["showSettingsWindow:", "showPreferencesWindow:"])
        XCTAssertTrue(activated)
    }
}
