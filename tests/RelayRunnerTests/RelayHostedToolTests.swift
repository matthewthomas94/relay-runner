import AppKit
import XCTest
@testable import relay_runner

final class RelayHostedToolTests: XCTestCase {
    @MainActor
    func testActionGlowWindowPolicyIsTopmostAndCaptureExcluded() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        RelayVisionOverlayWindowPolicy.configure(panel)

        XCTAssertGreaterThan(
            panel.level.rawValue,
            NSWindow.Level.screenSaver.rawValue + 1
        )
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertEqual(panel.title, RelayVisionOverlayWindowPolicy.actionGlowWindowTitle)
    }

    func testRelayVisionCapturePolicyExcludesOnlyActionGlowWindows() {
        let currentProcess = getpid()
        let actionGlowLayer = Int(RelayVisionOverlayWindowPolicy.windowLevel.rawValue)

        XCTAssertTrue(RelayVisionOverlayWindowPolicy.shouldExcludeFromCapture(
            ownerProcessID: currentProcess,
            windowLayer: actionGlowLayer,
            title: nil
        ))
        XCTAssertTrue(RelayVisionOverlayWindowPolicy.shouldExcludeFromCapture(
            ownerProcessID: currentProcess,
            windowLayer: 0,
            title: RelayVisionOverlayWindowPolicy.actionGlowWindowTitle
        ))
        XCTAssertFalse(RelayVisionOverlayWindowPolicy.shouldExcludeFromCapture(
            ownerProcessID: currentProcess + 1,
            windowLayer: actionGlowLayer,
            title: RelayVisionOverlayWindowPolicy.actionGlowWindowTitle
        ))
        XCTAssertFalse(RelayVisionOverlayWindowPolicy.shouldExcludeFromCapture(
            ownerProcessID: currentProcess,
            windowLayer: Int(NSWindow.Level.screenSaver.rawValue),
            title: "Workspace"
        ))
    }

    func testUnknownHostedToolReturnsStructuredFailure() async {
        let result = await RelayHostedTool.perform(tool: "unknown_tool", arguments: [:])

        switch result {
        case .success:
            XCTFail("Unknown hosted tools should fail.")
        case .failure(let message):
            XCTAssertTrue(message.contains("does not host a tool named 'unknown_tool'"))
        }
    }
}
