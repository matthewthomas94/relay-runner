import AppKit
import SwiftUI

/// Unified Workspace overlay for single-repo and multi-repo work surfaces.
/// Ticket mutations resolve through the repo advertised by Program Manager
/// status, while project scope decides whether the Work tab shows one repo or
/// all discovered workspace repos.
final class ProgramBoardOverlayController {
    enum SessionControlAction: Equatable {
        case start(String?)
        case end
    }

    enum UtilityRouteUpgrade: Equatable {
        case none
        case workspace
    }

    struct WorkspaceOpening: Equatable {
        let showsWorkTab: Bool
        let showsTerminalTab: Bool
        let showsSettingsTab: Bool
        let initialTab: WorkspaceTab
        let projectScope: [String]
        let selectedProjectPath: String?
        let startsLoading: Bool
        let contentLoadBlocked: Bool
        let reloadsWork: Bool
    }

    private var panel: BoardOverlayPanel?
    private(set) var isVisible = false
    private(set) var isSuspendedForExternalWindow = false
    private var lastSelectedTab: WorkspaceTab = .work
    private weak var revealContainer: BoardRevealContainerView?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var updateCheckTask: Task<Void, Never>?
    private var contentLoadBlocked = false
    private let model = ProgramBoardViewModel()
    private let workspace = WorkspaceViewModel()
    private var themeResolver: (() -> ParticleFieldRenderer.Theme?)?
    private var projectScopeProvider: () -> [String] = { [] }
    private var noSessionHandler: (() -> Void)?
    private var loadingStateHandler: ((Bool) -> Void)?
    private var startSessionHandler: ((String?) -> Void)?
    private var endSessionHandler: (() -> Void)?
    private var sessionActiveProvider: () -> Bool = { false }
    private var workerSizingDefaultsProvider: () -> TicketWriter.WorkerSizingDefaults? = { nil }
    private var settingsContentProvider: (() -> AnyView?)?
    private var terminalContentProvider: ((String?) -> AnyView?)?
    private var terminalHasFocusProvider: () -> Bool = { false }
    private var terminalFocusHandler: (() -> Void)?
    private var themePollTimer: Timer?
    private var statusPollTimer: Timer?
    private let boardRouteResolver: () -> ProjectResolver.BoardRoute

    init(boardRouteResolver: @escaping () -> ProjectResolver.BoardRoute = ProjectResolver.resolveBoardRoute) {
        self.boardRouteResolver = boardRouteResolver
    }

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    func setProjectScopeProvider(_ provider: @escaping () -> [String]) {
        projectScopeProvider = provider
    }

