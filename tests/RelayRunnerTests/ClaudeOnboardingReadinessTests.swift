import XCTest
@testable import relay_runner

final class ClaudeOnboardingReadinessTests: XCTestCase {
    private let homebrewClaude = "/opt/homebrew/bin/claude"

    // MARK: - Binary discovery

    func testHomebrewClaudePassesSetupSignInAndLaunch() {
        let isExecutable: (String) -> Bool = { $0 == self.homebrewClaude }

        XCTAssertTrue(VenvInstaller.cliInstalled(
            for: .claude,
            isExecutable: isExecutable,
            claudeShellLookup: { nil }
        ))
        XCTAssertEqual(
            ClaudeAuth.resolveBinary(isExecutable: isExecutable, shellLookup: { nil }),
            homebrewClaude
        )
        XCTAssertEqual(
            ProcessManager.resolveAgentBinary("claude", target: .claude, isExecutable: isExecutable),
            homebrewClaude
        )
        XCTAssertNil(ProcessManager.claudeLaunchReadinessError(
            agentBinary: "claude",
            isExecutable: isExecutable,
            shellLookup: { nil }
        ))

        let login = ClaudeAuth.loginCommand(claudePath: homebrewClaude)
        XCTAssertTrue(login.contains("'/opt/homebrew/bin/claude' auth login --claudeai"))
        XCTAssertFalse(login.contains("/login"))
        XCTAssertTrue(login.contains("Pro, Max, Team or Enterprise subscription"))
    }

    func testInstallerSymlinkIsPreferredAndNpmInstallsAreFoundThroughTheLaunchShell() {
        let local = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude")
        XCTAssertEqual(ClaudeAuth.candidatePaths, [local, homebrewClaude, "/usr/local/bin/claude"])
        XCTAssertEqual(
            ClaudeAuth.resolveBinary(isExecutable: { _ in true }, shellLookup: { XCTFail(); return nil }),
            local
        )

        let npm = "/Users/example/.npm-global/bin/claude"
        XCTAssertEqual(
            ClaudeAuth.resolveBinary(isExecutable: { $0 == npm }, shellLookup: { npm }),
            npm
        )
        XCTAssertTrue(VenvInstaller.cliInstalled(
            for: .claude,
            isExecutable: { $0 == npm },
            claudeShellLookup: { npm }
        ))
        // Shell output that isn't an executable path doesn't count.
        XCTAssertNil(ClaudeAuth.resolveBinary(isExecutable: { _ in false }, shellLookup: { "claude" }))
    }

    func testMissingClaudeIsAReadinessErrorBeforeLaunch() {
        let error = ProcessManager.claudeLaunchReadinessError(
            agentBinary: "claude",
            isExecutable: { _ in false },
            shellLookup: { nil }
        )
        XCTAssertEqual(error?.errorDescription, ClaudeAuth.notInstalledMessage)
        XCTAssertFalse(VenvInstaller.cliInstalled(
            for: .claude,
            isExecutable: { _ in false },
            claudeShellLookup: { nil }
        ))
        XCTAssertNotNil(ProcessManager.claudeLaunchReadinessError(
            agentBinary: "/custom/bin/claude",
            isExecutable: { _ in false },
            shellLookup: { nil }
        ))
        XCTAssertNil(ProcessManager.claudeLaunchReadinessError(
            agentBinary: "/custom/bin/claude",
            isExecutable: { $0 == "/custom/bin/claude" },
            shellLookup: { nil }
        ))
    }

    func testSelectingClaudeInSettingsShowsReadinessInsteadOfAFailedSession() {
        XCTAssertNil(GeneralSettingsTab.providerReadinessDescription(provider: .codex, claudeReadiness: nil))
        XCTAssertEqual(
            GeneralSettingsTab.providerReadinessDescription(
                provider: .claude,
                claudeReadiness: .unavailable(ClaudeAuth.notInstalledMessage)
            ),
            ClaudeAuth.notInstalledMessage
        )
        XCTAssertEqual(
            GeneralSettingsTab.providerReadinessDescription(provider: .claude, claudeReadiness: nil),
            "Checking your Claude subscription\u{2026}"
        )
        XCTAssertEqual(
            GeneralSettingsTab.providerReadinessDescription(provider: .claude, claudeReadiness: .verified),
            "Using your Claude subscription."
        )
    }

    // MARK: - Subscription gate

    func testReadinessUsesTheSubscriptionGateNotTheLoggedInFlag() throws {
        let fixture = try GateFixture()
        let subscription = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"max"}"#

        XCTAssertEqual(try fixture.check(status: subscription), .verified)

