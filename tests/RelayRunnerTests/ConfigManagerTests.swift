import Foundation
import XCTest
@testable import relay_runner

final class ConfigManagerTests: XCTestCase {

    func testCodexReasoningEffortPersistsThroughConfigManager() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        var config = AppConfig()
        config.general.codex_reasoning_effort = "high"

        try manager.save(config)
        let raw = try String(contentsOf: manager.configPath, encoding: .utf8)
        let loaded = manager.load()

        XCTAssertTrue(raw.contains("codex_reasoning_effort = \"high\""))
        XCTAssertEqual(loaded.general.codex_reasoning_effort, "high")
    }

    func testCodexReasoningEffortLoadNormalizesInvalidValue() throws {
        let configDir = temporaryConfigDir()
        let manager = ConfigManager(configDir: configDir)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        [general]
        provider = "codex"
        command = "codex"
        codex_reasoning_effort = "max"
        """.write(to: manager.configPath, atomically: true, encoding: .utf8)

        let loaded = manager.load()

        XCTAssertEqual(loaded.general.codex_reasoning_effort, GeneralConfig.defaultCodexReasoningEffort)
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
