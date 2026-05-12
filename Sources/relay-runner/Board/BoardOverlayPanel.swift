import AppKit

/// Fullscreen transparent panel hosting the kanban-board overlay.
///
/// Unlike the main `OverlayPanel` (pill / particle field), this panel
/// **accepts mouse events** so the user can click outside the columns to
/// dismiss, and (in a later milestone) click a card to focus it. It still
/// renders above all windows including full-screen apps.
final class BoardOverlayPanel: NSPanel {

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
        ignoresMouseEvents = false
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // Accept first responder so keyDown reaches the content view (Esc).
        becomesKeyOnlyIfNeeded = false

        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func reframe(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
