import AppKit

/// Fullscreen transparent panel hosting the Workspace overlay.
///
/// Unlike the main `OverlayPanel` (pill / particle field), this panel
/// **accepts mouse events** so the user can click outside the columns to
/// dismiss, and (in a later milestone) click a card to focus it. It still
/// renders above all windows including full-screen apps.
final class BoardOverlayPanel: NSPanel {
    private weak var hoveredWorkCard: ProgramWorkCardDragEventView?
    private weak var capturedWorkCard: ProgramWorkCardDragEventView?

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
        acceptsMouseMovedEvents = true
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none

        if let screen = NSScreen.main {
            setFrame(screen.frame, display: false)
        }
    }

    /// Toggled by `ProgramBoardOverlayController` while the editor modal is open —
    /// the panel needs key focus for TextField input but going key while the
    /// pill is playing back causes the pill to snap to compact mode. So we
    /// only opt in for the brief window the modal is on screen.
    var keyEligible: Bool = false

    // Esc dismissal is handled by the global+local NSEvent monitors in
    // ProgramBoardOverlayController; the panel doesn't need to be key unless the
    // editor modal is up.
    override var canBecomeKey: Bool { keyEligible }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            let workCard = programWorkCard(atWindowLocation: event.locationInWindow)
            if hoveredWorkCard !== workCard {
                hoveredWorkCard?.reconcilePointerContainment(
                    atWindowLocation: event.locationInWindow
                )
                hoveredWorkCard = workCard
            }
            if let workCard {
                workCard.mouseMoved(with: event)
                return
            }
        case .leftMouseDown:
            cancelCapturedWorkCard()
            if let workCard = programWorkCard(atWindowLocation: event.locationInWindow) {
                capturedWorkCard = workCard
                workCard.mouseDown(with: event)
                return
            }
        case .leftMouseDragged:
            if let capturedWorkCard {
                capturedWorkCard.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if let capturedWorkCard {
                self.capturedWorkCard = nil
                capturedWorkCard.mouseUp(with: event)
                return
            }
        default:
            break
        }
        super.sendEvent(event)
    }

    override func orderOut(_ sender: Any?) {
        let capturedWorkCard = capturedWorkCard
        let hoveredWorkCard = hoveredWorkCard
        self.capturedWorkCard = nil
        self.hoveredWorkCard = nil
        capturedWorkCard?.cancelOperation(nil)
        if hoveredWorkCard !== capturedWorkCard {
            hoveredWorkCard?.cancelOperation(nil)
        }
        super.orderOut(sender)
    }

    func reframe(to screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }

    private func cancelCapturedWorkCard() {
        let capturedWorkCard = capturedWorkCard
        self.capturedWorkCard = nil
        capturedWorkCard?.cancelOperation(nil)
    }

    private func programWorkCard(
        atWindowLocation location: CGPoint
    ) -> ProgramWorkCardDragEventView? {
        guard let contentView else { return nil }
        var candidate: NSView? = contentView.hitTest(
            contentView.convert(location, from: nil)
        )
        while let view = candidate {
            if let workCard = view as? ProgramWorkCardDragEventView {
                return workCard
            }
            candidate = view.superview
        }
        return nil
    }
}
