import XCTest
@testable import relay_runner

final class ParentPermissionGuidanceTests: XCTestCase {

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
