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

    func testSettingsTextHierarchyHasDistinctMutedAndDisabledLevels() {
        let primary = SettingsSurfaceColor.primaryTextNSColor.usingColorSpace(.sRGB)!
        let secondary = SettingsSurfaceColor.secondaryTextNSColor.usingColorSpace(.sRGB)!
        let muted = SettingsSurfaceColor.mutedTextNSColor.usingColorSpace(.sRGB)!
        let disabled = SettingsSurfaceColor.disabledTextNSColor.usingColorSpace(.sRGB)!

        XCTAssertGreaterThan(primary.alphaComponent, secondary.alphaComponent)
        XCTAssertGreaterThan(secondary.alphaComponent, muted.alphaComponent)
        XCTAssertGreaterThan(muted.alphaComponent, disabled.alphaComponent)
        XCTAssertGreaterThan(secondary.redComponent, muted.redComponent)
    }

    func testSettingsNavigationPresentationUsesWorkspacePrecedenceAndMotion() {
        let inactive = SettingsNavigationPresentation.resolve(
            selected: false,
            isHovered: false,
            isFocused: false,
            reduceMotion: false
        )
        XCTAssertEqual(inactive.fillOpacity, 0)
        XCTAssertEqual(inactive.foregroundOpacity, WorkspaceNavigationStyle.inactiveTextOpacity)
        XCTAssertEqual(inactive.animationDuration, ProgramBoardInteractionPresentation.motionDuration)

        let hovered = SettingsNavigationPresentation.resolve(
            selected: false,
            isHovered: true,
            isFocused: false,
            reduceMotion: false
        )
        XCTAssertEqual(hovered.fillOpacity, WorkspaceNavigationStyle.hoveredFillOpacity)
        XCTAssertEqual(hovered.foregroundOpacity, WorkspaceNavigationStyle.activeTextOpacity)

        let focused = SettingsNavigationPresentation.resolve(
            selected: false,
            isHovered: true,
            isFocused: true,
            reduceMotion: false
        )
        XCTAssertEqual(focused.fillOpacity, WorkspaceNavigationStyle.focusedFillOpacity)
        XCTAssertGreaterThan(focused.strokeOpacity, hovered.strokeOpacity)

        let selected = SettingsNavigationPresentation.resolve(
            selected: true,
            isHovered: true,
            isFocused: false,
            reduceMotion: true
        )
        XCTAssertEqual(selected.fillOpacity, WorkspaceNavigationStyle.selectedFillOpacity)
        XCTAssertEqual(selected.foregroundOpacity, WorkspaceNavigationStyle.activeTextOpacity)
        XCTAssertEqual(selected.animationDuration, 0)
    }

    func testSettingsSaveActionPresentationKeepsDisabledAndDirtyStatesDistinct() {
        let clean = SettingsActionPresentation.resolve(
            isEnabled: false,
            isHovered: true,
            isFocused: true,
            reduceMotion: false
        )
        XCTAssertEqual(clean.foregroundOpacity, 0.45)
        XCTAssertEqual(clean.accentOpacity, 0)

        let dirty = SettingsActionPresentation.resolve(
            isEnabled: true,
            isHovered: false,
            isFocused: false,
            reduceMotion: false
        )
        XCTAssertGreaterThan(dirty.foregroundOpacity, clean.foregroundOpacity)
        XCTAssertGreaterThan(dirty.accentOpacity, clean.accentOpacity)
        XCTAssertEqual(dirty.animationDuration, ProgramBoardInteractionPresentation.motionDuration)

        let focusedReduceMotion = SettingsActionPresentation.resolve(
            isEnabled: true,
            isHovered: false,
            isFocused: true,
            reduceMotion: true
        )
        XCTAssertGreaterThan(focusedReduceMotion.strokeOpacity, dirty.strokeOpacity)
        XCTAssertEqual(focusedReduceMotion.animationDuration, 0)
    }

    func testSettingsDetailContentKeepsNativeVerticalScrollIndicator() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("ScrollView(.vertical, showsIndicators: true)"))
        XCTAssertFalse(contents.contains("ScrollView(.vertical, showsIndicators: false)"))
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
