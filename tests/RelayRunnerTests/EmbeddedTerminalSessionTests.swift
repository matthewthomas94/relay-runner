import AppKit
import Darwin
import SwiftTerm
import XCTest
@testable import relay_runner

final class EmbeddedTerminalSessionTests: XCTestCase {
    func testReadyHandlerRunsAfterTheCurrentProcessBecomesInteractive() throws {
        let process = FakeEmbeddedTerminalProcess()
        process.autoReady = false
        let session = EmbeddedTerminalSession(processFactory: { process })
        let ready = expectation(description: "ready handled")
        session.setReadyHandler {
            XCTAssertEqual(session.phase, .running)
            ready.fulfill()
        }

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        XCTAssertEqual(session.phase, .starting)

        process.onReady?()
        wait(for: [ready], timeout: 1)
        XCTAssertEqual(session.phase, .running)
    }

    func testStartRejectsDuplicateActiveSession() throws {
        let process = FakeEmbeddedTerminalProcess()
        let session = EmbeddedTerminalSession(processFactory: { process })

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())

        XCTAssertEqual(session.phase, .running)
        XCTAssertThrowsError(
            try session.beginPreparing(providerName: "Claude", workingDirectory: "/other")
        ) { error in
            XCTAssertEqual(error as? EmbeddedTerminalProcessError, .alreadyRunning)
        }
        XCTAssertEqual(process.startCount, 1)
    }

    func testNaturalExitSurfacesDecodedStatusAndAllowsRestart() throws {
        let first = FakeEmbeddedTerminalProcess()
        let second = FakeEmbeddedTerminalProcess()
        var processes = [first, second]
        let session = EmbeddedTerminalSession(processFactory: { processes.removeFirst() })
        let exited = expectation(description: "exit handled")
        session.setExitHandler { code in
            XCTAssertEqual(code, 1)
            exited.fulfill()
        }

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        first.emitExit(rawStatus: 256)
        wait(for: [exited], timeout: 1)

        XCTAssertEqual(session.phase, .exited(1))

        try session.beginPreparing(providerName: "Claude", workingDirectory: "/other")
        try session.start(launch())

        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(second.startCount, 1)
    }

    func testExplicitEndTerminatesOnceAndIgnoresLateExit() throws {
        let process = FakeEmbeddedTerminalProcess()
        let session = EmbeddedTerminalSession(processFactory: { process })

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        let lateExit = process.onExit

        session.end()
        lateExit?(0)
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(session.phase, .ended)
        XCTAssertNotNil(session.hostedView)
    }

    func testStaleExitFromReplacedProcessCannotEndNewSession() throws {
        let first = FakeEmbeddedTerminalProcess()
        let second = FakeEmbeddedTerminalProcess()
        var processes = [first, second]
        let session = EmbeddedTerminalSession(processFactory: { processes.removeFirst() })

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        let staleExit = first.onExit
        first.emitExit(rawStatus: 0)
        let firstExit = expectation(description: "first exit")
        DispatchQueue.main.async { firstExit.fulfill() }
        wait(for: [firstExit], timeout: 1)

        try session.beginPreparing(providerName: "Claude", workingDirectory: "/other")
        try session.start(launch())
        staleExit?(256)
        let drained = expectation(description: "stale exit drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(session.phase, .running)
        XCTAssertTrue(session.hostedView === second.view)
    }

    func testFailedProcessStartIsVisibleAndCanRetry() throws {
        let failing = FakeEmbeddedTerminalProcess()
        failing.startError = EmbeddedTerminalProcessError.couldNotStart
        let succeeding = FakeEmbeddedTerminalProcess()
        var processes = [failing, succeeding]
        let session = EmbeddedTerminalSession(processFactory: { processes.removeFirst() })

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        XCTAssertThrowsError(try session.start(launch()))
        XCTAssertEqual(
            session.phase,
            .failed(EmbeddedTerminalProcessError.couldNotStart.localizedDescription)
        )

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())

        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(failing.terminateCount, 1)
        XCTAssertEqual(succeeding.startCount, 1)
    }

    func testProviderExitZeroBeforeReadinessIsFailureForCodexAndClaude() throws {
        for (providerName, providerKey) in [("Codex", "codex"), ("Claude", "claude")] {
            let process = FakeEmbeddedTerminalProcess()
            process.autoReady = false
            let session = EmbeddedTerminalSession(processFactory: { process })
            let exited = expectation(description: "\(providerName) early exit")
            session.setExitHandler { code in
                XCTAssertEqual(code, 0)
                exited.fulfill()
            }

            try session.beginPreparing(
                providerName: providerName,
                providerKey: providerKey,
                workingDirectory: "/repo"
            )
            try session.start(launch())
            XCTAssertEqual(session.phase, .starting)

            process.emitExit(rawStatus: 0)
            wait(for: [exited], timeout: 1)

            guard case .failed(let message) = session.phase else {
                return XCTFail("Expected \(providerName) early exit to fail the session")
            }
            XCTAssertTrue(message.contains("\(providerName) exited with code 0"))
            XCTAssertTrue(message.contains("during interactive provider readiness"))
            XCTAssertTrue(message.contains("orphaned voice bridge"))
        }
    }

    func testBridgeTimeoutMessageDoesNotClaimProviderExited() {
        let message = EmbeddedTerminalSession.launchFailureMessage(
            providerName: "Codex",
            rawStatus: 256,
            bridgeSocketOutcome: "timeout"
        )

        XCTAssertTrue(message.contains("voice bridge socket timed out"))
        XCTAssertTrue(message.contains("before Codex started"))
        XCTAssertFalse(message.contains("Codex exited"))
    }

    func testRealPTYCleanExitAfterFormerReadinessThresholdRemainsStartupFailure() throws {
        for (providerName, target) in [
            ("Codex", ProcessManager.AgentTarget.codex),
            ("Claude", ProcessManager.AgentTarget.claude),
        ] {
            let fixture = try makeRealPTYFixture()
            let session = EmbeddedTerminalSession()
            let exited = expectation(description: "\(providerName) post-threshold clean exit")
            session.setExitHandler { code in
                XCTAssertEqual(code, 0)
                exited.fulfill()
            }

            try session.beginPreparing(
                providerName: providerName,
                providerKey: providerName.lowercased(),
                workingDirectory: fixture.directory.path
            )
            try session.start(realPTYLaunch(
                command: """
                stty -icanon -echo
                printf 'interactive provider output\r\n'
                sleep 0.65
                exit 0
                """,
                target: target,
                fixture: fixture
            ))

            let crossedFormerThreshold = expectation(
                description: "\(providerName) crossed former readiness threshold"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                crossedFormerThreshold.fulfill()
            }
            wait(for: [crossedFormerThreshold], timeout: 1)
            XCTAssertEqual(
                session.phase,
                .starting,
                "\(providerName) output must not establish stable readiness"
            )

            wait(for: [exited], timeout: 2)
            guard case .failed(let message) = session.phase else {
                return XCTFail("Expected \(providerName) clean startup exit to fail")
            }
            XCTAssertTrue(message.contains("\(providerName) exited with code 0"))
            XCTAssertTrue(message.contains("interactive provider readiness"))
        }
    }

    func testAppOwnedDeliveryWaitsForStableProviderPTYForBothProviders() throws {
        for (providerName, target) in [
            ("Codex", ProcessManager.AgentTarget.codex),
            ("Claude", ProcessManager.AgentTarget.claude),
        ] {
            let fixture = try makeRealPTYFixture()
            let paths = deliveryPaths(in: fixture.directory)
            let providerSessionID = "mounted-\(providerName.lowercased())"
            try "ping\n".write(
                toFile: paths.command,
                atomically: true,
                encoding: .utf8
            )
            let metadata = """
            {"provider":"\(providerName.lowercased())","relay_command_id":"cmd-1","relay_command_seq":1}
            """
            try metadata.write(
                toFile: paths.metadata,
                atomically: true,
                encoding: .utf8
            )
            try metadata.write(
                toFile: paths.commandState,
                atomically: true,
                encoding: .utf8
            )
            try """
            {"schema_version":2,"records":[{"state":"active","origin":"manual","provider_session_id":"orphaned-previous-session","session_id":"startup-identity","turn_id":"startup-turn"}]}
            """.write(toFile: paths.providerTurns, atomically: true, encoding: .utf8)

            let process = SwiftTermEmbeddedProcess(
                readinessStabilityInterval: 0.2,
                readinessPollInterval: 0.02,
                voiceDeliveryPaths: paths
            )
            let session = EmbeddedTerminalSession(processFactory: { process })
            try session.beginPreparing(
                providerName: providerName,
                providerKey: providerName.lowercased(),
                workingDirectory: fixture.directory.path
            )
            try session.start(ProcessManager.PreparedSessionLaunch(
                executable: "/bin/bash",
                arguments: ["-c", """
                    sleep 0.35
                    stty -icanon -echo
                    printf 'interactive provider output\r\n'
                    IFS= read -r line
                    [ "$line" = "ping" ] || exit 3
                    printf 'input accepted\r\n'
                    sleep 5
                    """],
                launcherPath: "/bin/bash",
                workingDirectory: fixture.directory.path,
                target: target,
                voiceDelivery: .appOwned,
                sessionEventPath: fixture.events.path,
                providerSessionID: providerSessionID
            ))
            let host = EmbeddedTerminalHostNSView()
            host.install(session.hostedView)
            XCTAssertTrue(process.terminalView.superview === host, providerName)

            let bootstrapWindow = expectation(
                description: "\(providerName) bootstrap retains queued command"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                bootstrapWindow.fulfill()
            }
            wait(for: [bootstrapWindow], timeout: 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.command))
            XCTAssertEqual(session.phase, .starting)

            let accepted = expectation(description: "\(providerName) accepted gated input")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                accepted.fulfill()
            }
            wait(for: [accepted], timeout: 1.5)

            XCTAssertEqual(session.phase, .running)
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.command))
            let rendered = expectation(description: "\(providerName) rendered accepted input")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                rendered.fulfill()
            }
            wait(for: [rendered], timeout: 1)
            let terminalText = String(
                data: process.terminalView.getTerminal().getBufferAsData(),
                encoding: .utf8
            )
            XCTAssertTrue(terminalText?.contains("input accepted") == true)
            let events = try String(contentsOfFile: paths.deliveryEvents, encoding: .utf8)
            XCTAssertEqual(countEvent("claimed", in: events), 1, providerName)
            XCTAssertEqual(countEvent("claim_published", in: events), 1, providerName)
            XCTAssertTrue(events.contains(#""relay_command_seq":1"#), providerName)
            XCTAssertTrue(events.contains(#""relay_command_id":"cmd-1""#), providerName)
            XCTAssertTrue(
                events.contains("\"provider\":\"\(providerName.lowercased())\""),
                providerName
            )
            XCTAssertFalse(events.contains("ping"), providerName)
            session.end()
        }
    }

    func testMountedLifecycleProviderExitFinalizesOpenDeliveryForBothProviders() throws {
        for (providerName, target) in [
            ("Codex", ProcessManager.AgentTarget.codex),
            ("Claude", ProcessManager.AgentTarget.claude),
        ] {
            let fixture = try makeRealPTYFixture()
            let paths = deliveryPaths(in: fixture.directory)
            let provider = providerName.lowercased()
            let commandID = "termination-\(provider)"
            let command = "lifecycle voice request"
            let metadata = """
            {"provider":"\(provider)","relay_command_id":"\(commandID)","relay_command_seq":57}
            """
            try Data().write(to: URL(fileURLWithPath: paths.voiceInput))
            try "\(command)\n".write(toFile: paths.command, atomically: true, encoding: .utf8)
            try metadata.write(toFile: paths.metadata, atomically: true, encoding: .utf8)
            try metadata.write(toFile: paths.commandState, atomically: true, encoding: .utf8)

            let process = SwiftTermEmbeddedProcess(
                readinessStabilityInterval: 0.05,
                readinessPollInterval: 0.01,
                voiceDeliveryPaths: paths,
                voiceDeliveryAcknowledgementTimeout: 0.05
            )
            let session = EmbeddedTerminalSession(processFactory: { process })
            let exited = expectation(description: "\(providerName) real provider exit")
            session.setExitHandler { code in
                XCTAssertEqual(code, 0, providerName)
                exited.fulfill()
            }
            try session.beginPreparing(
                providerName: providerName,
                providerKey: provider,
                workingDirectory: fixture.directory.path
            )
            try session.start(ProcessManager.PreparedSessionLaunch(
                executable: "/bin/bash",
                arguments: ["-c", """
                    stty -icanon -echo
                    printf 'interactive provider output\r\n'
                    IFS= read -r line
                    [ "$line" = "\(command)" ] || exit 3
                    printf 'voice input accepted\r\n'
                    sleep 0.2
                    exit 0
                    """],
                launcherPath: "/bin/bash",
                workingDirectory: fixture.directory.path,
                target: target,
                voiceDelivery: .appOwned,
                sessionEventPath: fixture.events.path
            ))
            let host = EmbeddedTerminalHostNSView()
            host.install(session.hostedView)
            XCTAssertTrue(process.terminalView.superview === host, providerName)

            wait(for: [exited], timeout: 2)
            XCTAssertEqual(session.phase, .exited(0), providerName)

            let releasedCallbacks = expectation(
                description: "\(providerName) released delivery callbacks drained"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                releasedCallbacks.fulfill()
            }
            wait(for: [releasedCallbacks], timeout: 1)

            let events = try String(contentsOfFile: paths.deliveryEvents, encoding: .utf8)
            XCTAssertEqual(countEvent("provider_process_terminated", in: events), 1, providerName)
            XCTAssertEqual(countEvent("delivery_failure_published", in: events), 1, providerName)
            XCTAssertEqual(countEvent("delivery_failure_publish_failed", in: events), 0, providerName)
            XCTAssertEqual(countEvent("delivery_acknowledged", in: events), 0, providerName)
            XCTAssertEqual(countEvent("prompt_write", in: events), 1, providerName)
            XCTAssertFalse(events.contains(command), providerName)

            let publicOutput = try String(contentsOfFile: paths.voiceInput, encoding: .utf8)
            XCTAssertEqual(
                publicOutput.components(separatedBy: "__ORCHESTRATOR_REPLY__:").count - 1,
                1,
                providerName
            )
            XCTAssertTrue(publicOutput.contains(#""relay_command_seq":57"#), providerName)
            XCTAssertTrue(publicOutput.contains("\"relay_command_id\":\"\(commandID)\""), providerName)
            XCTAssertFalse(publicOutput.contains(command), providerName)

            let journal = try String(contentsOfFile: paths.actionJournal, encoding: .utf8)
            let terminalOutcomes = journal
                .split(separator: "\n")
                .compactMap { line -> [String: Any]? in
                    guard let data = String(line).data(using: .utf8) else { return nil }
                    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                }
                .filter { ($0["state"] as? String) == "delivery_failed" }
            XCTAssertEqual(terminalOutcomes.count, 1, providerName)
            XCTAssertEqual(terminalOutcomes.first?["relay_command_seq"] as? Int, 57, providerName)
            XCTAssertEqual(terminalOutcomes.first?["relay_command_id"] as? String, commandID, providerName)
            XCTAssertEqual(terminalOutcomes.first?["provider"] as? String, provider, providerName)
            XCTAssertFalse(journal.contains(command), providerName)
        }
    }

    func testPresentationDetachLeavesEmbeddedProcessRunning() throws {
        let process = FakeEmbeddedTerminalProcess()
        let session = EmbeddedTerminalSession(processFactory: { process })
        let host = EmbeddedTerminalHostNSView()

        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        host.install(session.hostedView)
        host.detach()

        XCTAssertTrue(process.isRunning)
        XCTAssertEqual(process.terminateCount, 0)
        XCTAssertEqual(session.phase, .running)
        XCTAssertNil(process.view.superview)
    }

    func testPreviousHostDetachDoesNotRemoveReparentedTerminalView() {
        let terminalView = NSView()
        let firstHost = EmbeddedTerminalHostNSView()
        let secondHost = EmbeddedTerminalHostNSView()

        firstHost.install(terminalView)
        secondHost.install(terminalView)
        firstHost.detach()

        XCTAssertTrue(terminalView.superview === secondHost)
    }

    private func makeRealPTYFixture() throws -> (directory: URL, events: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RR258-PTY-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let events = directory.appendingPathComponent("events.jsonl")
        try #"{"stage":"provider_spawn","outcome":"started"}"#.write(
            to: events,
            atomically: true,
            encoding: .utf8
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, events)
    }

    private func realPTYLaunch(
        command: String,
        target: ProcessManager.AgentTarget,
        fixture: (directory: URL, events: URL)
    ) -> ProcessManager.PreparedSessionLaunch {
        ProcessManager.PreparedSessionLaunch(
            executable: "/bin/bash",
            arguments: ["-c", command],
            launcherPath: "/bin/bash",
            workingDirectory: fixture.directory.path,
            target: target,
            voiceDelivery: .agentSkill,
            sessionEventPath: fixture.events.path
        )
    }

    private func deliveryPaths(in directory: URL) -> RelayVoiceCommandDelivery.Paths {
        RelayVoiceCommandDelivery.Paths(
            command: directory.appendingPathComponent("command").path,
            metadata: directory.appendingPathComponent("metadata").path,
            claimed: directory.appendingPathComponent("claimed").path,
            commandState: directory.appendingPathComponent("command-state").path,
            providerTurns: directory.appendingPathComponent("provider-turns").path,
            deliveryEvents: directory.appendingPathComponent("delivery-events").path,
            actionJournal: directory.appendingPathComponent("action-journal").path,
            voiceInput: directory.appendingPathComponent("voice-input").path,
            heartbeat: directory.appendingPathComponent("heartbeat").path
        )
    }

    private func countEvent(_ event: String, in events: String) -> Int {
        events.components(separatedBy: "\"event\":\"\(event)\"").count - 1
    }

    private func launch() -> ProcessManager.PreparedSessionLaunch {
        ProcessManager.PreparedSessionLaunch(
            executable: "/bin/bash",
            arguments: ["/tmp/voice_bridge_launch.command"],
            launcherPath: "/tmp/voice_bridge_launch.command",
            workingDirectory: "/repo",
            target: .codex,
            voiceDelivery: .appOwned
        )
    }
}

final class EmbeddedAgentDiagnosticsTests: XCTestCase {
    func testEveryAttemptWritesPrivateManifestWithoutMarkerOrTranscript() throws {
        let root = try makeRoot()
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let diagnostics = try XCTUnwrap(EmbeddedAgentDiagnostics.start(
            provider: "codex",
            workingDirectory: "/repo",
            baseDirectory: root,
            routeKind: "project",
            projectIdentity: "/repo",
            now: { now }
        ))
        diagnostics.flushForTesting()

        let manifest = try readManifest(root)
        XCTAssertEqual(manifest["schema_version"] as? Int, EmbeddedAgentDiagnostics.schemaVersion)
        XCTAssertEqual(manifest["provider"] as? String, "codex")
        XCTAssertEqual(manifest["configured_workspace_folder"] as? String, "/repo")
        XCTAssertEqual(manifest["route_kind"] as? String, "project")
        XCTAssertEqual(manifest["project_identity"] as? String, "/repo")
        XCTAssertEqual(manifest["state"] as? String, "starting")
        XCTAssertEqual(manifest["current_stage"] as? String, "launch_request")
        XCTAssertEqual(manifest["started_at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertNil(manifest["transcript_path"])
        XCTAssertNil(manifest["source_text"])
        XCTAssertNil(manifest["prompt"])

        XCTAssertEqual(try permissions(at: EmbeddedAgentDiagnostics.diagnosticsDirectoryURL(baseDirectory: root)), 0o700)
        XCTAssertEqual(try permissions(at: EmbeddedAgentDiagnostics.manifestURL(baseDirectory: root)), 0o600)
        XCTAssertEqual(try permissions(at: diagnostics.eventsURL), 0o600)
    }

    func testLifecycleStagesRecordOnlyBoundedSafeEvidence() throws {
        let root = try makeRoot()
        let diagnostics = try XCTUnwrap(EmbeddedAgentDiagnostics.start(
            provider: "codex",
            workingDirectory: "/repo",
            baseDirectory: root,
            routeKind: "project",
            projectIdentity: "/repo"
        ))

        diagnostics.markLauncherPrepared(path: "/tmp/voice_bridge_launch.command")
        diagnostics.recordChildPID(123)
        diagnostics.markInteractiveReady()
        diagnostics.flushForTesting()

        let manifest = try readManifest(root)
        XCTAssertEqual(manifest["child_pid"] as? Int, 123)
        XCTAssertEqual(manifest["state"] as? String, "ready")
        XCTAssertEqual(manifest["current_stage"] as? String, "interactive_provider_readiness")
        let events = try String(contentsOf: diagnostics.eventsURL, encoding: .utf8)
        let stages = try events.split(separator: "\n").map { line in
            let data = try XCTUnwrap(String(line).data(using: .utf8))
            let event = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            return try XCTUnwrap(event["stage"] as? String)
        }
        XCTAssertEqual(stages, [
            "launch_request",
            "launcher_prepared",
            "interactive_provider_readiness",
        ])
        XCTAssertFalse(events.contains("hello"))
        XCTAssertFalse(events.contains("source_text"))
        XCTAssertTrue(events.contains(#""controlling_pty":"stable""#))
    }

    func testLaunchdFailureAndBridgeTimeoutRemainDistinctFromProviderExit() throws {
        let root = try makeRoot()
        let diagnostics = try XCTUnwrap(EmbeddedAgentDiagnostics.start(
            provider: "claude",
            workingDirectory: "/repo",
            baseDirectory: root,
            routeKind: "project",
            projectIdentity: "/repo"
        ))
        let bridgeEvents = """
        {"stage":"launchd_bridge_submission","outcome":"failed","exit_status":1}
        {"stage":"bridge_socket_readiness","outcome":"timeout"}
        """
        try bridgeEvents.write(to: diagnostics.eventsURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(diagnostics.recordedOutcome(for: "launchd_bridge_submission"), "failed")
        XCTAssertEqual(diagnostics.recordedOutcome(for: "bridge_socket_readiness"), "timeout")
        XCTAssertNil(diagnostics.recordedOutcome(for: "provider_spawn"))

        diagnostics.markLaunchFailed(rawStatus: 256)
        diagnostics.flushForTesting()

        let manifest = try readManifest(root)
        XCTAssertEqual(manifest["provider"] as? String, "claude")
        XCTAssertEqual(manifest["state"] as? String, "setup_failed")
        XCTAssertEqual(manifest["exit_code"] as? Int, 1)
        let events = try String(contentsOf: diagnostics.eventsURL, encoding: .utf8)
        XCTAssertTrue(events.contains("launcher_exit_before_provider_spawn"))
        XCTAssertFalse(events.contains("provider_early_exit"))
    }

    func testEarlyExitAndSignalTerminationAreDecodedForBothProviders() throws {
        for (provider, rawStatus, expectedField, expectedValue) in [
            ("codex", Int32(0), "exit_code", 0),
            ("claude", Int32(9), "termination_signal", 9),
        ] {
            let root = try makeRoot()
            let diagnostics = try XCTUnwrap(EmbeddedAgentDiagnostics.start(
                provider: provider,
                workingDirectory: "/repo",
                baseDirectory: root,
                routeKind: "project",
                projectIdentity: "/repo"
            ))

            diagnostics.markExited(rawStatus: rawStatus, beforeInteractiveReadiness: true)
            diagnostics.flushForTesting()

            let manifest = try readManifest(root)
            XCTAssertEqual(manifest["provider"] as? String, provider)
            XCTAssertEqual(manifest["state"] as? String, "provider_early_exit")
            XCTAssertEqual(manifest["raw_exit_status"] as? Int, Int(rawStatus))
            XCTAssertEqual(manifest[expectedField] as? Int, expectedValue)
            XCTAssertEqual(
                manifest["failed_stage"] as? String,
                "interactive_provider_readiness"
            )
            let events = try String(contentsOf: diagnostics.eventsURL, encoding: .utf8)
            XCTAssertTrue(events.contains(#""failed_stage":"interactive_provider_readiness""#))
        }
    }

    func testDiagnosticsSetupFailureIsNonFatal() throws {
        let root = try makeRoot()
        let diagnosticsDirectory = EmbeddedAgentDiagnostics.diagnosticsDirectoryURL(baseDirectory: root)
        try Data("not a directory".utf8).write(to: diagnosticsDirectory)

        let diagnostics = EmbeddedAgentDiagnostics.start(
            provider: "codex",
            workingDirectory: "/repo",
            baseDirectory: root,
            routeKind: "project",
            projectIdentity: "/repo"
        )

        XCTAssertNil(diagnostics)
    }

    func testProviderLabelsCoverCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let root = try makeRoot()
            let diagnostics = try XCTUnwrap(EmbeddedAgentDiagnostics.start(
                provider: provider,
                workingDirectory: "/repo",
                baseDirectory: root,
                routeKind: "project",
                projectIdentity: "/repo"
            ))
            diagnostics.flushForTesting()

            let manifest = try readManifest(root)
            XCTAssertEqual(manifest["provider"] as? String, provider)
        }
    }

    func testAppRelaunchFinalizesUnfinishedAttempt() throws {
        let root = try makeRoot()
        let diagnostics = try XCTUnwrap(EmbeddedAgentDiagnostics.start(
            provider: "codex",
            workingDirectory: "/repo",
            baseDirectory: root,
            routeKind: "project",
            projectIdentity: "/repo"
        ))
        diagnostics.recordChildPID(321)
        diagnostics.flushForTesting()

        EmbeddedAgentDiagnostics.finalizeInterruptedSessionIfNeeded(
            baseDirectory: root,
            now: Date(timeIntervalSince1970: 1_800_000_010)
        )

        let manifest = try readManifest(root)
        XCTAssertEqual(manifest["state"] as? String, "app_relaunch")
        XCTAssertEqual(manifest["failure_kind"] as? String, "app_relaunch")
        XCTAssertEqual(manifest["ended_at"] as? String, "2027-01-15T08:00:10Z")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddedAgentDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func readManifest(_ root: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: EmbeddedAgentDiagnostics.manifestURL(baseDirectory: root))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func permissions(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}

final class RelayTerminalInputTrackerTests: XCTestCase {
    func testTrackerDefersVoiceDeliveryWhilePromptTextIsUnsubmitted() {
        var tracker = RelayTerminalInputTracker()

        tracker.record(data: ArraySlice(Array("partial".utf8)))
        XCTAssertTrue(tracker.hasUnsubmittedInput)

        tracker.record(data: ArraySlice([127, 127, 127, 127, 127, 127, 127]))
        XCTAssertFalse(tracker.hasUnsubmittedInput)

        XCTAssertEqual(
            tracker.record(data: ArraySlice(Array("next".utf8))),
            .draftChanged
        )
        XCTAssertTrue(tracker.hasUnsubmittedInput)

        XCTAssertEqual(
            tracker.record(data: ArraySlice([13])),
            .submitted(pendingByteCount: 4)
        )
        XCTAssertFalse(tracker.hasUnsubmittedInput)
    }

    func testTrackerUnderstandsKittyKeyboardClearAndEditingEvents() {
        var tracker = RelayTerminalInputTracker()

        tracker.record(data: ArraySlice(Array("/rel".utf8)))
        tracker.record(data: ArraySlice(Array("\u{1B}[117;5u".utf8)))
        XCTAssertFalse(tracker.hasUnsubmittedInput)

        tracker.record(data: ArraySlice(Array("\u{1B}[120u".utf8)))
        XCTAssertTrue(tracker.hasUnsubmittedInput)

        tracker.record(data: ArraySlice(Array("\u{1B}[127u".utf8)))
        XCTAssertFalse(tracker.hasUnsubmittedInput)

        tracker.record(data: ArraySlice(Array("\u{1B}[120;1:3u".utf8)))
        XCTAssertFalse(tracker.hasUnsubmittedInput)
    }

    func testTrackerIgnoresNativeNavigationShortcuts() {
        var tracker = RelayTerminalInputTracker()

        tracker.record(data: ArraySlice([27, 98]))
        tracker.record(data: ArraySlice([27, 102]))
        tracker.record(data: ArraySlice([1]))
        tracker.record(data: ArraySlice([5]))

        XCTAssertFalse(tracker.hasUnsubmittedInput)
    }

    func testTrackerCountsUnicodePasteBytesButDeletesOneInputUnit() {
        var tracker = RelayTerminalInputTracker()

        XCTAssertEqual(
            tracker.record(data: ArraySlice(Array("é".utf8))),
            .draftChanged
        )
        XCTAssertEqual(tracker.pendingByteCount, 2)

        tracker.record(data: ArraySlice([127]))

        XCTAssertFalse(tracker.hasUnsubmittedInput)
        XCTAssertEqual(tracker.pendingByteCount, 0)
    }
}

final class RelayTerminalViewInputOriginTests: XCTestCase {
    func testTerminalRendererDefaultsToCoreGraphics() {
        let view = RelayTerminalView(frame: .zero)

        XCTAssertFalse(view.configureRendererFromEnvironment([:]))
        XCTAssertFalse(view.isUsingMetalRenderer)
    }

    func testTerminalRendererFallsBackToCoreGraphicsAfterActivationError() {
        struct ActivationError: Error {}
        let view = RelayTerminalView(frame: .zero)

        XCTAssertFalse(view.configureRendererFromEnvironment(
            ["RELAY_RUNNER_TERMINAL_RENDERER": "metal"],
            activateMetal: { throw ActivationError() }
        ))
        XCTAssertFalse(view.isUsingMetalRenderer)
    }

    func testTerminalProtocolRepliesAreDistinctFromUserInput() {
        let view = RelayTerminalView(frame: .zero)
        let delegate = TerminalInputOriginCapturingDelegate(view: view)
        view.terminalDelegate = delegate

        view.send(
            source: view.getTerminal(),
            data: ArraySlice(Array("\u{1B}[1;1R".utf8))
        )
        view.send(data: ArraySlice(Array("typed".utf8)))

        XCTAssertEqual(delegate.terminalResponseFlags, [true, false])
    }

    func testNavigationShortcutsAreMarkedAsNonPromptInput() {
        let view = RelayTerminalView(frame: .zero)
        let delegate = TerminalInputOriginCapturingDelegate(view: view)
        view.terminalDelegate = delegate

        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(keyCode: 123, modifiers: .option)))
        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(keyCode: 124, modifiers: .option)))
        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(keyCode: 123, modifiers: .command)))
        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(keyCode: 124, modifiers: .command)))

        XCTAssertEqual(delegate.payloads, [[27, 98], [27, 102], [1], [5]])
        XCTAssertEqual(delegate.navigationShortcutFlags, [true, true, true, true])
        XCTAssertEqual(delegate.terminalResponseFlags, [false, false, false, false])
    }

    func testNavigationShortcutPayloadRequiresPlainOptionOrCommandArrow() {
        XCTAssertEqual(
            RelayTerminalView.navigationShortcutPayload(for: keyEvent(keyCode: 123, modifiers: .option)),
            [27, 98]
        )
        XCTAssertEqual(
            RelayTerminalView.navigationShortcutPayload(for: keyEvent(keyCode: 124, modifiers: .option)),
            [27, 102]
        )
        XCTAssertEqual(
            RelayTerminalView.navigationShortcutPayload(for: keyEvent(keyCode: 123, modifiers: .command)),
            [1]
        )
        XCTAssertEqual(
            RelayTerminalView.navigationShortcutPayload(for: keyEvent(keyCode: 124, modifiers: .command)),
            [5]
        )
        XCTAssertNil(RelayTerminalView.navigationShortcutPayload(for: keyEvent(keyCode: 123, modifiers: [.option, .shift])))
        XCTAssertNil(RelayTerminalView.navigationShortcutPayload(for: keyEvent(keyCode: 125, modifiers: .option)))
    }
}

final class RelayVoiceCommandDeliveryTests: XCTestCase {
    func testClaimPublishesMetadataBeforeSubmitAndWaitsForProviderAcknowledgement() throws {
        let fixture = try makeFixture()
        try "Fix the bridge\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        let metadata = #"{"provider":"codex","relay_command_id":"cmd-1","relay_command_seq":1}"#
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        var claimBeforeEnter: String?
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in
                let text = String(decoding: data, as: UTF8.self)
                if text == "\r" {
                    claimBeforeEnter = try? String(contentsOf: fixture.claimed)
                }
                sent.append(text)
            },
            acknowledgementTimeout: 0.5,
            schedule: { delay, _, work in scheduled.append((delay, work)) },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())

        XCTAssertEqual(sent, ["Fix the bridge"])
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertGreaterThanOrEqual(scheduled[0].delay, 0.05)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.claimed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.heartbeat.path))

        scheduled[0].work()

        XCTAssertEqual(sent, ["Fix the bridge", "\r"])
        XCTAssertEqual(claimBeforeEnter, metadata)
        XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.consumerAcknowledgement.path)
        )
        let eventsBeforeAck = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(eventsBeforeAck.contains(#""event":"submit_attempt""#))
        XCTAssertFalse(eventsBeforeAck.contains(#""event":"submit""#))
        XCTAssertFalse(eventsBeforeAck.contains(#""event":"provider_acknowledged""#))

        try writeProviderTurns([
            providerTurn(seq: 1, id: "cmd-1", provider: "codex", state: "active"),
        ], to: fixture.providerTurns)

        XCTAssertTrue(delivery.claimAndSendIfPossible())

        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"claimed""#))
        XCTAssertTrue(events.contains(#""event":"prompt_write""#))
        XCTAssertTrue(events.contains(#""event":"claim_published""#))
        XCTAssertTrue(events.contains(#""event":"submit_attempt""#))
        XCTAssertTrue(events.contains(#""event":"provider_acknowledged""#))
        XCTAssertTrue(events.contains(#""provider":"codex""#))
        XCTAssertTrue(events.contains(#""relay_command_id":"cmd-1""#))
        XCTAssertFalse(events.contains("Fix the bridge"))
        let journal = try String(contentsOf: fixture.actionJournal)
        XCTAssertTrue(journal.contains(#""state":"claimed""#))
        XCTAssertFalse(journal.contains("Fix the bridge"))
    }

    func testPromptWrittenWindowPreservesManualInputForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let command = "Voice-owned prompt"
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-1\",\"relay_command_seq\":1}"
            try "\(command)\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var ptyWrites: [[UInt8]] = []
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in ptyWrites.append(Array(data)) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true }
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(ptyWrites, [Array(command.utf8)], provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.claimed.path), provider)

            let manualInputs: [[UInt8]] = [
                Array("typed draft".utf8),
                Array(" pasted 🧪".utf8),
                [13],
            ]
            for input in manualInputs {
                if delivery.recordUserInput(ArraySlice(input)) {
                    ptyWrites.append(input)
                }
            }

            XCTAssertEqual(ptyWrites, [Array(command.utf8)], provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.claimed.path), provider)

            XCTAssertEqual(scheduled.count, 1, provider)
            scheduled[0]()

            XCTAssertEqual(
                ptyWrites,
                [Array(command.utf8), [13], manualInputs[0], manualInputs[1]],
                provider
            )
            XCTAssertEqual(ptyWrites.filter { $0 == [13] }.count, 1, provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)
            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "active"),
            ], to: fixture.providerTurns)

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(ptyWrites.filter { $0 == [13] }.count, 1, provider)
            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "completed_final"),
            ], to: fixture.providerTurns)

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(Array(ptyWrites.dropFirst(2)), manualInputs, provider)
            XCTAssertEqual(ptyWrites.filter { $0 == [13] }.count, 2, provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertEqual(countEvent("manual_input_quarantined", in: events), 3, provider)
            XCTAssertEqual(countEvent("manual_draft_restored", in: events), 1, provider)
            XCTAssertEqual(countEvent("manual_submit_replayed", in: events), 1, provider)
            XCTAssertTrue(events.contains(#""deferral_reason":"voice_submit_delay""#), provider)
            XCTAssertFalse(events.contains("typed draft"), provider)
            XCTAssertFalse(events.contains("pasted"), provider)
        }
    }

    func testTransportConfirmationOwnsComposerUntilVoiceReturnWritesForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let command = "Voice-owned prompt"
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-1\",\"relay_command_seq\":1}"
            try "\(command)\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var ptyWrites: [[UInt8]] = []
            var transportQueue: [(bytes: [UInt8], confirmation: () -> Void)] = []
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in
                    transportQueue.append((Array(data), {}))
                },
                transportSend: { data, confirmation in
                    transportQueue.append((Array(data), confirmation))
                },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true }
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(transportQueue.map(\.bytes), [Array(command.utf8)], provider)
            let promptWrite = transportQueue.removeFirst()
            ptyWrites.append(promptWrite.bytes)
            promptWrite.confirmation()

            XCTAssertEqual(scheduled.count, 1, provider)
            scheduled[0]()
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)
            XCTAssertEqual(transportQueue.map(\.bytes), [[13]], provider)

            let manualInputs: [[UInt8]] = [
                Array("typed draft".utf8),
                Array(" pasted 🧪".utf8),
                [13],
            ]
            for input in manualInputs {
                XCTAssertFalse(delivery.recordUserInput(ArraySlice(input)), provider)
            }

            XCTAssertEqual(ptyWrites, [Array(command.utf8)], provider)
            XCTAssertEqual(transportQueue.map(\.bytes), [[13]], provider)
            let eventsBeforeTransportConfirmation = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertEqual(countEvent("submit_attempt", in: eventsBeforeTransportConfirmation), 1, provider)
            XCTAssertEqual(
                countEvent("submit_transport_confirmed", in: eventsBeforeTransportConfirmation),
                0,
                provider
            )
            XCTAssertEqual(
                countEvent("manual_draft_restored", in: eventsBeforeTransportConfirmation),
                0,
                provider
            )
            let voiceReturn = transportQueue.removeFirst()
            ptyWrites.append(voiceReturn.bytes)
            voiceReturn.confirmation()

            XCTAssertEqual(ptyWrites, [Array(command.utf8), [13]], provider)
            XCTAssertEqual(ptyWrites.filter { $0 == [13] }.count, 1, provider)
            XCTAssertEqual(transportQueue.map(\.bytes), Array(manualInputs.dropLast()), provider)
            while !transportQueue.isEmpty {
                let draftWrite = transportQueue.removeFirst()
                ptyWrites.append(draftWrite.bytes)
                draftWrite.confirmation()
            }
            XCTAssertEqual(
                ptyWrites,
                [Array(command.utf8), [13], manualInputs[0], manualInputs[1]],
                provider
            )

            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "active"),
            ], to: fixture.providerTurns)
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertTrue(transportQueue.isEmpty, provider)

            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "completed_final"),
            ], to: fixture.providerTurns)
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(transportQueue.map(\.bytes), [[13]], provider)
            let manualReturn = transportQueue.removeFirst()
            ptyWrites.append(manualReturn.bytes)
            manualReturn.confirmation()

            XCTAssertEqual(
                ptyWrites,
                [Array(command.utf8), [13], manualInputs[0], manualInputs[1], manualInputs[2]],
                provider
            )
            XCTAssertEqual(ptyWrites.filter { $0 == [13] }.count, 2, provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertEqual(countEvent("submit_attempt", in: events), 1, provider)
            XCTAssertEqual(countEvent("submit_transport_confirmed", in: events), 1, provider)
            XCTAssertEqual(countEvent("manual_input_quarantined", in: events), 3, provider)
            XCTAssertEqual(countEvent("manual_draft_restored", in: events), 1, provider)
            XCTAssertEqual(countEvent("manual_submit_replayed", in: events), 1, provider)
            XCTAssertFalse(events.contains(command), provider)
            XCTAssertFalse(events.contains("typed draft"), provider)
        }
    }

    func testMissingProviderAcknowledgementRecoversWithoutRetryingReturn() throws {
        let fixture = try makeFixture()
        try "Fix the bridge\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        let metadata = #"{"provider":"codex","relay_command_id":"cmd-1","relay_command_seq":1}"#
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            acknowledgementTimeout: 0.5,
            schedule: { delay, _, work in scheduled.append((delay, work)) },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        scheduled[0].work()
        scheduled[1].work()

        XCTAssertEqual(sent, ["Fix the bridge", "\r"])
        XCTAssertEqual(sent.filter { $0 == "Fix the bridge" }.count, 1)
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"acknowledgement_timeout""#))
        XCTAssertTrue(events.contains(#""event":"recovery_started""#))
        XCTAssertFalse(events.contains(#""event":"submit_retry""#))
        XCTAssertFalse(events.contains(#""event":"delivery_failure_published""#))
        XCTAssertFalse(events.contains("Fix the bridge"))
    }

    func testDelayedProviderAcknowledgementDuringRecoveryPreventsFailure() throws {
        let fixture = try makeFixture()
        try Data().write(to: fixture.voiceInput)
        try "Fix the bridge\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        let metadata = #"{"provider":"codex","relay_command_id":"cmd-1","relay_command_seq":1}"#
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            acknowledgementTimeout: 0.5,
            schedule: { delay, _, work in scheduled.append((delay, work)) },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        scheduled[0].work()
        scheduled[1].work()
        try writeProviderTurns([
            providerTurn(seq: 1, id: "cmd-1", provider: "codex", state: "active"),
        ], to: fixture.providerTurns)
        scheduled[2].work()

        XCTAssertEqual(sent, ["Fix the bridge", "\r"])
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"late_ack_reconciled""#))
        XCTAssertTrue(events.contains(#""event":"provider_acknowledged""#))
        XCTAssertFalse(events.contains(#""event":"delivery_failure_published""#))
        XCTAssertFalse((try String(contentsOf: fixture.voiceInput)).contains("__TRACE__:"))
    }

    func testRecoveryPublishesFailureOnlyAfterProviderProcessTerminates() throws {
        let fixture = try makeFixture()
        try Data().write(to: fixture.voiceInput)
        try "Fix the bridge\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        let metadata = #"{"provider":"claude","relay_command_id":"cmd-1","relay_command_seq":1}"#
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        var running = true
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            acknowledgementTimeout: 0.5,
            schedule: { delay, _, work in scheduled.append((delay, work)) },
            isRunning: { running }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        scheduled[0].work()
        scheduled[1].work()
        running = false
        scheduled[2].work()

        XCTAssertEqual(sent, ["Fix the bridge", "\r"])
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"recovery_started""#))
        XCTAssertTrue(events.contains(#""event":"provider_process_terminated""#))
        XCTAssertTrue(events.contains(#""event":"delivery_failure_published""#))
        XCTAssertTrue(events.contains(#""provider":"claude""#))
        XCTAssertFalse(events.contains("Fix the bridge"))
        let control = try String(contentsOf: fixture.voiceInput)
        XCTAssertTrue(control.contains("__ORCHESTRATOR_REPLY__:"))
        XCTAssertTrue(control.contains(#""relay_command_id":"cmd-1""#))
        XCTAssertFalse(control.contains("Fix the bridge"))
        XCTAssertTrue(
            try String(contentsOf: fixture.actionJournal)
                .contains(#""state":"delivery_failed""#)
        )
    }

    func testProviderExitDuringAcknowledgementPublishesFailureWithoutReplay() throws {
        let fixture = try makeFixture()
        try Data().write(to: fixture.voiceInput)
        try "Fix the bridge\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        let metadata = #"{"provider":"codex","relay_command_id":"cmd-1","relay_command_seq":1}"#
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        var running = true
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            acknowledgementTimeout: 0.5,
            schedule: { delay, _, work in scheduled.append((delay, work)) },
            isRunning: { running }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        scheduled[0].work()
        running = false
        scheduled[1].work()

        XCTAssertEqual(sent, ["Fix the bridge", "\r"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path))
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"provider_process_terminated""#))
        XCTAssertTrue(events.contains(#""event":"delivery_failure_published""#))
        XCTAssertFalse(events.contains("Fix the bridge"))
        let control = try String(contentsOf: fixture.voiceInput)
        XCTAssertTrue(control.contains("__ORCHESTRATOR_REPLY__:"))
        XCTAssertTrue(control.contains(#""relay_command_id":"cmd-1""#))
    }

    func testConsecutiveCommandWaitsForAcknowledgementBeforeClaimingNext() throws {
        let fixture = try makeFixture()
        let firstMetadata = #"{"provider":"codex","relay_command_id":"cmd-1","relay_command_seq":1}"#
        let secondMetadata = #"{"provider":"codex","relay_command_id":"cmd-2","relay_command_seq":2}"#
        try "First request\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try firstMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try firstMetadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            acknowledgementTimeout: 0.5,
            schedule: { delay, _, work in scheduled.append((delay, work)) },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        scheduled[0].work()
        try "Second request\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try secondMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try secondMetadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)

        XCTAssertFalse(delivery.claimAndSendIfPossible())
        XCTAssertEqual(sent, ["First request", "\r"])

        try writeProviderTurns([
            providerTurn(seq: 1, id: "cmd-1", provider: "codex", state: "completed_final"),
        ], to: fixture.providerTurns)

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        XCTAssertTrue(delivery.claimAndSendIfPossible())

        XCTAssertEqual(sent, ["First request", "\r", "Second request"])
        XCTAssertEqual(scheduled.count, 3)
    }

    func testOrderedSiblingClaimsUseExactIntentIdentityForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let firstMetadata = """
            {"provider":"\(provider)","relay_command_id":"multi","relay_command_seq":1,"intent_id":"multi:item:1","within_turn_order":1}
            """
            let secondMetadata = """
            {"provider":"\(provider)","relay_command_id":"multi","relay_command_seq":1,"intent_id":"multi:item:2","within_turn_order":2}
            """
            try "First sibling\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try firstMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try firstMetadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var sent: [String] = []
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true }
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            scheduled[0]()
            try writeProviderTurns([
                providerTurn(
                    seq: 1,
                    id: "multi",
                    provider: provider,
                    state: "empty",
                    intentID: "multi:item:1"
                ),
            ], to: fixture.providerTurns)
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)

            try "Second sibling\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try secondMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try secondMetadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            scheduled[2]()

            XCTAssertEqual(
                sent,
                ["First sibling", "\r", "Second sibling", "\r"],
                provider
            )
            XCTAssertEqual(try String(contentsOf: fixture.claimed), secondMetadata, provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertEqual(countEvent("claimed", in: events), 2, provider)
            XCTAssertEqual(countEvent("provider_acknowledged", in: events), 1, provider)
        }
    }

    func testStaleProviderAcknowledgementCannotCompleteNewerPendingCommand() throws {
        let fixture = try makeFixture()
        let metadata = #"{"provider":"claude","relay_command_id":"cmd-2","relay_command_seq":2}"#
        try "Second request\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        try writeProviderTurns([
            providerTurn(seq: 1, id: "cmd-1", provider: "claude", state: "completed_final"),
        ], to: fixture.providerTurns)
        var sent: [String] = []
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            acknowledgementTimeout: 0.5,
            schedule: { delay, _, work in scheduled.append((delay, work)) },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        scheduled[0].work()
        XCTAssertFalse(delivery.claimAndSendIfPossible())
        scheduled[1].work()

        XCTAssertEqual(sent, ["Second request", "\r"])
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertFalse(events.contains(#""event":"provider_acknowledged""#))
        XCTAssertTrue(events.contains(#""event":"recovery_started""#))
        XCTAssertFalse(events.contains(#""event":"submit_retry""#))
        XCTAssertTrue(events.contains(#""provider":"claude""#))
    }

    func testDeliveryDefersWhenTypedInputIsPending() throws {
        let fixture = try makeFixture()
        try "Do the work\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        let metadata = #"{"provider":"codex","relay_command_id":"cmd-1","relay_command_seq":1}"#
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        try Data().write(to: fixture.voiceInput)
        var sent: [String] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            isRunning: { true }
        )
        delivery.recordUserInput(ArraySlice(Array("manual".utf8)))

        let queued = expectation(description: "input tracker updated")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            queued.fulfill()
        }
        wait(for: [queued], timeout: 1)

        XCTAssertFalse(delivery.claimAndSendIfPossible())
        XCTAssertEqual(sent, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.command.path))
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"deferred_terminal_draft""#))
        XCTAssertTrue(events.contains(#""pending_byte_count":6"#))
        XCTAssertFalse(events.contains("manual"))
        let feedback = try String(contentsOf: fixture.voiceInput)
        XCTAssertFalse(feedback.contains("__TRACE__:"))
        XCTAssertFalse(feedback.contains("Voice command queued"))
        XCTAssertFalse(feedback.contains("manual"))
    }

    func testManualReturnBarrierAndLateAcknowledgementHaveOneOutcome() throws {
        let fixture = try makeFixture()
        try Data().write(to: fixture.voiceInput)
        try "Do the queued work\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        let metadata = #"{"provider":"codex","relay_command_id":"cmd-7","relay_command_seq":7}"#
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var currentTime = Date(timeIntervalSince1970: 100)
        var sent: [String] = []
        var scheduled: [() -> Void] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            acknowledgementTimeout: 0.5,
            schedule: { _, _, work in scheduled.append(work) },
            isRunning: { true },
            now: { currentTime }
        )

        delivery.recordUserInput(ArraySlice(Array("typed provider turn".utf8)))
        waitForDeliveryQueue()
        XCTAssertFalse(delivery.claimAndSendIfPossible())

        delivery.recordUserInput(ArraySlice([13]))
        waitForDeliveryQueue()
        XCTAssertFalse(delivery.claimAndSendIfPossible())
        XCTAssertEqual(sent, [])

        try writeProviderTurnRecords([[
            "state": "active",
            "origin": "manual",
            "session_id": "codex-session",
            "provider": "codex",
            "created_at": 100.1,
            "updated_at": 100.1,
        ]], to: fixture.providerTurns)
        XCTAssertFalse(delivery.claimAndSendIfPossible())

        currentTime = Date(timeIntervalSince1970: 101)
        try writeProviderTurnRecords([[
            "state": "completed_manual",
            "origin": "manual",
            "session_id": "codex-session",
            "provider": "codex",
            "created_at": 100.1,
            "updated_at": 101.0,
        ]], to: fixture.providerTurns)
        XCTAssertTrue(delivery.claimAndSendIfPossible())
        XCTAssertEqual(sent, ["Do the queued work"])
        scheduled[0]()
        XCTAssertEqual(sent, ["Do the queued work", "\r"])

        scheduled[1]()
        try writeProviderTurns([
            providerTurn(seq: 7, id: "cmd-7", provider: "codex", state: "active"),
        ], to: fixture.providerTurns)
        scheduled[2]()

        XCTAssertEqual(sent.filter { $0 == "\r" }.count, 1)
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"manual_submit_barrier_started""#))
        XCTAssertTrue(events.contains(#""event":"safe_boundary_verified""#))
        XCTAssertTrue(events.contains(#""event":"acknowledgement_timeout""#))
        XCTAssertTrue(events.contains(#""event":"late_ack_reconciled""#))
        XCTAssertEqual(countEvent("delivery_acknowledged", in: events), 1)
        XCTAssertFalse(events.contains(#""event":"delivery_failure_published""#))
    }

    func testQueuedDraftDrainsAfterIdentityReconciledManualCompletionForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-342\",\"relay_command_seq\":342,\"intent_id\":\"intent-342\"}"
            try "Queued voice work\n".write(
                to: fixture.command,
                atomically: true,
                encoding: .utf8
            )
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var currentTime = Date(timeIntervalSince1970: 100)
            var sent: [String] = []
            var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { sent.append(String(decoding: $0, as: UTF8.self)) },
                schedule: { delay, _, work in scheduled.append((delay, work)) },
                isRunning: { true },
                now: { currentTime },
                providerSessionID: "embedded-\(provider)",
                appSessionID: "app-session",
                recoveryGeneration: "generation-2",
                foregroundGateHandle: "gate-2"
            )

            XCTAssertTrue(delivery.recordUserInput(ArraySlice(Array("private draft".utf8))), provider)
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            currentTime = Date(timeIntervalSince1970: 100.05)
            XCTAssertTrue(delivery.recordUserInput(ArraySlice(Array(" grows".utf8))), provider)
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)

            currentTime = Date(timeIntervalSince1970: 100.1)
            XCTAssertTrue(delivery.recordUserInput(ArraySlice([13])), provider)
            try writeProviderTurnRecords([[
                "state": "active",
                "origin": "manual",
                "provider": provider,
                "provider_session_id": "embedded-\(provider)",
                "app_session_id": "app-session",
                "recovery_generation": "generation-2",
                "actor_role": "foreground_manual",
                "foreground_gate_handle": "gate-2",
                "session_id": "transient-session",
                "turn_id": "physical-manual-turn",
                "created_at": 100.1,
                "updated_at": 100.1,
            ]], to: fixture.providerTurns)
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, [], provider)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.command.path), provider)

            currentTime = Date(timeIntervalSince1970: 100.3)
            try writeProviderTurnRecords([[
                "state": "completed_manual",
                "origin": "manual",
                "provider": provider,
                "provider_session_id": "embedded-\(provider)",
                "app_session_id": "app-session",
                "recovery_generation": "generation-2",
                "actor_role": "foreground_manual",
                "foreground_gate_handle": "gate-2",
                "session_id": "transient-session",
                "turn_id": "physical-manual-turn",
                "created_at": 100.1,
                "updated_at": 100.3,
                "completion_native_session_id": "persisted-session",
                "completion_correlation": "provider_identity_reconciled",
                "release_reason": "provider_stop_identity_reconciled",
            ]], to: fixture.providerTurns)

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Queued voice work"], provider)
            XCTAssertLessThanOrEqual(currentTime.timeIntervalSince1970 - 100.1, 0.5, provider)
            XCTAssertEqual(scheduled.count, 1, provider)
            XCTAssertLessThan(scheduled[0].delay, 0.5, provider)
            scheduled[0].work()
            XCTAssertEqual(sent, ["Queued voice work", "\r"], provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)

            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertTrue(events.contains(#""event":"deferred_terminal_draft""#), provider)
            XCTAssertTrue(events.contains(#""event":"manual_submit_barrier_started""#), provider)
            XCTAssertTrue(events.contains(#""event":"safe_boundary_wait""#), provider)
            XCTAssertTrue(events.contains(#""event":"safe_boundary_verified""#), provider)
            XCTAssertTrue(events.contains(#""next_drain_decision":"claim_oldest_eligible""#), provider)
            XCTAssertTrue(events.contains(#""provider_turn_release_reason":"provider_stop_identity_reconciled""#), provider)
            XCTAssertTrue(events.contains(#""intent_id":"intent-342""#), provider)
            XCTAssertEqual(countEvent("claimed", in: events), 1, provider)
            XCTAssertFalse(events.contains("private draft"), provider)
            XCTAssertFalse(events.contains("Queued voice work"), provider)
            let journal = try String(contentsOf: fixture.actionJournal)
            XCTAssertTrue(journal.contains(#""barrier_owner":"terminal_composer""#), provider)
            XCTAssertTrue(journal.contains(#""next_drain_decision":"claim_oldest_eligible""#), provider)
            XCTAssertFalse(journal.contains("private draft"), provider)
            XCTAssertFalse(journal.contains("Queued voice work"), provider)
        }
    }

    func testRapidCommandPreemptsBeforeFirstSubmitWithoutStaleEnter() throws {
        let fixture = try makeFixture()
        let firstMetadata = #"{"relay_command_id":"cmd-1","relay_command_seq":1}"#
        let secondMetadata = #"{"relay_command_id":"cmd-2","relay_command_seq":2}"#
        try "First request\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try firstMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try firstMetadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        var scheduled: [() -> Void] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            schedule: { _, _, work in scheduled.append(work) },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        try "Second request\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try secondMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try secondMetadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)

        XCTAssertFalse(delivery.claimAndSendIfPossible())
        scheduled[0]()

        XCTAssertEqual(sent, ["First request", "\u{15}"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.claimed.path))

        XCTAssertTrue(delivery.claimAndSendIfPossible())
        XCTAssertEqual(sent, ["First request", "\u{15}", "Second request"])
        XCTAssertEqual(scheduled.count, 2)
        scheduled[1]()

        XCTAssertEqual(sent, ["First request", "\u{15}", "Second request", "\r"])
        XCTAssertEqual(try String(contentsOf: fixture.claimed), secondMetadata)
    }

    func testStaleReadyCommandIsDroppedBeforePromptWrite() throws {
        let fixture = try makeFixture()
        let staleMetadata = #"{"relay_command_id":"cmd-1","relay_command_seq":1}"#
        let currentMetadata = #"{"relay_command_id":"cmd-2","relay_command_seq":2}"#
        try "Stale request\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try staleMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try currentMetadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())

        XCTAssertEqual(sent, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.claimed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path))
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"stale_command_dropped""#))
        XCTAssertFalse(events.contains("Stale request"))
    }

    func testOrderedInboxCommandRemainsDeliverableWhenNewerConversationExists() throws {
        let fixture = try makeFixture()
        let queuedMetadata = #"{"relay_command_id":"cmd-1","relay_command_seq":1,"intent_id":"intent-1"}"#
        let state = #"{"relay_command_id":"cmd-2","relay_command_seq":2,"deliverable_commands":[{"relay_command_id":"cmd-1","relay_command_seq":1,"intent_id":"intent-1","state":"delivered"}]}"#
        try "Queued project work\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try queuedMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try state.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        var sent: [String] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            schedule: { _, _, _ in },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())

        XCTAssertEqual(sent, ["Queued project work"])
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"claimed""#))
        XCTAssertFalse(events.contains(#""event":"stale_command_dropped""#))
    }

    func testDeliveryDefersNormalCommandWhileProviderTurnIsActive() throws {
        let fixture = try makeFixture()
        let metadata = #"{"relay_command_id":"cmd-2","relay_command_seq":2}"#
        try "Second request\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try #"{"schema_version":2,"records":[{"relay_command_id":"cmd-1","relay_command_seq":1,"state":"active"}]}"#
            .write(to: fixture.providerTurns, atomically: true, encoding: .utf8)
        let oldDate = Date(timeIntervalSinceReferenceDate: 1)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fixture.command.path)
        var sent: [String] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
            isRunning: { true }
        )

        XCTAssertFalse(delivery.claimAndSendIfPossible())

        XCTAssertEqual(sent, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.command.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: fixture.command.path)
        let modified = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertGreaterThan(modified, oldDate)
        let events = try String(contentsOf: fixture.deliveryEvents)
        XCTAssertTrue(events.contains(#""event":"safe_boundary_wait""#))
        XCTAssertFalse(events.contains("Second request"))
    }

    func testAppOwnedPendingCommandIsClaimedOnceAfterActiveTurnForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let secondMetadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-2\",\"relay_command_seq\":2}"
            try "Second request\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try secondMetadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try secondMetadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "active"),
            ], to: fixture.providerTurns)
            var sent: [String] = []
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true }
            )

            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)

            XCTAssertEqual(sent, [], provider)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.command.path), provider)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.metadata.path), provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.claimed.path), provider)

            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "stale"),
            ], to: fixture.providerTurns)

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Second request"], provider)
            XCTAssertEqual(scheduled.count, 1, provider)
            scheduled[0]()

            XCTAssertEqual(sent, ["Second request", "\r"], provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), secondMetadata, provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path), provider)

            try writeProviderTurns([
                providerTurn(seq: 2, id: "cmd-2", provider: provider, state: "active"),
            ], to: fixture.providerTurns)

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Second request", "\r"], provider)

            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertEqual(countEvent("safe_boundary_wait", in: events), 1, provider)
            XCTAssertEqual(countEvent("claimed", in: events), 1, provider)
            XCTAssertEqual(countEvent("prompt_write", in: events), 1, provider)
            XCTAssertEqual(countEvent("claim_published", in: events), 1, provider)
            XCTAssertEqual(countEvent("provider_acknowledged", in: events), 1, provider)
            XCTAssertTrue(events.contains(#""provider":"\#(provider)""#), provider)
            XCTAssertFalse(events.contains("Second request"), provider)
        }
    }

    func testDeliveryScopesPhantomManualRecordToEmbeddedProviderSession() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let providerSessionID = "embedded-\(provider)"
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-72\",\"relay_command_seq\":72}"
            try "Next ordered turn\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            try writeProviderTurnRecords([
                [
                    "state": "stale",
                    "provider": provider,
                    "provider_session_id": providerSessionID,
                    "session_id": "persisted-session",
                    "turn_id": "relay-turn",
                    "relay_command_seq": 71,
                    "relay_command_id": "cmd-71",
                    "release_reason": "stale_current_command",
                    "updated_at": 100.0,
                ],
                [
                    "state": "active",
                    "origin": "manual",
                    "provider": provider,
                    "provider_session_id": "orphaned-previous-session",
                    "session_id": "startup-identity",
                    "turn_id": "startup-turn",
                    "created_at": 99.0,
                    "updated_at": 99.0,
                ],
            ], to: fixture.providerTurns)
            var sent: [String] = []
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true },
                providerSessionID: providerSessionID
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Next ordered turn"], provider)
            XCTAssertEqual(scheduled.count, 1, provider)
            scheduled[0]()
            XCTAssertEqual(sent, ["Next ordered turn", "\r"], provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertFalse(events.contains(#""event":"safe_boundary_wait""#), provider)
            XCTAssertEqual(countEvent("claimed", in: events), 1, provider)
        }
    }

    func testDeliveryRequiresCurrentForegroundOwnershipEnvelope() throws {
        let expected = (
            providerSessionID: "provider-session",
            appSessionID: "app-session",
            recoveryGeneration: "generation-2",
            foregroundGateHandle: "gate-2"
        )
        let mismatches = [
            ("app_session_id", "previous-app"),
            ("recovery_generation", "generation-1"),
            ("actor_role", "messenger"),
            ("foreground_gate_handle", "gate-1"),
        ]

        for provider in ["codex", "claude"] {
            for (field, staleValue) in mismatches {
                let fixture = try makeFixture()
                let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-ownership\",\"relay_command_seq\":323}"
                try "Ownership isolated\n".write(to: fixture.command, atomically: true, encoding: .utf8)
                try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
                try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
                var record: [String: Any] = [
                    "state": "active",
                    "origin": "manual",
                    "provider": provider,
                    "provider_session_id": expected.providerSessionID,
                    "app_session_id": expected.appSessionID,
                    "recovery_generation": expected.recoveryGeneration,
                    "actor_role": "foreground_pm",
                    "foreground_gate_handle": expected.foregroundGateHandle,
                    "session_id": "native-session",
                    "turn_id": "competing-turn",
                ]
                record[field] = staleValue
                try writeProviderTurnRecords([record], to: fixture.providerTurns)
                var sent: [String] = []
                let delivery = RelayVoiceCommandDelivery(
                    paths: fixture.paths,
                    send: { sent.append(String(decoding: $0, as: UTF8.self)) },
                    schedule: { _, _, _ in },
                    isRunning: { true },
                    providerSessionID: expected.providerSessionID,
                    appSessionID: expected.appSessionID,
                    recoveryGeneration: expected.recoveryGeneration,
                    foregroundGateHandle: expected.foregroundGateHandle
                )

                XCTAssertTrue(delivery.claimAndSendIfPossible(), "\(provider) \(field)")
                XCTAssertEqual(sent, ["Ownership isolated"], "\(provider) \(field)")
            }

            let fixture = try makeFixture()
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-current\",\"relay_command_seq\":324}"
            try "Wait for current owner\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            try writeProviderTurnRecords([[
                "state": "active",
                "origin": "manual",
                "provider": provider,
                "provider_session_id": expected.providerSessionID,
                "app_session_id": expected.appSessionID,
                "recovery_generation": expected.recoveryGeneration,
                "actor_role": "foreground_pm",
                "foreground_gate_handle": expected.foregroundGateHandle,
                "session_id": "native-session",
                "turn_id": "current-turn",
            ]], to: fixture.providerTurns)
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { _ in XCTFail("matching foreground turn must hold delivery") },
                schedule: { _, _, _ in },
                isRunning: { true },
                providerSessionID: expected.providerSessionID,
                appSessionID: expected.appSessionID,
                recoveryGeneration: expected.recoveryGeneration,
                foregroundGateHandle: expected.foregroundGateHandle
            )
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
        }
    }

    func testGenuineScopedManualTurnBlocksUntilExactReleaseWithSafeDiagnostics() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let providerSessionID = "embedded-\(provider)"
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-82\",\"relay_command_seq\":82}"
            try "Queued after manual turn\n".write(
                to: fixture.command,
                atomically: true,
                encoding: .utf8
            )
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var currentTime = Date(timeIntervalSince1970: 101.0)
            try writeProviderTurnRecords([[
                "state": "active",
                "origin": "manual",
                "provider": provider,
                "provider_session_id": providerSessionID,
                "session_id": "native-session",
                "turn_id": "manual-turn",
                "created_at": 100.0,
                "updated_at": 100.0,
            ]], to: fixture.providerTurns)
            var sent: [String] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
                schedule: { _, _, _ in },
                isRunning: { true },
                now: { currentTime },
                providerSessionID: providerSessionID
            )

            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, [], provider)
            var events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertTrue(events.contains(#""provider_turn_origin":"manual""#), provider)
            XCTAssertTrue(events.contains(#""provider_native_session_id":"native-session""#), provider)
            XCTAssertTrue(events.contains(#""provider_native_turn_id":"manual-turn""#), provider)
            XCTAssertTrue(events.contains(#""provider_turn_age_ms":1000"#), provider)
            XCTAssertFalse(events.contains("Queued after manual turn"), provider)

            currentTime = Date(timeIntervalSince1970: 101.2)
            try writeProviderTurnRecords([[
                "state": "completed_manual",
                "origin": "manual",
                "provider": provider,
                "provider_session_id": providerSessionID,
                "session_id": "native-session",
                "turn_id": "manual-turn",
                "created_at": 100.0,
                "updated_at": 101.2,
                "release_reason": "provider_stop",
            ]], to: fixture.providerTurns)

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Queued after manual turn"], provider)
            events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertTrue(events.contains(#""provider_turn_release_reason":"provider_stop""#), provider)
            XCTAssertTrue(events.contains(#""event":"safe_boundary_verified""#), provider)
        }
    }

    func testIdentityReconciledStopReleasesNextCommandWithinPollingBoundary() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let providerSessionID = "embedded-\(provider)"
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-92\",\"relay_command_seq\":92}"
            try "Queued after reconciled stop\n".write(
                to: fixture.command,
                atomically: true,
                encoding: .utf8
            )
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var currentTime = Date(timeIntervalSince1970: 500.0)
            try writeProviderTurnRecords([[
                "state": "active",
                "provider": provider,
                "provider_session_id": providerSessionID,
                "session_id": "transient-session",
                "turn_id": "physical-turn",
                "relay_command_seq": 91,
                "relay_command_id": "cmd-91",
                "created_at": 499.0,
                "updated_at": 499.0,
            ]], to: fixture.providerTurns)
            var sent: [String] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
                schedule: { _, _, _ in },
                isRunning: { true },
                now: { currentTime },
                providerSessionID: providerSessionID
            )

            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            currentTime = Date(timeIntervalSince1970: 500.2)
            try writeProviderTurnRecords([[
                "state": "completed_final",
                "provider": provider,
                "provider_session_id": providerSessionID,
                "session_id": "transient-session",
                "turn_id": "physical-turn",
                "relay_command_seq": 91,
                "relay_command_id": "cmd-91",
                "created_at": 499.0,
                "updated_at": 500.2,
                "release_reason": "provider_stop_identity_reconciled",
                "completion_correlation": "provider_identity_reconciled",
                "completion_native_session_id": "persisted-session",
            ]], to: fixture.providerTurns)

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Queued after reconciled stop"], provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertTrue(events.contains(#""provider_turn_release_reason":"provider_stop_identity_reconciled""#), provider)
            XCTAssertTrue(events.contains(#""event":"safe_boundary_verified""#), provider)
        }
    }

    func testProviderTeardownReleasesOnlyItsScopedActiveRecord() throws {
        let fixture = try makeFixture()
        let ownership: [String: Any] = [
            "app_session_id": "app-session",
            "recovery_generation": "generation",
            "actor_role": "foreground_pm",
            "foreground_gate_handle": "gate",
        ]
        try writeProviderTurnRecords([
            ownership.merging([
                "state": "active",
                "provider_session_id": "current-session",
                "session_id": "native-current",
                "turn_id": "current-turn",
                "created_at": 100.0,
                "updated_at": 100.0,
            ]) { _, new in new },
            ownership.merging([
                "state": "active",
                "provider_session_id": "other-session",
                "session_id": "native-other",
                "turn_id": "other-turn",
                "created_at": 100.0,
                "updated_at": 100.0,
            ]) { _, new in new },
        ], to: fixture.providerTurns)
        XCTAssertEqual(Darwin.mkfifo(fixture.voiceInput.path, 0o600), 0)
        let reader = Darwin.open(fixture.voiceInput.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { Darwin.close(reader) }
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { _ in },
            isRunning: { false },
            now: { Date(timeIntervalSince1970: 101.0) },
            providerSessionID: "current-session",
            appSessionID: "app-session",
            recoveryGeneration: "generation",
            foregroundGateHandle: "gate"
        )

        delivery.providerProcessTerminated(releaseReason: "app_teardown")

        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(reader, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 0)
        let control = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
        XCTAssertTrue(control.hasPrefix("__PROVIDER_TURN_EVENT__:"))
        XCTAssertTrue(control.contains(#""event":"provider_terminated""#))
        XCTAssertFalse(control.contains("native-current"))

        let projectionData = try Data(contentsOf: fixture.providerTurns)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: projectionData) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [[String: Any]])
        XCTAssertEqual(records[0]["state"] as? String, "active")
        XCTAssertEqual(records[1]["state"] as? String, "active")
    }

    func testProviderOutputPublishesThrottledSafeProgressForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let ownership: [String: Any] = [
                "app_session_id": "app-session",
                "recovery_generation": "4",
                "actor_role": "foreground_pm",
                "foreground_gate_handle": "gate",
            ]
            try writeProviderTurnRecords([ownership.merging([
                "state": "active",
                "provider": provider,
                "provider_session_id": "provider-session",
                "relay_command_id": "private-command-id",
                "relay_command_seq": 7,
                "session_id": "private-native-session",
                "turn_id": "private-native-turn",
                "updated_at": 100.0,
            ]) { _, new in new }], to: fixture.providerTurns)
            XCTAssertEqual(Darwin.mkfifo(fixture.voiceInput.path, 0o600), 0)
            let reader = Darwin.open(fixture.voiceInput.path, O_RDONLY | O_NONBLOCK)
            XCTAssertGreaterThanOrEqual(reader, 0)
            defer { Darwin.close(reader) }
            var currentTime = Date(timeIntervalSince1970: 100)
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { _ in },
                isRunning: { true },
                now: { currentTime },
                providerSessionID: "provider-session",
                appSessionID: "app-session",
                recoveryGeneration: "4",
                foregroundGateHandle: "gate"
            )

            XCTAssertTrue(delivery.recordProviderOutputProgress(), provider)
            XCTAssertFalse(delivery.recordProviderOutputProgress(), provider)
            currentTime = Date(timeIntervalSince1970: 106)
            XCTAssertTrue(delivery.recordProviderOutputProgress(), provider)

            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(reader, &buffer, buffer.count)
            XCTAssertGreaterThan(count, 0)
            let control = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
            XCTAssertEqual(
                control.components(separatedBy: "__PROVIDER_TURN_EVENT__:").count - 1,
                2,
                provider
            )
            XCTAssertTrue(control.contains(#""event":"provider_progress""#), provider)
            XCTAssertTrue(control.contains(#""provider":"\#(provider)""#), provider)
            XCTAssertTrue(control.contains(#""relay_command_id":"private-command-id""#), provider)
            XCTAssertFalse(control.contains("private-native-session"), provider)
            XCTAssertFalse(control.contains("private-native-turn"), provider)
        }
    }

    func testStalledRecoveryRequiresExactRelayOwnedNonManualProviderTurn() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let commandID = ContinuityRecoveryRequest.opaqueIdentifier(
                kind: "command",
                nativeValue: "command-id"
            )
            let exact: [String: Any] = [
                "state": "active",
                "origin": "relay",
                "actor_role": "foreground_pm",
                "provider": provider,
                "provider_session_id": "provider-session",
                "app_session_id": "app-session",
                "recovery_generation": "generation-4",
                "foreground_gate_handle": "gate",
                "relay_command_id": "command-id",
                "updated_at": 100.0,
            ]
            try writeProviderTurnRecords([exact], to: fixture.providerTurns)

            XCTAssertTrue(ProcessManager.stalledForegroundProviderTurnOwned(
                commandID: commandID,
                provider: provider,
                recoveryGeneration: "generation-4",
                incidentObservedAt: 130,
                providerTurnsURL: fixture.providerTurns,
                providerSessionID: "provider-session",
                appSessionID: "app-session"
            ), provider)

            let rejected: [[String: Any]] = [
                exact.merging(["origin": "manual"]) { _, new in new },
                exact.merging(["actor_role": "foreground_manual"]) { _, new in new },
                exact.merging(["provider": provider == "codex" ? "claude" : "codex"]) {
                    _, new in new
                },
                exact.merging(["recovery_generation": "generation-5"]) { _, new in new },
                exact.merging(["app_session_id": "other-session"]) { _, new in new },
                exact.merging(["relay_command_id": "other-command"]) { _, new in new },
                exact.merging(["updated_at": 131.0]) { _, new in new },
            ]
            for record in rejected {
                try writeProviderTurnRecords([record], to: fixture.providerTurns)
                XCTAssertFalse(ProcessManager.stalledForegroundProviderTurnOwned(
                    commandID: commandID,
                    provider: provider,
                    recoveryGeneration: "generation-4",
                    incidentObservedAt: 130,
                    providerTurnsURL: fixture.providerTurns,
                    providerSessionID: "provider-session",
                    appSessionID: "app-session"
                ), provider)
            }
        }
    }

    func testInterruptBypassesActiveProviderTurnDeferral() throws {
        let fixture = try makeFixture()
        let metadata = #"{"relay_command_id":"cmd-3","relay_command_seq":3}"#
        try "__INTERRUPT__\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        try #"{"schema_version":2,"records":[{"relay_command_id":"cmd-1","relay_command_seq":1,"state":"active"}]}"#
            .write(to: fixture.providerTurns, atomically: true, encoding: .utf8)
        var sent: [[UInt8]] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { data in sent.append(Array(data)) },
            isRunning: { true }
        )

        XCTAssertTrue(delivery.claimAndSendIfPossible())

        XCTAssertEqual(sent, [[3]])
        XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path))
    }

    func testIdleInterruptIsAcknowledgedWithoutWritingTerminalInputForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-3\",\"relay_command_seq\":3}"
            try "__INTERRUPT__\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var sent: [[UInt8]] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(Array(data)) },
                isRunning: { true }
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)

            XCTAssertEqual(sent, [], provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)
            XCTAssertEqual(try String(contentsOf: fixture.consumerAcknowledgement), metadata, provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path), provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertEqual(countEvent("claimed", in: events), 1, provider)
            XCTAssertEqual(countEvent("claim_published", in: events), 1, provider)
            XCTAssertFalse(events.contains(#""event":"prompt_write""#), provider)
            XCTAssertTrue(events.contains(#""provider":"\#(provider)""#), provider)
        }
    }

    func testSuppressedReservedControlReleasesDurableLeaseForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-173\",\"relay_command_seq\":173,\"intent_id\":\"intent-173\"}"
            try "__TRACE__ {\"text\":\"malformed\"}\n".write(
                to: fixture.command,
                atomically: true,
                encoding: .utf8
            )
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var sent: [[UInt8]] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(Array(data)) },
                isRunning: { true }
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)

            XCTAssertEqual(sent, [], provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)
            XCTAssertEqual(
                try String(contentsOf: fixture.consumerAcknowledgement),
                metadata,
                provider
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path), provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertEqual(countEvent("superseded", in: events), 1, provider)
            XCTAssertEqual(countEvent("claim_published", in: events), 1, provider)
            XCTAssertTrue(events.contains(#""deferral_reason":"control""#), provider)
        }
    }

    func testAppOwnedInterruptPreemptionSendsOneControlCForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-3\",\"relay_command_seq\":3,\"preempt_provider\":true,\"work_disposition\":{\"route\":\"replace_current\"}}"
            try "__INTERRUPT__\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "active"),
            ], to: fixture.providerTurns)
            var sent: [[UInt8]] = []
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(Array(data)) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true }
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)

            XCTAssertEqual(sent, [[3]], provider)
            XCTAssertEqual(scheduled.count, 0, provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)
            XCTAssertEqual(
                try String(contentsOf: fixture.consumerAcknowledgement),
                metadata,
                provider
            )
        }
    }

    func testCompletedReplaceIntentInterruptsThenSubmitsForCodexAndClaude() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-3\",\"relay_command_seq\":3,\"preempt_provider\":true,\"work_disposition\":{\"route\":\"replace_current\"}}"
            try "Switch to the release task\n".write(
                to: fixture.command,
                atomically: true,
                encoding: .utf8
            )
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "active"),
            ], to: fixture.providerTurns)
            var sent: [[UInt8]] = []
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(Array(data)) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true }
            )

            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, [[3]], provider)
            XCTAssertEqual(scheduled.count, 0, provider)

            try writeProviderTurns([
                providerTurn(seq: 1, id: "cmd-1", provider: provider, state: "stale"),
            ], to: fixture.providerTurns)
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(scheduled.count, 1, provider)
            scheduled[0]()

            XCTAssertEqual(
                sent,
                [[3], Array("Switch to the release task".utf8), [13]],
                provider
            )
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)
        }
    }

    func testItemScopedReplacementDoesNotInterruptUnrelatedAcknowledgedWork() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-3\",\"relay_command_seq\":3,\"intent_id\":\"cancel-item\",\"preempt_provider\":false,\"provider_preempt_intent_ids\":[\"login-item\"],\"cancellation_scope\":\"item\",\"work_disposition\":{\"route\":\"replace_current\",\"cancellation_scope\":\"item\"}}"
            try "Cancel login\n".write(
                to: fixture.command,
                atomically: true,
                encoding: .utf8
            )
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            try writeProviderTurns([
                providerTurn(
                    seq: 1,
                    id: "cmd-1",
                    provider: provider,
                    state: "active",
                    intentID: "login-item",
                    updatedAt: 1
                ),
                providerTurn(
                    seq: 2,
                    id: "cmd-2",
                    provider: provider,
                    state: "active",
                    intentID: "search-item",
                    updatedAt: 2
                ),
            ], to: fixture.providerTurns)
            var sent: [[UInt8]] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(Array(data)) },
                isRunning: { true }
            )

            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, [], provider)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.command.path), provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.claimed.path), provider)
        }
    }

    func testRestartFaultMatrixEmitsEvidence() throws {
        let providers = ["codex", "claude"]
        let boundaries = [
            "accepted",
            "delivered",
            "claimed",
            "acknowledgement_delayed",
            "acknowledged",
            "terminal",
            "effect_reserved",
        ]
        var cases: [[String: Any]] = []

        for provider in providers {
            for boundary in boundaries {
                let fixture = try makeFixture()
                let commandID = "swift-\(provider)-\(boundary)"
                let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"\(commandID)\",\"relay_command_seq\":1}"
                try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
                if boundary == "accepted" || boundary == "delivered" {
                    try "Restart-safe prompt\n".write(
                        to: fixture.command,
                        atomically: true,
                        encoding: .utf8
                    )
                    try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
                } else {
                    try metadata.write(to: fixture.claimed, atomically: true, encoding: .utf8)
                    let state = boundary == "terminal" || boundary == "effect_reserved"
                        ? "completed_final"
                        : "active"
                    try writeProviderTurns([
                        providerTurn(
                            seq: 1,
                            id: commandID,
                            provider: provider,
                            state: state
                        ),
                    ], to: fixture.providerTurns)
                }

                var scheduled: [() -> Void] = []
                var sent: [String] = []
                let original = RelayVoiceCommandDelivery(
                    paths: fixture.paths,
                    send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
                    schedule: { _, _, work in scheduled.append(work) },
                    isRunning: { true }
                )
                let restarted = RelayVoiceCommandDelivery(
                    paths: fixture.paths,
                    send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
                    schedule: { _, _, work in scheduled.append(work) },
                    isRunning: { true }
                )

                XCTAssertFalse(original === restarted, "\(provider) \(boundary)")
                let shouldClaim = boundary == "accepted" || boundary == "delivered"
                XCTAssertEqual(
                    restarted.claimAndSendIfPossible(),
                    shouldClaim,
                    "\(provider) \(boundary)"
                )
                if shouldClaim {
                    XCTAssertEqual(sent, ["Restart-safe prompt"], "\(provider) \(boundary)")
                    XCTAssertEqual(scheduled.count, 1, "\(provider) \(boundary)")
                    scheduled[0]()
                    XCTAssertEqual(sent, ["Restart-safe prompt", "\r"], "\(provider) \(boundary)")
                } else {
                    XCTAssertEqual(sent, [], "\(provider) \(boundary)")
                }
                cases.append([
                    "provider": provider,
                    "lifecycle_boundary": boundary,
                    "instance_replaced": true,
                    "recovered": true,
                ])
            }
        }

        if let evidencePath = ProcessInfo.processInfo.environment["RR325_SWIFT_EVIDENCE_PATH"] {
            let evidence: [String: Any] = [
                "adapter": "RelayVoiceCommandDelivery",
                "providers": providers,
                "lifecycle_boundaries": boundaries,
                "case_count": cases.count,
                "passed": cases.allSatisfy { $0["recovered"] as? Bool == true },
                "cases": cases,
            ]
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
        }
    }

    func testInterruptPayloadUsesControlCWithoutPromptText() {
        XCTAssertEqual(
            RelayVoiceCommandDelivery.providerInputEvents(for: "Fix the bridge\n"),
            [Array("Fix the bridge".utf8), [13]]
        )
        XCTAssertEqual(RelayVoiceCommandDelivery.providerInputEvents(for: "__INTERRUPT__"), [[3]])
        XCTAssertNil(RelayVoiceCommandDelivery.providerInputEvents(for: "__BRIDGE_DIED__"))
    }

    private func makeFixture() throws -> (
        root: URL,
        command: URL,
        metadata: URL,
        claimed: URL,
        consumerAcknowledgement: URL,
        commandState: URL,
        providerTurns: URL,
        deliveryEvents: URL,
        actionJournal: URL,
        voiceInput: URL,
        heartbeat: URL,
        paths: RelayVoiceCommandDelivery.Paths
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayVoiceCommandDeliveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let command = root.appendingPathComponent("voice_cmd_ready")
        let metadata = root.appendingPathComponent("voice_cmd_ready.meta")
        let claimed = root.appendingPathComponent("voice_cmd_claimed.json")
        let consumerAcknowledgement = root.appendingPathComponent("voice_cmd_manual_ack.json")
        let commandState = root.appendingPathComponent("voice_command_state.json")
        let providerTurns = root.appendingPathComponent("voice_provider_turns.json")
        let deliveryEvents = root.appendingPathComponent("relay_terminal_delivery_events.jsonl")
        let actionJournal = root.appendingPathComponent("command-actions.jsonl")
        let voiceInput = root.appendingPathComponent("voice_in.fifo")
        let heartbeat = root.appendingPathComponent("voice_bridge_heartbeat")
        return (
            root: root,
            command: command,
            metadata: metadata,
            claimed: claimed,
            consumerAcknowledgement: consumerAcknowledgement,
            commandState: commandState,
            providerTurns: providerTurns,
            deliveryEvents: deliveryEvents,
            actionJournal: actionJournal,
            voiceInput: voiceInput,
            heartbeat: heartbeat,
            paths: RelayVoiceCommandDelivery.Paths(
                command: command.path,
                metadata: metadata.path,
                claimed: claimed.path,
                consumerAcknowledgement: consumerAcknowledgement.path,
                commandState: commandState.path,
                providerTurns: providerTurns.path,
                deliveryEvents: deliveryEvents.path,
                actionJournal: actionJournal.path,
                voiceInput: voiceInput.path,
                heartbeat: heartbeat.path
            )
        )
    }

    private func providerTurn(
        seq: Int,
        id: String,
        provider: String,
        state: String,
        intentID: String? = nil,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) -> [String: Any] {
        var record: [String: Any] = [
            "relay_command_seq": seq,
            "relay_command_id": id,
            "provider": provider,
            "state": state,
            "session_id": "session-\(provider)",
            "updated_at": updatedAt,
        ]
        if let intentID {
            record["intent_id"] = intentID
        }
        return record
    }

    private func writeProviderTurns(_ records: [[String: Any]], to url: URL) throws {
        try writeProviderTurnRecords(records, to: url)
    }

    private func writeProviderTurnRecords(_ records: [[String: Any]], to url: URL) throws {
        let payload: [String: Any] = [
            "schema_version": 2,
            "records": records,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func waitForDeliveryQueue() {
        let queued = expectation(description: "delivery queue updated")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            queued.fulfill()
        }
        wait(for: [queued], timeout: 1)
    }

    private func countEvent(_ event: String, in events: String) -> Int {
        events.components(separatedBy: "\"event\":\"\(event)\"").count - 1
    }
}

private final class TerminalInputOriginCapturingDelegate: TerminalViewDelegate {
    private weak var relayView: RelayTerminalView?
    private(set) var terminalResponseFlags: [Bool] = []
    private(set) var navigationShortcutFlags: [Bool] = []
    private(set) var payloads: [[UInt8]] = []

    init(view: RelayTerminalView) {
        relayView = view
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        terminalResponseFlags.append(relayView?.isSendingTerminalResponse == true)
        navigationShortcutFlags.append(relayView?.isSendingNavigationShortcut == true)
        payloads.append(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private func keyEvent(
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: keyCode
    )!
}

private final class FakeEmbeddedTerminalProcess: EmbeddedTerminalProcess {
    let view = NSView()
    var isRunning = false
    var hasFocus = false
    var childPID: Int? = 123
    var onExit: ((Int32?) -> Void)?
    var onReady: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var startError: Error?
    var autoReady = true
    var startCount = 0
    var terminateCount = 0

    func start(_ launch: ProcessManager.PreparedSessionLaunch) throws {
        startCount += 1
        if let startError { throw startError }
        isRunning = true
        if autoReady {
            onReady?()
        }
    }

    func focus() {
        hasFocus = true
    }

    func terminate() {
        terminateCount += 1
        isRunning = false
    }

    func emitExit(rawStatus: Int32?) {
        isRunning = false
        onExit?(rawStatus)
    }
}
