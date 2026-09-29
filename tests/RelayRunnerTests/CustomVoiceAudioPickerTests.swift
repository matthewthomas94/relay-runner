import XCTest
@testable import relay_runner

final class CustomVoiceAudioPickerTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/\(path)"), encoding: .utf8)
    }

    func testImportUsesTheAppOwnedPickerInsteadOfOpeningABlockingPanelInTheView() throws {
        let view = try source("Settings/CustomVoiceSettingsSection.swift")
        let start = try XCTUnwrap(view.range(of: "private func chooseAudio()"))
        let end = try XCTUnwrap(view.range(of: "private func importAudio(", range: start.upperBound..<view.endIndex))
        let picker = String(view[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(picker.contains("appState.chooseCustomVoiceAudio"))
        XCTAssertFalse(picker.contains("NSOpenPanel()"))
        XCTAssertFalse(picker.contains("runModal()"))
        XCTAssertTrue(picker.contains("guard let url else { return }"))
        XCTAssertTrue(view.contains("Task.detached(priority: .userInitiated)"))
    }

    func testImportWaitsForTheSameAnimatedHandoffAsAddProject() throws {
        let app = try source("App/AppState.swift")
        let start = try XCTUnwrap(app.range(of: "func chooseCustomVoiceAudio("))
        let end = try XCTUnwrap(app.range(of: "func addExistingProject(", range: start.upperBound..<app.endIndex))
        let picker = String(app[start.lowerBound..<end.lowerBound])
        let suspension = try XCTUnwrap(picker.range(of: "suspendWorkspaceForProjectPicker {"))
        let panel = try XCTUnwrap(picker.range(of: "let panel = NSOpenPanel()"))
        let presentation = try XCTUnwrap(picker.range(of: "WorkspaceDirectoryPicker.runAppKitPanel(panel)"))

        XCTAssertLessThan(suspension.lowerBound, panel.lowerBound)
        XCTAssertLessThan(panel.lowerBound, presentation.lowerBound)
        XCTAssertFalse(picker.contains("runModal()"))
        XCTAssertTrue(picker.contains("panel.canChooseFiles = true"))
        XCTAssertTrue(picker.contains("panel.canChooseDirectories = false"))
        XCTAssertTrue(picker.contains("panel.allowsMultipleSelection = false"))
        XCTAssertTrue(picker.contains("[.wav, .aiff, .mp3, .mpeg4Audio]"))
    }

    func testSelectionAndCancelBothRestoreOnlyAnAlreadyVisibleWorkspace() throws {
        let app = try source("App/AppState.swift")
        let start = try XCTUnwrap(app.range(of: "func chooseCustomVoiceAudio("))
        let end = try XCTUnwrap(app.range(of: "func addExistingProject(", range: start.upperBound..<app.endIndex))
        let picker = String(app[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(picker.contains("let resumeWorkspace = programBoardOverlay.isVisible"))
        XCTAssertTrue(picker.contains("defer {"))
        XCTAssertTrue(picker.contains("if resumeWorkspace { self.programBoardOverlay.showSettings() }"))
        XCTAssertTrue(picker.contains("completion(WorkspaceDirectoryPicker.runAppKitPanel(panel))"))
        XCTAssertFalse(picker.contains("guard let url"), "Cancellation must also reach the retained-workspace restore")
        XCTAssertFalse(picker.contains("saveConfig"))
    }
}
