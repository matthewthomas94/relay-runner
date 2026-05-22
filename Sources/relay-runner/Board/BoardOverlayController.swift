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

    /// Gesture state for the modifier-only ⌃⌥ hotkey. NSEvent doesn't have a
    /// native "hotkey is two modifiers and no letter" abstraction — we drive
    /// it off `.flagsChanged` instead. Press Control+Option together, release
    /// either to toggle. If any key is pressed while both modifiers are held
    /// (e.g. ⌃⌥+Arrow for word-selection in text editors), `sawKeyDownDuringGesture`
    /// aborts so the toggle doesn't fire on incidental modifier use.
    private var bothModifiersHeld = false
    private var sawKeyDownDuringGesture = false

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        themePollTimer?.invalidate()
    }

    /// Install global keyboard hooks: ⌃⌥ (Control+Option pressed together,
    /// no letter) toggles the board (works from any app); Esc dismisses while
    /// the board is visible. Both rely on the Accessibility / Input Monitoring
    /// permission the app already needs for Caps Lock detection.
    ///
    /// Call once from `AppState.startOverlay` — `BoardOverlayController` is
    /// long-lived for the app's lifetime.
    func installGlobalHotkeys() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        // Local monitor catches the same shortcuts when our app happens to be
        // frontmost (NSEvent splits them across global/local). Returning the
        // event lets it propagate normally.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event)
        case .keyDown:
            // Any keypress while both modifiers are held aborts the gesture —
            // ⌃⌥+Arrow word-selection, ⌃⌥+Click for option-click-with-control,
            // etc., should NOT fire the board toggle.
            if bothModifiersHeld { sawKeyDownDuringGesture = true }
            // Esc: cancel an open editor first, otherwise dismiss the board.
            if event.keyCode == 53, isVisible {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.model.editing != nil { self.cancelEditor() } else { self.hide() }
                }
            }
        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasBoth = flags.contains([.control, .option])
        if hasBoth && !bothModifiersHeld {
            // Both modifiers just became simultaneously held — start the
            // gesture window. The toggle doesn't fire yet; we wait for
            // release to make sure no key was pressed in the interim.
            bothModifiersHeld = true
            sawKeyDownDuringGesture = false
        } else if !hasBoth && bothModifiersHeld {
            // One or both modifiers released — gesture ends. Fire only if no
            // key intercepted (i.e. this was a clean ⌃⌥-tap, not the start of
            // a longer combo like ⌃⌥+Arrow).
            bothModifiersHeld = false
            if !sawKeyDownDuringGesture {
                DispatchQueue.main.async { [weak self] in self?.toggle() }
            }
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
        model.editing = nil

        let hosting = NSHostingView(rootView: BoardOverlayView(
            model: model,
            onDismiss: { [weak self] in self?.hide() },
            onDrop: { [weak self] id, status, idx in self?.handleDrop(ticketId: id, to: status, insertIndex: idx) },
            onCreate: { [weak self] status in self?.handleCreate(in: status) },
            onEdit: { [weak self] ticket in self?.openEditor(for: ticket) },
            onCommit: { [weak self] draft in self?.commitEditor(draft) },
            onCancel: { [weak self] in self?.cancelEditor() },
            onDelete: { [weak self] ticket in self?.handleDelete(ticket) }
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
        // Cancel any open edit so reopening the board lands on a clean view.
        if model.editing != nil {
            model.editing = nil
            setPanelKeyEligible(false)
        }
        model.dragState = nil
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

    // MARK: - Editor / mutation handlers

    private func openEditor(for ticket: Ticket) {
        // Pull the full description (all paragraphs until the next heading)
        // so the editor round-trips multi-paragraph content cleanly.
        let fullDescription = TicketParser.extractFullDescription(ticket.body) ?? ""
        model.editing = TicketDraft(
            editorId: ticket.id,
            original: ticket,
            title: ticket.title,
            description: fullDescription
        )
        setPanelKeyEligible(true)
    }

    private func cancelEditor() {
        model.editing = nil
        setPanelKeyEligible(false)
    }

    private func commitEditor(_ draft: TicketDraft) {
        guard let project = ProjectResolver.resolve() else { cancelEditor(); return }
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleToSave = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        let withDescription = TicketWriter.ticket(
            draft.original,
            withDescription: draft.description
        )
        let updated = Ticket(
            id: withDescription.id,
            title: titleToSave,
            status: withDescription.status,
            priority: withDescription.priority,
            dependsOn: withDescription.dependsOn,
            runId: withDescription.runId,
            canceled: withDescription.canceled,
            order: withDescription.order,
            description: withDescription.description,
            body: withDescription.body
        )
        do {
            try TicketWriter.save(updated, in: project)
        } catch {
            NSLog("[relay-runner] failed to save ticket \(updated.id): \(error)")
        }
        model.editing = nil
        setPanelKeyEligible(false)
        model.tickets = loadTickets()

        // Auto-dispatch when the saved ticket is in `ready`. Covers
        // "create-in-ready-then-type-title": handleCreate opens the editor
        // on a fresh ticket; the worker isn't useful until the user supplies
        // a real title/description, so we wait for the save. Daemon's
        // find_active makes the call idempotent.
        if updated.status == .ready {
            OrchestratorClient.dispatchTicket(ticketId: updated.id, repoPath: project.repoPath.path)
        }
    }

    private func handleCreate(in status: Ticket.Status) {
        guard let project = ProjectResolver.resolve() else { return }
        let existing = model.tickets.filter { $0.status == status }
        let nextOrder = (existing.map(\.order).max() ?? 0) + 10
        do {
            let ticket = try TicketWriter.mint(
                in: project,
                status: status,
                title: "Untitled",
                order: nextOrder
            )
            model.tickets = loadTickets()
            openEditor(for: ticket)
        } catch {
            NSLog("[relay-runner] failed to mint ticket: \(error)")
        }
    }

    private func handleDelete(_ ticket: Ticket) {
        guard let project = ProjectResolver.resolve() else { return }
        do {
            try TicketWriter.delete(ticket.id, in: project)
        } catch {
            NSLog("[relay-runner] failed to delete ticket \(ticket.id): \(error)")
        }
        model.editing = nil
        setPanelKeyEligible(false)
        model.tickets = loadTickets()
    }

    /// Drop handler: move `ticketId` into `status` at position `insertIndex`
    /// within the sorted column. Renumbers the column's `order` values so
    /// the new layout is stable on next load.
    private func handleDrop(ticketId: String, to status: Ticket.Status, insertIndex: Int) {
        guard let project = ProjectResolver.resolve() else { return }
        guard let dragged = model.tickets.first(where: { $0.id == ticketId }) else { return }

        // Build the new column order. `insertIndex` is the index in the
        // destination column's sorted list *before* the dragged ticket is
        // inserted. If the ticket is moving within the same column, remove
        // it from the source list first; then clamp the insert index.
        var destColumn = model.tickets
            .filter { $0.status == status && $0.id != ticketId }
            .sorted { $0.order < $1.order }
        let clampedIndex = max(0, min(insertIndex, destColumn.count))
        let moved = Ticket(
            id: dragged.id,
            title: dragged.title,
            status: status,
            priority: dragged.priority,
            dependsOn: dragged.dependsOn,
            runId: dragged.runId,
            canceled: dragged.canceled,
            order: dragged.order,
            description: dragged.description,
            body: dragged.body
        )
        destColumn.insert(moved, at: clampedIndex)

        // Renumber by 10s so future inserts have headroom without renumbering
        // every neighbor on every drop.
        for (i, t) in destColumn.enumerated() {
            let newOrder = (i + 1) * 10
            if t.order == newOrder && t.status == status && t.id != ticketId { continue }
            let updated = Ticket(
                id: t.id,
                title: t.title,
                status: status,
                priority: t.priority,
                dependsOn: t.dependsOn,
                runId: t.runId,
                canceled: t.canceled,
                order: newOrder,
                description: t.description,
                body: t.body
            )
            do {
                try TicketWriter.save(updated, in: project)
            } catch {
                NSLog("[relay-runner] failed to renumber ticket \(t.id): \(error)")
            }
        }
        model.tickets = loadTickets()

        // Auto-dispatch when this drop transitioned the dragged ticket INTO
        // ready (not when reordering within ready, not when moving out of ready).
        // The daemon's find_active short-circuits repeats, so even a drag-out-
        // then-drag-back is safe, but limiting the trigger to genuine
        // backlog/in_progress/done → ready transitions keeps logs clean.
        if dragged.status != .ready && status == .ready {
            OrchestratorClient.dispatchTicket(ticketId: dragged.id, repoPath: project.repoPath.path)
        }
    }

    private func setPanelKeyEligible(_ enabled: Bool) {
        guard let panel else { return }
        panel.keyEligible = enabled
        if enabled {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.resignKey()
        }
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
