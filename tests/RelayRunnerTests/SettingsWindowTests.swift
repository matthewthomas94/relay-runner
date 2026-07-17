import AppKit
import XCTest
@testable import relay_runner

final class SettingsWindowTests: XCTestCase {

    func testSettingsCategoriesExposeExpectedNavigationOrder() {
        XCTAssertEqual(
            SettingsCategory.allCases.map(\.title),
            ["Status", "Speech-to-Text", "Text-to-Speech", "General", "Awareness"]
        )
    }

    func testSettingsCategorySelectionIncludesHeaderTextNavigationLabelAndIcon() {
        for category in SettingsCategory.allCases {
            XCTAssertFalse(category.subtitle.isEmpty)
            XCTAssertEqual(category.navigationLabel, category.title)
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
        XCTAssertEqual(SettingsContentStyle.window.fixedFrame?.width, 860)
        XCTAssertEqual(SettingsContentStyle.window.fixedFrame?.height, 640)
        XCTAssertNil(SettingsContentStyle.workspace.fixedFrame)
    }

    func testSettingsContentUsesReadableMaximumWidth() {
        XCTAssertEqual(SettingsContentStyle.window.detailMaxWidth, 620)
        XCTAssertEqual(SettingsContentStyle.workspace.detailMaxWidth, SettingsLayout.detailMaxWidth)
        XCTAssertEqual(SettingsLayout.detailMaxWidth, 680)
    }

    func testWorkspaceSettingsDoesNotAddStandaloneChrome() {
        XCTAssertTrue(SettingsContentStyle.window.usesStandaloneChrome)
        XCTAssertFalse(SettingsContentStyle.workspace.usesStandaloneChrome)
    }

    func testSettingsDescriptionTypographyIsReadable() {
        let definition = AppTypography.definition(for: .settingsDescription)
        XCTAssertGreaterThanOrEqual(definition.size, 11)
        XCTAssertEqual(AppTypography.definition(for: .caption).size, 9)
    }

    func testSettingsSemanticColorsUsePurpleForDirtyAndFocusStates() {
        XCTAssertEqual(SettingsFooterPresentation(hasChanges: true).iconSemanticColor, .relayAccent)
        XCTAssertEqual(SettingsFooterPresentation(hasChanges: false).iconSemanticColor, .success)

        let accent = SettingsSurfaceColor.relayAccentNSColor
            .usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(accent.blueComponent, accent.redComponent)
        XCTAssertGreaterThan(accent.redComponent, accent.greenComponent)
    }

    func testSettingsSourceDoesNotUseOrangeStyling() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/relay-runner/Settings")
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }

        for path in paths {
            let contents = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(contents.contains(".orange"), "\(path) should not use orange styling in Settings")
            XCTAssertFalse(contents.contains("Color.orange"), "\(path) should not use orange styling in Settings")
        }
    }
}
