import AppKit
import CoreGraphics

/// Calls `onShow` when Mission Control opens (a three-finger swipe up, F3
/// or a hot corner) while it is watching. macOS has no public signal for
/// this, and the Dock's AXExpose notifications no longer fire on macOS 27,
/// so it looks for the full-screen window the Dock puts up at the Dock
/// level, a few times a second, only between `start()` and `stop()`.
final class MissionControlObserver {
    typealias WindowListProvider = () -> [[String: Any]]

    static let pollInterval: TimeInterval = 0.25

    private let onShow: () -> Void
    private let windowList: WindowListProvider
    private let screenSizes: () -> [CGSize]
    private var timer: Timer?

    init(
        windowList: @escaping WindowListProvider = {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
        },
        screenSizes: @escaping () -> [CGSize] = { NSScreen.screens.map(\.frame.size) },
        onShow: @escaping () -> Void
    ) {
        self.windowList = windowList
        self.screenSizes = screenSizes
        self.onShow = onShow
    }

    deinit { timer?.invalidate() }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        guard Self.isMissionControlShowing(windows: windowList(), screenSizes: screenSizes()) else { return }
        stop()
        onShow()
    }

    /// True when the Dock owns an on-screen window at the Dock level that
    /// covers a whole display, which it only does while Mission Control is open.
    static func isMissionControlShowing(windows: [[String: Any]], screenSizes: [CGSize]) -> Bool {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        return windows.contains { window in
            guard window[kCGWindowOwnerName as String] as? String == "Dock",
                  window[kCGWindowLayer as String] as? Int == dockLevel,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return false }
            return screenSizes.contains { size in
                abs(bounds.width - size.width) < 1 && abs(bounds.height - size.height) < 1
            }
        }
    }
}
