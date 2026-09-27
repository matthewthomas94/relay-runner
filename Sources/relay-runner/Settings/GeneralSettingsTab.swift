import SwiftUI

struct GeneralSettingsTab: View {
    static let workspaceFolderLabel = "Workspace folder"
    static let workspaceFolderHelpText = "Start sessions in this folder. Program Manager discovers child git repositories when this is a workspace."
    static let workspaceFolderPanelMessage = "Choose the workspace folder where Relay Runner should start sessions"
    static let orchestratorModelLabel = "Orchestrator Model"
    static let orchestratorEffortLabel = "Orchestrator Effort"
    static let subagentSizingLabel = "Sub-agent sizing"
    static let preventSleepLabel = "Prevent sleep while running"
    static let preventSleepDescription = "Keep your computer awake while Relay Runner is running a task."

    @Binding var config: GeneralConfig
    var onOpenExternalWindow: () -> Void = {}
    var projectRegistryAppState: AppState? = nil
    @State private var skillInstalled = ProcessManager().isSkillInstalled
    @State private var skillStatusText: String?
    @State private var skillStatusColor: SettingsSemanticColor = .idle
    @State private var showOverwriteAlert = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var claudeReadiness: ProcessManager.ClaudeSubscriptionCheck?

    var body: some View {
        SettingsStack {
            SettingsSection("Agent") {
                SettingsControlRow(
                    "LLM Provider",
                    description: Self.providerReadinessDescription(
                        provider: config.provider,
                        claudeReadiness: claudeReadiness
                    )
                ) {
                    SettingsMenuPicker(
                        "LLM Provider",
                        selection: providerSelection,
                        options: GeneralConfig.AgentProvider.allCases.map { (label: $0.displayName, value: $0) }
                    )
                }

                SettingsDivider()

                SettingsControlRow(
                    Self.orchestratorModelLabel,
                    description: GeneralConfig.accessNote(
                        for: config.model,
                        effort: config.orchestrator_effort,
                        provider: config.provider
                    )
                ) {
                    SettingsMenuPicker(
                        Self.orchestratorModelLabel,
                        selection: modelSelection,
                        options: GeneralConfig.modelOptions(for: config.provider).map { (label: $0.label, value: $0.value) }
                    )
                }

                SettingsDivider()

                SettingsControlRow(Self.orchestratorEffortLabel) {
                    SettingsMenuPicker(
                        Self.orchestratorEffortLabel,
                        selection: orchestratorEffortSelection,
                        options: GeneralConfig.reasoningEffortOptions(for: config.provider, model: config.model)
                            .map { (label: $0.label, value: $0.value) }
                    )
                }
            }

            SettingsSection("Sub-agents") {
                SettingsControlRow(Self.subagentSizingLabel) {
                    SettingsMenuPicker(
                        Self.subagentSizingLabel,
                        selection: $config.subagent_sizing_policy,
                        options: GeneralConfig.SubagentSizingPolicy.allCases.map { (label: $0.displayName, value: $0) }
                    )
                }

            }

            SettingsSection("Workspace") {
                if let projectRegistryAppState,
                   projectRegistryAppState.usesProjectRegistryV2 {
                    RegisteredProjectsSettingsView(appState: projectRegistryAppState)
                } else {
                    SettingsStackedControlRow(
                        Self.workspaceFolderLabel,
                        description: Self.workspaceFolderHelpText
                    ) {
                        HStack(spacing: 8) {
                            TextField(Self.workspaceFolderLabel, text: $config.working_directory, prompt: Text(""))
                                .appPlaceholder("~ (home)", when: config.working_directory.isEmpty, inset: 6)
                            SettingsActionButton(
                                title: "Browse\u{2026}",
                                systemImage: "folder"
                            ) {
                                pickDirectory()
                            }
                        }
                    }
                }
            }

            SettingsSection("Startup") {
                SettingsControlRow("Auto-start services on app launch") {
                    Toggle("Auto-start services on app launch", isOn: $config.auto_start)
                }

                SettingsDivider()

                SettingsControlRow(
                    Self.preventSleepLabel,
                    description: Self.preventSleepDescription
                ) {
                    Toggle(Self.preventSleepLabel, isOn: $config.prevent_sleep_while_running)
                }

                SettingsDivider()

                SettingsControlRow(
                    "Bypass agent permission prompts",
                    description: "When on, sessions launched from Relay Runner skip per-tool approval. Voice flow is much smoother, but anything the agent proposes runs without confirmation."
                ) {
                    Toggle("Bypass agent permission prompts", isOn: $config.bypass_permissions)
                }
            }

            SettingsSection("Relay Skills") {
                SettingsRow {
                    SettingsRowLabel(
                        "Relay Skills",
                        description: "Adds relay-bridge, relay-stop, relay-workflow, and relay-dispatch to Codex and Claude Code"
                    )
                    Spacer()
                    SettingsInlineStatus(
                        text: skillStatusText,
                        semanticColor: skillStatusColor,
                        reservedWidth: 150
                    )
                    SettingsActionButton(
                        title: skillInstalled ? "Reinstall" : "Install",
                        systemImage: skillInstalled ? "arrow.clockwise" : "square.and.arrow.down"
                    ) {
                        if skillInstalled {
                            showOverwriteAlert = true
                        } else {
                            doInstallSkill()
                        }
                    }
                }
                .alert("Overwrite existing skills?", isPresented: $showOverwriteAlert) {
                    Button("Overwrite", role: .destructive) { doInstallSkill() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will replace the installed Relay Runner command/skill files, including any you edited, with the default versions.")
                }
            }
        }
        .animation(
            RelayMotion.change(reduceMotion: reduceMotion),
            value: GeneralConfig.accessNote(
                for: config.model,
                effort: config.orchestrator_effort,
                provider: config.provider
            )
        )
        .task(id: config.provider) { await refreshProviderReadiness() }
    }

    /// Claude must be installed and verified on the user's subscription before
    /// a session can start, so choosing it shows that readiness here rather
    /// than as a failed session later. Codex shows nothing.
    static func providerReadinessDescription(
        provider: GeneralConfig.AgentProvider,
        claudeReadiness: ProcessManager.ClaudeSubscriptionCheck?
    ) -> String? {
        guard provider == .claude else { return nil }
        switch claudeReadiness {
        case nil:
            return "Checking your Claude subscription\u{2026}"
        case .verified:
            return "Using your Claude subscription."
        case .unavailable(let message):
            return message
        }
    }

    private func refreshProviderReadiness() async {
        claudeReadiness = nil
        guard config.provider == .claude else { return }
        let workingDirectory = WorkspaceFolder.url(from: config.working_directory).path
        claudeReadiness = await withCheckedContinuation { continuation in
            ClaudeSubscriptionMonitor.shared.refresh(workingDirectory: workingDirectory) {
                continuation.resume(returning: $0)
            }
        }
    }

    private var providerSelection: Binding<GeneralConfig.AgentProvider> {
        Binding(
            get: { config.provider },
            set: { config.selectProvider($0) }
        )
    }

    private var orchestratorEffortSelection: Binding<String> {
        Binding(
            get: { config.orchestrator_effort },
            set: {
                config.orchestrator_effort = GeneralConfig.normalizedOrchestratorEffort(
                    $0,
                    for: config.provider,
                    model: config.model
                )
                config.codex_reasoning_effort = GeneralConfig.normalizedCodexReasoningEffort(
                    config.orchestrator_effort,
                    model: config.model
                )
            }
        )
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { config.model },
            set: {
                config.model = GeneralConfig.normalizeModel($0, for: config.provider)
                config.orchestrator_effort = GeneralConfig.normalizedOrchestratorEffort(
                    config.orchestrator_effort,
                    for: config.provider,
                    model: config.model
                )
                config.codex_reasoning_effort = GeneralConfig.normalizedCodexReasoningEffort(
                    config.orchestrator_effort,
                    model: config.model
                )
            }
        )
    }

