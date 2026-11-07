import Darwin
import XCTest
@testable import relay_runner
@testable import relay_actions_mcp
@testable import relay_orchestrator_mcp

/// RR-442: the general session reaches every registered project, for Codex
/// and Claude alike, and nothing outside the registry.
final class GeneralSessionAccessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeneralSessionAccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Launch configuration

    func testGeneralLaunchGrantsEveryRegisteredPathAndTokenForBothProviders() throws {
        let fixture = try makeFixture()
        let access = GeneralSessionAccess.make(registry: fixture.service, sessionProject: fixture.general)

        XCTAssertEqual(Set(access.additionalDirectories), [fixture.alpha.lastResolvedPath, fixture.beta.lastResolvedPath])
        XCTAssertFalse(access.additionalDirectories.contains(fixture.general.lastResolvedPath), "The cwd is not re-added")
        XCTAssertEqual(Set(access.scopeTokens.map(\.projectID)), [fixture.general.projectID, fixture.alpha.projectID, fixture.beta.projectID])
        for token in access.scopeTokens {
            XCTAssertTrue(fixture.service.validateScopeToken(token).isValid, token.projectID)
        }
        let environment = try XCTUnwrap(access.tokensEnvironmentValue)
        let map = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(environment.utf8)) as? [String: String])
        XCTAssertEqual(map.count, 3)
        for token in access.scopeTokens {
            XCTAssertEqual(map[token.repositoryPath], token.encodedValue)
        }

        let generalToken = try fixture.service.scopeToken(matching: fixture.general.lastResolvedPath)
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            for delivery in [ProcessManager.SessionVoiceDelivery.appOwned, .agentSkill] {
                let label = "\(target) \(delivery)"
                let script = launchScript(target: target, delivery: delivery, workingDirectory: fixture.general.lastResolvedPath,
                                          token: generalToken, access: access)
                XCTAssertTrue(script.contains("export RELAY_PROJECT_SCOPE_TOKENS='\(environment)'"), label)
                XCTAssertTrue(script.contains("export RELAY_PROJECT_SCOPE_TOKEN='\(try XCTUnwrap(generalToken.encodedValue))'"), label)
                let arguments = try execArguments(script)
                for path in [fixture.alpha.lastResolvedPath, fixture.beta.lastResolvedPath] {
                    XCTAssertEqual(arguments.filter { $0 == "--add-dir=\(path)" }.count, 1, label)
                }
                XCTAssertFalse(arguments.contains("--add-dir=\(fixture.general.lastResolvedPath)"), label)
                XCTAssertFalse(arguments.contains("--add-dir"), "\(label): the = form keeps Claude's variadic flag from taking the prompt")
                if delivery == .agentSkill {
                    XCTAssertEqual(arguments.last, target == .claude ? "/relay-bridge" : "Use the relay-bridge skill now.", label)
                } else {
                    XCTAssertTrue(script.contains("This general session can read and edit every registered Relay project"), label)
                    XCTAssertTrue(script.contains("mcp__relay-actions__project_scope_token"), label)
                }
            }
        }
    }

    func testProjectSessionsKeepTheirSingleProjectLaunch() throws {
        let fixture = try makeFixture()
        XCTAssertEqual(GeneralSessionAccess.make(registry: fixture.service, sessionProject: fixture.alpha), .none)

        let token = try fixture.service.scopeToken(matching: fixture.alpha.lastResolvedPath)
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            let script = launchScript(target: target, delivery: .appOwned, workingDirectory: fixture.alpha.lastResolvedPath,
                                      token: token, access: .none)
            XCTAssertTrue(script.contains("unset RELAY_PROJECT_SCOPE_TOKENS"))
            XCTAssertFalse(script.contains("--add-dir"))
            XCTAssertFalse(script.contains("This general session can read and edit"))
        }
    }

    func testUnavailableProjectsGetNoDirectoryOrToken() throws {
        let fixture = try makeFixture()
        var document = try fixture.store.load().document
        let index = try XCTUnwrap(document.projects.firstIndex { $0.projectID == fixture.beta.projectID })
        document.projects[index].availability = .missing
        try fixture.store.save(document)

        let access = GeneralSessionAccess.make(registry: fixture.service, sessionProject: fixture.general)
        XCTAssertEqual(access.additionalDirectories, [fixture.alpha.lastResolvedPath])
        XCTAssertFalse(access.scopeTokens.contains { $0.projectID == fixture.beta.projectID })
    }

    func testCodexForwardsTheTokenMapOnlyToTheOrchestratorMCP() {
        let flag = ProcessManager.appOwnedMCPEnvironmentFlag(target: .codex, voiceDelivery: .appOwned)
        let orchestrator = flag.components(separatedBy: "-c ").first { $0.contains("mcp_servers.relay-orchestrator.env_vars=") }
        let actions = flag.components(separatedBy: "-c ").first { $0.contains("mcp_servers.relay-actions.env_vars=") }
        XCTAssertTrue(orchestrator?.contains("\"RELAY_PROJECT_SCOPE_TOKENS\"") == true)
        XCTAssertFalse(actions?.contains("RELAY_PROJECT_SCOPE_TOKENS") ?? true)
        XCTAssertTrue(actions?.contains("\"RELAY_CONTEXT_ID\"") == true, "project_scope_token identifies the general session")
        XCTAssertTrue(ProcessManager.appOwnedMCPEnvironmentFlag(target: .claude, voiceDelivery: .appOwned).isEmpty,
                      "Claude's MCP children inherit the provider environment")
    }

    // MARK: Token issuance

    func testTokenIssuanceServesOnlyTheGeneralSessionAndOnlyRegisteredProjects() throws {
        let fixture = try makeFixture()
        let generalContext = AssistantSessionContext.project(try fixture.service.scopeToken(matching: fixture.general.lastResolvedPath)).id

        let byPath = try GeneralSessionAccess.issueToken(for: fixture.alpha.lastResolvedPath, requestingContextID: generalContext,
                                                        registry: fixture.service)
        XCTAssertEqual(byPath.projectID, fixture.alpha.projectID)
        XCTAssertTrue(fixture.service.validateScopeToken(byPath).isValid)
        let byName = try GeneralSessionAccess.issueToken(for: "beta", requestingContextID: generalContext, registry: fixture.service)
        XCTAssertEqual(byName.projectID, fixture.beta.projectID)

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try makeGitRepo(at: outside)
        XCTAssertThrowsError(try GeneralSessionAccess.issueToken(for: outside.path, requestingContextID: generalContext,
                                                                registry: fixture.service)) { error in
            guard case ProjectRegistryV2Service.ServiceError.projectNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try GeneralSessionAccess.issueToken(for: "/", requestingContextID: generalContext, registry: fixture.service))

        let projectContext = AssistantSessionContext.project(try fixture.service.scopeToken(matching: fixture.alpha.lastResolvedPath)).id
        for context in [projectContext, "general", nil] as [String?] {
            XCTAssertThrowsError(try GeneralSessionAccess.issueToken(for: fixture.beta.lastResolvedPath, requestingContextID: context,
                                                                    registry: fixture.service)) { error in
                XCTAssertEqual(error as? GeneralSessionAccess.IssueError, .notGeneralSession)
            }
        }
    }

    func testProjectRegisteredMidSessionIsReachableWithoutRelaunch() throws {
        let fixture = try makeFixture()
        let generalContext = AssistantSessionContext.project(try fixture.service.scopeToken(matching: fixture.general.lastResolvedPath)).id
        let launch = GeneralSessionAccess.make(registry: fixture.service, sessionProject: fixture.general)
        try GeneralSessionAccess.syncClaudeSettings(registry: fixture.service)

        let gamma = try register("gamma", in: fixture)
        XCTAssertFalse(launch.additionalDirectories.contains(gamma.lastResolvedPath))

        let token = try GeneralSessionAccess.issueToken(for: gamma.lastResolvedPath, requestingContextID: generalContext,
                                                       registry: fixture.service)
        XCTAssertEqual(token.projectID, gamma.projectID)
        XCTAssertTrue(fixture.service.validateScopeToken(token).isValid)
        try GeneralSessionAccess.syncClaudeSettings(registry: fixture.service)
        XCTAssertTrue(try claudeDirectories(fixture).contains(gamma.lastResolvedPath))
    }

    // MARK: Claude mid-session directory settings

    func testClaudeSettingsTrackTheRegistryAndKeepTheUsersOwnEntries() throws {
        let fixture = try makeFixture()
        let settings = ClaudeGeneralSettings.settingsURL(projectRoot: URL(fileURLWithPath: fixture.general.lastResolvedPath))
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original: [String: Any] = [
            "permissions": ["allow": ["Bash(ls)"], "additionalDirectories": ["/user/own"]],
            "spinnerTipsEnabled": false,
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: settings)

        try GeneralSessionAccess.syncClaudeSettings(registry: fixture.service)
        XCTAssertEqual(try claudeDirectories(fixture), ["/user/own", fixture.alpha.lastResolvedPath, fixture.beta.lastResolvedPath].sorted())
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(written["spinnerTipsEnabled"] as? Bool, false)
        XCTAssertEqual((written["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls)"])
        let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let exclude = URL(fileURLWithPath: fixture.general.lastResolvedPath).appendingPathComponent(".git/info/exclude")
        XCTAssertTrue(try String(contentsOf: exclude, encoding: .utf8).contains(ClaudeGeneralSettings.excludePattern))
        XCTAssertFalse(try git(["status", "--porcelain", "--untracked-files=all"], in: URL(fileURLWithPath: fixture.general.lastResolvedPath))
            .contains("settings.local.json"))

        let before = try Data(contentsOf: settings)
        try GeneralSessionAccess.syncClaudeSettings(registry: fixture.service)
        XCTAssertEqual(try Data(contentsOf: settings), before, "An unchanged registry leaves the file alone")

        try fixture.service.removeProject(projectID: fixture.beta.projectID, confirmed: true)
        try GeneralSessionAccess.syncClaudeSettings(registry: fixture.service)
        XCTAssertEqual(try claudeDirectories(fixture), ["/user/own", fixture.alpha.lastResolvedPath].sorted(),
                       "A removed project is no longer granted; the user's own entry stays")
    }

    func testClaudeSettingsSyncNeverOverwritesAnUnreadableFile() throws {
        let fixture = try makeFixture()
        let settings = ClaudeGeneralSettings.settingsURL(projectRoot: URL(fileURLWithPath: fixture.general.lastResolvedPath))
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: settings)
        XCTAssertThrowsError(try GeneralSessionAccess.syncClaudeSettings(registry: fixture.service))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ not json")
    }

    // MARK: MCP token selection and the token tool

    func testOrchestratorMCPPicksTheTokenForTheRequestedRepository() {
        let environment = [
            "RELAY_PROJECT_SCOPE_TOKENS": #"{"/projects/alpha":"alpha-token","/projects/beta":"beta-token"}"#,
            "RELAY_PROJECT_SCOPE_TOKEN": "own-token",
        ]
        XCTAssertEqual(relay_orchestrator_mcp.projectScopeToken([:], repoPath: "/projects/beta/", environment: environment), "beta-token")
        XCTAssertEqual(relay_orchestrator_mcp.projectScopeToken(["project_scope_token": "explicit"], repoPath: "/projects/beta",
                                                                environment: environment), "explicit")
        XCTAssertEqual(relay_orchestrator_mcp.projectScopeToken([:], repoPath: "/projects/unlisted", environment: environment), "own-token",
                       "An unlisted repository falls back to the session's own token, which the daemon then refuses")
        XCTAssertEqual(relay_orchestrator_mcp.projectScopeToken([:], repoPath: nil, environment: environment), "own-token")
        XCTAssertNil(relay_orchestrator_mcp.projectScopeToken([:], repoPath: "/projects/alpha", environment: [:]))
    }

    func testProjectScopeTokenToolReturnsTheIssuedTokenOrTheRefusal() async throws {
        var requested: String?
        let tool = ProjectScopeTokenTool(notify: { true }, request: { project in
            requested = project
            return .issued(projectID: "project-alpha", displayName: "alpha", repoPath: "/projects/alpha", token: "token-value")
        })
        let content = try await tool.call(arguments: ["project": "alpha"])
        XCTAssertEqual(requested, "alpha")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(result, ["project_id": "project-alpha", "display_name": "alpha", "repo_path": "/projects/alpha",
                                "project_scope_token": "token-value"])

        let refused = ProjectScopeTokenTool(notify: { true }, request: { _ in .failed(message: "registered project not found: /outside") })
        do {
            _ = try await refused.call(arguments: ["project": "/outside"])
            XCTFail("A refusal must surface as a tool error")
        } catch {
            XCTAssertTrue(String(describing: error).contains("registered project not found"))
        }
        let unused = ProjectScopeTokenTool(notify: { XCTFail("No request without a project"); return true }, request: { _ in .menuBarUnavailable })
        do {
            _ = try await unused.call(arguments: ["project": "  "])
            XCTFail("An empty project must be refused")
        } catch {}
    }

    func testTokenRequestCarriesTheCallerContextThroughTheAppSocket() async throws {
        let fixture = try makeFixture()
        let issued = try fixture.service.scopeToken(matching: fixture.alpha.lastResolvedPath)
        let bus = ActionsConfirmBus(stateMachine: StateMachine(), onProjectScopeToken: { project, contextID in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(project, "alpha")
            return contextID == "project:general" ? .issued(issued, displayName: "alpha") : .failed(message: "not general")
        })

        let reply = try await socketRequest(["type": "project_scope_token", "project": "alpha", "context_id": "project:general"], bus: bus)
        XCTAssertEqual(reply["result"] as? String, "ok")
        XCTAssertEqual(reply["project_id"] as? String, fixture.alpha.projectID)
        XCTAssertEqual(reply["repo_path"] as? String, fixture.alpha.lastResolvedPath)
        XCTAssertEqual(reply["project_scope_token"] as? String, issued.encodedValue)

        let refused = try await socketRequest(["type": "project_scope_token", "project": "alpha"], bus: bus)
        XCTAssertEqual(refused["result"] as? String, "error")
        XCTAssertEqual(refused["message"] as? String, "not general")
        let empty = try await socketRequest(["type": "project_scope_token", "project": " "], bus: bus)
        XCTAssertEqual(empty["result"] as? String, "error")
    }

    // MARK: Fixtures

    private struct Fixture {
        let service: ProjectRegistryV2Service
        let store: ProjectRegistryV2Store
        let general: RegisteredProjectV2
        let alpha: RegisteredProjectV2
        let beta: RegisteredProjectV2
    }

    private var pendingProjectIDs: [String] = []

    private func makeFixture() throws -> Fixture {
        let state = root.appendingPathComponent("registry-state", isDirectory: true)
        let store = ProjectRegistryV2Store(
            primaryURL: state.appendingPathComponent("registry-v2.json"),
            backupURL: state.appendingPathComponent("registry-v2.backup.json"),
            quarantineDirectoryURL: state.appendingPathComponent("quarantine", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let service = ProjectRegistryV2Service(
            store: store,
            validator: ProjectRegistrationValidator(relayWorktreeRoots: []),
            accessGrants: AvailableAccessGrants(),
            appSupportRoot: root.appendingPathComponent("app-support", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeProjectID: { [unowned self] in self.pendingProjectIDs.removeFirst() }
        )
        pendingProjectIDs = ["general-tasks-id"]
        let general = try service.ensureGeneralTasksProject()
        let alpha = try register("alpha", service: service)
        let beta = try register("beta", service: service)
        return Fixture(service: service, store: store, general: general, alpha: alpha, beta: beta)
    }

    private func register(_ name: String, in fixture: Fixture) throws -> RegisteredProjectV2 {
        try register(name, service: fixture.service)
    }

    private func register(_ name: String, service: ProjectRegistryV2Service) throws -> RegisteredProjectV2 {
        let repo = root.appendingPathComponent("projects/\(name)", isDirectory: true)
        try makeGitRepo(at: repo)
        pendingProjectIDs.append("project-\(name)")
        return try service.register(candidate: service.inspect(selectedURL: repo), displayName: name)
    }

    private func claudeDirectories(_ fixture: Fixture) throws -> [String] {
        let settings = ClaudeGeneralSettings.settingsURL(projectRoot: URL(fileURLWithPath: fixture.general.lastResolvedPath))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        return ((object["permissions"] as? [String: Any])?["additionalDirectories"] as? [String] ?? []).sorted()
    }

    private func launchScript(
        target: ProcessManager.AgentTarget,
        delivery: ProcessManager.SessionVoiceDelivery,
        workingDirectory: String,
        token: ConfirmedProjectScopeToken,
        access: GeneralSessionAccess
    ) -> String {
        var config = AppConfig()
        config.general.provider = target == .codex ? .codex : .claude
        config.general.model = GeneralConfig.defaultModel(for: config.general.provider)
        config.general.working_directory = workingDirectory
        return ProcessManager.launchScript(
            relayBridge: "/Relay Runner/scripts/relay-bridge",
            target: target,
            agentBinary: target == .codex ? "/usr/local/bin/codex" : "/usr/local/bin/claude",
            config: config,
            voiceDelivery: delivery,
            resolvedCodexModel: "gpt-6.1-sol",
            resolvedCodexEffort: "high",
            projectScopeToken: token,
            generalAccess: access,
            sessionContext: .project(token)
        )
    }

    /// The argv the launcher's final `exec` produces, split by a real shell.
    /// Claude's appended prompt keeps literal newlines, so read to the end.
    private func execArguments(_ script: String) throws -> [String] {
        let start = try XCTUnwrap(script.range(of: "\nexec ", options: .backwards))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "printf '%s\\0' " + script[start.upperBound...]]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private func socketRequest(_ payload: [String: Any], bus: ActionsConfirmBus) async throws -> [String: Any] {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let client = descriptors[0]
        let server = descriptors[1]
        defer { close(client) }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        _ = data.withUnsafeBytes { send(client, $0.baseAddress!, $0.count, 0) }
        await Task.detached { await bus.handleConnection(fd: server) }.value
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let received = recv(client, &buffer, buffer.count, 0)
        XCTAssertGreaterThan(received, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer.prefix(max(received, 0)))) as? [String: Any])
    }

    private func makeGitRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try git(["init", "--quiet"], in: url)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return String(decoding: data, as: UTF8.self)
    }
}

private final class AvailableAccessGrants: ProjectAccessGrantManaging {
    private var urls: [String: URL] = [:]

    func storeGrant(for url: URL, projectID: String) throws -> ProjectBookmarkReference {
        urls[projectID] = url
        return .project(projectID)
    }

    func resolveGrant(reference: ProjectBookmarkReference) -> ProjectAccessGrantResolution {
        urls[reference.account].map { .available($0) } ?? .requiresRegrant(.missing, lastKnownURL: nil)
    }

    func releaseGrant(reference: ProjectBookmarkReference) throws {
        urls.removeValue(forKey: reference.account)
    }
}
