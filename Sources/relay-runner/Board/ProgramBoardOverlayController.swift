import AppKit
import SwiftUI

/// Program Board overlay. Unlike `BoardOverlayController`, this surface is
/// not scoped to `ProjectResolver.resolve()`; any ticket mutation resolves
/// through the owning child repo advertised by Program Manager status.
final class ProgramBoardOverlayController {
    enum SessionControlAction: Equatable {
        case start(String?)
        case end
    }

    private var panel: BoardOverlayPanel?
    private(set) var isVisible = false
    private weak var revealContainer: BoardRevealContainerView?
    private let model = ProgramBoardViewModel()
    private var themeResolver: (() -> ParticleFieldRenderer.Theme?)?
    private var openProjectHandler: ((String) -> Void)?
    private var loadingStateHandler: ((Bool) -> Void)?
    private var startSessionHandler: ((String?) -> Void)?
    private var endSessionHandler: (() -> Void)?
    private var sessionActiveProvider: () -> Bool = { false }
    private var workerSizingDefaultsProvider: () -> TicketWriter.WorkerSizingDefaults? = { nil }
    private var themePollTimer: Timer?
    private var statusPollTimer: Timer?

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    func setOpenProjectHandler(_ handler: @escaping (String) -> Void) {
        self.openProjectHandler = handler
    }

    func setLoadingStateHandler(_ handler: @escaping (Bool) -> Void) {
        self.loadingStateHandler = handler
    }

    func setStartSessionHandler(_ handler: @escaping (String?) -> Void) {
        self.startSessionHandler = handler
    }

    func setEndSessionHandler(_ handler: @escaping () -> Void) {
        self.endSessionHandler = handler
    }

    func setSessionActiveProvider(_ provider: @escaping () -> Bool) {
        self.sessionActiveProvider = provider
    }

    func setWorkerSizingDefaultsProvider(_ provider: @escaping () -> TicketWriter.WorkerSizingDefaults?) {
        self.workerSizingDefaultsProvider = provider
    }

    static func sessionControlAction(
        hasActiveSession: Bool,
        selectedProjectPath: String?
    ) -> SessionControlAction {
        hasActiveSession ? .end : .start(selectedProjectPath)
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
        let screen = currentMouseScreen()
        if let screen {
            p.reframe(to: screen)
        }

        let hasCachedSnapshot = model.snapshot != nil
        model.prepareForOpening()
        model.theme = themeResolver?()
        model.hasActiveSession = sessionActiveProvider()
        let reloadTask = hasCachedSnapshot ? model.refreshInBackground() : model.reload()
        if !hasCachedSnapshot {
            loadingStateHandler?(true)
        }

        let contentFrame = NSRect(origin: .zero, size: p.frame.size)
        let hosting = NSHostingView(rootView: ProgramBoardOverlayView(
            model: model,
            onDismiss: { [weak self] in self?.hide() },
            onRefresh: { [weak self] in self?.model.reload() },
            onStartSession: { [weak self] in self?.startSession() },
            onEndSession: { [weak self] in self?.endSession() },
            onOpenProject: { [weak self] repoPath in self?.openProjectHandler?(repoPath) },
            onCreateStart: { [weak self] lane in self?.beginCreate(in: lane) },
            onCreateCommit: { [weak self] request in self?.commitCreate(request) },
            onCreateCancel: { [weak self] in self?.cancelCreate() },
            onEditStart: { [weak self] detail in self?.beginEdit(detail: detail) },
            onEditCommit: { [weak self] request in self?.commitEdit(request) },
            onEditCancel: { [weak self] in self?.cancelEdit() },
            onDelete: { [weak self] request in self?.handleDelete(request) },
            onDrop: { [weak self] item, sourceLane, targetLane in
                self?.handleDrop(item: item, from: sourceLane, to: targetLane)
            }
        ))
        hosting.frame = contentFrame
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let container = BoardRevealContainerView(
            frame: contentFrame,
            contentView: hosting,
            displayGeometry: screen.map(NotchStatusDisplayGeometry.init(screen:))
                ?? NotchStatusDisplayGeometry(screenFrame: p.frame),
            startsLoading: !hasCachedSnapshot
        )
        container.autoresizingMask = [.width, .height]

        p.contentView = container
        p.orderFrontRegardless()
        panel = p
        revealContainer = container
        isVisible = true
        DispatchQueue.main.async { [weak container] in
            container?.animateReveal {}
        }

        startThemePoll()
        startStatusPoll()
        Task { @MainActor [weak self, weak container] in
            await reloadTask.value
            guard let self, self.isVisible else { return }
            container?.setLoading(false)
            if !hasCachedSnapshot {
                self.loadingStateHandler?(false)
            }
        }
    }

