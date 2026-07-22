import XCTest
@testable import relay_runner

final class GeneralConfigTests: XCTestCase {
    func testWorkspacePickerDismissesWorkspaceBeforePresentingPanel() {
        var events: [String] = []

        GeneralSettingsTab.pickWorkspaceDirectory(
            onOpenExternalWindow: { events.append("dismiss") },
            chooseDirectory: {
                events.append("picker")
                return URL(fileURLWithPath: "/Users/example/demo-workspace")
            },
            completion: { path in
                events.append("completion:\(path ?? "nil")")
            }
        )

        XCTAssertEqual(events, [
            "dismiss",
            "picker",
            "completion:/Users/example/demo-workspace",
        ])
    }


    func testCodexModelOptionsMatchCurrentCatalog() {
        XCTAssertEqual(
            GeneralConfig.codexModelOptions,
            [
                GeneralConfig.ModelOption(label: "Default", value: "default"),
                GeneralConfig.ModelOption(label: "GPT-5.6 Sol", value: "gpt-5.6-sol"),
                GeneralConfig.ModelOption(label: "GPT-5.6 Terra", value: "gpt-5.6-terra"),
                GeneralConfig.ModelOption(label: "GPT-5.6 Luna", value: "gpt-5.6-luna"),
                GeneralConfig.ModelOption(label: "GPT-5.5", value: "gpt-5.5"),
                GeneralConfig.ModelOption(label: "GPT-5.4", value: "gpt-5.4"),
                GeneralConfig.ModelOption(label: "GPT-5.4 Mini", value: "gpt-5.4-mini"),
                GeneralConfig.ModelOption(label: "GPT-5.3 Codex Spark", value: "gpt-5.3-codex-spark"),
            ]
        )
    }

    func testGPT56ModelsAreCodexOnlyPlanGatedOptions() {
        let models = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]

