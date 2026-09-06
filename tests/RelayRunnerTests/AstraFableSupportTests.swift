import XCTest
@testable import relay_runner

final class AstraFableSupportTests: XCTestCase {
    private let astra: [String: Any] = [
        "id": "gpt-6-astra", "hidden": false, "inputModalities": ["text", "image"],
        "defaultReasoningEffort": "medium",
        "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max", "ultra"],
    ]

    func testAstraCatalogResolutionAndUnavailableHandling() throws {
        let data = try JSONSerialization.data(withJSONObject: [astra])
        for selection in ["astra", "gpt-6-astra"] {
            let resolved = try CodexModelResolver.resolve(family: selection, effort: "ultra", catalogueData: data)
            XCTAssertEqual(resolved.selectedFamily, "astra")
            XCTAssertEqual(resolved.resolvedModel, "gpt-6-astra")
            XCTAssertEqual(resolved.resolvedEffort, "ultra")
        }
        XCTAssertThrowsError(try CodexModelResolver.resolve(family: "astra", effort: "none", catalogueData: data))
        for override: [String: Any] in [["hidden": true], ["inputModalities": ["audio"]]] {
            let unavailable = astra.merging(override) { _, new in new }
            let sol = astra.merging(["id": "gpt-6-sol"]) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: [sol, unavailable])
            XCTAssertThrowsError(try CodexModelResolver.resolve(family: "astra", catalogueData: data)) { error in
                XCTAssertEqual(error as? CodexModelResolver.Error, .familyUnavailable("astra"))
            }
        }
    }

    func testNewSelectionsPersistAndLaunchWithoutChangingDefaults() throws {
        XCTAssertEqual(GeneralConfig.defaultCodexModelFamily, "sol")
        XCTAssertEqual(GeneralConfig.defaultClaudeModel, "opus")
        XCTAssertEqual(GeneralConfig.defaultMessengerModel, "luna")
        for (provider, model, effort): (GeneralConfig.AgentProvider, String, String) in [
            (.codex, "astra", "ultra"), (.claude, "claude-fable-5-1", "max"),
        ] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let manager = ConfigManager(configDir: directory)
            var config = AppConfig()
            config.general.provider = provider
            config.general.model = model
            config.general.orchestrator_effort = effort
            config.general.messenger_model = model
            config.general.messenger_effort = effort
            try manager.save(config)
            let loaded = manager.load()
            XCTAssertEqual(loaded.general.model, model)
            XCTAssertEqual(loaded.general.orchestrator_effort, effort)
            XCTAssertEqual(loaded.general.messenger_model, model)
            XCTAssertEqual(loaded.general.messenger_effort, effort)
            let script = ProcessManager.launchScript(
                relayBridge: "/test/relay-bridge", target: provider == .codex ? .codex : .claude,
                agentBinary: "/test/agent", config: loaded,
                homeDirectory: URL(fileURLWithPath: "/test/home"),
                resolvedCodexModel: provider == .codex ? "gpt-6-astra" : nil,
                resolvedCodexEffort: provider == .codex ? effort : nil
            )
            XCTAssertTrue(script.contains("--model '\(provider == .codex ? "gpt-6-astra" : model)'"))
            XCTAssertTrue(GeneralConfig.isEffort(effort, validFor: provider, model: model))
            XCTAssertFalse(GeneralConfig.isModel(model, validFor: provider == .codex ? .claude : .codex))
            var selected = ""
            OnboardingView.persistGuidedSetupSelection(
                provider: provider, model: model, effort: effort,
                onSetAgentProvider: { _ in }, onSetModel: { selected = $0 }, onSetEffort: { _ in }
            )
            XCTAssertEqual(selected, model)
        }
        XCTAssertFalse(GeneralConfig.isEffort("ultra", validFor: .claude, model: "claude-fable-5-1"))
    }
}
