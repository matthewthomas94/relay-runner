import XCTest
@testable import relay_runner

final class ContextContinuationTests: XCTestCase {
    private func fixture() throws -> (AssistantSessionStore, URL, AssistantSessionContext, [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-continuation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AssistantSessionStore(directory: root)
        let destination = AssistantSessionContext(kind: .project, projectID: "confirmed", repositoryPath: "/confirmed/repo")
        let source = ["canonical_turn_id": "source-native-turn", "source_context_id": "general", "provider": "codex",
                      "provider_session_id": "source-transport", "native_session_id": "source-native", "app_session_id": "source-app",
                      "recovery_generation": "source-generation", "foreground_gate_handle": "source-gate", "manual_submission_id": "typed-source"]
        return (store, root, destination, source)
    }
    private func deliveryPaths(_ root: URL) -> RelayVoiceCommandDelivery.Paths {
        var paths = RelayVoiceCommandDelivery.Paths()
        paths.command = root.appendingPathComponent("command").path
        paths.metadata = root.appendingPathComponent("metadata").path
        paths.claimed = root.appendingPathComponent("claim").path
        paths.consumerAcknowledgement = root.appendingPathComponent("ack").path
        paths.commandState = root.appendingPathComponent("command-state").path
        paths.providerTurns = root.appendingPathComponent("turns").path
        paths.manualSubmissions = root.appendingPathComponent("manual").path
        paths.deliveryEvents = root.appendingPathComponent("events").path
        paths.actionJournal = root.appendingPathComponent("actions").path
        paths.voiceInput = root.appendingPathComponent("voice").path
        paths.heartbeat = root.appendingPathComponent("heartbeat").path
        return paths
    }
    private var owner: [String: String] {
        ["provider": "codex", "provider_session_id": "06aa4f98-1c27-46f0-bd37-66eddd753932", "native_session_id": "213030eb-22a1-4714-bea5-cc305020ca5b",
         "app_session_id": "destination-app", "recovery_generation": "destination-generation", "foreground_gate_handle": "destination-gate"]
    }
    private func ready(_ store: AssistantSessionStore, destination: AssistantSessionContext) throws {
        try store.select(destination, provider: "codex", model: "sol")
        try store.begin(context: destination, provider: "codex", model: "sol", transportSessionID: owner["provider_session_id"]!)
        let url = store.bindingURL(transportSessionID: owner["provider_session_id"]!)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["context_id": destination.id, "provider": "codex", "provider_session_id": owner["provider_session_id"]!,
            "native_session_id": owner["native_session_id"]!, "working_directory": destination.workingDirectory]).write(to: url)
        try store.reconcile(context: destination, activeRunIDs: [], pendingIntentIDs: [])
    }
    func testSourceMustFinishThenExactDestinationMustBeReadyAndSubmittingIsDurableBeforeDelivery() throws {
        let (store, root, destination, source) = try fixture()
        let reserved = try store.reserveContinuation(source: source, destination: destination, text: "Implement Y in the confirmed repo.")
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "active", context: .general, ready: true, clearToSend: true, owner: owner))
        try ready(store, destination: destination)
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "active", context: destination, ready: true, clearToSend: true, owner: owner))
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: false, clearToSend: true, owner: owner))
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: false, owner: owner))
        var foreign = owner; foreign["provider_session_id"] = "other"
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: foreign))
        let deliverable = try XCTUnwrap(store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: owner))
        XCTAssertEqual(deliverable.id, reserved.id)
        XCTAssertEqual(store.pendingContinuation?.state, .submitting)
        XCTAssertEqual(AssistantSessionStore(directory: root).pendingContinuation?.state, .recoveryRequired, "Persistence precedes any PTY delivery")
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: owner))
        try store.updateContinuation(reserved.id, state: .consumed)
        XCTAssertNil(store.pendingContinuation)
    }
    func testExplicitSourceDedupChangedTextControlsAndNavigationCancellation() throws {
        let (store, _, destination, source) = try fixture()
        let first = try store.reserveContinuation(source: source, destination: destination, text: "Only Y")
        XCTAssertEqual(try store.reserveContinuation(source: source, destination: destination, text: "Only Y").id, first.id)
        XCTAssertThrowsError(try store.reserveContinuation(source: source, destination: destination, text: "Different work"))
        try store.cancelContinuation()
        XCTAssertNil(store.pendingContinuation)
        XCTAssertEqual(try store.reserveContinuation(source: source, destination: destination, text: "Only Y").state, .cancelled)
        var next = source; next["canonical_turn_id"] = "new-turn"
        for text in ["\u{1b}[2J", "bad\rsubmit", "\u{7f}", "\u{9b}2J"] {
            XCTAssertThrowsError(try store.reserveContinuation(source: next, destination: destination, text: text))
        }
        XCTAssertTrue(store.document.history.isEmpty)
        XCTAssertTrue(store.publicHandoff(for: destination).isEmpty, "Outbox is execution intent, never arbitrary saved history")
    }

    func testFirstCodexDestinationCanReceiveOnceBeforeTranscriptAndOnlyResumeAfterRealTurn() throws {
        let (store, root, destination, source) = try fixture()
        let request = try store.reserveContinuation(source: source, destination: destination, text: "Continue Y in the confirmed new repository.")
        try store.select(destination, provider: "codex", model: "sol")
        try store.begin(context: destination, provider: "codex", model: "sol", transportSessionID: owner["provider_session_id"]!)
        let bindingURL = store.bindingURL(transportSessionID: owner["provider_session_id"]!)
        try FileManager.default.createDirectory(at: bindingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var binding: [String: Any] = ["context_id": destination.id, "provider": "codex", "provider_session_id": owner["provider_session_id"]!,
                                    "working_directory": destination.workingDirectory]
        try JSONSerialization.data(withJSONObject: binding).write(to: bindingURL)
        try store.reconcile(context: destination, activeRunIDs: [], pendingIntentIDs: [])
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: owner))
        XCTAssertEqual(store.pendingContinuation?.state, .queued)

        // Native startup observation supplies its exact process-owned writer
        // UUID before a user turn creates any transcript. This is sufficient
        // for first delivery ownership, but cannot select a saved resume.
        binding["native_session_id"] = owner["native_session_id"]!
        try JSONSerialization.data(withJSONObject: binding).write(to: bindingURL)
        try store.reconcile(context: destination, activeRunIDs: [], pendingIntentIDs: [])
        XCTAssertEqual(store.binding(for: destination)?.nativeSessionID, owner["native_session_id"])
        XCTAssertNil(store.binding(for: destination)?.resumableNativeSessionID)
        XCTAssertNil(AssistantSessionStore(directory: root).binding(for: destination)?.resumableNativeSessionID)
        try store.select(.general, provider: "codex", model: "sol")
        try store.select(destination, provider: "codex", model: "sol")
        let replacementTransport = UUID().uuidString.lowercased()
        try store.begin(context: destination, provider: "codex", model: "sol", transportSessionID: replacementTransport)
        XCTAssertNil(store.binding(for: destination)?.nativeSessionID, "A zero-turn A→B→A launch cannot inherit the old writer UUID")
        var replacementOwner = owner
        replacementOwner["provider_session_id"] = replacementTransport
        replacementOwner["native_session_id"] = UUID().uuidString.lowercased()
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: replacementOwner))
        let replacementBindingURL = store.bindingURL(transportSessionID: replacementTransport)
        binding["provider_session_id"] = replacementTransport
        binding["native_session_id"] = replacementOwner["native_session_id"]!
        try JSONSerialization.data(withJSONObject: binding).write(to: replacementBindingURL)
        try store.reconcile(context: destination, activeRunIDs: [], pendingIntentIDs: [])
        XCTAssertEqual(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: replacementOwner)?.id, request.id)
        XCTAssertNil(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: replacementOwner))
        try store.updateContinuation(request.id, state: .consumed)

        binding["transcript_path"] = root.appendingPathComponent("rollout-\(replacementOwner["native_session_id"]!).jsonl").path
        try JSONSerialization.data(withJSONObject: binding).write(to: replacementBindingURL)
        try store.reconcile(context: destination, activeRunIDs: [], pendingIntentIDs: [])
        XCTAssertEqual(store.binding(for: destination)?.resumableNativeSessionID, replacementOwner["native_session_id"])
        XCTAssertEqual(AssistantSessionStore(directory: root).binding(for: destination)?.resumableNativeSessionID, replacementOwner["native_session_id"])
        XCTAssertNil(store.pendingContinuation)
    }
    func testQueuedAndUncertainSubmissionsRequireExplicitRecoveryAfterRestart() throws {
        for submit in [false, true] {
            let (store, root, destination, source) = try fixture()
            let request = try store.reserveContinuation(source: source, destination: destination, text: "Y")
            if submit { try store.updateContinuation(request.id, state: .submitting, owner: owner) }
            let restored = AssistantSessionStore(directory: root)
            XCTAssertEqual(restored.pendingContinuation?.state, .recoveryRequired)
            try ready(restored, destination: destination)
            XCTAssertNil(try restored.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: owner))
            try restored.cancelContinuation()
            XCTAssertNil(AssistantSessionStore(directory: root).pendingContinuation)
        }
    }
    func testFailedDurableSubmittingDoesNotYieldPrompt() throws {
        let (store, root, destination, source) = try fixture()
        try store.reserveContinuation(source: source, destination: destination, text: "Y")
        try ready(store, destination: destination)
        let document = root.appendingPathComponent("conversation-v1.json")
        try FileManager.default.removeItem(at: document)
        try FileManager.default.createDirectory(at: document, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.prepareContinuationDelivery(sourceStatus: "ready", context: destination, ready: true, clearToSend: true, owner: owner))
        XCTAssertEqual(store.pendingContinuation?.state, .queued)
    }
    func testNativeManualBoundaryUsesOnePasteSeparateEnterAndParentProvenanceForBothProviders() throws {
        for provider in ["codex", "claude"] {
            let (store, root, destination, base) = try fixture()
            var source = base; source["provider"] = provider
            source["intent_id"] = "real-voice-intent"; source["command_seq"] = "42"; source["command_id"] = "real-voice-command"
            let request = try store.reserveContinuation(source: source, destination: destination, text: "Y")
            let paths = deliveryPaths(root)
            var sent: [String] = [], scheduled: [() -> Void] = []
            var authorized = true
            let delivery = RelayVoiceCommandDelivery(paths: paths, send: { sent.append(String(decoding: $0, as: UTF8.self)) },
                schedule: { _, _, work in scheduled.append(work) }, isRunning: { true },
                providerSessionID: "destination", provider: provider, appSessionID: "app", recoveryGeneration: "generation", foregroundGateHandle: "gate",
                continuationAuthority: { _ in authorized })
            XCTAssertTrue(delivery.submitContextContinuation(request))
            XCTAssertEqual(sent, [request.prompt])
            XCTAssertFalse(delivery.submitContextContinuation(request), "A pasted composer is owned until distinct Enter")
            let data = try Data(contentsOf: URL(fileURLWithPath: paths.manualSubmissions))
            let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(evidence["submission_id"] as? String, request.id)
            XCTAssertEqual((evidence["continuation_source"] as? [String: String])?["intent_id"], "real-voice-intent")
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.claimed))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.commandState))
            scheduled.removeFirst()()
            XCTAssertEqual(sent, [request.prompt, "\r"])
            XCTAssertFalse(delivery.submitContextContinuation(request), "Manual native boundary blocks another delivery")
            authorized = false
        }
    }
    func testRevocationBetweenPasteAndEnterClearsComposerAndNeverSubmits() throws {
        let (store, root, destination, source) = try fixture()
        let request = try store.reserveContinuation(source: source, destination: destination, text: "Y")
        let paths = deliveryPaths(root)
        var sent: [String] = [], scheduled: [() -> Void] = []
        let delivery = RelayVoiceCommandDelivery(paths: paths, send: { sent.append(String(decoding: $0, as: UTF8.self)) },
            schedule: { _, _, work in scheduled.append(work) }, isRunning: { true },
            providerSessionID: "destination", provider: "codex", appSessionID: "app", recoveryGeneration: "generation", foregroundGateHandle: "gate",
            continuationAuthority: { _ in false })
        XCTAssertTrue(delivery.submitContextContinuation(request))
        scheduled.removeFirst()()
        XCTAssertEqual(sent, [request.prompt, "\u{3}"])
        XCTAssertFalse(sent.contains("\r"))
    }
    func testClearOrNavigationBetweenPasteAndEnterCancelsOnlyExactInsertedContinuation() throws {
        for navigation in [false, true] {
            let (store, root, destination, source) = try fixture()
            let request = try store.reserveContinuation(source: source, destination: destination, text: "Y")
            var sent: [[UInt8]] = [], scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(paths: deliveryPaths(root), send: { sent.append(Array($0)) },
                schedule: { _, _, work in scheduled.append(work) }, isRunning: { true },
                providerSessionID: "destination", provider: "codex", appSessionID: "app", recoveryGeneration: "generation", foregroundGateHandle: "gate",
                continuationAuthority: { _ in true })
            XCTAssertTrue(delivery.submitContextContinuation(request))
            if navigation { try store.cancelContinuation(unless: .general) }
            else { try store.cancelContinuation() }
            delivery.cancelContextContinuation(id: request.id)
            scheduled.removeFirst()()
            XCTAssertEqual(store.document.continuations?[request.id]?.state, .cancelled)
            XCTAssertEqual(sent, [Array(request.prompt.utf8), [3]])
        }
        let (store, root, destination, source) = try fixture()
        let request = try store.reserveContinuation(source: source, destination: destination, text: "Y")
        var sent: [[UInt8]] = [], scheduled: [() -> Void] = []
        let delivery = RelayVoiceCommandDelivery(paths: deliveryPaths(root), send: { sent.append(Array($0)) },
            schedule: { _, _, work in scheduled.append(work) }, isRunning: { true },
            providerSessionID: "destination", provider: "codex", appSessionID: "app", recoveryGeneration: "generation", foregroundGateHandle: "gate",
            continuationAuthority: { _ in true })
        XCTAssertTrue(delivery.submitContextContinuation(request))
        delivery.cancelContextContinuation(id: "another-request")
        scheduled.removeFirst()()
        XCTAssertEqual(sent, [Array(request.prompt.utf8), [13]])
        delivery.cancelContextContinuation(id: request.id)
        XCTAssertEqual(sent, [Array(request.prompt.utf8), [13]], "Clear never silently cancels an already submitted native turn")
    }

    func testClearAndTypingDuringBlockedAuthorityLookupPreventReturn() throws {
        for input: [UInt8]? in [nil, Array("new draft".utf8), [3]] {
            let (store, root, destination, source) = try fixture()
            let request = try store.reserveContinuation(source: source, destination: destination, text: "Y")
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let finished = expectation(description: "Owned composer cancelled and human bytes preserved")
            var sent: [[UInt8]] = []
            let delivery = RelayVoiceCommandDelivery(paths: deliveryPaths(root), send: { bytes in
                sent.append(Array(bytes))
                if bytes.elementsEqual(input ?? [3]) { finished.fulfill() }
            }, submitDelay: 0, isRunning: { true }, providerSessionID: "destination", provider: "codex",
                appSessionID: "app", recoveryGeneration: "generation", foregroundGateHandle: "gate",
                continuationAuthority: { _ in
                    entered.signal()
                    return release.wait(timeout: .now() + 2) == .success
                })
            XCTAssertTrue(delivery.submitContextContinuation(request))
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            if let input { XCTAssertFalse(delivery.recordUserInput(ArraySlice(input))) }
            else { delivery.cancelContextContinuation(id: request.id) }
            release.signal()
            wait(for: [finished], timeout: 2)
            XCTAssertFalse(sent.contains([13]))
            let expected = input == [3] ? [Array(request.prompt.utf8), [3]]
                : [Array(request.prompt.utf8), [3]] + (input.map { [$0] } ?? [])
            XCTAssertEqual(sent, expected)
        }
    }

    func testCancellationAfterReturnEnqueueIsRecheckedAtActualTransportWrite() throws {
        let (store, root, destination, source) = try fixture()
        let request = try store.reserveContinuation(source: source, destination: destination, text: "Y")
        var sent: [[UInt8]] = [], scheduled: [() -> Void] = []
        var commit: RelayVoiceCommandDelivery.ContinuationCommit?
        var completion: ((Bool) -> Void)?
        let delivery = RelayVoiceCommandDelivery(paths: deliveryPaths(root), send: { sent.append(Array($0)) },
            schedule: { _, _, work in scheduled.append(work) }, isRunning: { true },
            providerSessionID: "destination", provider: "codex", appSessionID: "app", recoveryGeneration: "generation", foregroundGateHandle: "gate",
            continuationAuthority: { _ in true }, continuationEnterSend: { commit = $0; completion = $1 })
        XCTAssertTrue(delivery.submitContextContinuation(request))
        scheduled.removeFirst()()
        XCTAssertNotNil(commit)
        delivery.cancelContextContinuation(id: request.id)
        let write = try XCTUnwrap(commit)
        let entered = write { sent.append([13]) }
        try XCTUnwrap(completion)(entered)
        XCTAssertEqual(sent, [Array(request.prompt.utf8), [3]])
    }

    func testHumanInputBetweenPasteAndEnterCancelsInsertedComposerBeforeReplayingInput() throws {
        for input in [Array("new draft".utf8), [UInt8(3)], [UInt8(27)]] {
            let (store, root, destination, source) = try fixture()
            let request = try store.reserveContinuation(source: source, destination: destination, text: "Y\nwith two lines")
            var sent: [[UInt8]] = [], scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(paths: deliveryPaths(root), send: { sent.append(Array($0)) },
                schedule: { _, _, work in scheduled.append(work) }, isRunning: { true },
                providerSessionID: "destination", provider: "codex", appSessionID: "app", recoveryGeneration: "generation", foregroundGateHandle: "gate",
                continuationAuthority: { _ in true })
            XCTAssertTrue(delivery.submitContextContinuation(request))
            XCTAssertFalse(delivery.recordUserInput(ArraySlice(input)))
            scheduled.removeFirst()()
            XCTAssertEqual(sent, input.first == 3 ? [Array(request.prompt.utf8), input] : [Array(request.prompt.utf8), [3], input])
            XCTAssertFalse(sent.contains([13]), "User typing or cancellation wins before native submission")
        }
    }
    func testPublicContinuationTranscriptContainsOnlyExplicitPublicText() throws {
        let (store, _, destination, source) = try fixture()
        let continuation = try store.reserveContinuation(source: source, destination: destination, text: "Implement Y, keeping the public acceptance criteria.")
        let record: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": continuation.prompt]]]]
        let data = try JSONSerialization.data(withJSONObject: record)
        let entries = AssistantSessionStore.publicEntries(data: data, contextID: destination.id, nativeID: "native", provider: "codex")
        XCTAssertEqual(entries.map(\.text), [continuation.text])
    }
}
