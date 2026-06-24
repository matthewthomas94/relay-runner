import XCTest
@testable import relay_runner

final class ParentPermissionGuidanceTests: XCTestCase {

    func testProviderTargetsDescribeNativeVsTerminalHosts() {
        XCTAssertEqual(
            ParentPermissionGuidance.defaultParentHint(for: .codex),
            "the terminal or IDE running Codex (or Codex.app when using the native app)"
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetList(for: .codex),
            "the terminal or IDE running Codex (or Codex.app when using the native app)"
        )
        XCTAssertEqual(
            ParentPermissionGuidance.defaultParentHint(for: .claude),
            "the terminal or IDE running Claude (or Claude.app when using the native app)"
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetList(for: .claude),
            "the terminal or IDE running Claude (or Claude.app when using the native app)"
        )
    }

    func testDetectedParentTargetsOnlyDetectedHost() {
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "Terminal"),
            ["Terminal.app"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "Codex"),
            ["Codex.app"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "Claude"),
            ["Claude.app"]
        )
    }

    func testUnknownParentFallsBackToSupportedParentApps() {
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "unknown"),
            ["Terminal.app", "Codex.app", "Claude.app"]
        )
    }

    func testNonDefaultDetectedParentIsStillIncluded() {
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "Warp"),
            ["Warp"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetList(detectedParent: "iTerm"),
            "iTerm"
        )
    }

    func testProviderAppTargetsIncludeNativeAppAndTerminalNames() {
        let codexTargets = ParentPermissionGuidance.appTargets(for: .codex).map(\.displayName)
        let claudeTargets = ParentPermissionGuidance.appTargets(for: .claude).map(\.displayName)

        XCTAssertEqual(codexTargets, ["Codex.app", "Terminal.app"])
        XCTAssertEqual(claudeTargets, ["Claude.app", "Terminal.app"])
    }

    func testProviderTargetNamesSurfaceDraggableApps() {
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(for: .codex),
            ["Codex.app", "Terminal.app"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetNameList(for: .claude),
            "Claude.app and Terminal.app"
        )
    }

    func testDragGuideHighlightsOnlyActiveTargets() {
        let targets = [
            PermissionAppTarget(displayName: "Codex.app", bundleURL: nil),
            PermissionAppTarget(displayName: "Terminal.app", bundleURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")),
        ]

        XCTAssertEqual(
            PermissionAppDragGuide.highlightedTargetIDs(for: targets, isActive: true),
            Set(targets.map(\.id))
        )
        XCTAssertTrue(
            PermissionAppDragGuide.highlightedTargetIDs(for: targets, isActive: false).isEmpty
        )
    }

    func testDetectedParentDragHighlightParityForSupportedAndCustomParents() {
        for parent in ["Terminal", "Codex", "Claude", "Warp"] {
            let targets = ParentPermissionGuidance.appTargets(detectedParent: parent)

            XCTAssertEqual(
                PermissionAppDragGuide.highlightedTargetIDs(for: targets, isActive: true),
                Set(targets.map(\.id)),
                parent
            )
        }
    }
}
