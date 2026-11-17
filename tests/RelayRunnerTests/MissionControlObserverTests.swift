import CoreGraphics
import XCTest
@testable import relay_runner

final class MissionControlObserverTests: XCTestCase {
    private let screen = CGSize(width: 1512, height: 982)

    private func window(owner: String, layer: Int, size: CGSize, alpha: Double = 1) -> [String: Any] {
        [
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: CGRect(origin: .zero, size: size).dictionaryRepresentation,
        ]
    }

    func testDetectsFullScreenDockWindowAtDockLevel() {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertTrue(MissionControlObserver.isMissionControlShowing(
            windows: [window(owner: "Dock", layer: dockLevel, size: screen)], screenSizes: [screen]))
    }

    func testIgnoresTheDockBarAndOtherApps() {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertFalse(MissionControlObserver.isMissionControlShowing(
            windows: [
                window(owner: "Dock", layer: dockLevel, size: CGSize(width: 900, height: 70)),
                window(owner: "Finder", layer: dockLevel, size: screen),
                window(owner: "Dock", layer: dockLevel, size: screen, alpha: 0),
                window(owner: "Dock", layer: 0, size: screen),
            ],
            screenSizes: [screen]))
    }

    func testCheckCallsOnShowWhenMissionControlOpens() {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        var shown = 0
        let observer = MissionControlObserver(
            windowList: { [self] in [window(owner: "Dock", layer: dockLevel, size: screen)] },
            screenSizes: { [self] in [screen] },
            onShow: { shown += 1 }
        )
        observer.check()
        XCTAssertEqual(shown, 1)
    }
}
