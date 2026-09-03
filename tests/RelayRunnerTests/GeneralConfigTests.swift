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
                GeneralConfig.ModelOption(label: "Sol", value: "sol"),
                GeneralConfig.ModelOption(label: "Terra", value: "terra"),
                GeneralConfig.ModelOption(label: "Luna", value: "luna"),
            ]
        )
    }

    func testCodexFamiliesAreCodexOnlyPlanGatedOptions() {
        let models = ["sol", "terra", "luna"]

        for model in models {
            XCTAssertTrue(GeneralConfig.isModel(model, validFor: .codex))
            XCTAssertTrue(GeneralConfig.requiresLimitedPreviewAccess(model, for: .codex))
            XCTAssertFalse(GeneralConfig.isModel(model, validFor: .claude))
            XCTAssertFalse(GeneralConfig.requiresLimitedPreviewAccess(model, for: .claude))
        }
        XCTAssertEqual(
            GeneralConfig.codexPlanAccessNote,
            "Codex family availability and Ultra effort depend on your Codex plan."
        )
    }

    func testClaudeModelOptionsMatchClaudeCode2175Aliases() {
        XCTAssertEqual(
            GeneralConfig.claudeModelOptions,
            [
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
            codexMatrix["sol"],
            ["low", "medium", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(
            codexMatrix["terra"],
            ["low", "medium", "high", "xhigh", "max", "ultra"]
        )
        XCTAssertEqual(
            codexMatrix["luna"],
            ["low", "medium", "high", "xhigh", "max"]
        )
        XCTAssertNil(codexMatrix["default"])

        let claudeMatrix = Dictionary(
            uniqueKeysWithValues: GeneralConfig.modelEffortMatrix(for: .claude)
                .map { ($0.model, $0.efforts) }
        )
        XCTAssertNil(claudeMatrix["best"])
        XCTAssertEqual(claudeMatrix["fable"], ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(claudeMatrix["opus"], ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(claudeMatrix["sonnet"], ["low", "medium", "high", "max"])
        XCTAssertEqual(claudeMatrix["haiku"], ["low"])
        XCTAssertNil(claudeMatrix["default"])

        XCTAssertEqual(
            GeneralConfig.normalizedOrchestratorEffort("ultra", for: .codex, model: "sol"),
            "ultra"
        )
        XCTAssertEqual(
            GeneralConfig.normalizedOrchestratorEffort("ultra", for: .codex, model: "luna"),
            GeneralConfig.defaultOrchestratorEffort
        )
        XCTAssertEqual(
            GeneralConfig.normalizedOrchestratorEffort("xhigh", for: .claude, model: "sonnet"),
            "high"
        )
        XCTAssertEqual(GeneralConfig.normalizedOrchestratorEffort("max", for: .claude, model: "sonnet"), "max")
    }

    func testSubagentPolicyOptionsAreBinary() {
        XCTAssertEqual(
            GeneralConfig.SubagentSizingPolicy.allCases.map(\.displayName),
            ["Orchestrator decides", "Use my defaults"]
        )
        XCTAssertFalse(GeneralConfig().prevent_sleep_while_running)
        XCTAssertEqual(GeneralConfig.normalizedSubagentModel("opus"), "balanced")
        XCTAssertEqual(GeneralConfig.normalizedSubagentEffort("max"), "medium")
        XCTAssertEqual(GeneralConfig.normalizedSubagentSizingPolicy("user_default"), .userDefault)
    }

    func testLegacyCodexModelNormalizesToSol() {
        var config = GeneralConfig()
        config.provider = .codex
        config.model = "gpt-5.2-codex"

        config.normalize(providerWasExplicit: true)

        XCTAssertEqual(config.model, "sol")
    }

    func testCodexResolverSelectsNewestVisibleFamilyModel() throws {
        let resolution = try CodexModelResolver.resolve(
            family: "terra",
            effort: "default",
            catalogueData: Self.fixtureCodexCatalogue
        )

        XCTAssertEqual(resolution.selectedFamily, "terra")
        XCTAssertEqual(resolution.resolvedModel, "gpt-6.0-terra")
        XCTAssertEqual(resolution.resolvedEffort, "medium")
        XCTAssertEqual(resolution.supportedReasoningEfforts, ["low", "medium", "high", "xhigh"])
    }

    func testCodexResolverExcludesHiddenModelsAndReportsUnavailableFamilies() throws {
        XCTAssertThrowsError(
            try CodexModelResolver.resolve(
                family: "luna",
                catalogueData: Self.fixtureCodexCatalogue
            )
        ) { error in
            XCTAssertEqual(error as? CodexModelResolver.Error, .familyUnavailable("luna"))
        }
    }

    func testCodexResolverRejectsUnadvertisedEffort() throws {
        XCTAssertThrowsError(
            try CodexModelResolver.resolve(
                family: "terra",
                effort: "ultra",
                catalogueData: Self.fixtureCodexCatalogue
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexModelResolver.Error,
                .unsupportedEffort(
                    model: "gpt-6.0-terra",
                    effort: "ultra",
                    supported: ["low", "medium", "high", "xhigh"]
                )
            )
        }
    }

    func testInvalidCodexReasoningEffortNormalizesToDefault() {
        var config = GeneralConfig()
        config.provider = .codex
        config.model = "luna"
        config.codex_reasoning_effort = "ultra"

        config.normalize(providerWasExplicit: true)

        XCTAssertEqual(config.codex_reasoning_effort, GeneralConfig.defaultOrchestratorEffort)
    }

    func testSelectingProviderUpdatesDefaultCommandAndModelScope() {
        var config = GeneralConfig()
        config.provider = .codex
        config.command = "codex"
        config.model = "sol"
        config.orchestrator_effort = "ultra"

        config.selectProvider(.claude)

        XCTAssertEqual(config.provider, .claude)
        XCTAssertEqual(config.command, "claude")
        XCTAssertEqual(config.model, "opus")
        XCTAssertEqual(config.codex_reasoning_effort, "default")
        XCTAssertEqual(config.orchestrator_effort, "xhigh")
    }

    func testOrchestratorDefaultsAndLegacyValuesBecomeExplicit() {
        XCTAssertEqual(GeneralConfig().model, "sol")
        XCTAssertEqual(GeneralConfig().orchestrator_effort, "xhigh")

        var config = GeneralConfig()
        config.provider = .claude
        config.model = "best"
        config.orchestrator_effort = "default"
        config.normalize(providerWasExplicit: true, orchestratorEffortWasExplicit: true)

        XCTAssertEqual(config.model, "opus")
        XCTAssertEqual(config.orchestrator_effort, "xhigh")

        config.model = "sonnet"
        config.orchestrator_effort = "high"
        config.normalize(providerWasExplicit: true, orchestratorEffortWasExplicit: true)
        XCTAssertEqual(config.model, "sonnet")
        XCTAssertEqual(config.orchestrator_effort, "high")
    }

    func testMessengerSettingsRemainProviderScoped() {
        var config = GeneralConfig()
        config.provider = .codex
        config.messenger_model = "terra"
        config.messenger_effort = "ultra"

        config.selectProvider(.claude)

        XCTAssertTrue(config.messenger_enabled)
        XCTAssertEqual(config.messenger_model, "haiku")
        XCTAssertEqual(config.messenger_effort, GeneralConfig.defaultReasoningEffort)
        XCTAssertEqual(
            GeneralConfig.normalizedMessengerEffort("low", for: .claude, model: "sonnet"),
            "low"
        )
        XCTAssertEqual(
            GeneralConfig.normalizedMessengerEffort("low", for: .claude, model: "haiku"),
            GeneralConfig.defaultReasoningEffort
        )
    }

    func testGeneratedForegroundMessengerDefaultsMigrateToLightweightProviders() {
        var codex = GeneralConfig()
        codex.provider = .codex
        codex.messenger_model = "sol"
        codex.messenger_effort = "default"
        codex.normalize(providerWasExplicit: true)
        XCTAssertEqual(codex.messenger_model, "luna")
        XCTAssertEqual(codex.messenger_effort, "low")

        var claude = GeneralConfig()
        claude.provider = .claude
        claude.messenger_model = "best"
        claude.messenger_effort = "default"
        claude.normalize(providerWasExplicit: true)
        XCTAssertEqual(claude.messenger_model, "haiku")
        XCTAssertEqual(claude.messenger_effort, "default")

        codex.messenger_model = "sol"
        codex.messenger_effort = "high"
        codex.normalize(providerWasExplicit: true)
        XCTAssertEqual(codex.messenger_model, "sol")
        XCTAssertEqual(codex.messenger_effort, "high")
        XCTAssertEqual(
            GeneralConfig.normalizedMessengerModel("gpt-5.6-terra", for: .codex),
            "terra"
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

    func testGeneralSettingsExposeOnlyOrchestratorAndSubagentPolicyLabels() {
        XCTAssertEqual(GeneralSettingsTab.orchestratorModelLabel, "Orchestrator Model")
        XCTAssertEqual(GeneralSettingsTab.orchestratorEffortLabel, "Orchestrator Effort")
        XCTAssertEqual(GeneralSettingsTab.subagentSizingLabel, "Sub-agent sizing")
        XCTAssertEqual(GeneralSettingsTab.preventSleepLabel, "Prevent sleep while running")
        XCTAssertEqual(
            GeneralSettingsTab.preventSleepDescription,
            "Keep your computer awake while Relay Runner is running a task."
        )
    }

    private static let fixtureCodexCatalogue = """
    {
      "data": [
        {
          "id": "gpt-5.7-terra",
          "model": "gpt-5.7-terra",
          "hidden": false,
          "defaultReasoningEffort": "medium",
          "supportedReasoningEfforts": [
            {"reasoningEffort": "low"},
            {"reasoningEffort": "medium"},
            {"reasoningEffort": "high"},
            {"reasoningEffort": "xhigh"}
          ]
        },
        {
          "id": "gpt-6.0-terra",
          "model": "gpt-6.0-terra",
          "hidden": false,
          "defaultReasoningEffort": "medium",
          "supportedReasoningEfforts": [
            {"reasoningEffort": "low"},
            {"reasoningEffort": "medium"},
            {"reasoningEffort": "high"},
            {"reasoningEffort": "xhigh"}
          ]
        },
        {
          "id": "gpt-7.0-terra",
          "model": "gpt-7.0-terra",
          "hidden": false,
          "inputModalities": ["audio"],
          "defaultReasoningEffort": "low",
          "supportedReasoningEfforts": [
            {"reasoningEffort": "low"}
          ]
        },
        {
          "id": "gpt-9.0-luna",
          "model": "gpt-9.0-luna",
          "hidden": true,
          "defaultReasoningEffort": "low",
          "supportedReasoningEfforts": [
            {"reasoningEffort": "low"}
          ]
        }
      ]
    }
    """.data(using: .utf8)!
}