    private func doInstallSkill() {
        let pm = ProcessManager()
        if pm.installSkill() {
            skillInstalled = true
            skillStatusText = "Installed"
            skillStatusColor = .success
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                skillStatusText = nil
            }
        } else {
            skillStatusText = "Install failed"
            skillStatusColor = .error
        }
    }

    private func pickDirectory() {
        Self.pickWorkspaceDirectory(
            onOpenExternalWindow: onOpenExternalWindow,
            chooseDirectory: {
                WorkspaceDirectoryPicker.runAppKitDirectoryPanel(
                    message: Self.workspaceFolderPanelMessage
                )
            },
            completion: { path in
                if let path {
                    config.working_directory = path
                }
            }
        )
    }

    static func pickWorkspaceDirectory(
        onOpenExternalWindow: () -> Void,
        chooseDirectory: @escaping () -> URL?,
        completion: @escaping (String?) -> Void
    ) {
        WorkspaceDirectoryPicker.pick(
            message: Self.workspaceFolderPanelMessage,
            onPrepareExternalWindow: { ready in
                onOpenExternalWindow()
                ready()
            },
            chooseDirectory: chooseDirectory,
            completion: completion
        )
    }
}

private struct RegisteredProjectsSettingsView: View {
    @Bindable var appState: AppState
    @State private var projects: [RegisteredProjectV2] = []
    @State private var statusText: String?
    @State private var projectPendingRemoval: RegisteredProjectV2?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow {
                SettingsRowLabel(
                    "Registered projects",
                    description: "Sessions start only from an available project selected in Workspace. Relay Runner never uses its application-support folder as an agent workspace."
                )
                Spacer(minLength: 16)
                HStack(spacing: 8) {
                    SettingsActionButton(
                        title: "Add Existing",
                        systemImage: "folder.badge.plus"
                    ) {
                        appState.addExistingProject(resumeInSettings: true) { result in
                            handle(result)
                        }
                    }
                    SettingsActionButton(
                        title: "Create",
                        systemImage: "plus"
                    ) {
                        appState.createProject(resumeInSettings: true) { result in
                            handle(result)
                        }
                    }
                }
            }

