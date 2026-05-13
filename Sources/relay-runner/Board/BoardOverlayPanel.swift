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

        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }
    }

    // Don't become key. Esc dismissal is handled by the global+local NSEvent
    // monitors in BoardOverlayController, so the panel doesn't need keyboard
    // focus. Letting it become key was making the main overlay panel
    // (where the pill lives) lose state — specifically, the pill would
    // snap to compact mode during playback while the board was up.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reframe(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
