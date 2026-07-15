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
    private(set) var isSuspendedForExternalWindow = false
    private var lastSelectedTab: WorkspaceTab = .work
    private weak var revealContainer: BoardRevealContainerView?
    private var updateCheckTask: Task<Void, Never>?
    private var contentLoadBlocked = false
    private let model = ProgramBoardViewModel()
    private let workspace = WorkspaceViewModel()
    private var themeResolver: (() -> ParticleFieldRenderer.Theme?)?
    private var openProjectHandler: ((String) -> Void)?
    private var projectScopeProvider: () -> [String] = { [] }
    private var loadingStateHandler: ((Bool) -> Void)?
    private var startSessionHandler: ((String?) -> Void)?
    private var endSessionHandler: (() -> Void)?
    private var sessionActiveProvider: () -> Bool = { false }
    private var workerSizingDefaultsProvider: () -> TicketWriter.WorkerSizingDefaults? = { nil }
    private var settingsContentProvider: (() -> AnyView?)?
    private var terminalContentProvider: ((String?) -> AnyView?)?
    private var terminalFocusHandler: (() -> Void)?
    private var themePollTimer: Timer?
    private var statusPollTimer: Timer?

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    func setOpenProjectHandler(_ handler: @escaping (String) -> Void) {
        self.openProjectHandler = handler
    }

    func setProjectScopeProvider(_ provider: @escaping () -> [String]) {
        projectScopeProvider = provider
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

    func setSettingsContentProvider(_ provider: @escaping () -> AnyView?) {
        self.settingsContentProvider = provider
    }

    func setTerminalContentProvider(_ provider: @escaping (String?) -> AnyView?) {
        terminalContentProvider = provider
    }

    func setTerminalFocusHandler(_ handler: @escaping () -> Void) {
        terminalFocusHandler = handler
    }

    static func sessionControlAction(
        hasActiveSession: Bool,
        selectedProjectPath: String?
    ) -> SessionControlAction {
        hasActiveSession ? .end : .start(selectedProjectPath)
    }

    deinit {
        updateCheckTask?.cancel()
        themePollTimer?.invalidate()
        statusPollTimer?.invalidate()
    }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        show(initialTab: lastSelectedTab)
    }

    private func show(initialTab: WorkspaceTab) {
        if resumeAfterExternalWindow(initialTab: initialTab) { return }
        guard !isVisible else { return }
        let settingsContent = settingsContentProvider?()
        workspace.configure(
            showsWorkTab: true,
            showsTerminalTab: terminalContentProvider != nil,
            showsSettingsTab: settingsContent != nil,
            initialTab: initialTab
        )
        lastSelectedTab = workspace.selectedTab

        let p = panel ?? BoardOverlayPanel()
        let screen = currentMouseScreen()
        if let screen {
            p.reframe(to: screen)
        }

        model.setProjectScope(projectScopeProvider())
        let hasCachedSnapshot = model.snapshot != nil
        contentLoadBlocked = !hasCachedSnapshot
        model.prepareForOpening()
        model.theme = themeResolver?()
        model.hasActiveSession = sessionActiveProvider()

        let contentFrame = NSRect(origin: .zero, size: p.frame.size)
        let hosting = NSHostingView(rootView: ProgramBoardOverlayView(
            model: model,
            workspace: workspace,
            settingsContent: settingsContent,
            terminalContent: { [weak self] projectPath in
                self?.terminalContentProvider?(projectPath)
            },
            onDismiss: { [weak self] in self?.hide() },
            onWorkspaceTabChange: { [weak self] tab in self?.workspaceTabDidChange(tab) },
            onRefresh: { [weak self] in self?.checkForUpdates(inBackground: false) },
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
        updatePanelKeyEligibility()
        DispatchQueue.main.async { [weak container] in
            container?.animateReveal {}
        }

        startThemePoll()
        startStatusPoll()
        checkForUpdates(inBackground: hasCachedSnapshot)
    }

    func showSettings() {
        guard settingsContentProvider != nil else { return }
        if isVisible {
            selectWorkspaceTab(.systemSettings)
        } else {
            show(initialTab: .systemSettings)
        }
    }

    func showTerminal() {
        if isVisible {
            selectWorkspaceTab(.terminal)
        } else {
            show(initialTab: .terminal)
        }
    }

    func suspendForExternalWindow() {
        guard isVisible else { return }
        updateCheckTask?.cancel()
        updateCheckTask = nil
        loadingStateHandler?(false)
        revealContainer?.setUpdateCheckActive(false)
        lastSelectedTab = workspace.selectedTab
        setPanelKeyEligible(false)
        stopThemePoll()
        stopStatusPoll()
        isVisible = false
        isSuspendedForExternalWindow = true
        panel?.orderOut(nil)
    }

    private func resumeAfterExternalWindow(initialTab: WorkspaceTab) -> Bool {
        guard isSuspendedForExternalWindow,
              let panel,
              panel.contentView != nil else { return false }

        isSuspendedForExternalWindow = false
        workspace.select(initialTab)
        lastSelectedTab = workspace.selectedTab
        model.theme = themeResolver?()
        model.hasActiveSession = sessionActiveProvider()
        contentLoadBlocked = model.snapshot == nil
        isVisible = true
        panel.orderFrontRegardless()
        updatePanelKeyEligibility()
        startThemePoll()
        startStatusPoll()
        checkForUpdates(inBackground: model.snapshot != nil)
        return true
    }

    private func selectWorkspaceTab(_ tab: WorkspaceTab) {
        workspace.select(tab)
        workspaceTabDidChange(workspace.selectedTab)
    }

    private func workspaceTabDidChange(_ tab: WorkspaceTab) {
        lastSelectedTab = tab
        updatePanelKeyEligibility()
    }

    func hide() {
        guard isVisible else { return }
        updateCheckTask?.cancel()
        updateCheckTask = nil
        contentLoadBlocked = false
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
                if let self, self.revealContainer !== container { return }
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
            self.checkForUpdates(inBackground: false)
        }
    }

    private func stopStatusPoll() {
        statusPollTimer?.invalidate()
        statusPollTimer = nil
    }

    private func checkForUpdates(inBackground: Bool) {
        updateCheckTask?.cancel()
        model.setProjectScope(projectScopeProvider())
        if contentLoadBlocked {
            revealContainer?.setLoading(true)
        } else {
            revealContainer?.setUpdateCheckActive(true)
        }
        loadingStateHandler?(true)

        let reloadTask = inBackground ? model.refreshInBackground() : model.reload()
        let blocksContent = contentLoadBlocked
        updateCheckTask = Task { @MainActor [weak self] in
            await reloadTask.value
            guard !Task.isCancelled, let self else { return }
            self.updateCheckTask = nil
            guard self.isVisible else { return }

            if blocksContent {
                self.contentLoadBlocked = false
                self.revealContainer?.setLoading(false)
            } else {
                self.revealContainer?.setUpdateCheckActive(false)
            }
            self.loadingStateHandler?(false)
        }
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
            updatePanelKeyEligibility()
        }
    }

    private func cancelCreate() {
        model.cancelCreate()
        updatePanelKeyEligibility()
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
        updatePanelKeyEligibility()
        checkForUpdates(inBackground: true)
    }

    private func beginEdit(detail: ProgramTicketDetail) {
        model.beginEdit(detail: detail)
        if model.editing != nil {
            updatePanelKeyEligibility()
        }
    }

    private func cancelEdit() {
        model.cancelEdit()
        updatePanelKeyEligibility()
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
        updatePanelKeyEligibility()
        checkForUpdates(inBackground: true)
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
        updatePanelKeyEligibility()
        checkForUpdates(inBackground: true)
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
            checkForUpdates(inBackground: true)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            NSLog("[relay-runner] failed to move program ticket \(unresolved.ticketID): \(message)")
            checkForUpdates(inBackground: false)
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

    private func updatePanelKeyEligibility() {
        setPanelKeyEligible(
            model.creating != nil || model.editing != nil || workspace.selectedTab.requiresKeyWindow
        )
        if workspace.selectedTab == .terminal {
            DispatchQueue.main.async { [weak self] in
                self?.terminalFocusHandler?()
            }
        }
    }

    private func currentMouseScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        } ?? NSScreen.main
    }
}
