import Darwin
import XCTest
@testable import relay_runner
@testable import relay_actions_mcp

/// RR-443: a spoken project name resolves against the registry, and a project
/// the user names is registered only through the shared picker with their answer.
final class ProjectNameMatcherTests: XCTestCase {
    private let registry: [ProjectNameMatcher.Candidate] = [
        .init(projectID: "rr", displayName: "relay-runner", repoPath: "/Users/u/dev/relay-runner"),
        .init(projectID: "remote", displayName: "Relay Remote", repoPath: "/Users/u/dev/relay-remote-ios"),
        .init(projectID: "content", displayName: "Mentistic Content", repoPath: "/Users/u/dev/content_engine"),
        .init(projectID: "general", displayName: "general", repoPath: "/Users/u/Library/Application Support/relay-runner/general-tasks"),
        .init(projectID: "cafe", displayName: "Café Menu", repoPath: "/Users/u/dev/CafeMenu"),
    ]

    // MARK: Matching

    func testExactDisplayNameIgnoresCasePunctuationAndSpacing() {
        for spoken in ["relay-runner", "Relay Runner", "relay runner", "RelayRunner", "relay.runner!", "  RELAY   runner "] {
            let result = ProjectNameMatcher.match(spoken, in: registry)
            XCTAssertEqual(result.status, .exact, spoken)
            XCTAssertEqual(result.matches.map(\.candidate.projectID), ["rr"], spoken)
        }
        XCTAssertEqual(ProjectNameMatcher.match("cafe menu", in: registry).matches.first?.candidate.projectID, "cafe",
                       "Diacritics fold too")
        XCTAssertEqual(ProjectNameMatcher.match("the relay runner project", in: registry).status, .exact,
                       "Spoken filler around the name is ignored")
    }

    func testFolderNameMatchesWhenTheDisplayNameDiffers() {
        for spoken in ["content engine", "Content-Engine", "contentengine", "general tasks"] {
            let result = ProjectNameMatcher.match(spoken, in: registry)
            XCTAssertEqual(result.status, .folder, spoken)
            XCTAssertEqual(result.matches.count, 1, spoken)
        }
        XCTAssertEqual(ProjectNameMatcher.match("general tasks", in: registry).matches.first?.candidate.projectID, "general")
        XCTAssertEqual(ProjectNameMatcher.match("relay remote ios", in: registry).matches.first?.tier, .folder)
    }

    func testPathAndProjectIDAreExact() {
        XCTAssertEqual(ProjectNameMatcher.match("/Users/u/dev/content_engine/", in: registry).matches.map(\.candidate.projectID), ["content"])
        XCTAssertEqual(ProjectNameMatcher.match("/Users/u/dev/missing", in: registry).status, .none)
        XCTAssertEqual(ProjectNameMatcher.match("REMOTE", in: registry).status, .exact)
    }

    func testFuzzyFindsOneCloseName() {
        for spoken in ["relay runer", "relayrunnr", "mentistic contents"] {
            let result = ProjectNameMatcher.match(spoken, in: registry)
            XCTAssertEqual(result.status, .fuzzy, spoken)
            XCTAssertEqual(result.matches.count, 1, spoken)
            XCTAssertEqual(result.matches.first?.tier, .fuzzy, spoken)
        }
        XCTAssertEqual(ProjectNameMatcher.match("runner", in: registry).matches.map(\.candidate.projectID), ["rr"],
                       "A contained word still surfaces its project")
    }

    func testAmbiguousNamesEveryCandidate() {
        let partial = ProjectNameMatcher.match("relay", in: registry)
        XCTAssertEqual(partial.status, .ambiguous)
        XCTAssertEqual(Set(partial.matches.map(\.candidate.projectID)), ["rr", "remote"])

        let twins = registry + [.init(projectID: "rr-fork", displayName: "Relay Runner", repoPath: "/Users/u/forks/relay-runner")]
        let exact = ProjectNameMatcher.match("relay runner", in: twins)
        XCTAssertEqual(exact.status, .ambiguous)
        XCTAssertEqual(Set(exact.matches.map(\.candidate.projectID)), ["rr", "rr-fork"])
        XCTAssertTrue(exact.matches.allSatisfy { $0.tier == .exact })
    }

