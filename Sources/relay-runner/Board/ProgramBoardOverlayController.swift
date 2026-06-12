import AppKit
import SwiftUI

/// Program Board overlay. Unlike `BoardOverlayController`, this surface is
/// not scoped to `ProjectResolver.resolve()`; any ticket mutation resolves
/// through the owning child repo advertised by Program Manager status.
final class ProgramBoardOverlayController {

    private var panel: BoardOverlayPanel?
    private(set) var isVisible = false
    private let model = ProgramBoardViewModel()
    private var themeResolver: (() -> ParticleFieldRenderer.Theme?)?
    private var openProjectHandler: ((String) -> Void)?
    private var themePollTimer: Timer?
    private var statusPollTimer: Timer?

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    func setOpenProjectHandler(_ handler: @escaping (String) -> Void) {
        self.openProjectHandler = handler
    }

    deinit {
        themePollTimer?.invalidate()
        statusPollTimer?.invalidate()
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

        model.theme = themeResolver?()
        model.reload()

        let hosting = NSHostingView(rootView: ProgramBoardOverlayView(
            model: model,
            onDismiss: { [weak self] in self?.hide() },
            onRefresh: { [weak self] in self?.model.reload() },
            onOpenProject: { [weak self] repoPath in self?.openProjectHandler?(repoPath) },
            onCreateStart: { [weak self] lane in self?.beginCreate(in: lane) },
            onCreateCommit: { [weak self] request in self?.commitCreate(request) },
            onCreateCancel: { [weak self] in self?.cancelCreate() },
            onEditStart: { [weak self] detail in self?.beginEdit(detail: detail) },
            onEditCommit: { [weak self] request in self?.commitEdit(request) },
            onEditCancel: { [weak self] in self?.cancelEdit() },
            onDrop: { [weak self] item, sourceLane, targetLane in
                self?.handleDrop(item: item, from: sourceLane, to: targetLane)
            }
        ))
        hosting.frame = p.frame
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        p.contentView = hosting
        p.orderFrontRegardless()
        panel = p
        isVisible = true

        startThemePoll()
        startStatusPoll()
    }

    func hide() {
        guard isVisible else { return }
        model.endDrag()
        model.cancelCreate()
        model.cancelEdit()
        setPanelKeyEligible(false)
        stopThemePoll()
        stopStatusPoll()
        panel?.orderOut(nil)
        panel?.contentView = nil
        isVisible = false
    }

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

    private func startStatusPoll() {
        stopStatusPoll()
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            guard self.model.editing == nil else { return }
            self.model.reload()
        }
    }

    private func stopStatusPoll() {
        statusPollTimer?.invalidate()
        statusPollTimer = nil
    }

    private func beginCreate(in lane: ProgramBoardLane) {
        model.beginCreate(in: lane)
        if model.creating != nil {
            setPanelKeyEligible(true)
        }
    }

    private func cancelCreate() {
        model.cancelCreate()
        setPanelKeyEligible(false)
    }

    private func commitCreate(_ request: ProgramBoardCreateRequest) {
        do {
            let result = try ProgramBoardTicketCreator.create(request)
            if result.shouldDispatch {
                OrchestratorClient.dispatchTicket(
                    ticketId: result.ticket.id,
                    repoPath: request.repoPath,
                    source: "program-board-save"
                )
            }
        } catch {
            NSLog("[relay-runner] failed to create program ticket in \(request.repoPath): \(error)")
        }
        model.cancelCreate()
        setPanelKeyEligible(false)
        model.reload()
    }

    private func beginEdit(detail: ProgramTicketDetail) {
        model.beginEdit(detail: detail)
        if model.editing != nil {
            setPanelKeyEligible(true)
        }
    }

    private func cancelEdit() {
        model.cancelEdit()
        setPanelKeyEligible(false)
    }

    private func commitEdit(_ request: ProgramBoardEditRequest) {
        do {
            let result = try ProgramBoardTicketEditor.save(request)
            if result.shouldDispatch {
                OrchestratorClient.dispatchTicket(
                    ticketId: result.ticket.id,
                    repoPath: request.repoPath,
                    source: "program-board-save"
                )
            }
        } catch {
            NSLog("[relay-runner] failed to save program ticket \(request.ticketID) in \(request.repoPath): \(error)")
        }
        model.cancelEdit()
        setPanelKeyEligible(false)
        model.reload()
    }

    private func handleDrop(
        item: ProgramStatusItem,
        from sourceLane: ProgramBoardLane,
        to targetLane: ProgramBoardLane
    ) {
        guard let unresolved = model.dropRequest(
            for: item,
            sourceLane: sourceLane,
            targetLane: targetLane
        ) else {
            return
        }

        do {
            let result = try ProgramBoardTicketMover.move(unresolved)
            if let dispatch = result.dispatchRequest {
                OrchestratorClient.dispatchTicket(
                    ticketId: dispatch.ticketID,
                    repoPath: dispatch.repoPath,
                    source: dispatch.source
                )
            }
            model.reload()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("[relay-runner] failed to move program ticket \(unresolved.ticketID): \(message)")
            model.reload()
            model.reportDropFailure(message)
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

    private func currentMouseScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        } ?? NSScreen.main
    }
}
