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
        XCTAssertTrue(codexScript.contains("export RELAY_RUNNER_APP_SESSION=1"))
        XCTAssertTrue(codexScript.contains("cd '/Users/example/dev workspace'"))
        XCTAssertTrue(codexScript.contains(
            "exec '/usr/local/bin/codex' --dangerously-bypass-approvals-and-sandbox 'Use the relay-bridge skill now.'"
        ))

        var claudeConfig = AppConfig()
        claudeConfig.general.provider = .claude
        claudeConfig.general.model = "sonnet"
        claudeConfig.general.working_directory = "~/dev workspace"
        claudeConfig.general.orchestrator_effort = "high"
        let claudeScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: claudeConfig,
            homeDirectory: home
        )

        XCTAssertTrue(claudeScript.contains("export RELAY_RUNNER_PROVIDER='claude'"))
        XCTAssertTrue(claudeScript.contains("export RELAY_RUNNER_APP_SESSION=1"))
        XCTAssertTrue(claudeScript.contains("cd '/Users/example/dev workspace'"))
        XCTAssertTrue(claudeScript.contains(
            "exec '/usr/local/bin/claude' --model 'sonnet' --effort 'high' --dangerously-skip-permissions \"/relay-bridge\""
        ))
        XCTAssertFalse(claudeScript.contains("model_reasoning_effort"))
        XCTAssertFalse(claudeScript.contains(" -c "))
    }

    func testEmbeddedLaunchScriptStartsBridgeDaemonAndLeavesProviderPromptUsable() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .codex
        config.general.working_directory = "~/dev workspace"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            voiceDelivery: .appOwned,
            homeDirectory: home
        )

        XCTAssertTrue(script.contains("'/Relay Runner/relay-bridge' --start-daemon"))
        XCTAssertFalse(script.contains("--venv-only"))
        XCTAssertFalse(script.contains("Use the relay-bridge skill now."))
        XCTAssertFalse(script.contains("\"/relay-bridge\""))
        XCTAssertTrue(script.contains("developer_instructions="))
        XCTAssertTrue(script.contains("exec '/usr/local/bin/codex'"))
        XCTAssertTrue(script.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testEmbeddedLaunchScriptPassesEquivalentHiddenRelayInstructionsForCodexAndClaude() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        var codexConfig = AppConfig()
        codexConfig.general.provider = .codex
        let codexScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: codexConfig,
            voiceDelivery: .appOwned,
            homeDirectory: home
        )

        var claudeConfig = AppConfig()
        claudeConfig.general.provider = .claude
        let claudeScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: claudeConfig,
            voiceDelivery: .appOwned,
            homeDirectory: home
        )

        XCTAssertTrue(codexScript.contains("-c 'developer_instructions="))
        XCTAssertTrue(claudeScript.contains("--append-system-prompt '"))
        for phrase in [
            "app-owned foreground Relay orchestrator/PM",
            "Dispatching a worker or sending a final response ends only the current provider turn",
            "never invoke relay-stop or end the session unless the user explicitly asks",
            "only when its prompt text exactly matches agent_prompt",
            "legacy metadata without agent_prompt",
            "normal typed turn and do not use claimed metadata",
            "Raw Relay command captures are private metadata",
            "mcp__relay-actions__*",
            "mcp__relay-vision__screenshot",
            "__TRACE__",
            "__ORCHESTRATOR_REPLY__",
            "Provider responses, reasoning summaries, tool calls, progress, and final output should remain visible",
        ] {
            XCTAssertTrue(codexScript.contains(phrase), phrase)
            XCTAssertTrue(claudeScript.contains(phrase), phrase)
        }
        XCTAssertFalse(codexScript.contains("Use the relay-bridge skill now."))
        XCTAssertFalse(claudeScript.contains("\"/relay-bridge\""))
    }

    func testExternalLaunchScriptDoesNotInjectAppOwnedHiddenInstructions() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .codex

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            voiceDelivery: .agentSkill,
            homeDirectory: home
        )

        XCTAssertFalse(script.contains("developer_instructions="))
        XCTAssertFalse(script.contains("--append-system-prompt"))
        XCTAssertTrue(script.contains("Use the relay-bridge skill now."))
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
        config.general.model = "gpt-5.6-sol"
        config.general.orchestrator_effort = "ultra"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            homeDirectory: home
        )

        XCTAssertTrue(script.contains(
            "'/usr/local/bin/codex' --model 'gpt-5.6-sol' -c 'model_reasoning_effort=\"ultra\"' --dangerously-bypass-approvals-and-sandbox 'Use the relay-bridge skill now.'"
        ))
    }

    func testLaunchScriptAppliesClaudeEffortConfig() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .claude
        config.general.model = "fable"
        config.general.orchestrator_effort = "max"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: config,
            homeDirectory: home
        )

        XCTAssertTrue(script.contains(
            "'/usr/local/bin/claude' --model 'fable' --effort 'max' --dangerously-skip-permissions \"/relay-bridge\""
        ))
        XCTAssertFalse(script.contains("model_reasoning_effort"))
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

    func testLaunchScriptRejectsUnsupportedModelEffortCombinations() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        var codexConfig = AppConfig()
        codexConfig.general.provider = .codex
        codexConfig.general.model = "gpt-5.6-luna"
        codexConfig.general.orchestrator_effort = "ultra"
        let codexScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: codexConfig,
            homeDirectory: home
        )
        XCTAssertTrue(codexScript.contains("--model 'gpt-5.6-luna'"))
        XCTAssertFalse(codexScript.contains("model_reasoning_effort"))

        var claudeConfig = AppConfig()
        claudeConfig.general.provider = .claude
        claudeConfig.general.model = "sonnet"
        claudeConfig.general.orchestrator_effort = "xhigh"
        let claudeScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: claudeConfig,
            homeDirectory: home
        )
        XCTAssertTrue(claudeScript.contains("--model 'sonnet'"))
        XCTAssertFalse(claudeScript.contains("--effort"))
    }

    func testLaunchScriptRendersEverySupportedSessionModelEffortCombination() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        for (provider, target, binary) in [
            (GeneralConfig.AgentProvider.codex, ProcessManager.AgentTarget.codex, "/usr/local/bin/codex"),
            (GeneralConfig.AgentProvider.claude, ProcessManager.AgentTarget.claude, "/usr/local/bin/claude"),
        ] {
            for (model, efforts) in GeneralConfig.modelEffortMatrix(for: provider) {
                for effort in efforts {
                    var config = AppConfig()
                    config.general.provider = provider
                    config.general.model = model
                    config.general.orchestrator_effort = effort

                    let script = ProcessManager.launchScript(
                        relayBridge: "/Relay Runner/relay-bridge",
                        target: target,
                        agentBinary: binary,
                        config: config,
                        homeDirectory: home
                    )

                    if model == GeneralConfig.defaultModel {
                        XCTAssertFalse(script.contains("--model"), "\(provider) \(model) \(effort)")
                    } else {
                        XCTAssertTrue(script.contains("--model '\(model)'"), "\(provider) \(model) \(effort)")
                    }

                    if effort == GeneralConfig.defaultReasoningEffort {
                        XCTAssertFalse(script.contains("model_reasoning_effort"), "\(provider) \(model) \(effort)")
                        XCTAssertFalse(script.contains("--effort"), "\(provider) \(model) \(effort)")
                    } else if provider == .codex {
                        XCTAssertTrue(script.contains("model_reasoning_effort=\"\(effort)\""), "\(provider) \(model) \(effort)")
                        XCTAssertFalse(script.contains("--effort"), "\(provider) \(model) \(effort)")
                    } else {
                        XCTAssertTrue(script.contains("--effort '\(effort)'"), "\(provider) \(model) \(effort)")
                        XCTAssertFalse(script.contains("model_reasoning_effort"), "\(provider) \(model) \(effort)")
                    }
                }
            }
        }
    }

    func testPreparedSessionLaunchCarriesSharedEmbeddedAndExternalCommand() {
        let launch = ProcessManager.PreparedSessionLaunch(
            executable: "/bin/bash",
            arguments: ["/tmp/voice_bridge_launch.command"],
            launcherPath: "/tmp/voice_bridge_launch.command",
            workingDirectory: "/Users/example/dev",
            target: .codex,
            voiceDelivery: .appOwned
        )

        XCTAssertEqual(launch.executable, "/bin/bash")
        XCTAssertEqual(launch.arguments, [launch.launcherPath])
        XCTAssertEqual(launch.workingDirectory, "/Users/example/dev")
        XCTAssertEqual(launch.target, .codex)
        XCTAssertEqual(launch.voiceDelivery, .appOwned)
    }

    func testCodexBinaryResolutionPrefersCurrentChatGPTAppThenLegacyCodexApp() {
        let chatGPT = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let legacy = "/Applications/Codex.app/Contents/Resources/codex"

        XCTAssertEqual(
            ProcessManager.resolveAgentBinary(
                "codex",
                target: .codex,
                isExecutable: { $0 == chatGPT || $0 == legacy }
            ),
            chatGPT
        )
        XCTAssertEqual(
            ProcessManager.resolveAgentBinary(
                "codex",
                target: .codex,
                isExecutable: { $0 == legacy }
            ),
            legacy
        )
        XCTAssertEqual(
            ProcessManager.resolveAgentBinary(
                "codex",
                target: .codex,
                isExecutable: { _ in false }
            ),
            "codex"
        )
    }

    func testOnboardingUsesTheSameCurrentThenLegacyCodexBundleOrder() {
        XCTAssertEqual(
            VenvInstaller.codexCLIPaths,
            [
                "/Applications/ChatGPT.app/Contents/Resources/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
            ]
        )
    }
}
