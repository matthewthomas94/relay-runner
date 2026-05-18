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

    /// Toggled by `BoardOverlayController` while the editor modal is open —
    /// the panel needs key focus for TextField input but going key while the
    /// pill is playing back causes the pill to snap to compact mode. So we
    /// only opt in for the brief window the modal is on screen.
    var keyEligible: Bool = false

    // Esc dismissal is handled by the global+local NSEvent monitors in
    // BoardOverlayController; the panel doesn't need to be key unless the
    // editor modal is up.
    override var canBecomeKey: Bool { keyEligible }
    override var canBecomeMain: Bool { false }

    func reframe(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }
}
