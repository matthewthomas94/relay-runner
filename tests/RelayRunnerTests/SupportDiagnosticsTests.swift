import Foundation
import XCTest
@testable import relay_runner

final class SupportDiagnosticsTests: XCTestCase {
    func testAllowlistRedactsSensitiveValuesAndRejectsUnknownFields() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = RelayDiagnostics(
            directory: root,
            appSessionID: "session-test"
        )

        let event = try XCTUnwrap(diagnostics.record(
            process: "app",
            phase: "workspace_readiness",
            outcome: "failed",
            incidentID: "incident-test",
            retryAttempt: 1,
            correlationID: "correlation-test",
            provider: "codex",
            summary: "failed at /Users/alice/private/repo and /opt/homebrew/bin token=secret-value",
            attributes: ["error_code": "Bearer abcdefghijk"]
        ))

        XCTAssertFalse(event.summary?.contains("/Users/alice") == true)
        XCTAssertFalse(event.summary?.contains("/opt/homebrew") == true)
        XCTAssertFalse(event.summary?.contains("secret-value") == true)
        XCTAssertGreaterThanOrEqual(event.redactionCount, 3)
        XCTAssertNil(diagnostics.record(
            process: "app",
            phase: "workspace_readiness",
            outcome: "failed",
            attributes: ["repository_path": "/Users/alice/private/repo"]
        ))
        XCTAssertEqual(diagnostics.preview().eventCount, 1)
    }

    func testBundleContainsOnlyRevalidatedTimelineAndManifest() throws {
        let root = temporaryDirectory()
        let destination = root.deletingLastPathComponent()
            .appendingPathComponent("support-\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }
        let diagnostics = RelayDiagnostics(directory: root, appSessionID: "session-test")
        diagnostics.record(
            process: "orchestrator",
            phase: "orchestrator_launch",
            outcome: "ready",
            correlationID: "correlation-test",
            attributes: ["transport": "loopback_http"]
        )

        try diagnostics.createSupportBundle(at: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan(try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
        XCTAssertTrue(diagnostics.preview().summary.contains("excludes transcripts"))
    }

    func testProviderLaunchersDeferBridgeReadinessForBothProviders() {
        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            var config = AppConfig()
            config.general.provider = provider
            let target: ProcessManager.AgentTarget = provider == .codex ? .codex : .claude
            for delivery in [
                ProcessManager.SessionVoiceDelivery.agentSkill,
                .appOwned,
            ] {
                let script = ProcessManager.launchScript(
                    relayBridge: "/Relay Runner/relay-bridge",
                    target: target,
                    agentBinary: provider == .codex ? "/usr/local/bin/codex" : "/usr/local/bin/claude",
                    config: config,
                    voiceDelivery: delivery
                )
                let launchSteps = script.components(
                    separatedBy: "relay_record_session_event launcher_start started"
                )[1].components(
                    separatedBy: "relay_record_session_event provider_spawn started"
                )[0]

                XCTAssertTrue(script.contains("RELAY_APP_SESSION_ID"))
                XCTAssertTrue(script.contains("RELAY_CORRELATION_ID"))
                XCTAssertFalse(launchSteps.contains("bridge_readiness ready"))
                XCTAssertTrue(script.contains("relay_record_support_event provider provider_readiness spawned"))
                XCTAssertEqual(
                    launchSteps.contains("--venv-only"),
                    delivery == .agentSkill
                )
                XCTAssertFalse(script.contains("working_directory\":"))
                XCTAssertFalse(script.contains("provider_output\":"))
            }
        }
    }

    func testGeneratedProviderShellWriterEnforcesRetentionBounds() throws {
        for provider in [GeneralConfig.AgentProvider.codex, .claude] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let diagnosticsDirectory = root.appendingPathComponent("diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(
                at: diagnosticsDirectory,
                withIntermediateDirectories: true
            )
            let expired = diagnosticsDirectory.appendingPathComponent("events-v1-shell-expired.jsonl")
            let oldest = diagnosticsDirectory.appendingPathComponent("events-v1-shell-oldest.jsonl")
            let newest = diagnosticsDirectory.appendingPathComponent("events-v1-shell-newest.jsonl")
            try Data("{}\n".utf8).write(to: expired)
            try Data(count: 3 * 1024 * 1024).write(to: oldest)
            try Data(count: 3 * 1024 * 1024).write(to: newest)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-8 * 86_400)],
                ofItemAtPath: expired.path
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-120)],
                ofItemAtPath: oldest.path
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-60)],
                ofItemAtPath: newest.path
            )

            let bridge = root.appendingPathComponent("relay-bridge")
            let agent = root.appendingPathComponent("agent")
            let launcher = root.appendingPathComponent("launch.sh")
            try writeExecutable("#!/bin/bash\nexit 0\n", to: bridge)
            try writeExecutable("#!/bin/bash\nexit 0\n", to: agent)
            var config = AppConfig()
            config.general.provider = provider
            config.general.working_directory = root.path
            let target: ProcessManager.AgentTarget = provider == .codex ? .codex : .claude
            let script = ProcessManager.launchScript(
                relayBridge: bridge.path,
                target: target,
                agentBinary: agent.path,
                config: config,
                voiceDelivery: .agentSkill,
                homeDirectory: root
            )
            try writeExecutable(script, to: launcher)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [launcher.path]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HOME": root.path,
                "RELAY_DIAGNOSTICS_DIR": diagnosticsDirectory.path,
                "RELAY_CORRELATION_ID": "correlation-test",
            ]) { _, new in new }
            try process.run()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path))
            let retained = try FileManager.default.contentsOfDirectory(
                at: diagnosticsDirectory,
                includingPropertiesForKeys: [.fileSizeKey]
            )
            let total = retained.reduce(0) {
                $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            XCTAssertLessThanOrEqual(total, 5 * 1024 * 1024)
        }
    }

    @MainActor
    func testWorkspaceRetryKeepsIncidentAndIncrementsAttempt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = RelayDiagnostics(directory: root, appSessionID: "session-test")
        let model = ProgramBoardViewModel(
            fetchDashboard: { _ in throw URLError(.cannotConnectToHost) },
            diagnostics: diagnostics
        )

        await model.reload().value
        let incidentID = try XCTUnwrap(model.workspaceIncidentID)
        XCTAssertEqual(model.workspaceRetryAttempt, 1)
        XCTAssertTrue(model.errorMessage?.contains(incidentID) == true)
        XCTAssertNotNil(model.supportBundlePreview)

        await model.reload().value
        XCTAssertEqual(model.workspaceIncidentID, incidentID)
        XCTAssertEqual(model.workspaceRetryAttempt, 2)

        let events = try journalEvents(in: root)
        let failures = events.filter { $0["outcome"] as? String == "failed" }
        XCTAssertEqual(failures.compactMap { $0["retry_attempt"] as? Int }, [1, 2])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-support-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func journalEvents(in root: URL) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }
            .flatMap { url -> [[String: Any]] in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                return contents.split(separator: "\n").compactMap { line in
                    guard let data = String(line).data(using: .utf8) else { return nil }
                    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
            }
    }
}
