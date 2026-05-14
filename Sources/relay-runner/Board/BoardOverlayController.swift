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
    private var globalMonitor: Any?
    private var localMonitor: Any?
    /// Drives the SwiftUI view. Mutated by the controller (theme on every
    /// poll tick, tickets on each show) — the view re-renders automatically.
    private let model = BoardViewModel()
    /// Resolves the current particle-field theme (STT/TTS/none) so the
    /// board's glow matches whichever pill state is active.
    private var themeResolver: (() -> ParticleFieldRenderer.Theme?)?
    /// Polls the resolver while the board is visible to keep glow live.
    private var themePollTimer: Timer?

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        themePollTimer?.invalidate()
    }

    /// Install global keyboard hooks: ⌃⌥B toggles the board (works from any
    /// app); Esc dismisses while the board is visible. Both rely on the
    /// Accessibility / Input Monitoring permission the app already needs for
    /// Caps Lock detection.
    ///
    /// Call once from `AppState.startOverlay` — `BoardOverlayController` is
    /// long-lived for the app's lifetime.
    func installGlobalHotkeys() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        // Local monitor catches the same shortcuts when our app happens to be
        // frontmost (NSEvent splits them across global/local). Returning the
        // event lets it propagate normally.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        // ⌃⌥B (control + option + b) — toggle from anywhere.
        // charactersIgnoringModifiers is "b" even with Option pressed;
        // `event.characters` would be "∫" because Option+B types the integral
        // sign on the default US layout. We require exactly Control+Option as
        // the modifier mask so single-modifier presses (Option+B = ∫,
        // Control+B = ^B in terminal apps) don't fire the toggle by accident.
        let ctrlOpt = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option]
        if ctrlOpt, event.charactersIgnoringModifiers?.lowercased() == "b" {
            DispatchQueue.main.async { [weak self] in self?.toggle() }
            return
        }
        // Esc while visible — dismiss.
        if event.keyCode == 53, isVisible {
            DispatchQueue.main.async { [weak self] in self?.hide() }
            return
        }
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }

        let p = panel ?? BoardOverlayPanel()
        if let screen = currentMouseScreen() {
            p.reframe(to: screen)
        }

        // Refresh model from current state. Tickets get re-scanned every show;
        // theme is then kept live by the poll timer below.
        model.tickets = loadTickets()
        model.theme = themeResolver?()

        let hosting = NSHostingView(rootView: BoardOverlayView(
            model: model,
            onDismiss: { [weak self] in self?.hide() }
        ))
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

        startThemePoll()
    }

    func hide() {
        guard isVisible else { return }
        stopThemePoll()
        panel?.orderOut(nil)
        panel?.contentView = nil
        isVisible = false
    }

    /// Poll the resolver and update model.theme on changes. 100 ms feels
    /// instant for state flips (recording start, playback start, etc.) and
    /// the resolver itself is a constant-time enum lookup.
    private func startThemePoll() {
        stopThemePoll()
        themePollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let next = self.themeResolver?()
            if next != self.model.theme {
                self.model.theme = next
            }
        }
    }

    private func stopThemePoll() {
        themePollTimer?.invalidate()
        themePollTimer = nil
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
