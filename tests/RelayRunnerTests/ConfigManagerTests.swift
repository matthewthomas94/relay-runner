import Foundation
import XCTest
@testable import relay_runner

final class ConfigManagerTests: XCTestCase {

    func testOrchestratorAndSubagentSettingsPersistThroughConfigManager() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        var config = AppConfig()
        config.general.provider = .claude
        config.general.model = "fable"
        config.general.orchestrator_effort = "max"
        config.general.codex_reasoning_effort = GeneralConfig.normalizedCodexReasoningEffort(
            config.general.orchestrator_effort,
            model: config.general.model
        )
        config.general.subagent_sizing_policy = .userDefault
        config.general.subagent_model = "strong"
        config.general.subagent_effort = "xhigh"
        config.general.messenger_enabled = false
        config.general.messenger_model = "sonnet"
        config.general.messenger_effort = "low"

        try manager.save(config)
        let raw = try String(contentsOf: manager.configPath, encoding: .utf8)
        let loaded = manager.load()

        XCTAssertTrue(raw.contains("orchestrator_effort = \"max\""))
        XCTAssertTrue(raw.contains("codex_reasoning_effort = \"default\""))
        XCTAssertTrue(raw.contains("subagent_sizing_policy = \"user_default\""))
        XCTAssertTrue(raw.contains("messenger_enabled = false"))
        XCTAssertTrue(raw.contains("messenger_model = \"sonnet\""))
        XCTAssertEqual(loaded.general.provider, .claude)
        XCTAssertEqual(loaded.general.model, "fable")
        XCTAssertEqual(loaded.general.orchestrator_effort, "max")
        XCTAssertEqual(loaded.general.codex_reasoning_effort, GeneralConfig.defaultCodexReasoningEffort)
        XCTAssertEqual(loaded.general.subagent_sizing_policy, .userDefault)
        XCTAssertEqual(loaded.general.subagent_model, "strong")
        XCTAssertEqual(loaded.general.subagent_effort, "xhigh")
        XCTAssertFalse(loaded.general.messenger_enabled)
        XCTAssertEqual(loaded.general.messenger_model, "sonnet")
        XCTAssertEqual(loaded.general.messenger_effort, "low")
    }

    func testLegacyCodexReasoningEffortMigratesToOrchestratorEffort() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [general]
        provider = "codex"
        command = "codex"
        model = "gpt-5.5"
        codex_reasoning_effort = "high"
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.general.model, "gpt-5.5")
        XCTAssertEqual(loaded.general.orchestrator_effort, "high")
        XCTAssertEqual(loaded.general.codex_reasoning_effort, "high")
    }

    func testInvalidOrchestratorAndSubagentSettingsNormalizeToDefaults() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [general]
        provider = "codex"
        command = "codex"
        orchestrator_effort = "max"
        codex_reasoning_effort = "high"
        subagent_sizing_policy = "always"
        subagent_model = "opus"
        subagent_effort = "max"
        messenger_model = "haiku"
        messenger_effort = "ultra"
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.general.orchestrator_effort, GeneralConfig.defaultReasoningEffort)
        XCTAssertEqual(loaded.general.codex_reasoning_effort, GeneralConfig.defaultCodexReasoningEffort)
        XCTAssertEqual(loaded.general.subagent_sizing_policy, .orchestratorDecides)
        XCTAssertEqual(loaded.general.subagent_model, GeneralConfig.defaultSubagentModel)
        XCTAssertEqual(loaded.general.subagent_effort, GeneralConfig.defaultSubagentEffort)
        XCTAssertEqual(loaded.general.messenger_model, GeneralConfig.defaultMessengerModel)
        XCTAssertEqual(loaded.general.messenger_effort, GeneralConfig.defaultMessengerEffort)
    }

    private func temporaryConfigDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-runner-config-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
