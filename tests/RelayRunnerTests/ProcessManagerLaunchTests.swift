import XCTest
@testable import relay_runner

final class ProcessManagerLaunchTests: XCTestCase {

    func testLaunchScriptUsesWorkspaceFolderForCodexAndClaude() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        var codexConfig = AppConfig()
        codexConfig.general.provider = .codex
        codexConfig.general.working_directory = "~/dev workspace"
        let codexScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: codexConfig,
            homeDirectory: home
        )

        XCTAssertTrue(codexScript.contains("'/Relay Runner/relay-bridge' --venv-only"))
        XCTAssertTrue(codexScript.contains("rm -f /tmp/voice_bridge_stop_requested"))
        XCTAssertTrue(codexScript.contains("export RELAY_RUNNER_PROVIDER='codex'"))
        XCTAssertTrue(codexScript.contains("cd '/Users/example/dev workspace'"))
        XCTAssertTrue(codexScript.contains(
            "'/usr/local/bin/codex' --dangerously-bypass-approvals-and-sandbox 'Use the relay-bridge skill now.'"
        ))

        var claudeConfig = AppConfig()
        claudeConfig.general.provider = .claude
        claudeConfig.general.working_directory = "~/dev workspace"
        claudeConfig.general.codex_reasoning_effort = "high"
        let claudeScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: claudeConfig,
            homeDirectory: home
        )

        XCTAssertTrue(claudeScript.contains("export RELAY_RUNNER_PROVIDER='claude'"))
        XCTAssertTrue(claudeScript.contains("cd '/Users/example/dev workspace'"))
        XCTAssertTrue(claudeScript.contains(
            "'/usr/local/bin/claude' --dangerously-skip-permissions \"/relay-bridge\""
        ))
        XCTAssertFalse(claudeScript.contains("model_reasoning_effort"))
        XCTAssertFalse(claudeScript.contains(" -c "))
    }

    func testLaunchScriptUsesHomeDirectoryWhenWorkspaceFolderIsUnset() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.working_directory = ""

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            homeDirectory: home
        )

        XCTAssertTrue(script.contains("cd '/Users/example'"))
    }

    func testLaunchScriptPassesSelectedGPT56ModelForCodex() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .codex
        config.general.model = "gpt-5.6-sol"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            homeDirectory: home
        )

        XCTAssertTrue(script.contains(
            "'/usr/local/bin/codex' --model 'gpt-5.6-sol' --dangerously-bypass-approvals-and-sandbox 'Use the relay-bridge skill now.'"
        ))
    }

    func testLaunchScriptRejectsCodexPreviewModelForClaude() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .claude
        config.general.model = "gpt-5.6-sol"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: config,
            homeDirectory: home
        )

        XCTAssertFalse(script.contains("--model"))
        XCTAssertTrue(script.contains(
            "'/usr/local/bin/claude' --dangerously-skip-permissions \"/relay-bridge\""
        ))
    }

    func testLaunchScriptAppliesCodexReasoningEffortConfig() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .codex
        config.general.model = "gpt-5.5"
        config.general.codex_reasoning_effort = "xhigh"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            homeDirectory: home
        )

        XCTAssertTrue(script.contains(
            "'/usr/local/bin/codex' --model 'gpt-5.5' -c 'model_reasoning_effort=\"xhigh\"' --dangerously-bypass-approvals-and-sandbox 'Use the relay-bridge skill now.'"
        ))
    }

    func testLaunchScriptOmitsDefaultOrInvalidCodexReasoningEffort() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .codex
        config.general.codex_reasoning_effort = "max"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            homeDirectory: home
        )

        XCTAssertFalse(script.contains("model_reasoning_effort"))
        XCTAssertFalse(script.contains(" -c "))
    }
}
