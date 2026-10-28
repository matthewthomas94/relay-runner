import XCTest
@testable import relay_runner

final class AssistantSessionStoreTests: XCTestCase {
    func testBuiltInProjectDisplayNamePreservesStoredContextIdentity() throws {
        let path = AssistantSessionStore.rootDirectory.appendingPathComponent("general-tasks").path
        let context = AssistantSessionContext(kind: .project, projectID: "built-in", repositoryPath: path)
        let restored = try JSONDecoder().decode(AssistantSessionContext.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(restored.displayName, "general")
        XCTAssertEqual(restored.id, "project:built-in")
        XCTAssertEqual(restored.repositoryPath, path)
        let unrelated = AssistantSessionContext(kind: .project, projectID: "other", repositoryPath: "/other/general-tasks")
        XCTAssertEqual(unrelated.displayName, "general-tasks")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testCleanAndInterruptedRestartPreserveContextAndHistoryWithoutExecution() throws {
        let directory = try temporaryDirectory()
        let store = AssistantSessionStore(directory: directory)
        let project = AssistantSessionContext(kind: .project, projectID: "stable-project", repositoryPath: "/missing/project")
        try store.select(project, provider: "codex", model: "sol")
        try store.append(AssistantConversationEntry(id: "one", contextID: project.id, role: .user, text: "Completed request", createdAt: Date()))
        try store.begin(context: project, provider: "codex", model: "sol", transportSessionID: UUID().uuidString)
        try store.reconcile(context: project, activeRunIDs: [42], pendingIntentIDs: ["intent-existing"])
        let restored = AssistantSessionStore(directory: directory)
        XCTAssertEqual(restored.conversationID, store.conversationID)
        XCTAssertEqual(restored.activeContext, project)
        XCTAssertEqual(restored.history(for: project).map(\.text), ["Completed request"])
        XCTAssertEqual(restored.binding(for: project)?.lifecycle, .interrupted)
        XCTAssertEqual(restored.binding(for: project)?.activeRunIDs, [42])
        XCTAssertEqual(restored.binding(for: project)?.pendingIntentIDs, ["intent-existing"])
        try restored.mark(.saved, context: project)
        XCTAssertEqual(AssistantSessionStore(directory: directory).binding(for: project)?.lifecycle, .saved)
    }

    func testEveryActiveObligationProtectsProviderReplacement() {
        XCTAssertTrue(AssistantSessionStore.canReplace(recording: false, noteCapture: false, foregroundTurn: false, pendingCommand: false, approval: false, launching: false))
        for index in 0..<6 {
            var flags = Array(repeating: false, count: 6)
            flags[index] = true
            XCTAssertFalse(AssistantSessionStore.canReplace(recording: flags[0], noteCapture: flags[1], foregroundTurn: flags[2], pendingCommand: flags[3], approval: flags[4], launching: flags[5]))
        }
    }

    func testSelectKeepsRunningBindingsAndSavesOnlyStoppedOnes() throws {
        let directory = try temporaryDirectory()
        let store = AssistantSessionStore(directory: directory)
        let codex = AssistantSessionContext(kind: .project, projectID: "codex-project", repositoryPath: "/repo/a")
        let claude = AssistantSessionContext(kind: .project, projectID: "claude-project", repositoryPath: "/repo/b")
        try store.begin(context: codex, provider: "codex", model: "sol", transportSessionID: "codex-transport")
        try store.mark(.running, context: codex)
        try store.begin(context: claude, provider: "claude", model: "sonnet", transportSessionID: "claude-transport")
        try store.mark(.running, context: claude)

        // Focusing another context never implies the previous one stopped.
        try store.select(codex, provider: "codex", model: "sol", savingPreviousContext: true)
        XCTAssertEqual(store.binding(for: claude)?.lifecycle, .running)
        XCTAssertEqual(store.binding(for: codex)?.lifecycle, .running)

        // A process exit marks only its own context; switching away then saves it.
        try store.mark(.interrupted, context: codex)
        XCTAssertEqual(store.binding(for: claude)?.lifecycle, .running)
        try store.select(claude, provider: "claude", model: "sonnet", savingPreviousContext: true)
        XCTAssertEqual(store.binding(for: codex)?.lifecycle, .saved)
        XCTAssertEqual(store.binding(for: claude)?.lifecycle, .running)

        // Both bindings persist and resume with their own provider.
        let restored = AssistantSessionStore(directory: directory)
        XCTAssertEqual(restored.binding(for: codex)?.provider, "codex")
        XCTAssertEqual(restored.binding(for: codex)?.transportSessionID, "codex-transport")
        XCTAssertEqual(restored.binding(for: claude)?.provider, "claude")
        XCTAssertEqual(restored.binding(for: claude)?.transportSessionID, "claude-transport")
    }

    func testFailedContextTransitionRetainsSourceProviderAndCompleteDocument() throws {
        let directory = try temporaryDirectory()
        let store = AssistantSessionStore(directory: directory)
        let transport = UUID().uuidString.lowercased(), native = UUID().uuidString.lowercased()
        try store.begin(context: .general, provider: "codex", model: "sol", transportSessionID: transport)
        let sidecar = store.bindingURL(transportSessionID: transport)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "context_id": "general", "provider": "codex", "provider_session_id": transport,
            "native_session_id": native, "working_directory": AssistantSessionContext.general.workingDirectory,
            "provider_pid": 42, "provider_process_identity": "source birth uid group",
        ]).write(to: sidecar)
        try store.reconcile(context: .general, activeRunIDs: [7], pendingIntentIDs: ["current-command"])
        let before = store.document
        let url = directory.appendingPathComponent("conversation-v1.json")
        let previousURL = directory.appendingPathComponent("previous.json")
        let beforeBytes = try Data(contentsOf: url)
        // Force the atomic replacement itself to fail, after serialization
        // and permission setup have succeeded for the new temporary document.
        try FileManager.default.moveItem(at: url, to: previousURL)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let destination = AssistantSessionContext(kind: .project, projectID: "destination", repositoryPath: "/repo")
        XCTAssertThrowsError(try store.select(destination, provider: "claude", model: "sonnet", savingPreviousContext: true))
        XCTAssertEqual(store.document, before)
        XCTAssertEqual(store.activeContext, .general)
        XCTAssertEqual(store.binding(for: .general)?.lifecycle, .starting)
        XCTAssertEqual(store.binding(for: .general)?.nativeSessionID, native)
        XCTAssertEqual(store.managedProviderProcesses, [AssistantManagedProviderProcess(pid: 42, identity: "source birth uid group")])
        XCTAssertEqual(try Data(contentsOf: previousURL), beforeBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: previousURL, to: url)
        XCTAssertEqual(AssistantSessionStore(directory: directory).activeContext, .general)

        try store.select(destination, provider: "claude", model: "sonnet", savingPreviousContext: true)
        XCTAssertEqual(store.activeContext, destination)
        // RR-394: the source session keeps running beside the destination.
        XCTAssertEqual(store.binding(for: .general)?.lifecycle, .starting)
        XCTAssertEqual(store.binding(for: .general)?.nativeSessionID, native)
        XCTAssertEqual(store.binding(for: .general)?.activeRunIDs, [7])
        XCTAssertEqual(store.history(for: destination).map(\.text), ["Switched to repo"])
        XCTAssertEqual(try JSONDecoder().decode(AssistantSessionStore.Document.self, from: Data(contentsOf: url)), store.document)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRestartDuringSwitchRetainsSourceProcessOwnership() throws {
        let directory = try temporaryDirectory()
        let store = AssistantSessionStore(directory: directory)
        let transport = UUID().uuidString.lowercased()
        try store.begin(context: .general, provider: "codex", model: "sol", transportSessionID: transport)
        let sidecar = store.bindingURL(transportSessionID: transport)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["context_id": "general", "provider": "codex", "provider_session_id": transport, "working_directory": AssistantSessionContext.general.workingDirectory, "provider_pid": 42, "provider_process_identity": "exact source birth"]).write(to: sidecar)
        try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
        let destination = AssistantSessionContext(kind: .project, projectID: "destination", repositoryPath: "/repo")
        try store.select(destination, provider: "codex", model: "sol")
        // Selection is durable before process teardown. A crash at that point
        // must not hide the source process from replacement reconciliation.
        let restored = AssistantSessionStore(directory: directory)
        XCTAssertEqual(restored.activeContext, destination)
        XCTAssertEqual(restored.managedProviderProcesses, [AssistantManagedProviderProcess(pid: 42, identity: "exact source birth")])
        XCTAssertEqual(restored.binding(for: .general)?.lifecycle, .interrupted)
    }

