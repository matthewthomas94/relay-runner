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
        XCTAssertFalse(script.contains("--suppress-startup-greeting"))
        XCTAssertTrue(script.contains("developer_instructions="))
        XCTAssertTrue(script.contains("exec '/usr/local/bin/codex'"))
        XCTAssertTrue(script.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testLaunchScriptCanSuppressOnlyTheInitialBridgeGreetingForCodexAndClaude() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            var config = AppConfig()
            config.general.provider = provider
            let target: ProcessManager.AgentTarget = provider == .codex ? .codex : .claude
            let binary = provider == .codex ? "/usr/local/bin/codex" : "/usr/local/bin/claude"

            let script = ProcessManager.launchScript(
                relayBridge: "/Relay Runner/relay-bridge",
                target: target,
                agentBinary: binary,
                config: config,
                voiceDelivery: .appOwned,
                suppressStartupGreeting: true,
                homeDirectory: home
            )

            XCTAssertTrue(script.contains(
                "'/Relay Runner/relay-bridge' --start-daemon --suppress-startup-greeting"
            ))
        }
    }

    func testEmbeddedLaunchScriptPassesEquivalentHiddenRelayInstructionsForCodexAndClaude() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        var codexConfig = AppConfig()
        codexConfig.general.provider = .codex
        let codexScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/scripts/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: codexConfig,
            voiceDelivery: .appOwned,
            homeDirectory: home
        )

        var claudeConfig = AppConfig()
        claudeConfig.general.provider = .claude
        let claudeScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/scripts/relay-bridge",
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
            "if a newer command is present, stop stale work",
            "do not answer or act on the newer command",
            "atomically claim and inject the newer command as the next turn",
            "Raw Relay command captures are private metadata",
            "mcp__relay-actions__*",
            "mcp__relay-vision__screenshot",
            "__TRACE__",
            "__ORCHESTRATOR_REPLY__",
            "Do not write reply JSON or reply envelopes to /tmp/voice_in.fifo directly",
            "the sole app-owned __ORCHESTRATOR_REPLY__ encoder",
            "Provider responses, reasoning summaries, tool calls, progress, and final output should remain visible",
        ] {
            XCTAssertTrue(codexScript.contains(phrase), phrase)
            XCTAssertTrue(claudeScript.contains(phrase), phrase)
        }
        XCTAssertTrue(codexScript.contains(
            "export RELAY_REPLY_HELPER='/Relay Runner/services/relay_reply.py'"
        ))
        XCTAssertTrue(claudeScript.contains(
            "export RELAY_REPLY_HELPER='/Relay Runner/services/relay_reply.py'"
        ))
        XCTAssertFalse(codexScript.contains("handle the newest intent"))
        XCTAssertFalse(claudeScript.contains("handle the newest intent"))
        XCTAssertFalse(codexScript.contains("Use the relay-bridge skill now."))
        XCTAssertFalse(claudeScript.contains("\"/relay-bridge\""))
    }

    func testEmbeddedLaunchScriptRegistersSessionScopedCompletionHooksForCodexAndClaude() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        var codexConfig = AppConfig()
        codexConfig.general.provider = .codex
        let codexScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/scripts/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: codexConfig,
            voiceDelivery: .appOwned,
            homeDirectory: home
        )

        var claudeConfig = AppConfig()
        claudeConfig.general.provider = .claude
        let claudeScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/scripts/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: claudeConfig,
            voiceDelivery: .appOwned,
            homeDirectory: home
        )

        XCTAssertTrue(codexScript.contains("--enable hooks"))
        XCTAssertTrue(codexScript.contains("--dangerously-bypass-hook-trust"))
        XCTAssertTrue(codexScript.contains("hooks.UserPromptSubmit="))
        XCTAssertTrue(codexScript.contains("hooks.Stop="))
        XCTAssertFalse(codexScript.contains("hooks.StopFailure="))
        XCTAssertTrue(codexScript.contains("hooks.PreCompact="))
        XCTAssertTrue(codexScript.contains("hooks.PostCompact="))
        XCTAssertTrue(codexScript.contains("Relay voice prompt binding"))
        XCTAssertTrue(codexScript.contains("Relay voice completion"))
        XCTAssertTrue(codexScript.contains("/Relay Runner/services/relay_completion_hook.py"))
        XCTAssertFalse(codexScript.contains("--settings"))

        XCTAssertTrue(claudeScript.contains("--settings"))
        XCTAssertTrue(claudeScript.contains("\"UserPromptSubmit\""))
        XCTAssertTrue(claudeScript.contains("\"Stop\""))
        XCTAssertTrue(claudeScript.contains("\"StopFailure\""))
        XCTAssertTrue(claudeScript.contains("\"PreCompact\""))
        XCTAssertTrue(claudeScript.contains("\"PostCompact\""))
        XCTAssertTrue(claudeScript.contains("/Relay Runner/services/relay_completion_hook.py"))
        XCTAssertFalse(claudeScript.contains("--dangerously-bypass-hook-trust"))
    }

    func testEmbeddedLaunchUsesProviderNative150KAutomaticCompaction() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()

        let codexScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/scripts/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            voiceDelivery: .appOwned,
            homeDirectory: home,
            sessionEventPath: "/private/session.events.jsonl"
        )
        XCTAssertEqual(ProcessManager.embeddedAutoCompactTokenThreshold, 150_000)
        XCTAssertTrue(codexScript.contains("export RELAY_AUTO_COMPACT_THRESHOLD_TOKENS=150000"))
        XCTAssertTrue(codexScript.contains("model_auto_compact_token_limit=150000"))
        XCTAssertTrue(codexScript.contains("model_auto_compact_token_limit_scope=\"total\""))
        XCTAssertTrue(codexScript.contains("RELAY_CONTEXT_COMPACTION_EVENTS='/private/session.events.jsonl.context-compaction.jsonl'"))
        XCTAssertFalse(codexScript.contains("hooks.StopFailure"))
        XCTAssertFalse(codexScript.contains("CLAUDE_CODE_AUTO_COMPACT_WINDOW"))
        XCTAssertFalse(codexScript.contains("/compact\\r"))

        let nativeContextWindows = [
            "fable": 1_000_000,
            "opus": 1_000_000,
            "sonnet": 1_000_000,
            "haiku": 200_000,
        ]
        XCTAssertEqual(
            Set(nativeContextWindows.keys),
            Set(GeneralConfig.claudeModelOptions.map(\.value))
        )

        for (alias, nativeContextWindow) in nativeContextWindows {
            config.general.provider = .claude
            config.general.model = alias
            config.general.orchestrator_effort = "low"
            let claudeScript = ProcessManager.launchScript(
                relayBridge: "/Relay Runner/scripts/relay-bridge",
                target: .claude,
                agentBinary: "/usr/local/bin/claude",
                config: config,
                voiceDelivery: .appOwned,
                homeDirectory: home,
                sessionEventPath: "/private/session.events.jsonl"
            )
            XCTAssertTrue(claudeScript.contains("export RELAY_AUTO_COMPACT_THRESHOLD_TOKENS=150000"), alias)
            XCTAssertTrue(claudeScript.contains("unset DISABLE_AUTO_COMPACT DISABLE_COMPACT"), alias)
            XCTAssertTrue(claudeScript.contains("export CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000"), alias)
            XCTAssertTrue(claudeScript.contains(
                "export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=\(ProcessManager.claudeAutoCompactPercentage)"
            ), alias)
            XCTAssertFalse(claudeScript.contains("autoCompactEnabled"), alias)
            XCTAssertTrue(claudeScript.contains("StopFailure"), alias)
            XCTAssertFalse(claudeScript.contains("model_auto_compact_token_limit"), alias)
            XCTAssertFalse(claudeScript.contains("/compact\\r"), alias)

            // Runtime-equivalent to Claude Code 2.1.220: cap the configured
            // window, subtract the output reserve, then floor the percentage.
            let cappedWindow = min(
                nativeContextWindow,
                ProcessManager.claudeAutoCompactWindow
            )
            let usableContext = cappedWindow
                - min(cappedWindow, ProcessManager.claudeAutoCompactOutputReserve)
            let percentageBoundary = Int(floor(
                Double(usableContext)
                    * (ProcessManager.claudeAutoCompactPercentage / 100)
            ))
            let effectiveBoundary = min(
                percentageBoundary,
                usableContext - 13_000
            )
            XCTAssertEqual(effectiveBoundary, 150_000, alias)
        }
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
        XCTAssertFalse(script.contains("relay_completion_hook.py"))
        XCTAssertFalse(script.contains("relay_reply.py"))
        XCTAssertFalse(script.contains("RELAY_REPLY_HELPER"))
        XCTAssertFalse(script.contains("hooks.UserPromptSubmit"))
        XCTAssertFalse(script.contains("--settings"))
        XCTAssertFalse(script.contains("RELAY_AUTO_COMPACT_THRESHOLD_TOKENS"))
        XCTAssertFalse(script.contains("model_auto_compact_token_limit"))
        XCTAssertFalse(script.contains("CLAUDE_CODE_AUTO_COMPACT_WINDOW"))
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

    func testLaunchScriptPassesResolvedCodexFamilyModel() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .codex
        config.general.model = "sol"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            homeDirectory: home,
            resolvedCodexModel: "gpt-5.7-sol"
        )

        XCTAssertTrue(script.contains(
            "'/usr/local/bin/codex' --model 'gpt-5.7-sol' --dangerously-bypass-approvals-and-sandbox 'Use the relay-bridge skill now.'"
        ))
    }

    func testLaunchScriptRejectsCodexFamilyForClaude() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .claude
        config.general.model = "sol"

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
        config.general.model = "sol"
        config.general.orchestrator_effort = "ultra"

        let script = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            homeDirectory: home,
            resolvedCodexModel: "gpt-5.7-sol",
            resolvedCodexEffort: "ultra"
        )

        XCTAssertTrue(script.contains(
            "'/usr/local/bin/codex' --model 'gpt-5.7-sol' -c 'model_reasoning_effort=\"ultra\"' --dangerously-bypass-approvals-and-sandbox 'Use the relay-bridge skill now.'"
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

    func testLaunchScriptOmitsUnknownCodexReasoningEffortWithoutResolution() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        var config = AppConfig()
        config.general.provider = .codex
        config.general.codex_reasoning_effort = "banana"

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
        codexConfig.general.model = "luna"
        codexConfig.general.orchestrator_effort = "ultra"
        XCTAssertEqual(
            GeneralConfig.normalizedOrchestratorEffort("ultra", for: .codex, model: codexConfig.general.model),
            GeneralConfig.defaultReasoningEffort
        )

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

                    let resolvedCodexModel: String? = provider == .codex
                        ? "gpt-6.0-\(model)"
                        : nil
                    let resolvedCodexEffort: String? = provider == .codex
                        ? (effort == GeneralConfig.defaultReasoningEffort ? "medium" : effort)
                        : nil
                    let script = ProcessManager.launchScript(
                        relayBridge: "/Relay Runner/relay-bridge",
                        target: target,
                        agentBinary: binary,
                        config: config,
                        homeDirectory: home,
                        resolvedCodexModel: resolvedCodexModel,
                        resolvedCodexEffort: resolvedCodexEffort
                    )

                    if provider == .codex {
                        XCTAssertTrue(script.contains("--model 'gpt-6.0-\(model)'"), "\(provider) \(model) \(effort)")
                    } else if model == GeneralConfig.defaultModel {
                        XCTAssertFalse(script.contains("--model"), "\(provider) \(model) \(effort)")
                    } else {
                        XCTAssertTrue(script.contains("--model '\(model)'"), "\(provider) \(model) \(effort)")
                    }

                    if provider == .codex {
                        let expectedEffort = effort == GeneralConfig.defaultReasoningEffort ? "medium" : effort
                        XCTAssertTrue(script.contains("model_reasoning_effort=\"\(expectedEffort)\""), "\(provider) \(model) \(effort)")
                        XCTAssertFalse(script.contains("--effort"), "\(provider) \(model) \(effort)")
                    } else if effort == GeneralConfig.defaultReasoningEffort {
                        XCTAssertFalse(script.contains("model_reasoning_effort"), "\(provider) \(model) \(effort)")
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
        XCTAssertNil(launch.sessionEventPath)
    }

    func testEmbeddedLaunchScriptRecordsSingleSourceLifecycleStages() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            var config = AppConfig()
            config.general.provider = provider
            let target: ProcessManager.AgentTarget = provider == .codex ? .codex : .claude
            let binary = provider == .codex ? "/usr/local/bin/codex" : "/usr/local/bin/claude"
            let script = ProcessManager.launchScript(
                relayBridge: "/Relay Runner/scripts/relay-bridge",
                target: target,
                agentBinary: binary,
                config: config,
                voiceDelivery: .appOwned,
                homeDirectory: home,
                sessionEventPath: "/tmp/session-events.jsonl"
            )

            XCTAssertTrue(script.contains("RELAY_SESSION_EVENTS='/tmp/session-events.jsonl'"))
            XCTAssertTrue(script.contains("relay_record_session_event launcher_start started"))
            XCTAssertFalse(script.contains("relay_record_session_event bridge_socket_readiness ready"))
            XCTAssertTrue(script.contains("relay_record_session_event provider_spawn started"))
        }
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