    func hide() {
        guard isVisible else { return }
        loadingStateHandler?(false)
        model.endDrag()
        model.cancelCreate()
        model.cancelEdit()
        setPanelKeyEligible(false)
        stopThemePoll()
        stopStatusPoll()
        isVisible = false
        let panelToDismiss = panel
        let container = revealContainer ?? panelToDismiss?.contentView as? BoardRevealContainerView
        if let container {
            container.animateDismiss { [weak self, weak panelToDismiss] in
                guard let panelToDismiss else { return }
                panelToDismiss.orderOut(nil)
                if let self, self.panel === panelToDismiss {
                    self.panel?.contentView = nil
                    self.revealContainer = nil
                }
            }
        } else {
            panelToDismiss?.orderOut(nil)
            panelToDismiss?.contentView = nil
            revealContainer = nil
        }
    }

    private func startThemePoll() {
        stopThemePoll()
        themePollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isVisible else { return }
            let next = self.themeResolver?()
            if next != self.model.theme {
                self.model.theme = next
            }
            let hasActiveSession = self.sessionActiveProvider()
            if hasActiveSession != self.model.hasActiveSession {
                self.model.hasActiveSession = hasActiveSession
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

    private func startSession() {
        guard !model.hasActiveSession else { return }
        startSessionHandler?(model.selectedSessionProjectPath)
        model.hasActiveSession = sessionActiveProvider()
    }

    private func endSession() {
        guard model.hasActiveSession else { return }
        endSessionHandler?()
        model.hasActiveSession = sessionActiveProvider()
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
            let result = try ProgramBoardTicketCreator.create(
                request,
                workerSizingDefaults: workerSizingDefaultsProvider()
            )
            model.applyTicket(result.ticket, projectPath: request.repoPath)
            if result.shouldDispatch {
                OrchestratorClient.sweepReadyTickets(
                    repoPath: request.repoPath,
                    trigger: "program-board-save"
                )
            }
        } catch {
            NSLog("[relay-runner] failed to create program ticket in \(request.repoPath): \(error)")
        }
        model.cancelCreate()
        setPanelKeyEligible(false)
        model.refreshInBackground()
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
            let result = try ProgramBoardTicketEditor.save(
                request,
                workerSizingDefaults: workerSizingDefaultsProvider()
            )
            model.applyTicket(result.ticket, projectPath: request.repoPath)
            if result.shouldDispatch {
                OrchestratorClient.sweepReadyTickets(
                    repoPath: request.repoPath,
                    trigger: "program-board-save"
                )
            }
        } catch {
            NSLog("[relay-runner] failed to save program ticket \(request.ticketID) in \(request.repoPath): \(error)")
        }
        model.cancelEdit()
        setPanelKeyEligible(false)
        model.refreshInBackground()
    }

    private func handleDelete(_ request: ProgramBoardDeleteRequest) {
        do {
            _ = try ProgramBoardTicketDeleter.delete(request)
            model.removeTicket(ticketID: request.ticketID, projectPath: request.repoPath)
        } catch {
            NSLog("[relay-runner] failed to delete program ticket \(request.ticketID) in \(request.repoPath): \(error)")
        }
        model.cancelEdit()
        model.clearSelectedTicket()
        setPanelKeyEligible(false)
        model.refreshInBackground()
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
            let result = try ProgramBoardTicketMover.move(
                unresolved,
                workerSizingDefaults: workerSizingDefaultsProvider()
            )
            model.applyTicket(result.ticket, projectPath: unresolved.repoPath)
            if let dispatch = result.dispatchRequest {
                OrchestratorClient.sweepReadyTickets(
                    repoPath: dispatch.repoPath,
                    trigger: dispatch.source
                )
            }
            model.refreshInBackground()
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