        // A setup-token the CLI can attribute to a subscription plan is fine
        // and is not treated as an API key.
        let tokenWithPlan = #"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty","subscriptionType":"max"}"#
        XCTAssertEqual(
            try fixture.check(status: tokenWithPlan, environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-SECRET"]),
            .verified
        )

        let refused: [(String, [String: String], String)] = [
            // loggedIn with no identifiable route is ambiguous.
            (#"{"loggedIn":true,"apiProvider":"firstParty"}"#, [:], "couldn't confirm"),
            // Console (API) login.
            (#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","apiKeySource":"/login managed key"}"#, [:], "API key"),
            // Cloud route.
            (#"{"loggedIn":true,"authMethod":"third_party","apiProvider":"bedrock"}"#, [:], "cloud provider"),
            // A token with no plan stays unverified.
            (#"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}"#, ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-SECRET"], "long-lived OAuth token"),
            // An API key takes precedence over a subscription login.
            (subscription, ["ANTHROPIC_API_KEY": "sk-ant-api03-SECRET"], "ANTHROPIC_API_KEY"),
            (#"{"loggedIn":false}"#, [:], "claude auth login"),
        ]
        for (status, environment, expected) in refused {
            let result = try fixture.check(status: status, environment: environment)
            let message = try XCTUnwrap(result.message, status)
            XCTAssertTrue(message.contains(expected), "\(status): \(message)")
            XCTAssertFalse(message.contains("SECRET"), status)
        }
    }

    func testGateSeesTheShellProfileTheLauncherSources() throws {
        let fixture = try GateFixture()
        let subscription = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro"}"#

        let result = try fixture.check(
            status: subscription,
            prelude: "export ANTHROPIC_AUTH_TOKEN=gateway-SECRET"
        )

        XCTAssertTrue(result.message?.contains("ANTHROPIC_AUTH_TOKEN") == true)
        XCTAssertFalse(result.message?.contains("SECRET") == true)
    }

    func testGateOutputParsingKeepsOnlyTheRelayMessage() {
        XCTAssertEqual(ProcessManager.claudeSubscriptionCheck(exitStatus: 0, stderr: "noise"), .verified)
        XCTAssertEqual(
            ProcessManager.claudeSubscriptionCheck(
                exitStatus: 78,
                stderr: "profile noise\n[Relay Runner] Fix this.\n"
            ),
            .unavailable("Fix this.")
        )
        XCTAssertEqual(
            ProcessManager.claudeSubscriptionCheck(exitStatus: 1, stderr: "Traceback"),
            .unavailable(ProcessManager.claudeSubscriptionFallbackMessage)
        )
    }

    // MARK: - Monitor

    func testMonitorAnswersEachRefreshWithACheckThatStartedAfterIt() {
        var results: [ProcessManager.ClaudeSubscriptionCheck] = [
            .unavailable("not signed in"),
            .verified,
        ]
        var pending: [() -> Void] = []
        let monitor = ClaudeSubscriptionMonitor(
            check: { _ in results.removeFirst() },
            runInBackground: { pending.append($0) }
        )
        var first: ProcessManager.ClaudeSubscriptionCheck?
        var second: ProcessManager.ClaudeSubscriptionCheck?
        var third: ProcessManager.ClaudeSubscriptionCheck?

        monitor.refresh(workingDirectory: "/repo") { first = $0 }
        // Asked while the first check runs: shares the next check.
        monitor.refresh(workingDirectory: "/repo") { second = $0 }
        monitor.refresh(workingDirectory: "/repo") { third = $0 }
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(monitor.latest)

        pending.removeFirst()()
        drainMainQueue()
        XCTAssertEqual(first, .unavailable("not signed in"))
        XCTAssertNil(second)
        XCTAssertEqual(pending.count, 1)

        pending.removeFirst()()
        drainMainQueue()
        XCTAssertEqual(second, .verified)
        XCTAssertEqual(third, .verified)
        XCTAssertEqual(monitor.latest, .verified)
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Launch settings

    func testEmbeddedClaudeHoldsVoiceUntilFirstRunScreensAndKeepsAutoCompact() {
        var config = AppConfig()
        config.general.provider = .claude
        let claude = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/scripts/relay-bridge",
            target: .claude,
            agentBinary: "/usr/local/bin/claude",
            config: config,
            voiceDelivery: .appOwned
        )
        XCTAssertTrue(claude.contains(#""autoCompactEnabled":true"#))
        XCTAssertTrue(claude.contains(#""SessionStart":[{"hooks""#))
        // Relay doesn't accept Claude's bypass-permissions disclaimer for the
        // user; the terminal holds voice until they have answered it.
        XCTAssertFalse(claude.contains("skipDangerousModePermissionPrompt"))

        config.general.provider = .codex
        let codex = ProcessManager.launchScript(
            relayBridge: "/Relay Runner/scripts/relay-bridge",
            target: .codex,
            agentBinary: "/usr/local/bin/codex",
            config: config,
            voiceDelivery: .appOwned
        )
        XCTAssertFalse(codex.contains("SessionStart"))
        XCTAssertFalse(codex.contains("autoCompactEnabled"))
    }

    func testFreshClaudeProfileDoesNotReceiveVoiceInFirstRunDialog() throws {
        for (providerName, target, needsSessionStart) in [
            ("Claude", ProcessManager.AgentTarget.claude, true),
            ("Codex", ProcessManager.AgentTarget.codex, false),
        ] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("relay-first-run-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let events = directory.appendingPathComponent("events.jsonl")
            try #"{"stage":"provider_spawn","outcome":"started"}"#.write(
                to: events, atomically: true, encoding: .utf8
            )
            let paths = deliveryPaths(in: directory)
            try "ping\n".write(toFile: paths.command, atomically: true, encoding: .utf8)
            let metadata = """
            {"provider":"\(providerName.lowercased())","relay_command_id":"cmd-1","relay_command_seq":1}
            """
            try metadata.write(toFile: paths.metadata, atomically: true, encoding: .utf8)
            try metadata.write(toFile: paths.commandState, atomically: true, encoding: .utf8)

            let process = SwiftTermEmbeddedProcess(
                readinessStabilityInterval: 0.1,
                readinessPollInterval: 0.02,
                voiceDeliveryPaths: paths
            )
            let session = EmbeddedTerminalSession(processFactory: { process })
            try session.beginPreparing(
                providerName: providerName,
                providerKey: providerName.lowercased(),
                workingDirectory: directory.path
            )
            // A raw-mode first-run dialog: it looks like a ready prompt and
            // would take typed input as an answer.
            try session.start(ProcessManager.PreparedSessionLaunch(
                executable: "/bin/bash",
                arguments: ["-c", """
                    stty -icanon -echo
                    printf 'Do you trust the files in this folder?\\r\\n'
                    IFS= read -r line
                    printf 'dialog answered: %s\\r\\n' "$line"
                    sleep 5
                    """],
                launcherPath: "/bin/bash",
                workingDirectory: directory.path,
                target: target,
                voiceDelivery: .appOwned,
                sessionEventPath: events.path,
                providerSessionID: "first-run-\(providerName.lowercased())"
            ))
            let host = EmbeddedTerminalHostNSView()
            host.install(session.hostedView)

            waitForMainQueue(after: 0.6)
            if needsSessionStart {
                XCTAssertTrue(FileManager.default.fileExists(atPath: paths.command), providerName)
                XCTAssertEqual(session.phase, .starting, providerName)

                // Relay's SessionStart hook runs once Claude's first-run
                // screens are done.
                let handle = try FileHandle(forWritingTo: events)
                handle.seekToEndOfFile()
                handle.write(Data("\n{\"outcome\":\"ready\",\"stage\":\"provider_session_start\"}\n".utf8))
                try handle.close()
                waitForMainQueue(after: 0.6)
            }
            XCTAssertEqual(session.phase, .running, providerName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.command), providerName)
            session.end()
        }
    }

    // MARK: - Helpers

    private func deliveryPaths(in directory: URL) -> RelayVoiceCommandDelivery.Paths {
        RelayVoiceCommandDelivery.Paths(
            command: directory.appendingPathComponent("command").path,
            metadata: directory.appendingPathComponent("metadata").path,
            claimed: directory.appendingPathComponent("claimed").path,
            commandState: directory.appendingPathComponent("command-state").path,
            providerTurns: directory.appendingPathComponent("provider-turns").path,
            deliveryEvents: directory.appendingPathComponent("delivery-events").path,
            actionJournal: directory.appendingPathComponent("action-journal").path,
            voiceInput: directory.appendingPathComponent("voice-input").path,
            heartbeat: directory.appendingPathComponent("heartbeat").path
        )
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func waitForMainQueue(after delay: TimeInterval) {
        let waited = expectation(description: "waited")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { waited.fulfill() }
        wait(for: [waited], timeout: delay + 1)
    }
}

/// Runs the real subscription gate against a fake `claude` in a throwaway
/// HOME, so the user's own settings and credentials never take part.
private final class GateFixture {
    let home: URL
    let claude: URL

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-claude-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        claude = home.appendingPathComponent("claude")
        try "#!/bin/sh\ncat \"$(dirname \"$0\")/status.json\"\n"
            .write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: home)
    }

    func check(
        status: String,
        environment: [String: String] = [:],
        prelude: String = ""
    ) throws -> ProcessManager.ClaudeSubscriptionCheck {
        defer { try? FileManager.default.removeItem(at: home.appendingPathComponent("status.json")) }
        try status.write(to: home.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return ProcessManager.checkClaudeSubscription(
            agentBinary: claude.path,
            workingDirectory: home.path,
            shellPrelude: prelude,
            pythonPath: "/usr/bin/python3",
            gatePath: repo.appendingPathComponent("services/claude_subscription.py").path,
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        )
    }
}