    func testNoMatch() {
        for spoken in ["banana bread", "zz", "", "  ", "!!!"] {
            let result = ProjectNameMatcher.match(spoken, in: registry)
            XCTAssertEqual(result.status, .none, spoken)
            XCTAssertTrue(result.matches.isEmpty, spoken)
        }
        XCTAssertEqual(ProjectNameMatcher.match("relay runner", in: []).status, .none)
    }

    func testLookupPayloadCarriesTheMatchForTheProvider() throws {
        let payload = ActionsConfirmBus.lookupPayload(ProjectNameMatcher.match("content engine", in: registry))
        XCTAssertEqual(payload["status"] as? String, "folder")
        let match = try XCTUnwrap((payload["matches"] as? [[String: Any]])?.first)
        XCTAssertEqual(match["project_id"] as? String, "content")
        XCTAssertEqual(match["display_name"] as? String, "Mentistic Content")
        XCTAssertEqual(match["folder_name"] as? String, "content_engine")
        XCTAssertEqual(match["repo_path"] as? String, "/Users/u/dev/content_engine")
        XCTAssertEqual(match["match"] as? String, "folder")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    // MARK: Registration requests

    func testRegisterRequestNeedsTheUsersAnswerAndValidName() {
        XCTAssertThrowsError(try VoiceProjectRegistration.request(kind: "existing", name: nil, userAnswer: nil)) {
            XCTAssertEqual($0 as? VoiceProjectRegistration.RequestError, .missingUserAnswer)
        }
        XCTAssertThrowsError(try VoiceProjectRegistration.request(kind: "new", name: "x", userAnswer: "  \n")) {
            XCTAssertEqual($0 as? VoiceProjectRegistration.RequestError, .missingUserAnswer)
        }
        XCTAssertThrowsError(try VoiceProjectRegistration.request(kind: "maybe", name: nil, userAnswer: "yes")) {
            XCTAssertEqual($0 as? VoiceProjectRegistration.RequestError, .invalidKind)
        }
        XCTAssertThrowsError(try VoiceProjectRegistration.request(kind: "new", name: " ", userAnswer: "a new one")) {
            XCTAssertEqual($0 as? VoiceProjectRegistration.RequestError, .nameRequired)
        }
        XCTAssertThrowsError(try VoiceProjectRegistration.request(kind: "existing", name: "foo", userAnswer: "existing")) {
            XCTAssertEqual($0 as? VoiceProjectRegistration.RequestError, .nameNotAllowed)
        }
        for name in ["../escape", "a/b", ".hidden", "..", "a:b", "tab\there"] {
            XCTAssertThrowsError(try VoiceProjectRegistration.request(kind: "new", name: name, userAnswer: "new"), name) {
                XCTAssertEqual($0 as? VoiceProjectRegistration.RequestError, .invalidName, name)
            }
        }
        XCTAssertEqual(try VoiceProjectRegistration.request(kind: "new", name: " Recipe Box ", userAnswer: "a new one called recipe box"),
                       .init(kind: .new, name: "Recipe Box"))
        XCTAssertEqual(try VoiceProjectRegistration.request(kind: "existing", name: nil, userAnswer: "it already exists"),
                       .init(kind: .existing, name: nil))
    }

    func testPickerMessageNamesNoLocation() throws {
        let new = try VoiceProjectRegistration.request(kind: "new", name: "Recipe Box", userAnswer: "new")
        XCTAssertFalse(VoiceProjectRegistration.pickerMessage(for: new).contains("/"))
        XCTAssertTrue(VoiceProjectRegistration.pickerMessage(for: new).contains("Recipe Box"))
        XCTAssertEqual(VoiceProjectRegistration.pickerMessage(for: .init(kind: .existing, name: nil)), "Choose an existing project folder")
    }

    // MARK: MCP tools

    func testRegisterToolRefusesWithoutTheUsersAnswerBeforeReachingTheApp() async {
        var reachedApp = false
        var tool = RegisterProjectTool()
        tool.notify = { reachedApp = true; return true }
        tool.register = { _, _, _ in reachedApp = true; return .ok([:]) }
        for arguments: [String: Any] in [["kind": "existing"], ["kind": "new", "name": "x", "user_answer": " "], ["user_answer": "new"]] {
            do {
                _ = try await tool.call(arguments: arguments)
                XCTFail("\(arguments) should be refused")
            } catch {}
        }
        XCTAssertFalse(reachedApp)
    }

    func testRegistrationRequiresAnAppManagedTurnForBothProviders() {
        guard case .failed(let message) = ConfirmationClient.requestProjectRegistration(
            kind: "existing", name: nil, userAnswer: "existing", environment: [:]
        ) else { return XCTFail("A session without a native turn identity must be refused") }
        XCTAssertTrue(message.contains("app-managed"))
        XCTAssertEqual(ConfirmationClient.registrationTimeoutSeconds, ProcessManager.appOwnedActionsToolTimeoutSeconds)
        let codex = ProcessManager.appOwnedMCPEnvironmentFlag(target: .codex, voiceDelivery: .appOwned)
        XCTAssertTrue(codex.contains("mcp_servers.relay-actions.tool_timeout_sec=600"), "Codex waits for the picker as Claude does")
    }

    func testRegisterToolForwardsKindNameAndAnswer() async throws {
        var tool = RegisterProjectTool()
        tool.notify = { true }
        var forwarded: (String, String?, String)?
        tool.register = { kind, name, answer in
            forwarded = (kind, name, answer)
            return .ok(["project_id": "p", "repo_path": "/picked/Recipe Box", "project_scope_token": "t"])
        }
        let content = try await tool.call(arguments: ["kind": "new", "name": "Recipe Box", "user_answer": "a new one"])
        XCTAssertEqual(forwarded?.0, "new")
        XCTAssertEqual(forwarded?.1, "Recipe Box")
        XCTAssertEqual(forwarded?.2, "a new one")
        XCTAssertTrue((content.first?["text"] as? String)?.contains("\"project_scope_token\":\"t\"") == true)

        tool.register = { _, _, _ in .cancelled(message: "Nothing was registered.") }
        let cancelled = try await tool.call(arguments: ["kind": "existing", "user_answer": "existing"])
        XCTAssertEqual(cancelled.first?["text"] as? String, "Nothing was registered.")
    }

    func testFindToolReturnsTheMatchJSON() async throws {
        var tool = FindProjectTool()
        tool.notify = { true }
        tool.lookup = { name in
            XCTAssertEqual(name, "relay runner")
            return .ok(["match": ["status": "exact", "matches": []]])
        }
        let content = try await tool.call(arguments: ["name": "relay runner"])
        XCTAssertEqual(content.first?["text"] as? String, #"{"matches":[],"status":"exact"}"#)
    }

    // MARK: App socket

    func testAppSocketRefusesRegistrationWithoutAnswerOrTurnAndForwardsLookups() async throws {
        let registry = self.registry
        var registrations = 0
        let bus = ActionsConfirmBus(
            stateMachine: StateMachine(),
            onFindProject: { name, source in
                XCTAssertNil(source)
                return .found(ProjectNameMatcher.match(name, in: registry))
            },
            onRegisterProject: { request, answer, source in
                registrations += 1
                XCTAssertEqual(request, .init(kind: .existing, name: nil))
                XCTAssertEqual(answer, "it exists already")
                XCTAssertEqual(source["native_session_id"], "native")
                return .cancelled(message: "closed")
            }
        )
        let found = try await socketRequest(["type": "find_project", "name": "relay runner"], bus: bus)
        XCTAssertEqual(found["result"] as? String, "ok")
        XCTAssertEqual((found["match"] as? [String: Any])?["status"] as? String, "exact")

        let noAnswer = try await socketRequest(["type": "register_project", "kind": "existing", "source": ["native_session_id": "native"]], bus: bus)
        XCTAssertEqual(noAnswer["result"] as? String, "error")
        let noTurn = try await socketRequest(["type": "register_project", "kind": "existing", "user_answer": "it exists already"], bus: bus)
        XCTAssertEqual(noTurn["result"] as? String, "error")
        XCTAssertEqual(registrations, 0, "Refused before the app opens a picker")

        let closed = try await socketRequest(["type": "register_project", "kind": "existing", "user_answer": "it exists already",
                                              "source": ["native_session_id": "native"]], bus: bus)
        XCTAssertEqual(closed["result"] as? String, "cancelled")
        XCTAssertEqual(registrations, 1)
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

    // MARK: Source contracts

    func testVoiceRegistrationUsesTheSharedPresenterAndNoDefaultFolder() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appState = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"), encoding: .utf8)
        let start = try XCTUnwrap(appState.range(of: "func registerProjectByVoice("))
        let end = try XCTUnwrap(appState.range(of: "private static func activeCanonicalTurnID", range: start.upperBound..<appState.endIndex))
        let body = String(appState[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("WorkspaceDirectoryPicker.present("))
        XCTAssertTrue(body.contains("VoiceProjectRegistration.register("))
        for forbidden in ["directoryURL", "homeDirectory", "NSOpenPanel(", "NSSavePanel(", "createDirectory"] {
            XCTAssertFalse(body.contains(forbidden), forbidden)
        }
        let matcher = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/Board/ProjectNameMatcher.swift"), encoding: .utf8)
        for forbidden in ["directoryURL", "homeDirectory", "createDirectory", "store.save"] {
            XCTAssertFalse(matcher.contains(forbidden), forbidden)
        }
    }
}

/// RR-443: registering through the voice tools writes the same record as the
/// Add existing project and Create new project menu flows.
final class VoiceProjectRegistrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceProjectRegistrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExistingFolderMatchesAddExistingProject() throws {
        let folder = root.appendingPathComponent("picked/Existing Thing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let menu = try makeService("menu").registerExistingProject(at: folder)
        let voice = try VoiceProjectRegistration.register(
            .init(kind: .existing, name: nil), pickedFolder: folder, registry: makeService("voice")
        )
        XCTAssertEqual(voice, menu)
        XCTAssertEqual(voice.displayName, "Existing Thing")
    }

    func testNewProjectMatchesCreateNewProjectInsideThePickedParent() throws {
        let parent = root.appendingPathComponent("chosen-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("Recipe Box", isDirectory: true)

        let menu = try makeService("menu").createProject(at: target)
        try FileManager.default.removeItem(at: target)
        let voiceRegistry = makeService("voice")
        let voice = try VoiceProjectRegistration.register(
            .init(kind: .new, name: "Recipe Box"), pickedFolder: parent, registry: voiceRegistry
        )
        for keyPath in [\RegisteredProjectV2.projectID, \.displayName, \.selectedPath, \.lastResolvedPath] {
            XCTAssertEqual(voice[keyPath: keyPath], menu[keyPath: keyPath])
        }
        XCTAssertEqual(voice.worktreeKind, menu.worktreeKind)
        XCTAssertEqual(voice.remote, menu.remote)
        XCTAssertEqual(voice.availability, menu.availability)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["Recipe Box"],
                       "Only the named folder is created, inside the parent the user picked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(".git").path))
        XCTAssertEqual(try voiceRegistry.projects().map(\.projectID), [voice.projectID], "The registry is the only ledger")
    }

    func testNewProjectNeverAdoptsAnExistingFolder() throws {
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("Taken"), withIntermediateDirectories: true)
        let registry = makeService("voice")
        XCTAssertThrowsError(try VoiceProjectRegistration.register(.init(kind: .new, name: "Taken"), pickedFolder: parent, registry: registry))
        XCTAssertEqual(try registry.projects(), [])
    }

    private func makeService(_ name: String) -> ProjectRegistryV2Service {
        let state = root.appendingPathComponent("state-\(name)", isDirectory: true)
        let store = ProjectRegistryV2Store(
            primaryURL: state.appendingPathComponent("registry-v2.json"),
            backupURL: state.appendingPathComponent("registry-v2.backup.json"),
            quarantineDirectoryURL: state.appendingPathComponent("quarantine", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return ProjectRegistryV2Service(
            store: store,
            validator: ProjectRegistrationValidator(relayWorktreeRoots: []),
            accessGrants: RecordingAccessGrants(),
            appSupportRoot: root.appendingPathComponent("app-support-\(name)", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeProjectID: { "voice-project" }
        )
    }
}

private final class RecordingAccessGrants: ProjectAccessGrantManaging {
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
