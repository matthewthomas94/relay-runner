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

    func testSettingsCategoryKeyboardMovementClampsAtEnds() {
        XCTAssertEqual(SettingsCategory.category(after: .status), .speechToText)
        XCTAssertEqual(SettingsCategory.category(before: .speechToText), .status)
        XCTAssertEqual(SettingsCategory.category(before: .status), .status)
        XCTAssertEqual(SettingsCategory.category(after: .awareness), .awareness)
    }

    func testSettingsHeaderPresentationUsesSelectedCategory() {
        let category = SettingsDetailHeaderPresentation(category: .status)
        XCTAssertEqual(category.title, "Status")
        XCTAssertEqual(category.subtitle, "Permissions and runtime")
        XCTAssertNil(category.trailingText)
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
        XCTAssertFalse(SettingsContentStyle.window.showsEmbeddedHairline)
        XCTAssertTrue(SettingsContentStyle.workspace.showsEmbeddedHairline)
        XCTAssertEqual(SettingsContentStyle.workspace.embeddedCornerRadius, 16)
    }

    func testSettingsDescriptionTypographyIsReadable() {
        let definition = AppTypography.definition(for: .settingsDescription)
        XCTAssertGreaterThanOrEqual(definition.size, 11)
        XCTAssertEqual(AppTypography.definition(for: .caption).size, 9)
    }

    func testSettingsSemanticColorsUseWorkspaceNeutralForDirtyAndFocusStates() {
        XCTAssertEqual(SettingsFooterPresentation(hasChanges: true).iconSemanticColor, .neutralAccent)
        XCTAssertEqual(SettingsFooterPresentation(hasChanges: false).iconSemanticColor, .idle)

        let accent = SettingsSurfaceColor.neutralAccentNSColor.usingColorSpace(.sRGB)!
        let workspaceText = SettingsSurfaceColor.primaryTextNSColor.usingColorSpace(.sRGB)!
        XCTAssertEqual(accent.redComponent, workspaceText.redComponent, accuracy: 0.001)
        XCTAssertEqual(accent.greenComponent, workspaceText.greenComponent, accuracy: 0.001)
        XCTAssertEqual(accent.blueComponent, workspaceText.blueComponent, accuracy: 0.001)
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
        XCTAssertGreaterThan(dirty.neutralFillOpacity, clean.neutralFillOpacity)
        XCTAssertGreaterThan(dirty.neutralStrokeOpacity, clean.neutralStrokeOpacity)
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

    func testSharedActionButtonMetricsMatchSettingsActionGeometry() {
        XCTAssertEqual(SharedActionButtonMetrics.controlHeight, 28)
        XCTAssertEqual(SharedActionButtonMetrics.cornerRadius, SettingsLayout.sidebarCornerRadius)
        XCTAssertEqual(SharedActionButtonMetrics.cornerRadius, 6)
        XCTAssertEqual(SharedActionButtonMetrics.horizontalPadding, 11)
        XCTAssertEqual(SharedActionButtonMetrics.iconSpacing, 6)
    }

    func testSettingsDetailContentUsesQuietWorkspaceScrollTreatment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("ScrollView(.vertical, showsIndicators: false)"))
        XCTAssertTrue(contents.contains("ScrollViewReader"))
        XCTAssertTrue(contents.contains("proxy.scrollTo(target, anchor: .top)"))
        XCTAssertFalse(contents.contains("ScrollView(.vertical, showsIndicators: true)"))
    }

    func testSettingsFooterLivesInsideDetailPlaneWithRevertAction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("SettingsDetailHeader("))
        XCTAssertTrue(contents.contains("SettingsDetailHeaderPresentation(category: selectedCategory)"))
        XCTAssertTrue(contents.contains("SettingsActionButton(\n                title: \"Revert\""))
        XCTAssertTrue(contents.contains("draft = appState.config"))
        XCTAssertFalse(contents.contains("OnboardingPresentationState"))
        XCTAssertFalse(contents.contains("not selected"))
    }

    func testSharedActionButtonChromeOwnsFocusAndAccessibilityHooks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/SettingsComponents.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("struct SharedActionButtonChrome"))
        XCTAssertTrue(contents.contains(".focusable(isEnabled)"))
        XCTAssertTrue(contents.contains(".focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)"))
        XCTAssertTrue(contents.contains(".accessibilityLabel(accessibilityLabel)"))
    }

    func testSettingsSourceDoesNotHostOrRouteOnboarding() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("OnboardingPresentationState"))
        XCTAssertFalse(contents.contains("onboardingActive"))
        XCTAssertFalse(contents.contains("visibleSelection("))
        XCTAssertFalse(contents.contains("OnboardingRoutedToWorkspaceView"))
        XCTAssertFalse(contents.contains("OnboardingPermissionWaitView"))
        XCTAssertFalse(contents.contains("onboardingFooter"))
        XCTAssertFalse(contents.contains("onboardingRouteFooter"))
        XCTAssertFalse(contents.contains("rootView"))
        XCTAssertTrue(contents.contains("selection: $selectedCategory"))
        XCTAssertTrue(contents.contains("switch selectedCategory"))
    }

    func testStandaloneSettingsContentIsUnavailableDuringFirstRunExperience() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("AppState.allowsAppShellAccess("))
        XCTAssertTrue(contents.contains("firstRunExperienceActive: appState.isFirstRunExperienceActive"))
        XCTAssertTrue(contents.contains("} else {\n            EmptyView()"))
    }

    func testSettingsSlidersExposeProgrammaticValues() {
        XCTAssertEqual(TTSSettingsTab.speechSpeedAccessibilityValue(1.3), "1.3 times")
        XCTAssertEqual(AwarenessSettingsTab.particleIntensityAccessibilityValue(0.73), "73 percent")
    }

    func testSTTInputDeviceIsReadOnlyPresentation() throws {
        XCTAssertEqual(STTSettingsTab.inputDeviceDisplayName("default"), "System Default")
        XCTAssertEqual(STTSettingsTab.inputDeviceDisplayName("  Studio Mic  "), "Studio Mic")
        XCTAssertEqual(STTSettingsTab.inputDeviceAccessibilityValue("default"), "System Default, read-only")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/STTSettingsTab.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("Picker(\"Input Device\""))
        XCTAssertFalse(contents.contains("Picker(\"Input Mode\""))
        XCTAssertTrue(contents.contains("config.input_mode == \"push_to_talk\""))
    }

    func testKeyCaptureExposesAccessibleResetAndCancelRecovery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/KeyCaptureView.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("accessibilityLabel(\"Reset \\(label) to Caps Lock\")"))
        XCTAssertTrue(contents.contains("override func accessibilityRole() -> NSAccessibility.Role?"))
        XCTAssertTrue(contents.contains("override func accessibilityPerformPress() -> Bool"))
        XCTAssertTrue(contents.contains("override func keyDown(with event: NSEvent)"))
        XCTAssertTrue(contents.contains("restoreCommittedDisplay()"))
        XCTAssertFalse(contents.contains("xmark.circle.fill"))
    }

    func testSettingsSourceDoesNotUseOrangeOrPurpleStyling() throws {
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
            XCTAssertFalse(contents.contains(".purple"), "\(path) should not use purple styling in Settings")
            XCTAssertFalse(contents.contains("Color.purple"), "\(path) should not use purple styling in Settings")
        }
    }
}
