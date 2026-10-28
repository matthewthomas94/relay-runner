import XCTest
@testable import relay_runner

/// RR-447: after an app relaunch resumed a provider, a watchdog bridge restart
/// ran while the terminal submitted a voice prompt. The resumed provider's
/// first UserPromptSubmit hook ran after the restart had deleted the session
/// claim and command state, so it could not bind the prompt: the received turn
/// timed out as unacknowledged, blocked the queue, and its reply was refused.
final class BridgeRestartDeliveryTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testResumedProviderSlowFirstTurnIsAcknowledgedAcrossBridgeRestart() throws {
        for provider in ["codex", "claude"] {
            let sandbox = try makeSandbox()
            let spool = sandbox.appendingPathComponent("relay-sessions/session-a", isDirectory: true)
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            let paths = RelayVoiceCommandDelivery.Paths(
                command: spool.appendingPathComponent("voice_cmd_ready").path,
                metadata: spool.appendingPathComponent("voice_cmd_ready.meta").path,
                claimed: spool.appendingPathComponent("voice_cmd_claimed.json").path,
                consumerAcknowledgement: spool.appendingPathComponent("voice_cmd_manual_ack.json").path,
                commandState: spool.appendingPathComponent("voice_command_state.json").path,
                providerTurns: sandbox.appendingPathComponent("voice_provider_turns_v2.json").path,
                manualSubmissions: spool.appendingPathComponent("relay_terminal_manual_submission.json").path,
                deliveryEvents: spool.appendingPathComponent("relay_terminal_delivery_events.jsonl").path,
                actionJournal: sandbox.appendingPathComponent("command-actions/events.jsonl").path,
                voiceInput: sandbox.appendingPathComponent("voice_in.fifo").path,
                heartbeat: sandbox.appendingPathComponent("voice_bridge_heartbeat").path
            )
            let prompt = "Write a ticket for the voice delivery blocker"
            let metadata: [String: Any] = [
                "relay_command_seq": 60,
                "relay_command_id": "cmd-60",
                "intent_id": "cmd-60:item:1",
                "provider": provider,
                "agent_prompt": prompt,
                "source_text": prompt,
            ]
            let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            try "\(prompt)\n".write(toFile: paths.command, atomically: true, encoding: .utf8)
            try metadataData.write(to: URL(fileURLWithPath: paths.metadata))
            try metadataData.write(to: URL(fileURLWithPath: paths.commandState))

            var sent: [String] = []
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: paths,
                send: { sent.append(String(decoding: $0, as: UTF8.self)) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true },
                providerSessionID: "transport-a",
                provider: provider,
                appSessionID: "app-a",
                recoveryGeneration: "generation-a",
                foregroundGateHandle: "gate-a"
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            scheduled.removeFirst()()
            XCTAssertEqual(sent, [prompt, "\r"], provider)
            XCTAssertEqual(scheduled.count, 1, "only the acknowledgement timer is pending")

            // The watchdog restarts the bridge before the resumed provider's
            // slow first turn reaches its prompt hook.
            try runRecoveryCleanup(sandbox: sandbox, spool: spool, provider: provider)
            try runPromptSubmitHook(prompt: prompt, provider: provider, sandbox: sandbox, spool: spool, paths: paths)

            scheduled.removeFirst()()
            let events = try String(contentsOfFile: paths.deliveryEvents, encoding: .utf8)
            XCTAssertTrue(events.contains(#""event":"provider_acknowledged""#), provider)
            XCTAssertFalse(events.contains(#""event":"acknowledgement_timeout""#), provider)
            XCTAssertFalse(events.contains(#""event":"recovery_blocked""#), provider)
            XCTAssertFalse(delivery.isDeliveryBlocked, provider)
            // The reply helper binds the provider's reply to this claim.
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths.claimed)), metadataData, provider)
        }
    }

    /// Runs only the generated cleanup commands, with every /tmp path moved
    /// into the sandbox. Process control and launchd lines are never run.
    private func runRecoveryCleanup(sandbox: URL, spool: URL, provider: String) throws {
        let script = ProcessManager.bridgeRecoveryScript(
            relayBridge: "/usr/local/bin/relay-bridge",
            context: .init(workingDirectory: "/Users/example/dev", provider: provider, spoolDirectory: spool.path)
        )
        let lines = script.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("|| rm -f /tmp/voice_command_authorizations.json") })
        let end = try XCTUnwrap(lines.firstIndex { $0.contains("VOICE_BRIDGE_LOG_REASON=watchdog-recovery") })
        let cleanup = lines[start..<end]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let unexpected = cleanup.filter { line in
            !["rm -f ", "[ ", "if [ ", "fi"].contains { line.hasPrefix($0) }
        }
        let sandboxed = cleanup.joined(separator: "\n")
            .replacingOccurrences(of: " /tmp/", with: " \(sandbox.path)/")
        let escaped = sandboxed.split(whereSeparator: \.isWhitespace).filter {
            $0.hasPrefix("/") && !$0.hasPrefix(sandbox.path + "/")
        }
        guard unexpected.isEmpty, escaped.isEmpty else {
            XCTFail("unsafe cleanup: \(unexpected) \(escaped)")
            throw CocoaError(.fileWriteNoPermission)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", sandboxed]
        process.environment = [
            "SPOOL": spool.path,
            "RELAY_SESSION_SPOOL_DIR": spool.path,
            "RELAY_CONTINUITY_RECOVERY_PENDING": "0",
            "RELAY_PRESERVE_CONTEXT_AUTHORIZATION": "1",
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func runPromptSubmitHook(
        prompt: String,
        provider: String,
        sandbox: URL,
        spool: URL,
        paths: RelayVoiceCommandDelivery.Paths
    ) throws {
        var payload: [String: Any] = [
            "hook_event_name": "UserPromptSubmit",
            "prompt": prompt,
            "session_id": "3f1c2a64-8d3b-4c55-9e1a-6b7f0d2c9e41",
        ]
        payload[provider == "claude" ? "prompt_id" : "turn_id"] = "native-turn-1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [Self.repositoryRoot.appendingPathComponent("services/relay_completion_hook.py").path]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": sandbox.path,
            "RELAY_RUNNER_PROVIDER": provider,
            "RELAY_PROVIDER_SESSION_ID": "transport-a",
            "RELAY_APP_SESSION_ID": "app-a",
            "RELAY_RECOVERY_GENERATION": "generation-a",
            "RELAY_ACTOR_ROLE": "foreground_pm",
            "RELAY_FOREGROUND_GATE_HANDLE": "gate-a",
            "VOICE_COMMAND_CLAIM_FILE": paths.claimed,
            "VOICE_COMMAND_STATE_FILE": paths.commandState,
            "RELAY_TERMINAL_MANUAL_SUBMISSION_FILE": paths.manualSubmissions,
            "VOICE_PROVIDER_TURNS_FILE": sandbox.appendingPathComponent("voice_provider_turns.json").path,
            "VOICE_PROVIDER_TURN_PROJECTION_FILE": paths.providerTurns,
            "VOICE_INTENT_INBOX": sandbox.appendingPathComponent("relay_intent_inbox.sqlite3").path,
            "VOICE_FIFO": paths.voiceInput,
        ]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeSandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr447-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