        for model in models {
            XCTAssertTrue(GeneralConfig.isModel(model, validFor: .codex))
            XCTAssertTrue(GeneralConfig.requiresLimitedPreviewAccess(model, for: .codex))
            XCTAssertFalse(GeneralConfig.isModel(model, validFor: .claude))
            XCTAssertFalse(GeneralConfig.requiresLimitedPreviewAccess(model, for: .claude))
        }
        XCTAssertEqual(
            GeneralConfig.codexPlanAccessNote,
            "GPT-5.6 models and Ultra effort depend on your Codex plan."
        )
    }

    func testClaudeModelOptionsMatchClaudeCode2175Aliases() {
        XCTAssertEqual(
            GeneralConfig.claudeModelOptions,
            [
                GeneralConfig.ModelOption(label: "Default", value: "default"),
                GeneralConfig.ModelOption(label: "Best", value: "best"),
                GeneralConfig.ModelOption(label: "Fable", value: "fable"),
                GeneralConfig.ModelOption(label: "Opus", value: "opus"),
                GeneralConfig.ModelOption(label: "Sonnet", value: "sonnet"),
                GeneralConfig.ModelOption(label: "Haiku", value: "haiku"),
            ]
        )
    }

    func testLegacyCodexReasoningEffortOptionsRemainSharedBaseValues() {
        XCTAssertEqual(
            GeneralConfig.codexReasoningEffortOptions,
            [
                GeneralConfig.ReasoningEffortOption(label: "Default", value: "default"),
                GeneralConfig.ReasoningEffortOption(label: "Low", value: "low"),
                GeneralConfig.ReasoningEffortOption(label: "Medium", value: "medium"),
                GeneralConfig.ReasoningEffortOption(label: "High", value: "high"),
                GeneralConfig.ReasoningEffortOption(label: "Extra High", value: "xhigh"),
            ]
        )
        XCTAssertFalse(
            GeneralConfig.codexReasoningEffortOptions.contains { $0.value == "max" }
        )
    }

    func testModelAwareReasoningEffortMatrixMatchesRR150() {
        let codexMatrix = Dictionary(
            uniqueKeysWithValues: GeneralConfig.modelEffortMatrix(for: .codex)
                .map { ($0.model, $0.efforts) }
        )
        XCTAssertEqual(
            codexMatrix["gpt-5.6-sol"],
            ["default", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(
            codexMatrix["gpt-5.6-terra"],
            ["default", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(
            codexMatrix["gpt-5.6-luna"],
            ["default", "low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertEqual(codexMatrix["gpt-5.5"], ["default", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(codexMatrix["gpt-5.4"], ["default", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(codexMatrix["gpt-5.4-mini"], ["default", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(codexMatrix["gpt-5.3-codex-spark"], ["default", "low", "medium", "high", "xhigh"])
        XCTAssertEqual(codexMatrix["default"], ["default"])

        let claudeMatrix = Dictionary(
            uniqueKeysWithValues: GeneralConfig.modelEffortMatrix(for: .claude)
                .map { ($0.model, $0.efforts) }
        )
        XCTAssertEqual(claudeMatrix["best"], ["default", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(claudeMatrix["fable"], ["default", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(claudeMatrix["opus"], ["default", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(claudeMatrix["sonnet"], ["default", "low", "medium", "high", "max"])
        XCTAssertEqual(claudeMatrix["haiku"], ["default"])
        XCTAssertEqual(claudeMatrix["default"], ["default"])

        XCTAssertEqual(
            GeneralConfig.normalizedOrchestratorEffort("ultra", for: .codex, model: "gpt-5.6-sol"),
            "ultra"
        )
        XCTAssertEqual(
            GeneralConfig.normalizedOrchestratorEffort("ultra", for: .codex, model: "gpt-5.6-luna"),
            GeneralConfig.defaultReasoningEffort
        )
        XCTAssertEqual(
            GeneralConfig.normalizedOrchestratorEffort("xhigh", for: .claude, model: "sonnet"),
            GeneralConfig.defaultReasoningEffort
        )
        XCTAssertEqual(GeneralConfig.normalizedOrchestratorEffort("max", for: .claude, model: "sonnet"), "max")
    }

    func testSubagentDefaultOptionsAreProviderNeutralSharedValues() {
        XCTAssertEqual(
            GeneralConfig.subagentModelOptions.map(\.value),
            ["fast", "balanced", "strong"]
        )
        XCTAssertEqual(
            GeneralConfig.subagentEffortOptions.map(\.value),
            ["low", "medium", "high", "xhigh"]
        )
        XCTAssertEqual(GeneralConfig.normalizedSubagentModel("opus"), "balanced")
        XCTAssertEqual(GeneralConfig.normalizedSubagentEffort("max"), "medium")
        XCTAssertEqual(GeneralConfig.normalizedSubagentSizingPolicy("user_default"), .userDefault)
    }

    func testLegacyCodexModelNormalizesToDefault() {
        var config = GeneralConfig()
        config.provider = .codex
        config.model = "gpt-5.2-codex"

        config.normalize(providerWasExplicit: true)

        XCTAssertEqual(config.model, GeneralConfig.defaultModel)
    }

    func testInvalidCodexReasoningEffortNormalizesToDefault() {
        var config = GeneralConfig()
        config.provider = .codex
        config.model = "gpt-5.5"
        config.codex_reasoning_effort = "max"

        config.normalize(providerWasExplicit: true)

        XCTAssertEqual(config.codex_reasoning_effort, GeneralConfig.defaultCodexReasoningEffort)
    }

    func testSelectingProviderUpdatesDefaultCommandAndModelScope() {
        var config = GeneralConfig()
        config.provider = .codex
        config.command = "codex"
        config.model = "gpt-5.6-sol"
        config.orchestrator_effort = "ultra"

        config.selectProvider(.claude)

        XCTAssertEqual(config.provider, .claude)
        XCTAssertEqual(config.command, "claude")
        XCTAssertEqual(config.model, GeneralConfig.defaultModel)
        XCTAssertEqual(config.codex_reasoning_effort, "default")
        XCTAssertEqual(config.orchestrator_effort, "default")
    }

    func testMessengerSettingsRemainProviderScoped() {
        var config = GeneralConfig()
        config.provider = .codex
        config.messenger_model = "gpt-5.6-terra"
        config.messenger_effort = "ultra"

        config.selectProvider(.claude)

        XCTAssertTrue(config.messenger_enabled)
        XCTAssertEqual(config.messenger_model, GeneralConfig.defaultMessengerModel)
        XCTAssertEqual(config.messenger_effort, GeneralConfig.defaultMessengerEffort)
        XCTAssertEqual(
            GeneralConfig.normalizedMessengerEffort("low", for: .claude, model: "sonnet"),
            "low"
        )
        XCTAssertEqual(
            GeneralConfig.normalizedMessengerEffort("low", for: .claude, model: "haiku"),
            GeneralConfig.defaultMessengerEffort
        )
    }

    func testWorkspaceFolderResolvesLegacyWorkingDirectoryValues() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(WorkspaceFolder.url(from: "", homeDirectory: home).path, "/Users/example")
        XCTAssertEqual(WorkspaceFolder.url(from: "~", homeDirectory: home).path, "/Users/example")
        XCTAssertEqual(WorkspaceFolder.url(from: "~/dev", homeDirectory: home).path, "/Users/example/dev")
        XCTAssertEqual(
            WorkspaceFolder.url(from: "/Users/example/workspace", homeDirectory: home).path,
            "/Users/example/workspace"
        )
    }

    func testWorkspaceFolderSettingsCopyAvoidsProjectOnlyLanguage() {
        XCTAssertEqual(GeneralSettingsTab.workspaceFolderLabel, "Workspace folder")
        XCTAssertTrue(GeneralSettingsTab.workspaceFolderHelpText.contains("child git repositories"))
        XCTAssertTrue(OnboardingView.workspaceFolderHelpText.contains("child git repositories"))
        XCTAssertFalse(GeneralSettingsTab.workspaceFolderHelpText.contains("always a project"))
        XCTAssertFalse(OnboardingView.workspaceFolderHelpText.contains("always a project"))
    }

    func testGeneralSettingsExposeOrchestratorAndSubagentControlLabels() {
        XCTAssertEqual(GeneralSettingsTab.orchestratorModelLabel, "Orchestrator Model")
        XCTAssertEqual(GeneralSettingsTab.orchestratorEffortLabel, "Orchestrator Effort")
        XCTAssertEqual(GeneralSettingsTab.subagentSizingLabel, "Sub-agent sizing")
        XCTAssertEqual(GeneralSettingsTab.subagentModelLabel, "Sub-agent Model")
        XCTAssertEqual(GeneralSettingsTab.subagentEffortLabel, "Sub-agent Effort")
    }
}
