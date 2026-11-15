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
        let live = (0..<4).map { "context-\($0)-\(UUID().uuidString.lowercased())" }
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

    func testPlayingLabelNamesTheReplySessionProject() {
        let names = ["a": "Alpha", "b": "Beta"]
        let keys = ["a": "key-a", "b": "key-b"]
        func name(_ key: String?, live: [String]) -> String? {
            playbackTargetName(
                sessionKey: key, liveContextIDs: live,
                spoolKey: { keys[$0] }, displayName: { names[$0] }
            )
        }
        XCTAssertEqual(name("key-b", live: ["a", "b"]), "Beta")
        XCTAssertEqual(name("key-a", live: ["a", "b"]), "Alpha")
        XCTAssertNil(name("key-b", live: ["b"]))
        XCTAssertNil(name("unknown", live: ["a", "b"]))
        XCTAssertNil(name(nil, live: ["a", "b"]))

        let presented = NotchActivityLabelPlanner.labels(for: .speaking, playbackTargetName: "Beta")
        XCTAssertEqual(presented, ["Playing · Beta"])
        XCTAssertEqual(
            NotchActivityLabelPlanner.hoverLabel(for: .speaking, playbackTargetName: "Beta"),
            "Playing · Beta"
        )
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .speaking), ["Playing"])
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: .recording, playbackTargetName: "Beta"), ["Listening"])
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

    /// Two sessions in one repository share the per-repository generation
    /// entry; a focus must carry each session's own launch generation, or the
    /// bridge re-owns the older session and its claims are never acknowledged.
    func testFocusCarriesEachSessionsOwnRecoveryGeneration() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"), encoding: .utf8)
        let syncStart = try XCTUnwrap(source.range(of: "    private func syncVoiceFocus(force: Bool = false) -> Bool {"))
        let syncBody = String(source[syncStart.lowerBound...]).components(separatedBy: "\n    }\n")[0]
        let own = try XCTUnwrap(syncBody.range(of: "recoveryGeneration: owner[\"recovery_generation\"]"))
        let shared = try XCTUnwrap(syncBody.range(of: "continuityRecoveryGenerationBySession[sessionID]"))
        XCTAssertLessThan(own.lowerBound, shared.lowerBound, "The session's own generation wins over the shared repository entry")
    }
}