    func testMovedProjectKeepsItsHistoryWithTheConfirmedCurrentPath() throws {
        let store = AssistantSessionStore(directory: try temporaryDirectory())
        let original = AssistantSessionContext(kind: .project, projectID: "stable", repositoryPath: "/old/project")
        let moved = AssistantSessionContext(kind: .project, projectID: "stable", repositoryPath: "/new/project")
        try store.select(original, provider: "codex", model: "sol")
        try store.append(AssistantConversationEntry(id: "one", contextID: original.id, role: .user, text: "Saved request", createdAt: Date()))
        try store.select(moved, provider: "codex", model: "sol")
        XCTAssertEqual(store.binding(for: moved)?.context, moved)
        XCTAssertEqual(store.history(for: moved).map(\.text), ["Saved request"])
        try store.begin(context: moved, provider: "codex", model: "sol", transportSessionID: UUID().uuidString)
        XCTAssertEqual(store.binding(for: moved)?.context, moved)
    }

    func testGeneralHasNoProjectAndHandoffContainsOnlyDestinationHistory() throws {
        let store = AssistantSessionStore(directory: try temporaryDirectory())
        let project = AssistantSessionContext(kind: .project, projectID: "project", repositoryPath: "/repo")
        try store.select(.general, provider: "claude", model: "sonnet")
        try store.append(AssistantConversationEntry(id: "general", contextID: "general", role: .user, text: "General request", createdAt: Date()))
        try store.select(project, provider: "claude", model: "sonnet")
        try store.append(AssistantConversationEntry(id: "project", contextID: project.id, role: .user, text: "Private project request", createdAt: Date()))
        XCTAssertNil(AssistantSessionContext.general.repositoryPath)
        XCTAssertTrue(AssistantSessionContext.general.workingDirectory.hasSuffix("relay-runner/files"))
        XCTAssertEqual(store.publicHandoff(for: .general), "user: General request")
        XCTAssertFalse(store.publicHandoff(for: .general).contains("Private"))
    }

