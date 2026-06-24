import AppKit
import SwiftUI

/// Manages the kanban-board overlay lifecycle. Owns a single
/// `BoardOverlayPanel` and an `NSHostingView` rendering the SwiftUI tree.
///
/// Currently toggled from the menu, RelayActions, or the STT gesture monitor.
/// Click-outside dismissal lands in a follow-up commit.
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
    /// Polls the daemon's runs-index file while the board is visible so live
    /// run state (In-progress placement + status pills) tracks within ~1s.
    private var runStatePollTimer: Timer?
    private var currentProject: ProjectResolver.LinkedProject?

    private let boardRouteResolver: () -> ProjectResolver.BoardRoute

    init(boardRouteResolver: @escaping () -> ProjectResolver.BoardRoute = ProjectResolver.resolveBoardRoute) {
        self.boardRouteResolver = boardRouteResolver
    }

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    /// Called when the user toggles the board without an active /relay-bridge
    /// session. Wired by AppState to `stateMachine.showSessionPrompt()` so the
    /// board reuses the exact same pill the rest of the app shows when a user
    /// tries to record voice out of session — same component, same auto-dismiss,
    /// same "Double tap Option to start a new session" affordance.
    private var noSessionHandler: (() -> Void)?
    func setNoSessionHandler(_ handler: @escaping () -> Void) {
        self.noSessionHandler = handler
    }

    private var programBoardHandler: (() -> Void)?
    func setProgramBoardHandler(_ handler: @escaping () -> Void) {
        self.programBoardHandler = handler
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        themePollTimer?.invalidate()
        runStatePollTimer?.invalidate()
    }

    /// Install global keyboard hook: Esc dismisses while the board is visible.
    /// The double-tap Shift board trigger is emitted by `CapsLockGesture` so
    /// it shares the same Input Monitoring recovery path as the other global
    /// activation gestures.
    ///
    /// Call once from `AppState.startOverlay` — `BoardOverlayController` is
    /// long-lived for the app's lifetime.
    func installGlobalDismissHotkey() {
        let mask: NSEvent.EventTypeMask = [.keyDown]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
            }
        }
        // Local monitor catches the same shortcuts when our app happens to be
        // frontmost (NSEvent splits them across global/local). Returning the
        // event lets it propagate normally.
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
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

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        guard !isVisible else { return }

        // Board routing follows the active workspace/project distinction: a
        // single project opens its repo board, while a workspace root opens
        // Program Board without creating a parent `.orchestrator/`.
        let project: ProjectResolver.LinkedProject
        switch boardRouteResolver() {
        case .project(let resolvedProject):
            project = resolvedProject
        case .programBoard:
            programBoardHandler?()
            return
        case .unavailable:
            noSessionHandler?()
            return
        }
        present(project: project)
    }

    func show(project: ProjectResolver.LinkedProject) {
        if isVisible { hide() }
        present(project: project)
    }

    private func present(project: ProjectResolver.LinkedProject) {
        guard !isVisible else { return }
        currentProject = project

        let p = panel ?? BoardOverlayPanel()
        if let screen = currentMouseScreen() {
            p.reframe(to: screen)
        }

        // Refresh model from current state. Tickets get re-scanned every show;
        // theme is then kept live by the poll timer below.
        model.tickets = loadTickets()
        model.runStates = loadRunStates()
        model.theme = themeResolver?()
        model.editing = nil
        OrchestratorClient.sweepReadyTickets(repoPath: project.repoPath.path, trigger: "board-show")

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
        startRunStatePoll()
    }

    func hide() {
        guard isVisible else { return }
        // Cancel any open edit so reopening the board lands on a clean view.
        if model.editing != nil {
            cancelEditor()
        }
        model.dragState = nil
        currentProject = nil
        stopThemePoll()
        stopRunStatePoll()
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

    /// Re-read the daemon's runs-index every 0.5s (well under the ~1s budget)
    /// and push changes into the model. Only updates on actual change so an
    /// idle board doesn't churn the SwiftUI tree.
    private func startRunStatePoll() {
        stopRunStatePoll()
        runStatePollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let next = self.loadRunStates()
            if next != self.model.runStates {
                self.model.runStates = next
            }
        }
    }

    private func stopRunStatePoll() {
        runStatePollTimer?.invalidate()
        runStatePollTimer = nil
    }

    // MARK: - Editor / mutation handlers

    private func openEditor(for ticket: Ticket, isNew: Bool = false) {
        // Pull the full description (all paragraphs until the next heading)
        // so the editor round-trips multi-paragraph content cleanly.
        let fullDescription = TicketParser.extractFullDescription(ticket.body) ?? ""
        model.editing = TicketDraft(
            editorId: ticket.id,
            original: ticket,
            isNew: isNew,
            title: ticket.title,
            status: ticket.status,
            priority: ticket.priority,
            description: fullDescription,
            acceptanceCriteria: TicketParser.extractAcceptanceCriteria(ticket.body) ?? ""
        )
        setPanelKeyEligible(true)
    }

    private func cancelEditor() {
        if let draft = model.editing, draft.isNew, let project = currentProject {
            do {
                try TicketWriter.delete(draft.original.id, in: project)
            } catch {
                NSLog("[relay-runner] failed to delete new ticket draft \(draft.original.id): \(error)")
            }
            model.tickets = loadTickets()
        }
        model.editing = nil
        setPanelKeyEligible(false)
    }

    private func commitEditor(_ draft: TicketDraft) {
        guard let project = currentProject else { cancelEditor(); return }
        let trimmedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleToSave = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        let withDescription = TicketWriter.ticket(
            draft.original,
            withDescription: draft.description,
            acceptanceCriteria: draft.acceptanceCriteria
        )
        let updated = Ticket(
            id: withDescription.id,
            title: titleToSave,
            status: draft.status,
            priority: draft.priority,
            dependsOn: withDescription.dependsOn,
            runId: withDescription.runId,
            canceled: withDescription.canceled,
            draft: false,
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

        // Reconcile queued tickets after save. Covers
        // "create-in-queued-then-type-title": handleCreate opens the editor
        // on a fresh ticket; the worker isn't useful until the user supplies
        // a real title/description, so we wait for the save. The daemon skips
        // dependency-gated queued tickets until their predecessors are done.
        if updated.status == .ready && !updated.draft {
            OrchestratorClient.sweepReadyTickets(
                repoPath: project.repoPath.path,
                trigger: "board-save"
            )
        }
    }

    private func handleCreate(in status: Ticket.Status) {
        guard let project = currentProject else { return }
        do {
            let ticket = try TicketWriter.mintDraft(
                in: project,
                status: status,
                existingTickets: model.tickets,
                title: "Untitled"
            )
            model.tickets = loadTickets()
            openEditor(for: ticket, isNew: true)
        } catch {
            NSLog("[relay-runner] failed to mint ticket: \(error)")
        }
    }

    private func handleDelete(_ ticket: Ticket) {
        guard let project = currentProject else { return }
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
        guard let project = currentProject else { return }
        guard let dragged = model.tickets.first(where: { $0.id == ticketId }) else { return }

        // Build the new column order. `insertIndex` is the index in the
        // destination column's sorted list *before* the dragged ticket is
        // inserted. If the ticket is moving within the same column, remove
        // it from the source list first; then clamp the insert index.
        var destColumn = model.tickets
            .filter { $0.status == status && $0.id != ticketId }
            .sorted(by: Ticket.newestFirst)
        let clampedIndex = max(0, min(insertIndex, destColumn.count))
        let moved = Ticket(
            id: dragged.id,
            title: dragged.title,
            status: status,
            priority: dragged.priority,
            dependsOn: dragged.dependsOn,
            runId: dragged.runId,
            canceled: dragged.canceled,
            draft: dragged.draft,
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
                draft: t.draft,
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

        // Reconcile queued tickets when this drop transitioned the dragged
        // ticket INTO ready (not when reordering within ready, not when moving
        // out of ready). The daemon dispatches only dependency-satisfied
        // tickets, so dependency-gated work stays queued without a failed run.
        if dragged.status != .ready && status == .ready && !dragged.draft {
            OrchestratorClient.sweepReadyTickets(
                repoPath: project.repoPath.path,
                trigger: "board-drop"
            )
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
        guard let project = currentProject else { return [] }
        return ProjectResolver.scanTickets(in: project)
    }

    private func loadRunStates() -> [String: RunState] {
        guard let project = currentProject else { return [:] }
        return RunStateStore.load(forRepo: project.repoPath)
    }

    private func currentMouseScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        } ?? NSScreen.main
    }
}
