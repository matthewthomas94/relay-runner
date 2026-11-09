import AppKit
import XCTest
@testable import relay_runner

final class SettingsWindowTests: XCTestCase {

    func testSettingsCategoriesExposeExpectedNavigationOrder() {
        XCTAssertEqual(
            SettingsCategory.allCases.map(\.title),
            ["Permissions", "Speech-to-Text", "Text-to-Speech", "General", "Awareness", "Relay Remote"]
        )
    }

    func testSettingsCategorySelectionIncludesNavigationLabelAndIcon() {
        for category in SettingsCategory.allCases {
            XCTAssertEqual(category.navigationLabel, category.title)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
    }

    func testSettingsCategoryKeyboardMovementClampsAtEnds() {
        XCTAssertEqual(SettingsCategory.category(after: .permissions), .speechToText)
        XCTAssertEqual(SettingsCategory.category(before: .speechToText), .permissions)
        XCTAssertEqual(SettingsCategory.category(before: .permissions), .permissions)
        XCTAssertEqual(SettingsCategory.category(after: .awareness), .relayRemote)
        XCTAssertEqual(SettingsCategory.category(after: .relayRemote), .relayRemote)
    }

    func testWorkspaceSurfacesUseExplicitFillWidthSizing() {
        XCTAssertEqual(WorkspaceSurfaceSizing.terminalMaxWidth, .infinity)
        XCTAssertEqual(WorkspaceSurfaceSizing.settingsMaxWidth, .infinity)
        XCTAssertTrue(WorkspaceSurfaceSizing.terminalMaxWidth.isInfinite)
        XCTAssertTrue(WorkspaceSurfaceSizing.settingsMaxWidth.isInfinite)
    }

    func testStandaloneSettingsWindowKeepsItsDetailWidthAlongsideAgentCard() {
        XCTAssertEqual(SettingsContentStyle.window.fixedFrame?.width, 860 + 8 + 280)
        XCTAssertEqual(SettingsContentStyle.window.fixedFrame?.height, 640)
        XCTAssertNil(SettingsContentStyle.workspace.fixedFrame)
    }

    func testSettingsContentFillsAvailableWidth() {
        XCTAssertEqual(SettingsContentStyle.window.detailMaxWidth, .infinity)
        XCTAssertEqual(SettingsContentStyle.workspace.detailMaxWidth, .infinity)
        XCTAssertEqual(SettingsLayout.detailMaxWidth, .infinity)
    }

    func testWorkspaceSettingsDoesNotAddStandaloneChrome() {
        XCTAssertTrue(SettingsContentStyle.window.usesStandaloneChrome)
        XCTAssertFalse(SettingsContentStyle.workspace.usesStandaloneChrome)
        XCTAssertFalse(SettingsContentStyle.window.showsEmbeddedHairline)
        XCTAssertTrue(SettingsContentStyle.workspace.showsEmbeddedHairline)
        XCTAssertEqual(SettingsContentStyle.workspace.embeddedCornerRadius, GraphicalTheme.radiusM)
    }

    func testSettingsDescriptionTypographyIsReadable() {
        let definition = AppTypography.definition(for: .settingsDescription)
        XCTAssertGreaterThanOrEqual(definition.size, 11)
        XCTAssertEqual(AppTypography.definition(for: .caption).size, GraphicalTheme.textXS)
    }

    func testSettingsSemanticColorsUseWorkspaceNeutralForFocusStates() {
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

        // The kit steps text down the neutral scale at full alpha rather than fading it.
        XCTAssertGreaterThan(primary.redComponent, secondary.redComponent)
        XCTAssertGreaterThan(secondary.redComponent, muted.redComponent)
        XCTAssertGreaterThan(muted.redComponent, disabled.redComponent)
        XCTAssertEqual(disabled.alphaComponent, 1, accuracy: 0.001)
    }

    func testSettingsNavigationPresentationUsesTicketPrecedenceAndMotion() {
        let inactive = SettingsNavigationPresentation.resolve(
            selected: false,
            isHovered: false,
            isFocused: false,
            reduceMotion: false
        )
        XCTAssertFalse(inactive.usesHoverFill)
        XCTAssertEqual(inactive.fillOverlayOpacity, 0)
        XCTAssertEqual(inactive.foregroundOpacity, 0.82)
        XCTAssertEqual(inactive.animationDuration, ProgramBoardInteractionPresentation.motionDuration)

        let hovered = SettingsNavigationPresentation.resolve(
            selected: false,
            isHovered: true,
            isFocused: false,
            reduceMotion: false
        )
        XCTAssertTrue(hovered.usesHoverFill)
        XCTAssertEqual(hovered.fillOverlayOpacity, 0)
        XCTAssertEqual(hovered.strokeOpacity, 0.15)
        XCTAssertEqual(hovered.foregroundOpacity, 0.98)

        let focused = SettingsNavigationPresentation.resolve(
            selected: false,
            isHovered: true,
            isFocused: true,
            reduceMotion: false
        )
        XCTAssertTrue(focused.usesHoverFill)
        XCTAssertEqual(focused.fillOverlayOpacity, 0)
        XCTAssertEqual(focused.strokeOpacity, hovered.strokeOpacity)

        let selected = SettingsNavigationPresentation.resolve(
            selected: true,
            isHovered: true,
            isFocused: false,
            reduceMotion: true
        )
        XCTAssertTrue(selected.usesHoverFill)
        XCTAssertEqual(selected.fillOverlayOpacity, 0)
        XCTAssertEqual(selected.strokeOpacity, 0.15)
        XCTAssertEqual(selected.foregroundOpacity, 0.98)
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
        XCTAssertTrue(dirty.isEnabled)
        XCTAssertFalse(clean.isEnabled)
        XCTAssertEqual(dirty.animationDuration, ProgramBoardInteractionPresentation.motionDuration)

        // The kit tints a secondary button only on hover, and rings it only on focus.
        let hovered = SettingsActionPresentation.resolve(
            isEnabled: true,
            isHovered: true,
            isFocused: false,
            reduceMotion: false
        )
        XCTAssertGreaterThan(hovered.neutralFillOpacity, dirty.neutralFillOpacity)
        XCTAssertEqual(hovered.fillOpacity, 0)
        XCTAssertEqual(hovered.strokeOpacity, 0)

        let focusedReduceMotion = SettingsActionPresentation.resolve(
            isEnabled: true,
            isHovered: false,
            isFocused: true,
            reduceMotion: true
        )
        XCTAssertGreaterThan(focusedReduceMotion.strokeOpacity, dirty.strokeOpacity)
        XCTAssertGreaterThan(focusedReduceMotion.accentOpacity, clean.accentOpacity)
        XCTAssertEqual(focusedReduceMotion.animationDuration, 0)
    }

    func testSharedActionButtonMetricsMatchSettingsActionGeometry() {
        // Graphical "RR" kit: button radius s (16), padding m (16); sidebar rows radius xs (8).
        XCTAssertEqual(SharedActionButtonMetrics.controlHeight, GraphicalTheme.controlHeight)
        XCTAssertEqual(SharedActionButtonMetrics.cornerRadius, GraphicalTheme.radiusS)
        XCTAssertEqual(SettingsLayout.sidebarCornerRadius, GraphicalTheme.radiusXS)
        XCTAssertEqual(SharedActionButtonMetrics.horizontalPadding, 16)
        XCTAssertEqual(SharedActionButtonMetrics.iconSpacing, 6)
    }

    func testSettingsDetailContentUsesQuietWorkspaceScrollTreatment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(contents.contains("RelayFadingScrollView(showsIndicators: false)"))
        XCTAssertTrue(contents.contains("ScrollViewReader"))
        XCTAssertTrue(contents.contains("proxy.scrollTo(target, anchor: .top)"))
        XCTAssertFalse(contents.contains("ScrollView(.vertical, showsIndicators: true)"))
    }

