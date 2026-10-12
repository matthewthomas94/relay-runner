import XCTest
@testable import relay_runner
@testable import relay_actions_mcp
@testable import relay_orchestrator_mcp

final class ProviderMCPEnvironmentTests: XCTestCase {
    func testNativeOwnershipReachesOwnedMCPChildrenAndTheirAuthorityConsumers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-mcp-environment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = root.appendingPathComponent("native binding.json")
        try JSONSerialization.data(withJSONObject: ["native_session_id": "native", "provider_session_id": "transport", "context_id": "general"])
            .write(to: binding)
        let ownership = ["RELAY_PROVIDER_SESSION_ID": "transport", "RELAY_APP_SESSION_ID": "app", "RELAY_RECOVERY_GENERATION": "generation", "RELAY_FOREGROUND_GATE_HANDLE": "gate", "RELAY_SESSION_BINDING_PATH": binding.path,
                         "RELAY_CONTEXT_ID": "general", "RELAY_PROJECT_SCOPE_TOKEN": "confirmed-scope", "RELAY_UNRELATED_SECRET": "must-not-forward"]
        let fixture = #"""
        import json,os,subprocess,sys
        allowed={}
        for index,arg in enumerate(sys.argv[2:],2):
            if arg=='-c':
                key,value=sys.argv[index+1].split('=',1)
                allowed[key.split('.')[1]]=json.loads(value)
        result={}
        for name in ('relay-actions','relay-orchestrator','unrelated'):
            env=dict(os.environ) if sys.argv[1]=='claude' else {key:os.environ[key] for key in allowed.get(name,[]) if key in os.environ}
            output=subprocess.check_output(['/usr/bin/python3','-c','import json,os;print(json.dumps({k:v for k,v in os.environ.items() if k.startswith("RELAY_")}))'],env=env)
            result[name]=json.loads(output)
        print(json.dumps(result))
        """#
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            let flag = ProcessManager.appOwnedMCPEnvironmentFlag(target: target, voiceDelivery: .appOwned)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", "exec /usr/bin/python3 -c \(quote(fixture)) \(target == .codex ? "codex" : "claude") \(flag)"]
            process.environment = ownership.merging(["RELAY_RUNNER_PROVIDER": target == .codex ? "codex" : "claude"]) { $1 }
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let children = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
            let actions = try XCTUnwrap(children["relay-actions"])
            let orchestrator = try XCTUnwrap(children["relay-orchestrator"])
            XCTAssertEqual(ConfirmationClient.continuationSource(text: "unfinished public work", environment: actions)?["native_session_id"], "native")
            let projection: [String: Any] = ["records": [["provider_session_id": "transport", "session_id": "native", "app_session_id": "app", "recovery_generation": "generation", "foreground_gate_handle": "gate", "manual_submission_id": "continuation-source-destination", "created_at": 100.0, "relay_command_seq": 45, "relay_command_id": "original", "intent_id": "intent"]]]
            XCTAssertEqual(contextContinuationLineage(environment: orchestrator, binding: ["native_session_id": "native"], projection: projection), .voice(seq: 45, id: "original", intentID: "intent"))
            XCTAssertEqual(orchestrator["RELAY_PROJECT_SCOPE_TOKEN"], "confirmed-scope")
            if target == .codex {
                XCTAssertNil(actions["RELAY_PROJECT_SCOPE_TOKEN"])
                XCTAssertNil(actions["RELAY_UNRELATED_SECRET"])
                XCTAssertNil(orchestrator["RELAY_UNRELATED_SECRET"])
                XCTAssertEqual(children["unrelated"], [:])
            } else {
                XCTAssertTrue(flag.isEmpty, "Claude's native MCP children inherit the provider environment")
            }
        }
    }

    func testOnlyAppOwnedCodexLaunchesAddPerSessionMCPAllowlists() {
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            XCTAssertTrue(ProcessManager.appOwnedMCPEnvironmentFlag(target: target, voiceDelivery: .agentSkill).isEmpty)
            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            let script = ProcessManager.launchScript(relayBridge: "/App/scripts/relay-bridge", target: target, agentBinary: "/agent", config: config, voiceDelivery: .appOwned, resolvedCodexModel: "gpt-6.1-sol")
            if target == .codex {
                let flag = ProcessManager.appOwnedMCPEnvironmentFlag(target: target, voiceDelivery: .appOwned)
                XCTAssertTrue(script.split(separator: "\n").last!.contains(flag))
                XCTAssertFalse(flag.contains("relay-vision"))
                XCTAssertFalse(flag.contains(".command="))
                XCTAssertFalse(script.contains("mcp add"))
            } else {
                XCTAssertFalse(script.contains(".env_vars="))
            }
        }
    }

    private func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
