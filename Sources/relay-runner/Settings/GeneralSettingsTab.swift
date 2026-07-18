import SwiftUI

struct GeneralSettingsTab: View {
    static let workspaceFolderLabel = "Workspace folder"
    static let workspaceFolderHelpText = "Start sessions in this folder. Program Manager discovers child git repositories when this is a workspace."
    static let workspaceFolderPanelMessage = "Choose the workspace folder where Relay Runner should start sessions"
    static let orchestratorModelLabel = "Orchestrator Model"
    static let orchestratorEffortLabel = "Orchestrator Effort"
    static let subagentSizingLabel = "Sub-agent sizing"
    static let subagentModelLabel = "Sub-agent Model"
    static let subagentEffortLabel = "Sub-agent Effort"

    @Binding var config: GeneralConfig
    var onOpenExternalWindow: () -> Void = {}
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

                if config.subagent_sizing_policy == .userDefault {
                    SettingsDivider()

                    SettingsControlRow(Self.subagentModelLabel) {
                        Picker(Self.subagentModelLabel, selection: subagentModelSelection) {
                            ForEach(GeneralConfig.subagentModelOptions) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                    }

                    SettingsDivider()

                    SettingsControlRow(Self.subagentEffortLabel) {
                        Picker(Self.subagentEffortLabel, selection: subagentEffortSelection) {
                            ForEach(GeneralConfig.subagentEffortOptions) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                    }
                }
            }

            SettingsSection("Workspace") {
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

            SettingsSection("Startup") {
                SettingsControlRow("Auto-start services on app launch") {
                    Toggle("Auto-start services on app launch", isOn: $config.auto_start)
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

    private var subagentModelSelection: Binding<String> {
        Binding(
            get: { config.subagent_model },
            set: { config.subagent_model = GeneralConfig.normalizedSubagentModel($0) }
        )
    }

    private var subagentEffortSelection: Binding<String> {
        Binding(
            get: { config.subagent_effort },
            set: { config.subagent_effort = GeneralConfig.normalizedSubagentEffort($0) }
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
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Self.workspaceFolderPanelMessage
        if let path = Self.pickWorkspaceDirectory(
            onOpenExternalWindow: onOpenExternalWindow,
            chooseDirectory: {
                panel.runModal() == .OK ? panel.url : nil
            }
        ) {
            config.working_directory = path
        }
    }

    static func pickWorkspaceDirectory(
        onOpenExternalWindow: () -> Void,
        chooseDirectory: () -> URL?
    ) -> String? {
        onOpenExternalWindow()
        return chooseDirectory()?.path
    }
}
