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
    @State private var skillInstalled = ProcessManager().isSkillInstalled
    @State private var showSkillSuccess = false
    @State private var showOverwriteAlert = false

    var body: some View {
        Form {
            Picker("LLM Provider", selection: providerSelection) {
                ForEach(GeneralConfig.AgentProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker(Self.orchestratorModelLabel, selection: $config.model) {
                    ForEach(GeneralConfig.modelOptions(for: config.provider)) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                if GeneralConfig.requiresLimitedPreviewAccess(config.model, for: config.provider) {
                    Text(GeneralConfig.limitedPreviewAccessNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker(Self.orchestratorEffortLabel, selection: orchestratorEffortSelection) {
                ForEach(GeneralConfig.reasoningEffortOptions(for: config.provider)) { option in
                    Text(option.label).tag(option.value)
                }
            }

            Picker(Self.subagentSizingLabel, selection: $config.subagent_sizing_policy) {
                ForEach(GeneralConfig.SubagentSizingPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }

            if config.subagent_sizing_policy == .userDefault {
                Picker(Self.subagentModelLabel, selection: subagentModelSelection) {
                    ForEach(GeneralConfig.subagentModelOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }

                Picker(Self.subagentEffortLabel, selection: subagentEffortSelection) {
                    ForEach(GeneralConfig.subagentEffortOptions) { option in
                        Text(option.label).tag(option.value)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(Self.workspaceFolderLabel)
                HStack {
                    TextField(Self.workspaceFolderLabel, text: $config.working_directory, prompt: Text("~ (home)"))
                    Button("Browse\u{2026}") { pickDirectory() }
                }
                Text(Self.workspaceFolderHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Auto-start services on app launch", isOn: $config.auto_start)

            Toggle(isOn: $config.bypass_permissions) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bypass agent permission prompts")
                    Text("When on, sessions launched from Relay Runner skip per-tool approval. Voice flow is much smoother, but anything the agent proposes runs without confirmation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Relay Skills")
                    Text("Adds relay-bridge and relay-stop support to Codex and Claude Code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if showSkillSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Button(skillInstalled ? "Reinstall" : "Install") {
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
                    for: config.provider
                )
                config.codex_reasoning_effort = GeneralConfig.normalizedCodexReasoningEffort(
                    config.orchestrator_effort
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
            showSkillSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                showSkillSuccess = false
            }
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Self.workspaceFolderPanelMessage
        if panel.runModal() == .OK, let url = panel.url {
            config.working_directory = url.path
        }
    }
}
