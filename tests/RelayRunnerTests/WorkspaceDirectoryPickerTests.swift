import XCTest
@testable import relay_runner

final class WorkspaceDirectoryPickerTests: XCTestCase {
    func testPickerWaitsForExternalWindowPreparationBeforeOpeningPanel() {
        var events: [String] = []
        var openPanel: (() -> Void)?

        WorkspaceDirectoryPicker.pick(
            message: "Choose a project",
            onPrepareExternalWindow: { ready in
                events.append("prepare")
                openPanel = ready
            },
            chooseDirectory: {
                events.append("panel")
                return URL(fileURLWithPath: "/repo")
            },
            completion: { path in
                events.append("complete:\(path ?? "nil")")
            }
        )

        XCTAssertEqual(events, ["prepare"])
        openPanel?()
        XCTAssertEqual(events, ["prepare", "panel", "complete:/repo"])
    }

    func testAppKitPanelHelperActivatesApplicationBeforeRunningModalPanel() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/relay-runner/Config/WorkspaceDirectoryPicker.swift")
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        let activation = try XCTUnwrap(
            contents.range(of: "NSApplication.shared.activate(ignoringOtherApps: true)")
        )
        let modalRun = try XCTUnwrap(
            contents.range(of: "panel.runModal()", range: activation.upperBound..<contents.endIndex)
        )

        XCTAssertLessThan(activation.lowerBound, modalRun.lowerBound)
    }
}
