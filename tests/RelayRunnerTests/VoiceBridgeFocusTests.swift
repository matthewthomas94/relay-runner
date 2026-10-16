import XCTest
@testable import relay_runner

/// RR-398: one shared bridge follows the focused session through `__FOCUS__`.
final class VoiceBridgeFocusTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func focusMessage(_ key: String, provider: String, sessionsRoot: String, focus: Bool, live: [String]) -> String? {
        AppState.voiceFocusMessage(
            sessionKey: key,
            provider: provider,
            providerSessionID: "\(provider)-\(key)-native",
            workingDirectory: "/Users/me/\(key)",
            spoolDirectory: "\(sessionsRoot)/\(key)",
            appSessionID: "app-\(key)",
            recoveryGeneration: "1",
            projectName: "Project \(key)",
            focus: focus,
            liveSessionKeys: live
        )
    }

    func testFocusMessageFitsOneBridgeDatagram() throws {
        let live = (0..<4).map { "context-\($0)-\(UUID().uuidString)" }
        let message = try XCTUnwrap(focusMessage(live[0], provider: "claude", sessionsRoot: "/tmp/relay-sessions", focus: true, live: live))
        XCTAssertTrue(message.hasPrefix("__FOCUS__:"))
        XCTAssertLessThan(message.utf8.count, 2048)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.dropFirst("__FOCUS__:".count).utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["session_key"] as? String, live[0])
        XCTAssertEqual(payload["spool_dir"] as? String, "/tmp/relay-sessions/\(live[0])")
        XCTAssertEqual(payload["provider_session_id"] as? String, "claude-\(live[0])-native")
        XCTAssertEqual(payload["focus"] as? Bool, true)
        XCTAssertEqual(payload["live_session_keys"] as? [String], live)
    }

    /// AppState's focus payloads drive the Python bridge's target: with A and B
    /// live and focus on B, new commands land only in B's spool, while a
    /// recording stamped on A still reaches A.
    func testAppStateFocusPayloadsRouteTheBridgeToTheFocusedSpool() throws {
        let fixture = #"""
        import json, os, sys, tempfile, types
        sys.path.insert(0, sys.argv[1])
        sys.modules.setdefault("numpy", types.SimpleNamespace(asarray=lambda s: s, int16=object()))
        import voice_bridge as vb
        sessions = sys.argv[2]
        vb.RELAY_SESSIONS_ROOT = sessions
        vb.BRIDGE_CWD_FILE = os.path.join(sessions, "bridge.cwd")
        vb.BRIDGE_PROVIDER_FILE = os.path.join(sessions, "bridge.provider")
        vb.BRIDGE_SPOOL_FILE = os.path.join(sessions, "bridge.spool")
        for message in sys.argv[3:]:
            assert message.startswith("__FOCUS__:"), message
            assert vb._apply_voice_focus(json.loads(message[len("__FOCUS__:"):])) is not None
        print(json.dumps({
            "current": vb._current_voice_target().session_key,
            "unstamped": vb._voice_mailbox_for({})[0],
            "stamped_a": vb._voice_mailbox_for({"voice_target_session_key": "A"})[0],
            "provider": open(vb.BRIDGE_PROVIDER_FILE).read().strip(),
            "native": vb._authoritative_provider_session_id(),
        }))
        """#
        for (providerA, providerB) in [("codex", "claude"), ("claude", "codex")] {
            let sessions = FileManager.default.temporaryDirectory.appendingPathComponent("rr398-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: sessions) }
            let live = ["A", "B"]
            // syncVoiceFocus sends the other live sessions first and the focused one last.
            let messages = try [
                XCTUnwrap(focusMessage("A", provider: providerA, sessionsRoot: sessions, focus: false, live: live)),
                XCTUnwrap(focusMessage("B", provider: providerB, sessionsRoot: sessions, focus: true, live: live)),
            ]
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", fixture, Self.root.appendingPathComponent("services").path, sessions] + messages
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, providerB)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String], providerB)
            XCTAssertEqual(result["current"], "B", providerB)
            XCTAssertEqual(result["unstamped"], "\(sessions)/B/voice_cmd_ready", providerB)
            XCTAssertEqual(result["stamped_a"], "\(sessions)/A/voice_cmd_ready", providerB)
            XCTAssertEqual(result["provider"], providerB)
            XCTAssertEqual(result["native"], "\(providerB)-B-native")
        }
    }

    func testJoiningSessionLaunchDoesNotRestartTheSharedBridge() {
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            let launch = { (joins: Bool) in
                ProcessManager.launchScript(
                    relayBridge: "/Relay Runner/scripts/relay-bridge",
                    target: target,
                    agentBinary: "/usr/local/bin/agent",
                    config: config,
                    voiceDelivery: .appOwned,
                    appSessionID: "app-session",
                    recoveryGeneration: "generation-1",
                    foregroundGateHandle: "foreground-gate",
                    startsVoiceBridge: true,
                    joinsRunningVoiceBridge: joins
                )
            }
            XCTAssertTrue(launch(false).contains("--start-daemon"), "\(target)")
            let joining = launch(true)
            XCTAssertFalse(joining.contains("--start-daemon"), "\(target)")
            XCTAssertTrue(joining.contains("Join the running shared Relay voice bridge"), "\(target)")
        }
    }

    func testListeningLabelNamesTheVoiceTargetProject() {
        XCTAssertEqual(NotchVisualLabelAllowlist.presentation(for: .recording).labels.first, "Listening")
        XCTAssertEqual(
            NotchVisualLabelAllowlist.presentation(for: .recording, voiceTargetName: "Relay Runner").labels.first,
            "Listening · Relay Runner"
        )
    }

    func testAppStateSendsFocusInsteadOfRelaunchingALiveBridge() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"), encoding: .utf8)
        let retargetStart = try XCTUnwrap(source.range(of: "    private func retargetVoiceBridge(releasing endedSpool: VoiceSessionSpool?) {"))
        let retargetBody = String(source[retargetStart.lowerBound...]).components(separatedBy: "\n    }\n")[0]
        let focus = try XCTUnwrap(retargetBody.range(of: "processManager.bridgeAlive(), syncVoiceFocus(force: true)"))
        let relaunch = try XCTUnwrap(retargetBody.range(of: "processManager.relaunchBridgeDaemon("))
        XCTAssertLessThan(focus.lowerBound, relaunch.lowerBound, "A live bridge is re-targeted before any relaunch")
        let publishStart = try XCTUnwrap(source.range(of: "    private func publishConversationState() {"))
        let publishBody = String(source[publishStart.lowerBound...]).components(separatedBy: "\n    }\n")[0]
        XCTAssertTrue(publishBody.contains("syncVoiceFocus()"), "Every focus change re-targets the bridge")
        XCTAssertTrue(source.contains("joinsRunningVoiceBridge: joinsVoiceBridge"))
        XCTAssertTrue(source.contains("sttEngine?.voiceTargetSessionKey"))
    }
}