            if projects.isEmpty {
                VStack(spacing: 0) {
                    SettingsDivider()
                    SettingsRow {
                        Text("No projects registered. Workspace can remain empty until you add or create one.")
                            .font(AppTypography.font(.settingsDescription))
                            .foregroundStyle(SettingsSurfaceColor.secondaryText)
                    }
                }
                .transition(.relayReplacing(.element))
            } else {
                ForEach(Array(projects.enumerated()), id: \.element.projectID) { index, project in
                    VStack(spacing: 0) {
                        SettingsDivider()
                        projectRow(project)
                    }
                    .transition(.relayElement)
                }
            }

            if let statusText {
                VStack(spacing: 0) {
                    SettingsDivider()
                    SettingsRow {
                        RelaySwap(statusText, style: .text, alignment: .leading) { statusText in
                            Text(statusText)
                                .font(AppTypography.font(.settingsDescription))
                                .foregroundStyle(SettingsSurfaceColor.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .transition(.relayElement)
            }
        }
        .onAppear(perform: reload)
        .alert(
            "Remove registered project?",
            isPresented: Binding(
                get: { projectPendingRemoval != nil },
                set: { if !$0 { projectPendingRemoval = nil } }
            ),
            presenting: projectPendingRemoval
        ) { project in
            Button("Remove", role: .destructive) {
                animated {
                    do {
                        try appState.removeRegisteredProject(project.projectID)
                        statusText = "Removed \(project.displayName). Its repository and artifact history were not changed."
                        reload()
                    } catch {
                        statusText = String(describing: error)
                    }
                }
                projectPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { projectPendingRemoval = nil }
        } message: { project in
            Text("Relay Runner will remove its registry entry, access grant, and derived cache for \(project.displayName). The repository is left untouched.")
        }
    }

    private func projectRow(_ project: RegisteredProjectV2) -> some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.displayName)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(SettingsSurfaceColor.primaryText)
                RelaySwap("\(project.availability.settingsLabel) · \(project.lastResolvedPath)", style: .text, alignment: .leading) { availabilityText in
                    Text(availabilityText)
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(
                            project.availability == .available
                                ? SettingsSurfaceColor.secondaryText
                                : SettingsSurfaceColor.error
                        )
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                SettingsActionButton(
                    title: "Refresh",
                    systemImage: "arrow.clockwise"
                ) {
                    animated {
                        do {
                            _ = try appState.refreshRegisteredProject(project.projectID)
                            statusText = nil
                        } catch {
                            statusText = String(describing: error)
                        }
                        reload()
                    }
                }
                SettingsActionButton(
                    title: project.availability == .accessRequiresRegrant ? "Regrant" : "Locate",
                    systemImage: "location.magnifyingglass"
                ) {
                    appState.locateRegisteredProject(project.projectID) { result in
                        handle(result)
                    }
                }
                SettingsActionButton(
                    title: "Remove",
                    systemImage: "minus.circle"
                ) {
                    projectPendingRemoval = project
                }
            }
        }
    }

    private func handle(_ result: Result<RegisteredProjectV2, Error>) {
        animated {
            switch result {
            case .success(let project):
                statusText = "\(project.displayName) is registered and available."
            case .failure(let error):
                statusText = String(describing: error)
            }
            reload()
        }
    }

    /// Row and status changes from user actions ease in; the first load on
    /// appear stays instant so the empty placeholder never flashes.
    private func animated(_ changes: () -> Void) {
        withAnimation(RelayMotion.change(reduceMotion: reduceMotion), changes)
    }

    private func reload() {
        projects = appState.registeredProjectsV2()
    }
}

private extension RegisteredProjectAvailability {
    var settingsLabel: String {
        switch self {
        case .available: return "Available"
        case .missing: return "Missing"
        case .offline: return "Offline"
        case .accessRequiresRegrant: return "Access needs regrant"
        case .identityMismatch: return "Identity mismatch"
        }
    }
}
