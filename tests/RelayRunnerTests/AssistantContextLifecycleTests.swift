import AppKit
import Darwin
import XCTest
@testable import relay_runner

final class AssistantContextLifecycleTests: XCTestCase {
    @MainActor
    func testIdleBoundarySavesBeforeEndingAndResumesExactNativeSessionForBothProviders() throws {
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            let directory = try temporaryDirectory()
            let store = AssistantSessionStore(directory: directory)
            let model = target == .codex ? "sol" : "sonnet"
            let started = Date(timeIntervalSince1970: 1_800_000_000)
            let native = UUID().uuidString.lowercased()
            let transport = UUID().uuidString.lowercased()
            try store.begin(context: .general, provider: target.providerMetadataValue, model: model,
                            transportSessionID: transport, now: started)
            try bind(store, context: .general, target: target, transport: transport, native: native)
            try store.append(AssistantConversationEntry(id: "public-turn", contextID: "general", role: .user,
                text: "Keep my completed request", createdAt: started))
            try store.mark(.running, context: .general, now: started)

            let first = LifecycleTerminalProcess(), resumed = LifecycleTerminalProcess()
            var processes = [first, resumed]
            let terminal = EmbeddedTerminalSession(processFactory: { processes.removeFirst() })
            try terminal.beginPreparing(providerName: target.providerMetadataValue, workingDirectory: directory.path)
            try terminal.start(launch(target: target, directory: directory))
            XCTAssertEqual(terminal.phase, .running)
            let before = store.document
            let boundary = started.addingTimeInterval(AssistantSessionStore.idleTimeout)
            var resets = 0
            func end() {
                let persisted = AssistantSessionStore(directory: directory)
                XCTAssertEqual(persisted.binding(for: .general)?.lifecycle, .saved,
                               "The durable save must precede termination")
                XCTAssertEqual(persisted.binding(for: .general)?.lastActivity, boundary)
                XCTAssertTrue(first.isRunning)
                terminal.end()
                resets += 1
            }
            XCTAssertFalse(try store.saveIfIdle(context: .general, now: boundary.addingTimeInterval(-0.001),
                                               eligible: terminal.phase == .running, end: end))
            XCTAssertEqual(store.document, before)
            XCTAssertEqual(first.terminateCount, 0)
            XCTAssertTrue(try store.saveIfIdle(context: .general, now: boundary,
                                              eligible: terminal.phase == .running, end: end))
            XCTAssertEqual(terminal.phase, .ended)
            XCTAssertEqual(first.terminateCount, 1)
            XCTAssertEqual(resets, 1)
            XCTAssertFalse(try store.saveIfIdle(context: .general, now: boundary.addingTimeInterval(1),
                                               eligible: terminal.phase == .running, end: end))

            let restored = AssistantSessionStore(directory: directory)
            XCTAssertEqual(restored.conversationID, store.conversationID)
            XCTAssertEqual(restored.binding(for: .general)?.nativeSessionID, native)
            XCTAssertEqual(restored.binding(for: .general)?.resumableNativeSessionID, native)
            XCTAssertEqual(restored.history(for: .general).map(\.id), ["public-turn"])
            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            config.general.model = model
            config.general.working_directory = AssistantSessionContext.general.workingDirectory
            let script = ProcessManager.launchScript(relayBridge: "/fixture/relay-bridge", target: target,
                agentBinary: "/fixture/provider", config: config, voiceDelivery: .appOwned,
                sessionContext: .general, nativeResumeID: restored.binding(for: .general)?.resumableNativeSessionID)
            XCTAssertTrue(script.contains(target == .codex ? "resume '\(native)'" : "--resume '\(native)'"))
            XCTAssertFalse(script.contains("Keep my completed request"), "Saved work must not be submitted again")
            try restored.begin(context: .general, provider: target.providerMetadataValue, model: model,
                               transportSessionID: UUID().uuidString.lowercased(), now: boundary)
            try terminal.beginPreparing(providerName: target.providerMetadataValue, workingDirectory: directory.path)
            try terminal.start(launch(target: target, directory: directory, script: script))
            XCTAssertEqual(terminal.phase, .running)
            XCTAssertEqual(resumed.launches.count, 1)
            XCTAssertEqual(restored.binding(for: .general)?.nativeSessionID, native)
            XCTAssertNotEqual(restored.binding(for: .general)?.transportSessionID, transport)
            XCTAssertEqual(restored.history(for: .general).map(\.id), ["public-turn"])
            terminal.end()
        }
    }

    @MainActor
    func testEveryProtectedObligationPreventsIdleSaveAndTermination() throws {
        let store = AssistantSessionStore(directory: try temporaryDirectory())
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        try store.begin(context: .general, provider: "codex", model: "sol", transportSessionID: "transport", now: started)
        let process = LifecycleTerminalProcess()
        let terminal = EmbeddedTerminalSession(processFactory: { process })
        try terminal.beginPreparing(providerName: "Codex", workingDirectory: store.directory.path)
        try terminal.start(launch(target: .codex, directory: store.directory))
        let before = store.document
        for protected in 0..<6 {
            var flags = Array(repeating: false, count: 6)
            flags[protected] = true
            let eligible = AssistantSessionStore.canReplace(recording: flags[0], noteCapture: flags[1],
                foregroundTurn: flags[2], pendingCommand: flags[3], approval: flags[4], launching: flags[5])
            XCTAssertFalse(try store.saveIfIdle(context: .general,
                now: started.addingTimeInterval(AssistantSessionStore.idleTimeout + 60), eligible: eligible,
                end: { terminal.end(); XCTFail("An active obligation must retain the provider") }))
            XCTAssertEqual(store.document, before)
            XCTAssertTrue(process.isRunning)
        }
        XCTAssertEqual(process.terminateCount, 0)
        terminal.end()
    }

    @MainActor
    func testFailedIdlePersistenceRetainsRunningTerminalAndPreviousDocument() throws {
        let directory = try temporaryDirectory(), store = AssistantSessionStore(directory: directory)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        try store.begin(context: .general, provider: "claude", model: "sonnet", transportSessionID: "transport", now: started)
        try store.mark(.running, context: .general, now: started)
        let before = store.document
        let documentURL = directory.appendingPathComponent("conversation-v1.json")
        let backupURL = directory.appendingPathComponent("previous.json")
        let previousBytes = try Data(contentsOf: documentURL)
        try FileManager.default.moveItem(at: documentURL, to: backupURL)
        try FileManager.default.createDirectory(at: documentURL, withIntermediateDirectories: false)
        let process = LifecycleTerminalProcess()
        let terminal = EmbeddedTerminalSession(processFactory: { process })
        try terminal.beginPreparing(providerName: "Claude", workingDirectory: directory.path)
        try terminal.start(launch(target: .claude, directory: directory))

        XCTAssertThrowsError(try store.saveIfIdle(context: .general,
            now: started.addingTimeInterval(AssistantSessionStore.idleTimeout), eligible: true,
            end: { terminal.end(); XCTFail("A failed durable save must not terminate the provider") }))
        XCTAssertEqual(store.document, before)
        XCTAssertEqual(terminal.phase, .running)
        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(process.terminateCount, 0)
        XCTAssertEqual(try Data(contentsOf: backupURL), previousBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
        terminal.end()
    }

    // Component integration: a private published run fixture and separately
    // owned child stand in for the daemon, which this test never contacts.
    func testForegroundContextSwitchRetainsOriginalWorkerOwnershipForBothProviders() async throws {
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            let directory = try temporaryDirectory(), store = AssistantSessionStore(directory: directory)
            let model = target == .codex ? "sol" : "sonnet"
            let project = AssistantSessionContext(kind: .project, projectID: "registered-project", repositoryPath: directory.path)
            let workerPID = try spawnChild(), foregroundPID = try spawnChild()
            let workerIdentity = try XCTUnwrap(AssistantManagedProviderProcess.identity(Int(workerPID)))
            let foregroundIdentity = try XCTUnwrap(AssistantManagedProviderProcess.identity(Int(foregroundPID)))
            let native = UUID().uuidString.lowercased(), transport = UUID().uuidString.lowercased()
            let runURL = directory.appendingPathComponent("published-runs.json")
            let runBytes = try JSONSerialization.data(withJSONObject: ["runs": [[
                "ticket_id": "FIXTURE-1", "repo_path": project.workingDirectory, "run_id": 421,
                "state": "Running", "provider_key": target.providerMetadataValue, "model_alias": model,
                "worker_pid": workerPID, "worker_process_identity": workerIdentity,
                "project_scope_token": "original-worker-authority", "artifact_id": "original-output"
            ]]], options: [.sortedKeys])
            try runBytes.write(to: runURL)
            let originalRuns = try JSONDecoder().decode(LifecycleRunIndex.self, from: runBytes).runs
            try store.begin(context: project, provider: target.providerMetadataValue, model: model, transportSessionID: transport)
            try bind(store, context: project, target: target, transport: transport, native: native,
                     pid: Int(foregroundPID), identity: foregroundIdentity, runIDs: originalRuns.map(\.runId))
            XCTAssertEqual(store.managedProviderProcesses.map(\.pid), [Int(foregroundPID)])

            try store.select(.general, provider: target.providerMetadataValue, model: model, savingPreviousContext: true)
            for process in store.managedProviderProcesses { XCTAssertTrue(process.requestTermination()) }
            for _ in 0..<100 where AssistantManagedProviderProcess.isAlive(Int(foregroundPID)) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(AssistantManagedProviderProcess.isAlive(Int(foregroundPID)))
            XCTAssertEqual(AssistantManagedProviderProcess(pid: Int(workerPID), identity: workerIdentity).state(), .matching)
            XCTAssertEqual(store.activeContext, .general)
            XCTAssertEqual(store.binding(for: project)?.activeRunIDs, [421])
            XCTAssertEqual(store.binding(for: project)?.nativeSessionID, native)
            XCTAssertEqual(store.binding(for: .general)?.activeRunIDs, [])
            XCTAssertEqual(store.binding(for: .general)?.pendingIntentIDs, [])
            try store.begin(context: .general, provider: target.providerMetadataValue, model: model, transportSessionID: UUID().uuidString)
            try store.select(project, provider: target.providerMetadataValue, model: model, savingPreviousContext: true)
            XCTAssertEqual(store.binding(for: project)?.nativeSessionID, native)
            XCTAssertEqual(store.binding(for: project)?.activeRunIDs, [421])
            XCTAssertEqual(AssistantManagedProviderProcess(pid: Int(workerPID), identity: workerIdentity).state(), .matching)
            XCTAssertEqual(try Data(contentsOf: runURL), runBytes, "Foreground switches cannot rewrite worker status, authority or artifacts")
            XCTAssertEqual(try JSONDecoder().decode(LifecycleRunIndex.self, from: Data(contentsOf: runURL)).runs, originalRuns)
        }
    }

    func testAppStateUsesTestedIdleAndScopedReplacementPaths() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"), encoding: .utf8)
        let idleStart = try XCTUnwrap(source.range(of: "    private func reconcileAssistantContext("))
        let switchStart = try XCTUnwrap(source.range(of: "    func newSession(", range: idleStart.upperBound..<source.endIndex))
        let switchEnd = try XCTUnwrap(source.range(of: "    private func transitionFromNoteToSession(", range: switchStart.upperBound..<source.endIndex))
        let idle = source[idleStart.lowerBound..<switchStart.lowerBound]
        XCTAssertTrue(idle.contains("assistantSessionStore.saveIfIdle(context: activeContext, now: now,"))
        XCTAssertTrue(idle.contains("eligible: menuSessionActive && embeddedTerminal.phase == .running && canReplaceContextProvider"))
        XCTAssertTrue(idle.contains("assistantSessionStore.pendingContinuation == nil"))
        XCTAssertTrue(idle.contains("end: { endSession(context: activeContext) }"))
        let switching = source[switchStart.lowerBound..<switchEnd.lowerBound]
        XCTAssertTrue(switching.contains(".filter { !sessionRegistry.isLive($0.context.id) }"))
        XCTAssertTrue(switching.contains("switch sessionRegistry.admit(contextID: context.id)"))
        XCTAssertFalse(switching.contains("embeddedTerminal.end()"))
        XCTAssertTrue(switching.contains("case .refused(let message):"))
        let endStart = try XCTUnwrap(source.range(of: "    func endSession(context: AssistantSessionContext) {"))
        let endBody = String(source[endStart.lowerBound...]).components(separatedBy: "\n    }\n")[0]
        XCTAssertTrue(endBody.contains("sessionRegistry.end(contextID: context.id)"))
        XCTAssertFalse(endBody.contains("pkill"))
        XCTAssertFalse(endBody.contains("killBridge"))
        let exitStart = try XCTUnwrap(source.range(of: "    private func embeddedTerminalDidExit(contextID: String, exitCode: Int32?) {"))
        let exitBody = String(source[exitStart.lowerBound...]).components(separatedBy: "\n    }\n")[0]
        XCTAssertTrue(exitBody.contains("saveAssistantSession(lifecycle: .interrupted, context: exitedContext)"))
        XCTAssertTrue(exitBody.contains("if sessionRegistry.hasLiveSessions { return }"))
        XCTAssertTrue(switching.contains("try assistantSessionStore.select(context,"))
        XCTAssertTrue(switching.contains("for process in previousProcesses"))
        XCTAssertTrue(switching.contains("process.requestTermination()"))
        XCTAssertFalse(switching.contains("cancelRun"))
        XCTAssertFalse(switching.contains("cancelTicket"))
        XCTAssertFalse(switching.contains("stopDaemon"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func bind(_ store: AssistantSessionStore, context: AssistantSessionContext, target: ProcessManager.AgentTarget,
                      transport: String, native: String, pid: Int? = nil, identity: String? = nil, runIDs: [Int] = []) throws {
        let url = store.bindingURL(transportSessionID: transport)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let transcript = store.directory.appendingPathComponent("native-\(native).jsonl")
        let metadata: [String: Any] = target == .codex
            ? ["type": "session_meta", "payload": ["id": native, "cwd": context.workingDirectory]]
            : ["type": "system", "subtype": "init", "sessionId": native, "cwd": context.workingDirectory]
        var transcriptBytes = try JSONSerialization.data(withJSONObject: metadata)
        transcriptBytes.append(0x0a)
        try transcriptBytes.write(to: transcript)
        var record: [String: Any] = ["context_id": context.id, "provider": target.providerMetadataValue,
            "provider_session_id": transport, "native_session_id": native, "working_directory": context.workingDirectory,
            "transcript_path": transcript.path]
        if let pid, let identity { record["provider_pid"] = pid; record["provider_process_identity"] = identity }
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        try store.reconcile(context: context, activeRunIDs: runIDs, pendingIntentIDs: [])
    }

    private func launch(target: ProcessManager.AgentTarget, directory: URL, script: String = "fixture") -> ProcessManager.PreparedSessionLaunch {
        ProcessManager.PreparedSessionLaunch(executable: "/bin/bash", arguments: ["-c", script],
            launcherPath: "/fixture/launcher", workingDirectory: directory.path, target: target, voiceDelivery: .appOwned)
    }

    private func spawnChild() throws -> Int32 {
        var pid: pid_t = 0
        let arguments: [String] = ["/bin/sleep", "30"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        sigaddset(&mask, SIGTERM)
        posix_spawnattr_setsigdefault(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        let result = argv.withUnsafeMutableBufferPointer { posix_spawn(&pid, "/bin/sleep", nil, &attributes, $0.baseAddress!, environ) }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        addTeardownBlock {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                _ = Darwin.kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
        }
        return pid
    }
}

private struct LifecycleRunIndex: Decodable {
    let runs: [RunState]
}

private final class LifecycleTerminalProcess: EmbeddedTerminalProcess {
    let view = NSView()
    var isRunning = false
    var hasFocus = false
    var childPID: Int? { nil }
    var onExit: ((Int32?) -> Void)?
    var onReady: (() -> Void)?
    var onInteractive: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var onDeliveryBlocked: ((Bool) -> Void)?
    var onInboxRecoveryBlocked: ((InboxRecoveryBlocker?) -> Void)?
    var launches: [ProcessManager.PreparedSessionLaunch] = []
    var terminateCount = 0

    func start(_ launch: ProcessManager.PreparedSessionLaunch) throws { launches.append(launch); isRunning = true; onReady?() }
    func focus() { hasFocus = true }
    func terminate() { terminateCount += 1; isRunning = false }
    func requestDeliveryRecovery() -> Bool { false }
    func skipUncertainMessage(_ blocker: InboxRecoveryBlocker) -> Bool { false }
}
