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

    func testWorkspaceSurfacesUseExplicitFillWidthSizing() {
        XCTAssertEqual(WorkspaceSurfaceSizing.terminalMaxWidth, .infinity)
        XCTAssertEqual(WorkspaceSurfaceSizing.settingsMaxWidth, .infinity)
        XCTAssertTrue(WorkspaceSurfaceSizing.terminalMaxWidth.isInfinite)
        XCTAssertTrue(WorkspaceSurfaceSizing.settingsMaxWidth.isInfinite)
    }

    func testStandaloneSettingsWindowKeepsItsFixedSize() {
        XCTAssertEqual(SettingsContentStyle.window.fixedFrame?.width, 720)
        XCTAssertEqual(SettingsContentStyle.window.fixedFrame?.height, 560)
        XCTAssertNil(SettingsContentStyle.workspace.fixedFrame)
    }
}
