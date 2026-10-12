import XCTest
@testable import relay_runner

final class ProcessManagerLaunchTests: XCTestCase {

    func testOnlyManagedCodexLaunchObservesExactNativeStartupIdentityBeforeExec() throws {
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            for context in [AssistantSessionContext?.none, .some(.general)] {
                let script = ProcessManager.launchScript(relayBridge: "/Relay Runner/scripts/relay-bridge", target: target,
                    agentBinary: "/Native Provider/bin/provider", config: config, voiceDelivery: .appOwned,
                    sessionContext: context, providerBindingPath: "/private/bindings/transport.json")
                if target == .codex && context != nil {
                    let process = try XCTUnwrap(script.range(of: " --record-process"))
                    let binary = try XCTUnwrap(script.range(of: "export RELAY_PROVIDER_BINARY='/Native Provider/bin/provider'"))
                    let observation = try XCTUnwrap(script.range(of: " --record-codex-startup </dev/null >/dev/null 2>&1 &"))
                    let execution = try XCTUnwrap(script.range(of: "exec '/Native Provider/bin/provider'"))
                    XCTAssertLessThan(process.lowerBound, binary.lowerBound)
                    XCTAssertLessThan(binary.lowerBound, observation.lowerBound)
                    XCTAssertLessThan(observation.lowerBound, execution.lowerBound)
                    XCTAssertFalse(script.contains("hooks.SessionStart="), "The configured native Codex does not emit this before its first turn")
                } else {
                    XCTAssertFalse(script.contains(" --record-codex-startup"))
                }
            }
        }
    }

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
            homeDirectory: home,
            resolvedCodexModel: "gpt-6.1-sol",
            resolvedCodexEffort: "xhigh"
        )

        XCTAssertTrue(codexScript.contains("'/Relay Runner/relay-bridge' --venv-only"))
        XCTAssertTrue(codexScript.contains("rm -f /tmp/voice_bridge_stop_requested"))
        XCTAssertTrue(codexScript.contains("export RELAY_RUNNER_PROVIDER='codex'"))
        XCTAssertTrue(codexScript.contains("export RELAY_RUNNER_APP_SESSION=1"))
        XCTAssertTrue(codexScript.contains("cd '/Users/example/dev workspace'"))
        XCTAssertTrue(codexScript.contains("exec '/usr/local/bin/codex'"))
        XCTAssertTrue(codexScript.contains("model_reasoning_effort=\"xhigh\""))
        XCTAssertTrue(codexScript.contains("--search"))

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
        XCTAssertFalse(claudeScript.contains("--tools"))
        XCTAssertFalse(claudeScript.contains("model_reasoning_effort"))
        XCTAssertFalse(claudeScript.contains(" -c "))
    }

    func testClaudeLaunchChecksSubscriptionBeforeBridgeAndProvider() {
        let relayBridge = "/App/Contents/SharedSupport/scripts/relay-bridge"
        for target in [ProcessManager.AgentTarget.claude, .codex] {
            var config = AppConfig()
            config.general.provider = target == .claude ? .claude : .codex
            let script = ProcessManager.launchScript(
                relayBridge: relayBridge,
                target: target,
                agentBinary: "/usr/local/bin/agent",
                config: config,
                voiceDelivery: .appOwned
            )
            guard target == .claude else {
                XCTAssertFalse(script.contains("claude_subscription"))
                continue
            }
            let gate = script.range(of: "'/App/Contents/SharedSupport/services/claude_subscription.py' --binary '/usr/local/bin/agent' --cwd \"$PWD\"")
            let bridge = script.range(of: "--start-daemon")
            let provider = script.range(of: "exec '/usr/local/bin/agent'")
            XCTAssertNotNil(gate)
            XCTAssertLessThan(gate!.lowerBound, bridge!.lowerBound)
            XCTAssertLessThan(gate!.lowerBound, provider!.lowerBound)
            XCTAssertTrue(script.contains("exit 78"))
        }
    }

    func testClaudeSubscriptionGateRefusesAnAPIKeyRouteWithoutPrintingIt() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-subscription-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let claude = temp.appendingPathComponent("claude")
        let status = temp.appendingPathComponent("status.json")
        try "#!/bin/sh\ncat \"$(dirname \"$0\")/status.json\"\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let gate = ProcessManager.claudeSubscriptionGate(
            relayBridge: repo.appendingPathComponent("scripts/relay-bridge").path,
            target: .claude,
            agentBinary: claude.path
        )
        let script = "relay_record_session_event() { :; }\ncd \(temp.path)\n\(gate)\necho launched\n"

        func run(_ json: String, environment extra: [String: String] = [:]) throws -> (Int32, String) {
            try json.write(to: status, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
            process.environment = ["HOME": temp.path, "PATH": "/usr/bin:/bin"].merging(extra) { $1 }
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (process.terminationStatus, text)
        }

        let subscription = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
        let verified = try run(subscription)
        XCTAssertEqual(verified.0, 0, verified.1)
        XCTAssertTrue(verified.1.contains("launched"))

        let keyed = try run(subscription, environment: ["ANTHROPIC_API_KEY": "sk-ant-api03-SECRET"])
        XCTAssertEqual(keyed.0, ProcessManager.claudeSubscriptionGateExitCode)
        XCTAssertFalse(keyed.1.contains("launched"))
        XCTAssertTrue(keyed.1.contains("ANTHROPIC_API_KEY"))
        XCTAssertFalse(keyed.1.contains("SECRET"))

        let message = EmbeddedTerminalSession.launchFailureMessage(
            providerName: "Claude",
            rawStatus: ProcessManager.claudeSubscriptionGateExitCode << 8,
            bridgeSocketOutcome: nil
        )
        XCTAssertTrue(message.contains("Claude subscription"))
        XCTAssertTrue(message.contains("configuration issue shown in the terminal"))
    }

    func testProviderLoginRunsOnceAndRechecksBeforeLaunchForBothProviders() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for target in [ProcessManager.AgentTarget.claude, .codex] {
            for scenario in ["ready", "login", "cancel", "still_missing", "api"] {
                if target == .claude && scenario == "api" { continue }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("relay-login-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temp) }
                let agent = temp.appendingPathComponent("agent")
                let ready = target == .claude
                    ? #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#
                    : "Logged in using ChatGPT"
                let missing = target == .claude ? #"{"loggedIn":false}"# : "Not logged in"
                try (scenario == "ready" ? ready : (scenario == "api" ? "Logged in using an API key: SECRET" : missing))
                    .write(to: temp.appendingPathComponent("status"), atomically: true, encoding: .utf8)
                try ready.write(to: temp.appendingPathComponent("ready"), atomically: true, encoding: .utf8)
                try """
                #!/bin/bash
                cd "$(dirname "$0")"
                printf '%s\\n' "$*" >> calls
                [ "$1" = -c ] && shift 2
                if [ "$1 $2" = 'auth status' ] || [ "$1 $2" = 'login status' ]; then
                    cat status
                    exit 0
                fi
                [ "\(scenario)" = cancel ] && exit 1
                [ "\(scenario)" != still_missing ] && cp ready status
                exit 0
                """.write(to: agent, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
                let gate = target == .claude
                    ? ProcessManager.claudeSubscriptionGate(
                        relayBridge: repo.appendingPathComponent("scripts/relay-bridge").path,
                        target: target, agentBinary: agent.path
                    )
                    : ProcessManager.codexLoginGate(target: target, agentBinary: agent.path)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-e", "-c", """
                    relay_record_session_event() { printf '%s %s\\n' "$1" "$2"; }
                    cd '\(temp.path)'
                    \(gate)
                    echo launched
                    """]
                process.environment = ["HOME": temp.path, "PATH": "/usr/bin:/bin"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                try process.run()
                process.waitUntilExit()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let calls = try String(contentsOf: temp.appendingPathComponent("calls"), encoding: .utf8)
                    .split(separator: "\n").map(String.init)
                let loginCalls = calls.filter { !$0.contains("status") }
                XCTAssertEqual(loginCalls.count, scenario == "ready" ? 0 : 1, "\(target) \(scenario): \(calls)")
                if let login = loginCalls.first {
                    XCTAssertTrue(target == .claude ? login == "auth login --claudeai" : login.contains("forced_login_method=\"chatgpt\" login"))
                }
                let succeeds = ["ready", "login", "api"].contains(scenario)
                XCTAssertEqual(process.terminationStatus, succeeds ? 0 : (target == .claude ? 78 : 79), text)
                XCTAssertEqual(text.contains("launched"), succeeds, "\(target) \(scenario): \(text)")
                XCTAssertEqual(calls.filter { $0.contains("status") }.count, ["ready", "cancel"].contains(scenario) ? 1 : 2)
                XCTAssertFalse(text.contains("SECRET"))
            }
        }
    }

    func testCodexResolvesSelectedModelAfterLoginAndBeforeBridge() throws {
        var config = AppConfig()
        config.general.provider = .codex
        config.general.model = "astra"
        config.general.orchestrator_effort = "ultra"
        let script = ProcessManager.launchScript(
            relayBridge: "/App/scripts/relay-bridge", target: .codex,
            agentBinary: "/usr/local/bin/codex", config: config, voiceDelivery: .appOwned
        )
        let login = try XCTUnwrap(script.range(of: "login ||"))
        let resolver = try XCTUnwrap(script.range(of: "services/codex_model_catalog.py"))
        let bridge = try XCTUnwrap(script.range(of: "--start-daemon"))
        XCTAssertLessThan(login.lowerBound, resolver.lowerBound)
        XCTAssertLessThan(resolver.lowerBound, bridge.lowerBound)
        XCTAssertTrue(script.contains("--family 'astra' --effort 'ultra'"))
        XCTAssertTrue(script.contains("--model \"$relay_codex_model\""))
    }

    func testCodexLauncherResolvesCatalogueAndStopsOnUnavailableFamily() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var config = AppConfig()
        config.general.model = "astra"
        config.general.orchestrator_effort = "ultra"
        for available in [true, false] {
            let catalogue = available ? #"{"data":[{"id":"gpt-6-astra","defaultReasoningEffort":"high","supportedReasoningEfforts":["ultra"]}]}"# : #"{"data":[]}"#
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", """
                \(ProcessManager.codexModelResolutionScript(
                    relayBridge: repo.appendingPathComponent("scripts/relay-bridge").path,
                    agentBinary: "/unused/codex", config: config
                ))
                printf '%s\\n' "$relay_codex_model" "$relay_codex_effort"
                """]
            process.environment = ["PATH": "/usr/bin:/bin", "RELAY_CODEX_MODEL_LIST_JSON": catalogue]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, available ? 0 : 1, text)
            if available {
                XCTAssertEqual(text, "gpt-6-astra\nultra\n")
            } else {
                XCTAssertTrue(text.contains("family 'astra' is unavailable"))
            }
        }
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
            homeDirectory: home,
            providerSessionID: "embedded-provider-session"
        )

        XCTAssertTrue(script.contains("'/Relay Runner/relay-bridge' --start-daemon"))
        XCTAssertFalse(script.contains("--venv-only"))
        XCTAssertFalse(script.contains("Use the relay-bridge skill now."))
        XCTAssertFalse(script.contains("\"/relay-bridge\""))
        XCTAssertFalse(script.contains("--suppress-startup-greeting"))
        XCTAssertTrue(script.contains("developer_instructions="))
        XCTAssertTrue(script.contains("export RELAY_PROVIDER_SESSION_ID='embedded-provider-session'"))
        XCTAssertTrue(script.contains(
            "printf '%s\\n' \"$RELAY_PROVIDER_SESSION_ID\" > /tmp/voice_provider_session_id"
        ))
        XCTAssertTrue(script.contains("exec '/usr/local/bin/codex'"))
        XCTAssertTrue(script.contains("--search"))
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

    func testLaunchScriptExportsEquivalentConfirmedProjectScopeForCodexAndClaude() throws {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let project = RegisteredProjectV2(
            projectID: "project-scope",
            displayName: "Scoped Project",
            selectedPath: "/Users/example/dev/scoped",
            lastResolvedPath: "/Users/example/dev/scoped",
            fileResourceIdentifier: nil,
            gitCommonDirectoryFingerprint: "fingerprint-scope",
            worktreeKind: .primary,
            remote: .localOnly,
            availability: .available,
            bookmarkReference: .project("project-scope"),
            createdAt: timestamp,
            updatedAt: timestamp,
            lastResolvedAt: timestamp,
            legacyRecordID: nil
        )
        let token = ConfirmedProjectScopeToken(
            project: project,
            registrySchemaVersion: ProjectRegistryV2Document.currentSchemaVersion,
            issuedAt: timestamp
        )
        let encoded = try XCTUnwrap(token.encodedValue)

        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            var config = AppConfig()
            config.general.provider = provider
            config.general.model = GeneralConfig.defaultModel(for: provider)
            config.general.working_directory = project.lastResolvedPath
            let script = ProcessManager.launchScript(
                relayBridge: "/Relay Runner/relay-bridge",
                target: provider == .codex ? .codex : .claude,
                agentBinary: provider == .codex ? "/usr/local/bin/codex" : "/usr/local/bin/claude",
                config: config,
                homeDirectory: home,
                projectScopeToken: token
            )

            XCTAssertTrue(script.contains("export RELAY_PROJECT_SCOPE_TOKEN='\(encoded)'"), provider.rawValue)
            XCTAssertTrue(script.contains("export RELAY_PROJECT_ID='project-scope'"), provider.rawValue)
            XCTAssertTrue(script.contains("export RELAY_PROJECT_SCOPE_VERSION='1'"), provider.rawValue)
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
            "Relay Runner may inject and claim a newer voice prompt while you are working",
            "incorporate that prompt as steering in this same PM session",
            "preserve earlier bounded work unless its authorization was revoked",
            "newer command exists only in state and has not been injected and claimed",
            "do not answer or act on it yet",
            "A newer continue_current command with authorization_effect preserve",
            "does not revoke the earlier item",
            "For any other newer unclaimed command, stop stale output",
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
        for script in [codexScript, claudeScript] {
            XCTAssertTrue(script.contains("export RELAY_APP_SESSION_ID="))
            XCTAssertTrue(script.contains("export RELAY_RECOVERY_GENERATION="))
            XCTAssertTrue(script.contains("export RELAY_ACTOR_ROLE=foreground_pm"))
            XCTAssertTrue(script.contains("export RELAY_FOREGROUND_GATE_HANDLE="))
        }
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
            "claude-fable-5-1": 1_000_000,
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
            XCTAssertTrue(claudeScript.contains(#""autoCompactEnabled":true"#), alias)
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
            resolvedCodexModel: "gpt-6.1-sol",
            resolvedCodexEffort: "xhigh"
        )

        XCTAssertTrue(script.contains("--model 'gpt-6.1-sol'"))
        XCTAssertTrue(script.contains("model_reasoning_effort=\"xhigh\""))
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

        XCTAssertFalse(script.contains("--model 'sol'"))
        XCTAssertTrue(script.contains("--effort 'xhigh'"))
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
            "'/usr/local/bin/codex' --model 'gpt-5.7-sol' -c 'model_reasoning_effort=\"ultra\"' -c 'forced_login_method=\"chatgpt\"' --search --dangerously-bypass-approvals-and-sandbox 'Use the relay-bridge skill now.'"
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
        XCTAssertFalse(script.contains("--tools"))
        XCTAssertFalse(script.contains("model_reasoning_effort"))
    }

    func testLaunchScriptNormalizesUnsupportedModelEffortCombinations() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        var codexConfig = AppConfig()
        codexConfig.general.provider = .codex
        codexConfig.general.model = "luna"
        codexConfig.general.orchestrator_effort = "ultra"
        XCTAssertEqual(
            GeneralConfig.normalizedOrchestratorEffort("ultra", for: .codex, model: codexConfig.general.model),
            GeneralConfig.defaultOrchestratorEffort
        )

        var claudeConfig = AppConfig()
        claudeConfig.general.provider = .claude
        claudeConfig.general.model = "haiku"
        claudeConfig.general.orchestrator_effort = "xhigh"
        let claudeScript = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: claudeConfig,
            homeDirectory: home
        )
        XCTAssertTrue(claudeScript.contains("--model 'haiku'"))
        XCTAssertTrue(claudeScript.contains("--effort 'low'"))
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
                        ? "gpt-6-\(model)"
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
                        XCTAssertTrue(script.contains("--model 'gpt-6-\(model)'"), "\(provider) \(model) \(effort)")
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
        XCTAssertNil(launch.providerSessionID)
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

    func testLaunchRefreshKeepsSkillEditsWhileSettingsReinstallOverwrites() {
        XCTAssertEqual(ProcessManager.skillInstallArgument(force: false), "--refresh-skills")
        XCTAssertEqual(ProcessManager.skillInstallArgument(force: true), "--install-skills")
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

    func testAbsoluteCommandIsUsedOnlyForTheProviderItTargets() {
        let codexPath = "/Applications/ChatGPT.app/Contents/Resources/codex"
        let claudePath = "/opt/homebrew/bin/claude"

        XCTAssertEqual(
            ProcessManager.resolveAgentBinary(codexPath, target: .codex, isExecutable: { _ in false }),
            codexPath
        )
        XCTAssertEqual(
            ProcessManager.resolveAgentBinary(claudePath, target: .claude, isExecutable: { _ in false }),
            claudePath
        )
        XCTAssertEqual(
            ProcessManager.resolveAgentBinary(codexPath, target: .claude, isExecutable: { _ in false }),
            "claude"
        )
        XCTAssertEqual(
            ProcessManager.resolveAgentBinary(claudePath, target: .codex, isExecutable: { _ in false }),
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
