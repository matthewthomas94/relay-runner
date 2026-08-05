import AppKit
import QuartzCore
import SwiftUI

struct WorkspaceLatencyMetric: Equatable {
    let name: String
    let milliseconds: Int

    static func measure(
        _ name: String,
        from start: CFTimeInterval,
        to end: CFTimeInterval
    ) -> WorkspaceLatencyMetric {
        WorkspaceLatencyMetric(
            name: name,
            milliseconds: Int(((end - start) * 1000).rounded())
        )
    }

    static func duration(_ name: String, _ duration: CFTimeInterval) -> WorkspaceLatencyMetric {
        WorkspaceLatencyMetric(
            name: name,
            milliseconds: Int((duration * 1000).rounded())
        )
    }
}

private struct WorkspaceLatencyProbe {
    let recognizedAt: CFTimeInterval

    init(recognizedAt: CFTimeInterval?) {
        self.recognizedAt = recognizedAt ?? CACurrentMediaTime()
    }

    func log(_ name: String, at time: CFTimeInterval = CACurrentMediaTime()) {
        let metric = WorkspaceLatencyMetric.measure(name, from: recognizedAt, to: time)
        NSLog("[relay-runner] Workspace latency \(metric.name)=\(metric.milliseconds)ms")
    }

    func logDuration(_ name: String, duration: CFTimeInterval) {
        let metric = WorkspaceLatencyMetric.duration(name, duration)
        NSLog("[relay-runner] Workspace animation \(metric.name)=\(metric.milliseconds)ms")
    }
}

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
    private var resumesExternalWindowWithAnimation = false
    private var dismissInFlight = false
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
    private var addExistingProjectHandler: (() -> Void)?
    private var createProjectHandler: (() -> Void)?
    private var startSessionHandler: ((String?) -> Void)?
    private var endSessionHandler: (() -> Void)?
    private var sessionActiveProvider: () -> Bool = { false }
    private var requiresConfirmedProjectProvider: () -> Bool = {
        ProjectRegistryV2Rollout.isEnabled()
    }
    private var projectScopeTokenProvider: (String) -> String? = { _ in nil }
    private var workerSizingDefaultsProvider: () -> TicketWriter.WorkerSizingDefaults? = { nil }
    private var settingsContentProvider: (() -> AnyView?)?
    private var terminalContentProvider: ((String?) -> AnyView?)?
    private var terminalHasFocusProvider: () -> Bool = { false }
    private var terminalFocusHandler: (() -> Void)?
    private var themePollTimer: Timer?
    private var statusPollTimer: Timer?
    private var boardRouteResolver: () -> ProjectResolver.BoardRoute

    init(boardRouteResolver: @escaping () -> ProjectResolver.BoardRoute = ProjectResolver.resolveBoardRoute) {
        self.boardRouteResolver = boardRouteResolver
    }

    func setThemeResolver(_ resolver: @escaping () -> ParticleFieldRenderer.Theme?) {
        self.themeResolver = resolver
    }

    func setProjectScopeProvider(_ provider: @escaping () -> [String]) {
        projectScopeProvider = provider
    }

    func setBoardRouteResolver(_ resolver: @escaping () -> ProjectResolver.BoardRoute) {
        boardRouteResolver = resolver
    }

    func setNoSessionHandler(_ handler: @escaping () -> Void) {
        self.noSessionHandler = handler
    }

    func setLoadingStateHandler(_ handler: @escaping (Bool) -> Void) {
        self.loadingStateHandler = handler
    }

    func setProjectManagementHandlers(
        addExisting: @escaping () -> Void,
        create: @escaping () -> Void
    ) {
        addExistingProjectHandler = addExisting
        createProjectHandler = create
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

    func setRequiresConfirmedProjectProvider(_ provider: @escaping () -> Bool) {
        requiresConfirmedProjectProvider = provider
    }

    func setProjectScopeTokenProvider(_ provider: @escaping (String) -> String?) {
        projectScopeTokenProvider = provider
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
        activityProjectPaths: [String],
        showsRegisteredProjectCatalog: Bool = false
    ) -> WorkspaceOpening? {
        let showsWorkTab: Bool
        let projectScope: [String]
        let selectedProjectPath: String?
        let requestedTab: WorkspaceTab

        switch route {
        case .project(let project):
            let path = project.repoPath.path
            showsWorkTab = true
            projectScope = Self.projectScope(
                for: route,
                activityProjectPaths: activityProjectPaths,
                showsRegisteredProjectCatalog: showsRegisteredProjectCatalog
            )
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
        model.cancelReload()
        themePollTimer?.invalidate()
        statusPollTimer?.invalidate()
    }

    @discardableResult
    func toggle(recognizedAt: CFTimeInterval? = nil) -> Bool {
        if isVisible {
            hide(recognizedAt: recognizedAt)
            return true
        }
        return show(recognizedAt: recognizedAt)
    }

    @discardableResult
    func show(recognizedAt: CFTimeInterval? = nil) -> Bool {
        show(initialTab: lastSelectedTab, recognizedAt: recognizedAt)
    }

    @discardableResult
    func showWork() -> Bool {
        show(initialTab: .work)
    }

    @discardableResult
    private func show(
        initialTab: WorkspaceTab,
        recognizedAt: CFTimeInterval? = nil
    ) -> Bool {
        if resumeAfterExternalWindow(initialTab: initialTab) { return true }
        guard !isVisible else { return true }
        let probe = WorkspaceLatencyProbe(recognizedAt: recognizedAt)
        let settingsContent = settingsContentProvider?()
        let route = boardRouteResolver()
        let activityProjectPaths = projectScopeProvider()
        let showsRegisteredProjectCatalog = requiresConfirmedProjectProvider()
        let terminalAvailable = terminalContentProvider != nil
        let hasCachedSnapshot = model.snapshot != nil && model.projectPaths == Self.projectScope(
            for: route,
            activityProjectPaths: activityProjectPaths,
            showsRegisteredProjectCatalog: showsRegisteredProjectCatalog
        )
        guard let opening = Self.workspaceOpening(
            route: route,
            initialTab: initialTab,
            hasTerminalTab: terminalAvailable,
            hasSettingsTab: settingsContent != nil,
            hasCachedSnapshot: hasCachedSnapshot,
            activityProjectPaths: activityProjectPaths,
            showsRegisteredProjectCatalog: showsRegisteredProjectCatalog
        ) else {
            noSessionHandler?()
            return false
        }
        present(opening: opening, settingsContent: settingsContent, probe: probe)
        return true
    }

    private static func projectScope(
        for route: ProjectResolver.BoardRoute,
        activityProjectPaths: [String],
        showsRegisteredProjectCatalog: Bool
    ) -> [String] {
        switch route {
        case .project(let project):
            let activePath = project.repoPath.path
            if showsRegisteredProjectCatalog,
               activityProjectPaths.contains(activePath) {
                return activityProjectPaths
            }
            return [activePath]
        case .programBoard:
            return activityProjectPaths
        case .unavailable:
            return []
        }
    }

    static func refreshedProjectSelection(
        route: ProjectResolver.BoardRoute,
        currentSelection: String?,
        projectScope: [String]
    ) -> String? {
        if let currentSelection, projectScope.contains(currentSelection) {
            return currentSelection
        }
        if case .project(let project) = route {
            return project.repoPath.path
        }
        return nil
    }

    func refreshProjectScopeAfterRegistryChange() {
        guard isVisible else { return }
        guard workspace.showsWorkTab else {
            refreshRouteIfNeeded()
            return
        }
        updateCheckTask?.cancel()
        updateCheckTask = nil
        model.cancelReload()
        checkForUpdates(
            inBackground: model.snapshot != nil,
            preserveProjectSelection: false
        )
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

    private func present(
        opening: WorkspaceOpening,
        settingsContent: AnyView?,
        probe: WorkspaceLatencyProbe
    ) {
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
        let displayGeometry = screen.map(NotchStatusDisplayGeometry.init(screen:))
            ?? NotchStatusDisplayGeometry(screenFrame: p.frame)
        let container: BoardRevealContainerView
        if !dismissInFlight,
           let cachedContainer = p.contentView as? BoardRevealContainerView,
           cachedContainer.canReuse(displayGeometry: displayGeometry) {
            cachedContainer.prepareForOpening(startsLoading: opening.startsLoading)
            container = cachedContainer
        } else {
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
                onAddExistingProject: { [weak self] in self?.addExistingProjectHandler?() },
                onCreateProject: { [weak self] in self?.createProjectHandler?() },
                onStartSession: { [weak self] in self?.startSession() },
                onEndSession: { [weak self] in self?.endSession() },
                onCreateStart: { [weak self] lane in self?.beginCreate(in: lane) },
                onCreateCommit: { [weak self] request in self?.commitCreate(request) },
                onCreateCancel: { [weak self] in self?.cancelCreate() },
                onEditStart: { [weak self] detail in self?.beginEdit(detail: detail) },
                onEditCommit: { [weak self] request in self?.commitEdit(request) },
                onEditCancel: { [weak self] in self?.cancelEdit() },
                onDelete: { [weak self] request in self?.handleDelete(request) },
                onSpikeFollowupStart: { [weak self] detail in self?.beginSpikeFollowups(detail) },
                onSpikeFollowupReview: { [weak self] batch, proposal, decision, updates in
                    self?.reviewSpikeFollowup(
                        batch: batch,
                        proposal: proposal,
                        decision: decision,
                        updates: updates
                    )
                },
                onSpikeFollowupClose: { [weak self] in self?.model.spikeFollowupBatch = nil },
                onDrop: { [weak self] item, sourceLane, targetLane in
                    self?.handleDrop(item: item, from: sourceLane, to: targetLane)
                }
            ))
            hosting.frame = contentFrame
            hosting.autoresizingMask = [.width, .height]
            hosting.layer?.backgroundColor = NSColor.clear.cgColor

            container = BoardRevealContainerView(
                frame: contentFrame,
                contentView: hosting,
                displayGeometry: displayGeometry,
                startsLoading: opening.startsLoading
            )
            container.autoresizingMask = [.width, .height]
            p.contentView = container
        }
        p.orderFrontRegardless()
        probe.log("command_to_first_visible_shell")
        probe.logDuration(
            "reveal_duration",
            duration: BoardRevealTransitionTiming.revealAnimationDuration
        )
        panel = p
        revealContainer = container
        dismissInFlight = false
        isVisible = true
        updatePanelKeyEligibility()
        DispatchQueue.main.async { [weak container] in
            container?.animateReveal(
                firstMotion: {
                    probe.log("command_to_first_motion")
                },
                completion: {
                    probe.log("command_to_interactive_content")
                }
            )
        }

        startThemePoll()
        startStatusPoll()
        if opening.reloadsWork {
            checkForUpdates(inBackground: true)
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
        suspendForExternalWindow(animated: false, completion: {})
    }

    func suspendForExternalWindowAnimated(completion: @escaping () -> Void) {
        suspendForExternalWindow(animated: true, completion: completion)
    }

    private func suspendForExternalWindow(
        animated: Bool,
        completion: @escaping () -> Void
    ) {
        guard isVisible else {
            completion()
            return
        }
        updateCheckTask?.cancel()
        updateCheckTask = nil
        model.cancelReload()
        loadingStateHandler?(false)
        revealContainer?.setUpdateCheckActive(false)
        revealContainer?.setLoading(false)
        lastSelectedTab = workspace.selectedTab
        setPanelKeyEligible(false)
        stopThemePoll()
        stopStatusPoll()
        isVisible = false
        isSuspendedForExternalWindow = true
        resumesExternalWindowWithAnimation = animated

        let panelToDismiss = panel
        let container = revealContainer ?? panelToDismiss?.contentView as? BoardRevealContainerView
        guard animated, let container else {
            panelToDismiss?.orderOut(nil)
            dismissInFlight = false
            completion()
            return
        }

        dismissInFlight = true
        container.animateDismiss(
            firstMotion: {},
            completion: { [weak self, weak panelToDismiss] in
                panelToDismiss?.orderOut(nil)
                self?.dismissInFlight = false
                completion()
            }
        )
    }

    private func resumeAfterExternalWindow(initialTab: WorkspaceTab) -> Bool {
        guard isSuspendedForExternalWindow,
              let panel,
              panel.contentView != nil else { return false }

        let animated = resumesExternalWindowWithAnimation
        isSuspendedForExternalWindow = false
        resumesExternalWindowWithAnimation = false
        workspace.select(initialTab)
        lastSelectedTab = workspace.selectedTab
        model.theme = themeResolver?()
        model.hasActiveSession = sessionActiveProvider()
        contentLoadBlocked = workspace.showsWorkTab && model.snapshot == nil
        let container = revealContainer ?? panel.contentView as? BoardRevealContainerView
        if animated, let container {
            container.prepareForOpening(startsLoading: contentLoadBlocked)
        }
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
        if animated, let container {
            DispatchQueue.main.async {
                container.animateReveal(firstMotion: {}, completion: {})
            }
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

    func hide(recognizedAt: CFTimeInterval? = nil) {
        guard isVisible else { return }
        let probe = WorkspaceLatencyProbe(recognizedAt: recognizedAt)
        probe.logDuration(
            "dismiss_duration",
            duration: BoardRevealTransitionTiming.dismissAnimationDuration
        )
        updateCheckTask?.cancel()
        updateCheckTask = nil
        model.cancelReload()
        contentLoadBlocked = false
        revealContainer?.setLoading(false)
        revealContainer?.setUpdateCheckActive(false)
        loadingStateHandler?(false)
        model.endDrag()
        model.cancelCreate()
        model.cancelEdit()
        setPanelKeyEligible(false)
        stopThemePoll()
        stopStatusPoll()
        isVisible = false
        dismissInFlight = true
        let panelToDismiss = panel
        let container = revealContainer ?? panelToDismiss?.contentView as? BoardRevealContainerView
        if let container {
            container.animateDismiss(
                firstMotion: {
                    probe.log("command_to_first_motion")
                },
                completion: { [weak self, weak panelToDismiss] in
                    guard let panelToDismiss else { return }
                    if let self, self.revealContainer !== container { return }
                    panelToDismiss.orderOut(nil)
                    probe.log("command_to_hidden")
                    if let self, self.panel === panelToDismiss {
                        self.dismissInFlight = false
                    }
                }
            )
        } else {
            panelToDismiss?.orderOut(nil)
            probe.log("command_to_hidden")
            revealContainer = nil
            dismissInFlight = false
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

    private func checkForUpdates(
        inBackground: Bool,
        preserveProjectSelection: Bool = true
    ) {
        guard workspace.showsWorkTab else {
            contentLoadBlocked = false
            revealContainer?.setLoading(false)
            revealContainer?.setUpdateCheckActive(false)
            loadingStateHandler?(false)
            return
        }
        guard !model.hasReloadInFlight else { return }
        let route = boardRouteResolver()
        let nextScope = Self.projectScope(
            for: route,
            activityProjectPaths: projectScopeProvider(),
            showsRegisteredProjectCatalog: requiresConfirmedProjectProvider()
        )
        let selectedProjectPath = Self.refreshedProjectSelection(
            route: route,
            currentSelection: preserveProjectSelection ? model.selectedProjectPath : nil,
            projectScope: nextScope
        )
        model.setProjectScope(nextScope, selectedProjectPath: selectedProjectPath)
        if contentLoadBlocked {
            revealContainer?.setLoading(true)
        } else {
            revealContainer?.setUpdateCheckActive(true)
        }
        loadingStateHandler?(true)

        guard let reloadTask = model.reloadIfIdle(inBackground: inBackground) else {
            return
        }
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
        guard !requiresConfirmedProjectProvider()
                || model.selectedSessionProjectPath != nil else { return }
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
                workerSizingDefaults: workerSizingDefaultsProvider(),
                projectScopeToken: projectScopeTokenProvider(request.repoPath)
            )
            model.applyTicket(result.ticket, projectPath: request.repoPath)
            if result.shouldDispatch {
                OrchestratorClient.sweepReadyTickets(
                    repoPath: request.repoPath,
                    trigger: "program-board-save",
                    projectScopeToken: projectScopeTokenProvider(request.repoPath)
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

    private func beginSpikeFollowups(_ detail: ProgramTicketDetail) {
        guard let identity = detail.identity,
              let runID = detail.ticket?.runId else { return }
        Task { @MainActor [weak self] in
            do {
                self?.model.spikeFollowupBatch = try await OrchestratorClient.proposeSpikeFollowups(
                    originRepoPath: identity.projectPath,
                    originTicketID: identity.ticketID,
                    originRunID: runID
                )
            } catch {
                self?.model.errorMessage = "Could not propose spike follow-ups: \(error.localizedDescription)"
            }
        }
    }

    private func reviewSpikeFollowup(
        batch: SpikeFollowupBatch,
        proposal: SpikeFollowupProposal,
        decision: String,
        updates: [String: Any]?
    ) {
        Task { @MainActor [weak self] in
            do {
                self?.model.spikeFollowupBatch = try await OrchestratorClient.reviewSpikeFollowup(
                    batchID: batch.id,
                    proposalID: proposal.id,
                    decision: decision,
                    updates: updates
                )
                if decision == "accept" {
                    self?.checkForUpdates(inBackground: true)
                }
            } catch {
                self?.model.errorMessage = "Could not review spike follow-up: \(error.localizedDescription)"
            }
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
                workerSizingDefaults: workerSizingDefaultsProvider(),
                projectScopeToken: projectScopeTokenProvider(request.repoPath)
            )
            model.applyTicket(result.ticket, projectPath: request.repoPath)
            if result.shouldDispatch {
                OrchestratorClient.sweepReadyTickets(
                    repoPath: request.repoPath,
                    trigger: "program-board-save",
                    projectScopeToken: projectScopeTokenProvider(request.repoPath)
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
            _ = try ProgramBoardTicketDeleter.delete(
                request,
                projectScopeToken: projectScopeTokenProvider(request.repoPath)
            )
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
                workerSizingDefaults: workerSizingDefaultsProvider(),
                projectScopeToken: projectScopeTokenProvider(unresolved.repoPath)
            )
            model.applyTicket(result.ticket, projectPath: unresolved.repoPath)
            if let dispatch = result.dispatchRequest {
                OrchestratorClient.sweepReadyTickets(
                    repoPath: dispatch.repoPath,
                    trigger: dispatch.source,
                    projectScopeToken: projectScopeTokenProvider(dispatch.repoPath)
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
