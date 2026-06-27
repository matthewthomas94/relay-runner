import Foundation
import XCTest
@testable import relay_runner

final class ConfigManagerTests: XCTestCase {

    func testOrchestratorAndSubagentSettingsPersistThroughConfigManager() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        var config = AppConfig()
        config.general.provider = .claude
        config.general.orchestrator_effort = "max"
        config.general.codex_reasoning_effort = GeneralConfig.normalizedCodexReasoningEffort(
            config.general.orchestrator_effort
        )
        config.general.subagent_sizing_policy = .userDefault
        config.general.subagent_model = "strong"
        config.general.subagent_effort = "xhigh"

        try manager.save(config)
        let raw = try String(contentsOf: manager.configPath, encoding: .utf8)
        let loaded = manager.load()

        XCTAssertTrue(raw.contains("orchestrator_effort = \"max\""))
        XCTAssertTrue(raw.contains("codex_reasoning_effort = \"default\""))
        XCTAssertTrue(raw.contains("subagent_sizing_policy = \"user_default\""))
        XCTAssertEqual(loaded.general.provider, .claude)
        XCTAssertEqual(loaded.general.orchestrator_effort, "max")
        XCTAssertEqual(loaded.general.codex_reasoning_effort, GeneralConfig.defaultCodexReasoningEffort)
        XCTAssertEqual(loaded.general.subagent_sizing_policy, .userDefault)
        XCTAssertEqual(loaded.general.subagent_model, "strong")
        XCTAssertEqual(loaded.general.subagent_effort, "xhigh")
    }

    func testLegacyCodexReasoningEffortMigratesToOrchestratorEffort() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [general]
        provider = "codex"
        command = "codex"
        codex_reasoning_effort = "high"
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

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
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.general.orchestrator_effort, GeneralConfig.defaultReasoningEffort)
        XCTAssertEqual(loaded.general.codex_reasoning_effort, GeneralConfig.defaultCodexReasoningEffort)
        XCTAssertEqual(loaded.general.subagent_sizing_policy, .orchestratorDecides)
        XCTAssertEqual(loaded.general.subagent_model, GeneralConfig.defaultSubagentModel)
        XCTAssertEqual(loaded.general.subagent_effort, GeneralConfig.defaultSubagentEffort)
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