    func testSettingsFooterReportsSavesWithoutSaveOrRevertButtons() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root.appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift")
        let contents = try String(contentsOf: source, encoding: .utf8)

        XCTAssertFalse(contents.contains("SettingsDetailHeader("))
        XCTAssertFalse(contents.contains("SettingsDetailHeaderPresentation"))
        XCTAssertFalse(contents.contains("title: \"Revert\""))
        XCTAssertFalse(contents.contains("title: \"Save\""))
        XCTAssertFalse(contents.contains("SettingsFooterSaveButton"))
        XCTAssertFalse(contents.contains("draft"), "Settings edits the live config, not a copy")
        XCTAssertTrue(contents.contains("SettingsFooterPresentation(status: autoSave.status)"))
        XCTAssertFalse(contents.contains("OnboardingPresentationState"))
        XCTAssertFalse(contents.contains("not selected"))
    }

    func testSettingsFooterShowsSavedOrTheSaveError() {
        let idle = SettingsFooterPresentation(status: .idle)
        XCTAssertEqual(idle.statusText, "Changes save automatically")
        XCTAssertEqual(idle.iconSemanticColor, .idle)

        let saved = SettingsFooterPresentation(status: .saved)
        XCTAssertEqual(saved.statusText, "Saved")
        XCTAssertEqual(saved.iconSemanticColor, .idle, "A save is reported quietly")

        let failed = SettingsFooterPresentation(status: .failed("The disk is full."))
        XCTAssertEqual(failed.statusText, "Couldn\u{2019}t save settings: The disk is full.")
        XCTAssertEqual(failed.iconSemanticColor, .error)
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

    func testWorkspaceSettingsButtonsStaySecondaryWhileOnboardingRetainsPrimary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsWindow = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Settings/SettingsWindow.swift"),
            encoding: .utf8
        )
        let generalSettings = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Settings/GeneralSettingsTab.swift"),
            encoding: .utf8
        )
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Onboarding/OnboardingView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(settingsWindow.contains("prominence: .primary"))
        XCTAssertFalse(generalSettings.contains("prominence: .primary"))
        XCTAssertTrue(onboarding.contains("prominence: .primary"))
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

    func testFreshTTSConfigDefaultsSpeechSpeedToOnePointThreeX() {
        XCTAssertEqual(AppConfig().tts.rate, 1.3)
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
