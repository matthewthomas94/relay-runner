import AppKit

/// Transparent, click-through NSPanel that sits above all windows including full-screen apps.
/// Hosts the glow layers and transcription pill.
final class OverlayPanel: NSPanel {

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none

        // Size to current main screen
        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }
    }

    /// Reframe to match a given screen (used when cursor moves between displays).
    func reframe(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
