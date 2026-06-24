import XCTest
@testable import relay_runner

final class PermissionAppDragGuideTests: XCTestCase {

    func testGoalRowsUseProviderTargetsForCodexAndClaude() {
        let codexRows = PermissionAppDragGuide.goalRows(
            for: ParentPermissionGuidance.appTargets(for: .codex)
        )
        let claudeRows = PermissionAppDragGuide.goalRows(
            for: ParentPermissionGuidance.appTargets(for: .claude)
        )

        XCTAssertEqual(codexRows.map(\.displayName), ["Codex.app", "Terminal.app"])
        XCTAssertEqual(claudeRows.map(\.displayName), ["Claude.app", "Terminal.app"])
        XCTAssertTrue(codexRows.allSatisfy(\.enabled))
        XCTAssertTrue(claudeRows.allSatisfy(\.enabled))
    }

    func testGoalRowsTrackTargetCountsWithoutPlaceholderLabels() {
        let targetSets = [
            ["Codex.app"],
            ["Codex.app", "Terminal.app"],
            ["Codex.app", "Terminal.app", "Warp.app"],
            ["Codex.app", "Terminal.app", "Warp.app", "iTerm.app"]
        ].map { names in
            names.map { PermissionAppTarget(displayName: $0, bundleURL: nil) }
        }

        for targets in targetSets {
            let rows = PermissionAppDragGuide.goalRows(for: targets)

            XCTAssertEqual(rows.map(\.displayName), targets.map(\.displayName))
            XCTAssertEqual(rows.count, targets.count)
            XCTAssertFalse(rows.contains { $0.displayName.hasPrefix("App ") })
            XCTAssertTrue(rows.allSatisfy(\.enabled))
        }
    }

    func testMissingIconFallbackStillNamesActualApp() {
        let rows = PermissionAppDragGuide.goalRows(
            for: [PermissionAppTarget(displayName: "Warp.app", bundleURL: nil)]
        )

        XCTAssertEqual(rows.first?.displayName, "Warp.app")
        XCTAssertEqual(rows.first?.fallbackInitial, "W")
        XCTAssertNil(rows.first?.bundleURL)
    }
}
