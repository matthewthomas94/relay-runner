import XCTest
@testable import relay_runner

final class SettingsWindowTests: XCTestCase {

    func testSettingsCategoriesExposeExpectedNavigationOrder() {
        XCTAssertEqual(
            SettingsCategory.allCases.map(\.title),
            ["Status", "Speech-to-Text", "Text-to-Speech", "General", "Awareness"]
        )
    }

    func testSettingsCategorySelectionIncludesTextAndIconState() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.subtitle.isEmpty)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
    }
}
