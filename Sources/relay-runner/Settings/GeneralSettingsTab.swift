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

    var body: some View {
        SettingsStack {
            SettingsSection("Agent") {
                SettingsControlRow("LLM Provider") {
                    Picker("LLM Provider", selection: providerSelection) {
                        ForEach(GeneralConfig.AgentProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
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
                    Picker(Self.orchestratorModelLabel, selection: modelSelection) {
                        ForEach(GeneralConfig.modelOptions(for: config.provider)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                }

                SettingsDivider()

                SettingsControlRow(Self.orchestratorEffortLabel) {
                    Picker(Self.orchestratorEffortLabel, selection: orchestratorEffortSelection) {
                        ForEach(GeneralConfig.reasoningEffortOptions(for: config.provider, model: config.model)) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                }
            }

            SettingsSection("Sub-agents") {
                SettingsControlRow(Self.subagentSizingLabel) {
                    Picker(Self.subagentSizingLabel, selection: $config.subagent_sizing_policy) {
                        ForEach(GeneralConfig.SubagentSizingPolicy.allCases) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
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
                            TextField(Self.workspaceFolderLabel, text: $config.working_directory, prompt: Text("~ (home)"))
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
                        description: "Adds relay-bridge and relay-stop support to Codex and Claude Code"
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
                    Text("This will replace the installed Relay Runner voice command/skill files with the default versions.")
                }
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
                SettingsDivider()
                SettingsRow {
                    Text("No projects registered. Workspace can remain empty until you add or create one.")
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.secondaryText)
                }
            } else {
                ForEach(Array(projects.enumerated()), id: \.element.projectID) { index, project in
                    SettingsDivider()
                    projectRow(project)
                }
            }

            if let statusText {
                SettingsDivider()
                SettingsRow {
                    Text(statusText)
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                do {
                    try appState.removeRegisteredProject(project.projectID)
                    statusText = "Removed \(project.displayName). Its repository and artifact history were not changed."
                    reload()
                } catch {
                    statusText = String(describing: error)
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
                Text("\(project.availability.settingsLabel) · \(project.lastResolvedPath)")
                    .font(AppTypography.font(.settingsDescription))
                    .foregroundStyle(
                        project.availability == .available
                            ? SettingsSurfaceColor.secondaryText
                            : SettingsSurfaceColor.error
                    )
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                SettingsActionButton(
                    title: "Refresh",
                    systemImage: "arrow.clockwise"
                ) {
                    do {
                        _ = try appState.refreshRegisteredProject(project.projectID)
                        statusText = nil
                    } catch {
                        statusText = String(describing: error)
                    }
                    reload()
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
        switch result {
        case .success(let project):
            statusText = "\(project.displayName) is registered and available."
        case .failure(let error):
            statusText = String(describing: error)
        }
        reload()
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
