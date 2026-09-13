import XCTest
@testable import relay_runner

final class CustomVoiceSettingsStyleTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/relay-runner/Settings/\(name).swift"),
            encoding: .utf8
        )
    }

    func testVoiceSectionsUseTheSameSharedHeading() throws {
        let standard = try source("TTSSettingsTab")
        let custom = try source("CustomVoiceSettingsSection")
        let shared = try source("SettingsComponents")

        XCTAssertTrue(standard.contains("SettingsSection(\"Standard Voices\")"))
        XCTAssertFalse(standard.contains("SettingsSection(\"Voice\")"))
        XCTAssertTrue(custom.contains("SettingsSection(\"Custom Voices\", badge: \"Experimental\")"))
        XCTAssertTrue(shared.contains(".font(AppTypography.font(.sectionHeading))"))
        XCTAssertEqual(AppTypography.definition(for: .sectionHeading).size, 13)
    }

    func testCustomVoiceContentUsesSettingsRowsAndTypography() throws {
        let custom = try source("CustomVoiceSettingsSection")

        XCTAssertTrue(custom.contains("SettingsRow {"))
        XCTAssertTrue(custom.contains("SettingsControlRow("))
        XCTAssertTrue(custom.contains("SettingsStackedControlRow("))
        XCTAssertTrue(custom.contains("SettingsDivider()"))
        XCTAssertTrue(custom.contains("SettingsInlineStatus("))
        XCTAssertFalse(custom.contains(".padding(12)"))
        XCTAssertFalse(custom.contains(".font(.caption)"))
        XCTAssertFalse(custom.contains(".foregroundStyle(.secondary)"))
    }

    func testCustomVoicePageUsesSharedButtonsAndRetainsNativeConfirmations() throws {
        let custom = try source("CustomVoiceSettingsSection")
        let content = try XCTUnwrap(custom.components(separatedBy: ".onAppear").first)
        let draft = try XCTUnwrap(custom.components(separatedBy: "private var draftEditor:").last)
        let nativeButton = #"\bButton\s*\("#

        XCTAssertNil(content.range(of: nativeButton, options: .regularExpression))
        XCTAssertNil(draft.range(of: nativeButton, options: .regularExpression))
        XCTAssertTrue(content.contains("SettingsActionButton("))
        XCTAssertTrue(draft.contains("SettingsActionButton("))
        XCTAssertTrue(custom.contains("isEnabled: audioActionsEnabled"))
        XCTAssertTrue(custom.contains("Button(\"Delete\", role: .destructive)"))
        XCTAssertTrue(custom.contains("Button(\"Cancel\", role: .cancel)"))
    }

    func testStandardVoiceModeActionUsesSharedButton() throws {
        let standard = try source("TTSSettingsTab")
        XCTAssertFalse(standard.contains("Button(\"Use Standard\")"))
        XCTAssertTrue(standard.contains("title: \"Use Standard\""))
    }

    func testExperimentalReleaseExplainsTheSeparateRuntimeRequirement() throws {
        let custom = try source("CustomVoiceSettingsSection")
        XCTAssertTrue(custom.contains("badge: \"Experimental\""))
        XCTAssertTrue(custom.contains("Requires a separately provisioned local cloning runtime."))
        XCTAssertTrue(custom.contains("The app download does not include the engine or models."))
        XCTAssertTrue(custom.contains("Standard voices remain available."))
    }
}
