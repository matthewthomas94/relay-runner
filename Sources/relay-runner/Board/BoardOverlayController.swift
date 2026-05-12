import AppKit
import SwiftUI

/// Manages the kanban-board overlay lifecycle. Owns a single
/// `BoardOverlayPanel` and an `NSHostingView` rendering the SwiftUI tree.
///
/// Currently a manual toggle (`show` / `hide` / `toggle` from the menu).
/// Esc / click-outside / global hotkey dismissal land in a follow-up commit.
///
/// All methods must be called from the main thread (AppKit requirement). The
/// type itself isn't marked `@MainActor` so it can be held by `AppState` as a
/// plain stored property without forcing AppState onto the main actor.
final class BoardOverlayController {

    private var panel: BoardOverlayPanel?
    private(set) var isVisible = false

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }

        let p = panel ?? BoardOverlayPanel()
        if let screen = currentMouseScreen() {
            p.reframe(to: screen)
        }

        let tickets = loadTickets()
        let hosting = NSHostingView(rootView: BoardOverlayView(tickets: tickets) { [weak self] in
            self?.hide()
        })
        hosting.frame = p.frame
        hosting.autoresizingMask = [.width, .height]
        // Transparent background so the panel's transparency shows through
        // the unused SwiftUI canvas (the columns themselves opt back in with
        // their own backgrounds).
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        p.contentView = hosting
        p.orderFrontRegardless()
        self.panel = p
        self.isVisible = true
    }

    func hide() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        panel?.contentView = nil
        isVisible = false
    }

    // MARK: - Helpers

    private func loadTickets() -> [Ticket] {
        guard let project = ProjectResolver.resolve() else { return [] }
        return ProjectResolver.scanTickets(in: project)
    }

    private func currentMouseScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        } ?? NSScreen.main
    }
}
