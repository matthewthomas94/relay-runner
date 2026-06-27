import XCTest
@testable import relay_runner

final class GeneralConfigTests: XCTestCase {

    func testCodexModelOptionsMatchCurrentCatalog() {
        XCTAssertEqual(
            GeneralConfig.codexModelOptions,
            [
                GeneralConfig.ModelOption(label: "Default", value: "default"),
                GeneralConfig.ModelOption(label: "GPT-5.6 Sol Preview", value: "gpt-5.6-sol"),
                GeneralConfig.ModelOption(label: "GPT-5.6 Terra Preview", value: "gpt-5.6-terra"),
                GeneralConfig.ModelOption(label: "GPT-5.6 Luna Preview", value: "gpt-5.6-luna"),
                GeneralConfig.ModelOption(label: "GPT-5.5", value: "gpt-5.5"),
                GeneralConfig.ModelOption(label: "GPT-5.4", value: "gpt-5.4"),
                GeneralConfig.ModelOption(label: "GPT-5.4-Mini", value: "gpt-5.4-mini"),
                GeneralConfig.ModelOption(label: "GPT-5.3-Codex-Spark", value: "gpt-5.3-codex-spark"),
            ]
        )
    }

    func testGPT56PreviewModelsAreCodexOnlyLimitedPreviewOptions() {
        let previewModels = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]

        for model in previewModels {
            XCTAssertTrue(GeneralConfig.isModel(model, validFor: .codex))
            XCTAssertTrue(GeneralConfig.requiresLimitedPreviewAccess(model, for: .codex))
            XCTAssertFalse(GeneralConfig.isModel(model, validFor: .claude))
            XCTAssertFalse(GeneralConfig.requiresLimitedPreviewAccess(model, for: .claude))
        }
        XCTAssertEqual(
            GeneralConfig.limitedPreviewAccessNote,
            "Limited preview access: requires an approved Codex workspace."
        )
    }

    func testClaudeModelOptionsRemainClaudeScoped() {
        XCTAssertEqual(
            GeneralConfig.claudeModelOptions,
            [
                GeneralConfig.ModelOption(label: "Default", value: "default"),
                GeneralConfig.ModelOption(label: "Opus", value: "opus"),
                GeneralConfig.ModelOption(label: "Sonnet", value: "sonnet"),
                GeneralConfig.ModelOption(label: "Haiku", value: "haiku"),
            ]
        )
    }

    func testCodexReasoningEffortOptionsMatchCurrentPublicCodexValues() {
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
        config.codex_reasoning_effort = "max"

        config.normalize(providerWasExplicit: true)

        XCTAssertEqual(config.codex_reasoning_effort, GeneralConfig.defaultCodexReasoningEffort)
    }

    func testSelectingProviderUpdatesDefaultCommandAndModelScope() {
        var config = GeneralConfig()
        config.provider = .codex
        config.command = "codex"
        config.model = "gpt-5.6-sol"
        config.codex_reasoning_effort = "high"

        config.selectProvider(.claude)

        XCTAssertEqual(config.provider, .claude)
        XCTAssertEqual(config.command, "claude")
        XCTAssertEqual(config.model, GeneralConfig.defaultModel)
        XCTAssertEqual(config.codex_reasoning_effort, "high")
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
}