    func testNativeBindingRequiresExactScopeProviderTransportAndDirectory() throws {
        let directory = try temporaryDirectory()
        let store = AssistantSessionStore(directory: directory)
        let transport = UUID().uuidString.lowercased(), native = UUID().uuidString.lowercased()
        try store.begin(context: .general, provider: "codex", model: "sol", transportSessionID: transport)
        let url = store.bindingURL(transportSessionID: transport)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var record: [String: Any] = ["context_id": "project:wrong", "provider": "codex", "provider_session_id": transport, "native_session_id": native, "working_directory": AssistantSessionContext.general.workingDirectory]
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
        XCTAssertNil(store.binding(for: .general)?.nativeSessionID)
        record["context_id"] = "general"
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
        XCTAssertEqual(store.binding(for: .general)?.nativeSessionID, native)
        try store.begin(context: .general, provider: "claude", model: "sonnet", transportSessionID: UUID().uuidString)
        XCTAssertNil(store.binding(for: .general)?.nativeSessionID)
    }

    func testStartupOnlyResumePreservesValidatedTranscriptAcrossAnotherCrashForBothProviders() throws {
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            let home = try temporaryDirectory(), directory = home.appendingPathComponent("state")
            let store = AssistantSessionStore(directory: directory)
            let provider = target.providerMetadataValue, model = target == .codex ? "sol" : "sonnet"
            let native = UUID().uuidString.lowercased(), transport = UUID().uuidString.lowercased()
            let root = target == .codex ? ".codex/sessions" : ".claude/projects"
            let transcript = home.appendingPathComponent("\(root)/rollout-\(native).jsonl")
            try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
            let message: [String: Any] = ["type": "message", "role": "user", "content": [["type": "text", "text": "Completed before crash"]]]
            let record: [String: Any] = target == .codex
                ? ["type": "response_item", "payload": message] : ["type": "user", "message": message]
            var transcriptData = try JSONSerialization.data(withJSONObject: record)
            transcriptData.append(10)
            try transcriptData.write(to: transcript)
            try store.begin(context: .general, provider: provider, model: model, transportSessionID: transport)
            let sidecar = store.bindingURL(transportSessionID: transport)
            try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
            var nativeRecord: [String: Any] = ["context_id": "general", "provider": provider,
                "provider_session_id": transport, "native_session_id": native,
                "working_directory": AssistantSessionContext.general.workingDirectory, "transcript_path": transcript.path]
            try JSONSerialization.data(withJSONObject: nativeRecord).write(to: sidecar)
            try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
            try store.importPublicHistory(context: .general, providerHome: home)
            try store.mark(.running, context: .general)

            let resumed = AssistantSessionStore(directory: directory)
            XCTAssertEqual(resumed.binding(for: .general)?.lifecycle, .interrupted)
            XCTAssertEqual(resumed.binding(for: .general)?.resumableNativeSessionID, native)
            let resumedTransport = UUID().uuidString.lowercased()
            try resumed.begin(context: .general, provider: provider, model: model, transportSessionID: resumedTransport)
            nativeRecord["provider_session_id"] = resumedTransport
            nativeRecord["transcript_path"] = NSNull()
            try JSONSerialization.data(withJSONObject: nativeRecord).write(to: resumed.bindingURL(transportSessionID: resumedTransport))
            try resumed.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
            XCTAssertEqual(resumed.binding(for: .general)?.transcriptPath, transcript.path)
            XCTAssertEqual(resumed.binding(for: .general)?.transcriptOffset, UInt64(transcriptData.count))
            try resumed.mark(.running, context: .general)
            // The resumed provider exits before new input or a transcript event.
            try resumed.mark(.interrupted, context: .general)
            let recovered = AssistantSessionStore(directory: directory)
            XCTAssertEqual(recovered.binding(for: .general)?.lifecycle, .interrupted)
            XCTAssertEqual(recovered.binding(for: .general)?.resumableNativeSessionID, native)
            XCTAssertEqual(recovered.history(for: .general).map(\.text), ["Completed before crash"])
            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            config.general.working_directory = AssistantSessionContext.general.workingDirectory
            let script = ProcessManager.launchScript(relayBridge: "/fixture/relay-bridge", target: target,
                agentBinary: "/fixture/provider", config: config, voiceDelivery: .appOwned,
                sessionContext: .general, nativeResumeID: recovered.binding(for: .general)?.resumableNativeSessionID)
            XCTAssertTrue(script.contains(target == .codex ? "resume '\(native)'" : "--resume '\(native)'"))
            XCTAssertFalse(script.contains("Completed before crash"))
        }
    }

    func testChangedStartupNativeUUIDClearsPreviousTranscriptForBothProviders() throws {
        for provider in ["codex", "claude"] {
            let directory = try temporaryDirectory(), store = AssistantSessionStore(directory: directory)
            let transport = UUID().uuidString.lowercased(), native = UUID().uuidString.lowercased()
            try store.begin(context: .general, provider: provider, model: "model", transportSessionID: transport)
            let sidecar = store.bindingURL(transportSessionID: transport)
            try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
            var record: [String: Any] = ["context_id": "general", "provider": provider,
                "provider_session_id": transport, "native_session_id": native,
                "working_directory": AssistantSessionContext.general.workingDirectory,
                "transcript_path": "/provider/rollout-\(native).jsonl"]
            try JSONSerialization.data(withJSONObject: record).write(to: sidecar)
            try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
            XCTAssertEqual(store.binding(for: .general)?.resumableNativeSessionID, native)
            // The transcript file was never written, so a launch starts fresh.
            XCTAssertNil(store.binding(for: .general)?.launchableNativeSessionID)
            let transcript = directory.appendingPathComponent("rollout-\(native).jsonl")
            try Data().write(to: transcript)
            record["transcript_path"] = transcript.path
            try JSONSerialization.data(withJSONObject: record).write(to: sidecar)
            try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
            XCTAssertEqual(store.binding(for: .general)?.launchableNativeSessionID, native)
            let changedNative = UUID().uuidString.lowercased()
            record["native_session_id"] = changedNative
            record["transcript_path"] = NSNull()
            try JSONSerialization.data(withJSONObject: record).write(to: sidecar)
            try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
            let restored = AssistantSessionStore(directory: directory)
            XCTAssertEqual(restored.binding(for: .general)?.nativeSessionID, changedNative)
            XCTAssertNil(restored.binding(for: .general)?.transcriptPath)
            XCTAssertNil(restored.binding(for: .general)?.transcriptOffset)
            XCTAssertNil(restored.binding(for: .general)?.resumableNativeSessionID)
        }
    }

    func testForgettingARefusedResumeLaunchesFreshForBothProviders() throws {
        for provider in ["codex", "claude"] {
            let directory = try temporaryDirectory(), store = AssistantSessionStore(directory: directory)
            let transport = UUID().uuidString.lowercased(), native = UUID().uuidString.lowercased()
            try store.begin(context: .general, provider: provider, model: "model", transportSessionID: transport)
            let sidecar = store.bindingURL(transportSessionID: transport)
            try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
            let transcript = directory.appendingPathComponent("rollout-\(native).jsonl")
            try Data().write(to: transcript)
            try JSONSerialization.data(withJSONObject: ["context_id": "general", "provider": provider,
                "provider_session_id": transport, "native_session_id": native,
                "working_directory": AssistantSessionContext.general.workingDirectory,
                "transcript_path": transcript.path]).write(to: sidecar)
            try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
            XCTAssertEqual(store.binding(for: .general)?.launchableNativeSessionID, native)

            try store.forgetNativeSession(context: .general)
            // The sidecar is gone too, so a later reconcile can't restore the refused id.
            try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
            let restored = AssistantSessionStore(directory: directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
            XCTAssertNil(restored.binding(for: .general)?.nativeSessionID)
            XCTAssertNil(restored.binding(for: .general)?.transcriptPath)
            XCTAssertNil(restored.binding(for: .general)?.launchableNativeSessionID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path), "The provider's transcript is left alone")
        }
    }

    func testPublicHistoryFiltersReasoningToolsAndScaffoldingAndParsesFractionalTime() throws {
        let lines = [
            #"{"type":"response_item","timestamp":"2026-10-11T06:00:00.123Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","channel":"analysis","content":[{"type":"output_text","text":"private reasoning"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"tool output"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"Developer setup"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"system","content":[{"type":"input_text","text":"System setup"}]}}"#,
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for repo"}]}}"##
        ].joined(separator: "\n")
        let entries = AssistantSessionStore.publicEntries(data: Data(lines.utf8), contextID: "general", nativeID: UUID().uuidString, provider: "codex")
        XCTAssertEqual(entries.map(\.text), ["Hello"])
        XCTAssertGreaterThan(entries[0].createdAt.timeIntervalSince1970, 1_700_000_000)
        let claude = #"{"type":"assistant","timestamp":"2026-10-11T06:00:00Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Public reply"},{"type":"tool_use","name":"shell"}]}}"#
        XCTAssertEqual(AssistantSessionStore.publicEntries(data: Data(claude.utf8), contextID: "general", nativeID: UUID().uuidString, provider: "claude").map(\.text), ["Public reply"])
    }

    func testStreamingHistoryRetainsMessagesBeforeLargeToolsAndImportsEachTurnOnce() throws {
        let home = try temporaryDirectory(), store = AssistantSessionStore(directory: home.appendingPathComponent("state"))
        let native = UUID().uuidString.lowercased(), transport = UUID().uuidString.lowercased()
        let transcript = home.appendingPathComponent(".codex/sessions/rollout-\(native).jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = #"{"type":"response_item","timestamp":"2026-10-11T06:00:00.123Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"One visible turn"}]}}"# + "\n"
        let tool = "{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\"" + String(repeating: "x", count: 5 * 1024 * 1024) + "\"}}\n"
        try Data((first + tool).utf8).write(to: transcript)
        try store.begin(context: .general, provider: "codex", model: "sol", transportSessionID: transport)
        let binding = store.bindingURL(transportSessionID: transport)
        try FileManager.default.createDirectory(at: binding.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["context_id": "general", "provider": "codex", "provider_session_id": transport, "native_session_id": native, "working_directory": AssistantSessionContext.general.workingDirectory, "transcript_path": transcript.path]).write(to: binding)
        try store.reconcile(context: .general, activeRunIDs: [], pendingIntentIDs: [])
        try store.importPublicHistory(context: .general, providerHome: home)
        XCTAssertEqual(store.history(for: .general).map(\.text), ["One visible turn"])
        XCTAssertEqual(store.binding(for: .general)?.transcriptOffset, UInt64(first.utf8.count + tool.utf8.count))
        let restored = AssistantSessionStore(directory: home.appendingPathComponent("state"))
        try restored.importPublicHistory(context: .general, providerHome: home)
        XCTAssertEqual(restored.history(for: .general).count, 1)
    }

    func testPublicUserTurnsStripOnlyKnownRelaySuffixForBothProviders() throws {
        let original = "For this runtime check, reply with exactly RELAY_GENERAL_READY_20261011.\nNo tools or actions are requested."
        let suffix = """


        Relay Runner command action:
        - action: direct_action
        - ticket_id: null

        Relay work-intent disposition:
        - route: continue_current
        - target_work_ids: none
        - conflicting_work_ids: none
        - mutation_authorization_effect: preserve
        - public_reason: The turn can proceed in the foreground orchestration context.

        Relay intent qualification (provisional):
        - bucket: discussion
        - source: deterministic
        - unresolved: false
        - mixed: false
        - command_id: 5153-1791700650794094000-42
        - command_seq: 42
        - This bucket does not authorize any effect.
        """
        for provider in ["codex", "claude"] {
            let message: [String: Any] = ["role": "user", "type": "message", "content": [["type": "text", "text": original + suffix]]]
            let record: [String: Any] = provider == "codex"
                ? ["type": "response_item", "payload": message]
                : ["type": "user", "message": message]
            let entries = AssistantSessionStore.publicEntries(data: try JSONSerialization.data(withJSONObject: record), contextID: "general", nativeID: UUID().uuidString, provider: provider)
            XCTAssertEqual(entries.map(\.text), [original], provider)
        }
        // A user discussing the heading without generated metadata keeps it.
        let quoted = "Explain this heading:\n\nRelay work-intent disposition:\nThis is my draft."
        XCTAssertEqual(AssistantSessionStore.publicUserText(quoted), quoted)
        let dispositionOnly = original + "\n\nRelay work-intent disposition:\n- route: continue_current\n- target_work_ids: none"
        XCTAssertEqual(AssistantSessionStore.publicUserText(dispositionOnly), original)
    }

    func testGeneratedCommandActionPrefixRetainsOnlyItsSourceForBothProvidersAndSavedHistory() throws {
        let original = "For this runtime check only, reply with RELAY_QUEUED_SWITCH_20261011.\n\nSource command:\nThis is part of my actual request."
        let wrapper = """
        Relay Runner command action:
        - action: create_ticket
        - ticket_id: null
        - outcome_to_report: project work needs refined ticket
        - repo_path: /managed/files
        - reason: project work needs a refined visible ticket before dispatch; keep raw Relay transcript private
        - relay_command_seq: 43
        - relay_command_id: 55965-1791702285682096000-43

        PM frontstage contract:
        - You are the PM frontstage for the user, not the implementation worker.
        - Keep the user-facing response concise and status-oriented.
        - Creating or editing visible tickets is PM management work.

        Source command:
        """ + "\n" + original + "\n\nRelay work-intent disposition:\n- route: continue_current"
        XCTAssertEqual(AssistantSessionStore.publicUserText(wrapper), original)
        for provider in ["codex", "claude"] {
            let message: [String: Any] = ["role": "user", "type": "message", "content": [["type": "text", "text": wrapper]]]
            let record: [String: Any] = provider == "codex" ? ["type": "response_item", "payload": message] : ["type": "user", "message": message]
            XCTAssertEqual(AssistantSessionStore.publicEntries(data: try JSONSerialization.data(withJSONObject: record), contextID: "general", nativeID: UUID().uuidString, provider: provider).map(\.text), [original])
        }
        let quote = "Relay Runner command action:\n- action: explain this heading\n\nSource command:\nKeep my document intact."
        XCTAssertEqual(AssistantSessionStore.publicUserText(quote), quote)
        let root = try temporaryDirectory()
        var document = AssistantSessionStore.Document()
        document.history = [AssistantConversationEntry(id: "original-public-id", contextID: "general", role: .user, text: wrapper, createdAt: Date())]
        try JSONEncoder().encode(document).write(to: root.appendingPathComponent("conversation-v1.json"))
        let restored = AssistantSessionStore(directory: root)
        XCTAssertEqual(restored.history(for: .general).map(\.text), [original])
        XCTAssertEqual(restored.history(for: .general).first?.id, "original-public-id")
        XCTAssertFalse(restored.publicHandoff(for: .general).contains("PM frontstage contract"))
    }

    func testPreviouslySavedUserMetadataIsRemovedWithoutChangingTurnIdentity() throws {
        let directory = try temporaryDirectory()
        let original = "Preserve this user's request."
        let injected = original + "\n\nRelay intent qualification (provisional):\n- bucket: discussion\n- command_seq: 42"
        let entry = AssistantConversationEntry(id: "existing-public-turn", contextID: "general", role: .user, text: injected, createdAt: Date())
        var document = AssistantSessionStore.Document()
        document.history = [entry, AssistantConversationEntry(id: "assistant", contextID: "general", role: .assistant, text: injected, createdAt: Date())]
        let url = directory.appendingPathComponent("conversation-v1.json")
        try JSONEncoder().encode(document).write(to: url)

        let restored = AssistantSessionStore(directory: directory)
        XCTAssertEqual(restored.history(for: .general).first?.text, original)
        XCTAssertEqual(restored.history(for: .general).first?.id, entry.id)
        XCTAssertEqual(restored.history(for: .general).last?.text, injected, "Assistant-authored text is preserved")
        XCTAssertTrue(restored.publicHandoff(for: .general).hasPrefix("user: \(original)\nassistant:"))
        try restored.select(.general, provider: "codex", model: "sol")
        let saved = try JSONDecoder().decode(AssistantSessionStore.Document.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.history.first?.text, original)
        XCTAssertEqual(saved.history.first?.id, entry.id)
    }

    func testClaudeNativePasteEnvelopeHidesOnlyRecognizedRelayRoutingOnImportAndLoad() throws {
        let original = "Continue this public request in the selected project.\nKeep this second line."
        let envelope = "\n\n<pasted_content id=\"bb63\">\n" + original + "\n\nRelay work-intent disposition:\n- route: continue_current\n- target_work_ids: none\n\nRelay intent qualification (provisional):\n- bucket: discussion\n- command_seq: 45\n\n</pasted_content id=\"bb63\">\n"
        let record: [String: Any] = ["type": "user", "timestamp": "2026-10-11T19:00:00.123Z", "sessionId": "native-claude", "message": ["role": "user", "content": [["type": "text", "text": envelope]]]]
        let entries = AssistantSessionStore.publicEntries(data: try JSONSerialization.data(withJSONObject: record), contextID: "general", nativeID: "native-claude", provider: "claude")
        XCTAssertEqual(entries.map(\.text), [original])

        let directory = try temporaryDirectory()
        var document = AssistantSessionStore.Document()
        document.history = [AssistantConversationEntry(id: "native-public-id", contextID: "general", role: .user, text: envelope, createdAt: Date())]
        try JSONEncoder().encode(document).write(to: directory.appendingPathComponent("conversation-v1.json"))
        let restored = AssistantSessionStore(directory: directory)
        XCTAssertEqual(restored.history(for: .general).map(\.text), [original])
        XCTAssertEqual(restored.history(for: .general).first?.id, "native-public-id")
        XCTAssertEqual(restored.publicHandoff(for: .general), "user: " + original)

        let literal = "\n\n<pasted_content id=\"bb63\">\nExplain this markup literally.\nRelay work-intent disposition:\nThis is my draft.\n</pasted_content id=\"bb63\">\n"
        XCTAssertEqual(AssistantSessionStore.publicUserText(literal), literal)
        let mismatched = literal.replacingOccurrences(of: "</pasted_content id=\"bb63\">", with: "</pasted_content id=\"other\">")
        XCTAssertEqual(AssistantSessionStore.publicUserText(mismatched), mismatched)
        let unmatched = "<pasted_content id=\"bb63\">\nKeep my unfinished literal example."
        XCTAssertEqual(AssistantSessionStore.publicUserText(unmatched), unmatched)
        let outside = "My example:\n" + literal
        XCTAssertEqual(AssistantSessionStore.publicUserText(outside), outside)
    }

    func testCorruptHistoryDoesNotOverwriteThePreviousConversation() throws {
        let directory = try temporaryDirectory(), url = directory.appendingPathComponent("conversation-v1.json")
        try Data("corrupt original".utf8).write(to: url)
        let store = AssistantSessionStore(directory: directory)
        XCTAssertNotNil(store.loadError)
        XCTAssertThrowsError(try store.select(.general, provider: "codex", model: "sol"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupt original")
    }

    func testBothProvidersUseExactNativeResumeAndGeneralScopeEnvironment() {
        let native = UUID().uuidString.lowercased(), transport = UUID().uuidString.lowercased()
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            config.general.working_directory = AssistantSessionContext.general.workingDirectory
            let script = ProcessManager.launchScript(relayBridge: "/app/scripts/relay-bridge", target: target, agentBinary: "/bin/provider", config: config, voiceDelivery: .appOwned, providerSessionID: transport, sessionContext: .general, conversationID: "conversation", nativeResumeID: native, providerBindingPath: "/private/bindings/\(transport).json")
            XCTAssertTrue(script.contains("export RELAY_SESSION_SCOPE='general'"))
            XCTAssertTrue(script.contains("unset RELAY_PROJECT_SCOPE_TOKEN RELAY_PROJECT_ID RELAY_PROJECT_SCOPE_VERSION"))
            XCTAssertTrue(script.contains(target == .codex ? "resume '\(native)'" : "--resume '\(native)'"))
            XCTAssertTrue(script.contains("general-tasks"))
            XCTAssertTrue(script.contains("dispatch_ticket"))
            let external = ProcessManager.launchScript(relayBridge: "/app/scripts/relay-bridge", target: target, agentBinary: "/bin/provider", config: config, voiceDelivery: .agentSkill, providerSessionID: transport, sessionContext: .general, conversationID: "conversation", providerBindingPath: "/private/bindings/\(transport).json")
            XCTAssertTrue(external.contains("export RELAY_PROVIDER_SESSION_ID='\(transport)'"))
            XCTAssertTrue(external.contains("--record-process"))
        }
    }

    func testNativeResumeUsesConfirmedMovedProjectDirectoryForBothProviders() {
        let native = UUID().uuidString.lowercased()
        let context = AssistantSessionContext(kind: .project, projectID: "stable", repositoryPath: "/new/repo's folder")
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            config.general.working_directory = context.workingDirectory
            let script = ProcessManager.launchScript(relayBridge: "/app/scripts/relay-bridge", target: target,
                agentBinary: "/bin/provider", config: config, voiceDelivery: .appOwned,
                sessionContext: context, nativeResumeID: native)
            let quotedPath = "'/new/repo'\\''s folder'"
            XCTAssertTrue(script.contains("cd \(quotedPath)"))
            XCTAssertTrue(script.contains(target == .codex
                ? "resume '\(native)' --cd \(quotedPath)"
                : "--resume '\(native)'"))
            if target == .claude { XCTAssertFalse(script.contains("--cd ")) }
        }
    }
}
