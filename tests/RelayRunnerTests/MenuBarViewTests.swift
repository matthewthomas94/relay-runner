import Foundation
import XCTest

final class MenuBarViewTests: XCTestCase {
    func testMenuOmitsRedundantStatusAndVoiceControls() throws {
        let source = try menuSource()

        XCTAssertFalse(source.contains("statusLabel"))
        XCTAssertFalse(source.contains("appState.statusText"))
        XCTAssertFalse(source.contains("Button(\"Start Session"))
        XCTAssertFalse(source.contains("Button(\"Record\""))
        XCTAssertFalse(source.contains("Button(\"Replay\""))
        XCTAssertTrue(source.contains("Button(\"End Session\")"))
    }

    func testSettingsAndUpdatesLabelsHaveNoEllipsis() throws {
        let source = try menuSource()

        XCTAssertTrue(source.contains("Button(\"Workspace Settings\")"))
        XCTAssertTrue(source.contains("Button(\"Check for Updates\")"))
    }

    private func menuSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "Sources/relay-runner/MenuBar/MenuBarView.swift"
        ), encoding: .utf8)
    }
}