    func setNoSessionHandler(_ handler: @escaping () -> Void) {
        self.noSessionHandler = handler
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

    func setTerminalFocusProvider(
        hasFocus: @escaping () -> Bool,
        focus: @escaping () -> Void
    ) {
        terminalHasFocusProvider = hasFocus
        terminalFocusHandler = focus
    }

    static func sessionControlAction(
        hasActiveSession: Bool,
        selectedProjectPath: String?
    ) -> SessionControlAction {
        hasActiveSession ? .end : .start(selectedProjectPath)
    }

    static func workspaceOpening(
        route: ProjectResolver.BoardRoute,
        initialTab: WorkspaceTab,
        hasTerminalTab: Bool,
        hasSettingsTab: Bool,
        hasCachedSnapshot: Bool,
        activityProjectPaths: [String]
    ) -> WorkspaceOpening? {
        let showsWorkTab: Bool
        let projectScope: [String]
        let selectedProjectPath: String?
        let requestedTab: WorkspaceTab

        switch route {
        case .project(let project):
            let path = project.repoPath.path
            showsWorkTab = true
            projectScope = [path]
            selectedProjectPath = path
            requestedTab = initialTab
        case .programBoard:
            showsWorkTab = true
            projectScope = activityProjectPaths
            selectedProjectPath = nil
            requestedTab = initialTab
        case .unavailable:
            guard hasTerminalTab || hasSettingsTab else { return nil }
            showsWorkTab = false
            projectScope = []
            selectedProjectPath = nil
            requestedTab = initialTab == .work ? .terminal : initialTab
        }

        let normalizedTab = WorkspaceViewModel.normalized(
            requestedTab,
            showsWorkTab: showsWorkTab,
            showsTerminalTab: hasTerminalTab,
            showsSettingsTab: hasSettingsTab
        )
        let blocksContent = showsWorkTab && !hasCachedSnapshot
        return WorkspaceOpening(
            showsWorkTab: showsWorkTab,
            showsTerminalTab: hasTerminalTab,
            showsSettingsTab: hasSettingsTab,
            initialTab: normalizedTab,
            projectScope: projectScope,
            selectedProjectPath: selectedProjectPath,
            startsLoading: blocksContent,
            contentLoadBlocked: blocksContent,
            reloadsWork: showsWorkTab
        )
    }

    static func utilityRouteUpgrade(
        isVisible: Bool,
        showsWorkTab: Bool,
        route: ProjectResolver.BoardRoute
    ) -> UtilityRouteUpgrade {
        guard isVisible, !showsWorkTab else { return .none }
        switch route {
        case .project, .programBoard:
            return .workspace
        case .unavailable:
            return .none
        }
    }

    func installGlobalDismissHotkey() {
        let mask: NSEvent.EventTypeMask = [.keyDown]
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                self?.handle(event)
            }
        }
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
            if event.keyCode == 53,
               isVisible,
               workspace.selectedTab.allowsEscapeDismissal(
                   terminalHasFocus: terminalHasFocusProvider()
               ) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.model.editing != nil {
                        self.cancelEdit()
                    } else if self.model.creating != nil {
                        self.cancelCreate()
                    } else {
                        self.hide()
                    }
                }
            }
        default:
            break
        }
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        updateCheckTask?.cancel()
        themePollTimer?.invalidate()
        statusPollTimer?.invalidate()
    }

    @discardableResult
    func toggle() -> Bool {
        if isVisible {
            hide()
            return true
        }
        return show()
    }

    @discardableResult
    func show() -> Bool {
        show(initialTab: lastSelectedTab)
    }

    @discardableResult
    func showWork() -> Bool {
        show(initialTab: .work)
    }

    @discardableResult
    private func show(initialTab: WorkspaceTab) -> Bool {
        if resumeAfterExternalWindow(initialTab: initialTab) { return true }
        guard !isVisible else { return true }
        let settingsContent = settingsContentProvider?()
        let route = boardRouteResolver()
        let activityProjectPaths = projectScopeProvider()
        let terminalAvailable = terminalContentProvider != nil
        let hasCachedSnapshot = model.snapshot != nil && model.projectPaths == Self.projectScope(
            for: route,
            activityProjectPaths: activityProjectPaths
        )
        guard let opening = Self.workspaceOpening(
            route: route,
            initialTab: initialTab,
            hasTerminalTab: terminalAvailable,
            hasSettingsTab: settingsContent != nil,
            hasCachedSnapshot: hasCachedSnapshot,
            activityProjectPaths: activityProjectPaths
        ) else {
            noSessionHandler?()
            return false
        }
        present(opening: opening, settingsContent: settingsContent)
        return true
    }

    private static func projectScope(
        for route: ProjectResolver.BoardRoute,
        activityProjectPaths: [String]
    ) -> [String] {
        switch route {
        case .project(let project):
            return [project.repoPath.path]
        case .programBoard:
            return activityProjectPaths
        case .unavailable:
            return []
        }
    }

    func refreshRouteIfNeeded() {
        guard isVisible, !workspace.showsWorkTab else { return }
        let route = boardRouteResolver()
        guard Self.utilityRouteUpgrade(
            isVisible: isVisible,
            showsWorkTab: workspace.showsWorkTab,
            route: route
        ) == .workspace else {
            return
        }
        let initialTab = workspace.selectedTab
        hide()
        show(initialTab: initialTab)
    }

    private func present(opening: WorkspaceOpening, settingsContent: AnyView?) {
        workspace.configure(
            showsWorkTab: opening.showsWorkTab,
            showsTerminalTab: opening.showsTerminalTab,
            showsSettingsTab: opening.showsSettingsTab,
            initialTab: opening.initialTab
        )
        lastSelectedTab = workspace.selectedTab

        let p = panel ?? BoardOverlayPanel()
        let screen = currentMouseScreen()
        if let screen {
            p.reframe(to: screen)
        }

        model.setProjectScope(opening.projectScope, selectedProjectPath: opening.selectedProjectPath)
        contentLoadBlocked = opening.contentLoadBlocked
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
            startsLoading: opening.startsLoading
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
        if opening.reloadsWork {
            checkForUpdates(inBackground: !opening.startsLoading)
        } else {
            loadingStateHandler?(false)
        }
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
        contentLoadBlocked = workspace.showsWorkTab && model.snapshot == nil
        isVisible = true
        panel.orderFrontRegardless()
        updatePanelKeyEligibility()
        startThemePoll()
        startStatusPoll()
        if workspace.showsWorkTab {
            checkForUpdates(inBackground: model.snapshot != nil)
        } else {
            loadingStateHandler?(false)
        }
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
        guard workspace.showsWorkTab else {
            contentLoadBlocked = false
            revealContainer?.setLoading(false)
            revealContainer?.setUpdateCheckActive(false)
            loadingStateHandler?(false)
            return
        }
        updateCheckTask?.cancel()
        let route = boardRouteResolver()
        let nextScope = Self.projectScope(for: route, activityProjectPaths: projectScopeProvider())
        let selectedProjectPath: String?
        switch route {
        case .project(let project):
            selectedProjectPath = project.repoPath.path
        case .programBoard:
            selectedProjectPath = model.selectedProjectPath
        case .unavailable:
            selectedProjectPath = nil
        }
        model.setProjectScope(nextScope, selectedProjectPath: selectedProjectPath)
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

    private func selectProject(_ repoPath: String) {
        model.selectProject(path: repoPath)
        selectWorkspaceTab(.work)
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
