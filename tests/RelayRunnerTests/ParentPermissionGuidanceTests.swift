import XCTest
@testable import relay_runner

final class ParentPermissionGuidanceTests: XCTestCase {

    func testProviderTargetsStayFocusedOnSelectedAgent() {
        XCTAssertEqual(
            ParentPermissionGuidance.defaultParentApps(for: .codex),
            ["Terminal.app", "Codex.app"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetList(for: .codex),
            "Terminal.app and Codex.app"
        )
        XCTAssertEqual(
            ParentPermissionGuidance.defaultParentApps(for: .claude),
            ["Terminal.app", "Claude.app"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetList(for: .claude),
            "Terminal.app and Claude.app"
        )
    }

    func testDefaultTargetsIncludeSupportedParentApps() {
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "Terminal"),
            ["Terminal.app", "Codex.app", "Claude.app"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "Codex"),
            ["Terminal.app", "Codex.app", "Claude.app"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "Claude"),
            ["Terminal.app", "Codex.app", "Claude.app"]
        )
    }

    func testNonDefaultDetectedParentIsStillIncluded() {
        XCTAssertEqual(
            ParentPermissionGuidance.targetNames(detectedParent: "Warp"),
            ["Terminal.app", "Codex.app", "Claude.app", "Warp"]
        )
        XCTAssertEqual(
            ParentPermissionGuidance.targetList(detectedParent: "iTerm"),
            "Terminal.app, Codex.app, Claude.app, and iTerm"
        )
    }
}
