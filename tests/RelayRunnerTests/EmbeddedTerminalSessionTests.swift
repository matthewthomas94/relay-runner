import AppKit
import Darwin
import SwiftTerm
import XCTest
@testable import relay_runner

final class EmbeddedTerminalSessionTests: XCTestCase {
    func testBlockedNoticeIsOwnedByCurrentProcessAndRecoveryWaitsForExit() throws {
        let first = FakeEmbeddedTerminalProcess()
        let second = FakeEmbeddedTerminalProcess()
        var processes = [first, second]
        let session = EmbeddedTerminalSession(processFactory: { processes.removeFirst() })
        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())
        XCTAssertFalse(session.requestDeliveryRecovery())
        let staleNotice = first.onDeliveryBlocked
        let staleInboxNotice = first.onInboxRecoveryBlocked
        let blocker = InboxRecoveryBlocker(intent_id: "old", command_seq: 94, command_id: "old", recovered_at: 123)
        first.onInboxRecoveryBlocked?(blocker)
        first.onDeliveryBlocked?(true)
        let shown = expectation(description: "blocked notice shown")
        DispatchQueue.main.async { shown.fulfill() }
        wait(for: [shown], timeout: 1)
        XCTAssertTrue(session.deliveryBlocked)
        XCTAssertEqual(session.inboxRecoveryBlocker, blocker)
        session.skipUncertainMessage(blocker)
        XCTAssertEqual(first.skipped, [blocker])
        XCTAssertTrue(session.requestDeliveryRecovery())
        XCTAssertEqual(first.recoveryCount, 1)
        XCTAssertEqual(session.phase, .running, "A signal is not proof of process exit")
        XCTAssertEqual(second.startCount, 0)
        session.end()
        try session.beginPreparing(providerName: "Claude", workingDirectory: "/repo")
        try session.start(launch())
        staleNotice?(true)
        staleInboxNotice?(blocker)
        let drained = expectation(description: "stale notice ignored")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertFalse(session.deliveryBlocked)
        XCTAssertNil(session.inboxRecoveryBlocker)
        session.skipUncertainMessage(blocker)
        XCTAssertTrue(second.skipped.isEmpty)
    }
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

    func testLoaderStandsInUntilTheProviderInterfaceIsShownForBothProviders() throws {
        for provider in ["Codex", "Claude"] {
            let process = FakeEmbeddedTerminalProcess()
            process.autoReady = false
            let session = EmbeddedTerminalSession(processFactory: { process })
            XCTAssertNil(session.loadingStatus, provider)

            try session.beginPreparing(providerName: provider, workingDirectory: "/repo")
            XCTAssertEqual(session.loadingStatus, "Updating \(provider)")
            try session.start(launch())
            XCTAssertEqual(session.loadingStatus, "Starting \(provider)")

            process.onInteractive?()
            XCTAssertTrue(session.providerInterfaceShown, provider)
            XCTAssertEqual(session.phase, .starting, provider)
            XCTAssertNil(session.loadingStatus, "A first-run screen is never hidden")

            process.onReady?()
            XCTAssertEqual(session.phase, .running, provider)
            XCTAssertNil(session.loadingStatus, provider)

            // A restart shows the loader again until its own interface appears.
            session.end()
            try session.beginPreparing(providerName: provider, workingDirectory: "/repo")
            try session.start(launch())
            XCTAssertFalse(session.providerInterfaceShown, provider)
            XCTAssertEqual(session.loadingStatus, "Starting \(provider)")
            session.end()
        }
    }

    func testLoaderGivesWayToALaunchFailure() throws {
        let process = FakeEmbeddedTerminalProcess()
        process.autoReady = false
        let session = EmbeddedTerminalSession(processFactory: { process })
        try session.beginPreparing(providerName: "Claude", workingDirectory: "/repo")
        try session.start(launch())
        XCTAssertNotNil(session.loadingStatus)

        process.emitExit(rawStatus: 1 << 8)
        drainMainQueue()
        guard case .failed = session.phase else {
            return XCTFail("Exit before readiness is a failure, got \(session.phase)")
        }
        XCTAssertNil(session.loadingStatus, "The terminal output and failure stay visible")
        XCTAssertTrue(session.presentsTerminal)
    }

    func testClaudeFirstRunScreenEndsTheLoaderBeforeReadiness() throws {
        let fixture = try makeRealPTYFixture()
        // Only the spawn is recorded: Claude has not reached SessionStart.
        try "{\"stage\":\"provider_spawn\",\"outcome\":\"started\"}\n".write(
            to: fixture.events,
            atomically: true,
            encoding: .utf8
        )
        let process = SwiftTermEmbeddedProcess(
            readinessStabilityInterval: 0.2,
            readinessPollInterval: 0.02,
            voiceDeliveryPaths: deliveryPaths(in: fixture.directory)
        )
        let session = EmbeddedTerminalSession(processFactory: { process })
        try session.beginPreparing(
            providerName: "Claude",
            providerKey: "claude",
            workingDirectory: fixture.directory.path
        )
        try session.start(ProcessManager.PreparedSessionLaunch(
            executable: "/bin/bash",
            arguments: ["-c", """
                stty -icanon -echo
                printf 'Do you trust the files in this folder?\\r\\n'
                sleep 5
                """],
            launcherPath: "/bin/bash",
            workingDirectory: fixture.directory.path,
            target: .claude,
            voiceDelivery: .appOwned,
            sessionEventPath: fixture.events.path,
            providerSessionID: "first-run-screen"
        ))
        defer { session.end() }
        XCTAssertEqual(session.loadingStatus, "Starting Claude")

        waitOnMainQueue(0.8)
        XCTAssertTrue(session.providerInterfaceShown)
        XCTAssertNil(session.loadingStatus, "The trust screen is shown")
        XCTAssertEqual(session.phase, .starting, "Readiness still waits for SessionStart")

        let handle = try FileHandle(forWritingTo: fixture.events)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"stage\":\"provider_session_start\",\"outcome\":\"ready\"}\n".utf8))
        try handle.close()
        waitOnMainQueue(0.6)
        XCTAssertEqual(session.phase, .running)
    }

    func testLoginScreenIsVisibleWithoutStartingVoiceDeliveryForBothProviders() throws {
        for (provider, target) in [("Codex", ProcessManager.AgentTarget.codex), ("Claude", .claude)] {
            let fixture = try makeRealPTYFixture()
            try "{\"stage\":\"provider_login\",\"outcome\":\"started\"}\n".write(
                to: fixture.events, atomically: true, encoding: .utf8
            )
            var paths = deliveryPaths(in: fixture.directory)
            paths.manualSubmissions = fixture.directory.appendingPathComponent("manual-submissions").path
            try "queued voice command".write(toFile: paths.command, atomically: true, encoding: .utf8)
            let process = SwiftTermEmbeddedProcess(
                readinessStabilityInterval: 0.05, readinessPollInterval: 0.01,
                voiceDeliveryPaths: paths
            )
            let session = EmbeddedTerminalSession(processFactory: { process })
            try session.beginPreparing(providerName: provider, providerKey: provider.lowercased(), workingDirectory: fixture.directory.path)
            try session.start(ProcessManager.PreparedSessionLaunch(
                executable: "/bin/bash",
                arguments: ["-c", """
                    printf 'Sign in using your browser, or paste the code here:\\r\\n'
                    sleep 0.6
                    printf '%s\\n' '{"stage":"provider_spawn","outcome":"started"}' '{"stage":"provider_session_start","outcome":"ready"}' >> '\(fixture.events.path)'
                    stty -icanon -echo
                    printf 'Provider ready\\r\\n'
                    sleep 5
                    """],
                launcherPath: "/bin/bash", workingDirectory: fixture.directory.path,
                target: target, voiceDelivery: .appOwned,
                sessionEventPath: fixture.events.path, providerSessionID: "login-\(provider)",
                appSessionID: "login-app", recoveryGeneration: "login-generation",
                foregroundGateHandle: "login-gate"
            ))
            defer { session.end() }
            waitOnMainQueue(0.25)
            XCTAssertTrue(session.providerInterfaceShown, provider)
            XCTAssertNil(session.loadingStatus, "Login instructions remain visible in a canonical terminal")
            XCTAssertEqual(session.phase, .starting, "Login is not provider readiness")
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.command), "Voice must not enter the login prompt")
            process.send(source: process.terminalView, data: ArraySlice(Array("login-code\r".utf8)))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.manualSubmissions), "Login input is not a work turn")
            waitOnMainQueue(0.65)
            XCTAssertEqual(session.phase, .running, provider)
        }
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    private func waitOnMainQueue(_ seconds: TimeInterval) {
        let elapsed = expectation(description: "waited \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: seconds + 1)
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
        XCTAssertTrue(session.presentsTerminal)
        first.emitExit(rawStatus: 256)
        wait(for: [exited], timeout: 1)

        XCTAssertEqual(session.phase, .exited(1))
        XCTAssertFalse(session.presentsTerminal, "The tab returns to its empty state")

        try session.beginPreparing(providerName: "Claude", workingDirectory: "/other")
        try session.start(launch())

        XCTAssertEqual(session.phase, .running)
        XCTAssertEqual(second.startCount, 1)
        XCTAssertTrue(session.presentsTerminal)
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
        XCTAssertFalse(session.presentsTerminal, "The stale output gives way to the empty state")
    }

    func testEndKeepsPhysicalProcessOwnershipVisibleUntilDelayedTeardownCompletes() throws {
        let process = FakeEmbeddedTerminalProcess()
        process.terminateStopsImmediately = false
        let session = EmbeddedTerminalSession(processFactory: { process })
        try session.beginPreparing(providerName: "Codex", workingDirectory: "/repo")
        try session.start(launch())

        session.end()

        XCTAssertEqual(session.phase, .ended)
        XCTAssertFalse(session.isEmbeddedProcessRunning)
        XCTAssertTrue(session.hasLiveEmbeddedProcess)
        process.isRunning = false
        XCTAssertFalse(session.hasLiveEmbeddedProcess)
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

    func testAppOwnedPasteAndReturnExcludeConcurrentNativeFocusReportsForBothProviders() throws {
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            let fixture = try makeRealPTYFixture()
            var paths = deliveryPaths(in: fixture.directory)
            paths.manualSubmissions = fixture.directory.appendingPathComponent("manual-submissions").path
            let prompt = "Reply with exactly FOCUS_BOUNDARY_TEST"
            let provider = target == .codex ? "codex" : "claude"
            try "\(prompt)\n".write(toFile: paths.command, atomically: true, encoding: .utf8)
            let metadata = """
            {"provider":"\(provider)","relay_command_id":"focus-test","relay_command_seq":1}
            """
            try metadata.write(toFile: paths.metadata, atomically: true, encoding: .utf8)
            try metadata.write(toFile: paths.commandState, atomically: true, encoding: .utf8)
            let received = fixture.directory.appendingPathComponent("received")
            let process = SwiftTermEmbeddedProcess(
                readinessStabilityInterval: 0.2, readinessPollInterval: 0.01,
                voiceDeliveryPaths: paths
            )
            let session = EmbeddedTerminalSession(processFactory: { process })
            try session.beginPreparing(providerName: provider, workingDirectory: fixture.directory.path)
            try session.start(ProcessManager.PreparedSessionLaunch(
                executable: "/bin/bash", arguments: ["-c", """
                    stty raw -echo
                    printf '\\033[?1004h\\033[?2004hready\\r\\n'
                    /usr/bin/perl -e 'open(my $out, ">", "received") or die $!; binmode($out); while (sysread(STDIN, my $byte, 1)) { print $out $byte; last if ord($byte) == 13; } close($out);'
                    sleep 5
                    """], launcherPath: "/bin/bash", workingDirectory: fixture.directory.path,
                target: target, voiceDelivery: .appOwned, sessionEventPath: fixture.events.path,
                providerSessionID: "focus-\(provider)"
            ))
            defer { session.end() }
            process.send(source: process.terminalView, data: [])
            // Real SwiftTerm focus notifications, including DECSET's initial
            // report, race startup, the automatic paste, and its delayed Return.
            for index in 0..<100 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.005) {
                    process.terminalView.getTerminal().setTerminalFocus(index.isMultiple(of: 2))
                }
            }
            let receivedReturn = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in (try? Data(contentsOf: received))?.last == 13 },
                object: nil
            )
            wait(for: [receivedReturn], timeout: 4)
            XCTAssertEqual(session.phase, .running, provider)
            let bytes = Array(try Data(contentsOf: received))
            let framed = SwiftTermEmbeddedProcess.promptBytes(Array(prompt.utf8), bracketedPaste: true)
            let data = Data(bytes)
            let range = try XCTUnwrap(data.range(of: Data(framed)), provider)
            XCTAssertEqual(Array(data[range.upperBound...]), [13], provider)
            let prefix = Array(data[..<range.lowerBound])
            XCTAssertFalse(prefix.isEmpty, "Startup focus reporting resumes before the paste")
            XCTAssertEqual(prefix.count % 3, 0, provider)
            for offset in stride(from: 0, to: prefix.count, by: 3) {
                XCTAssertTrue(
                    Array(prefix[offset..<(offset + 3)]) == [27, 91, 73]
                        || Array(prefix[offset..<(offset + 3)]) == [27, 91, 79], provider
                )
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.claimed), provider)
        }
    }

    func testContinuationReturnReachesRealPTYInsidePermissionAndCancellationSendsNoReturn() throws {
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            for permitted in [true, false] {
                let fixture = try makeRealPTYFixture()
                let received = fixture.directory.appendingPathComponent("received")
                let process = SwiftTermEmbeddedProcess(
                    readinessStabilityInterval: 0.05, readinessPollInterval: 0.01,
                    voiceDeliveryPaths: deliveryPaths(in: fixture.directory)
                )
                let ready = expectation(description: "Real PTY ready")
                process.onReady = { ready.fulfill() }
                try process.start(ProcessManager.PreparedSessionLaunch(
                    executable: "/bin/bash", arguments: ["-c", """
                        stty raw -echo
                        printf 'ready\\r\\n'
                        /usr/bin/perl -e 'open(my $out, ">", "received") or die $!; binmode($out); select($out); $| = 1; while (sysread(STDIN, my $byte, 1)) { print $out $byte; last if ord($byte) == 13; } close($out);'
                        sleep 5
                        """], launcherPath: "/bin/bash", workingDirectory: fixture.directory.path,
                    target: target, voiceDelivery: .appOwned, sessionEventPath: fixture.events.path
                ))
                defer { process.terminate() }
                wait(for: [ready], timeout: 2)
                let flags = fcntl(process.localProcess.childfd, F_GETFL)
                XCTAssertGreaterThanOrEqual(flags, 0)
                XCTAssertNotEqual(flags & O_NONBLOCK, 0)
                process.send(source: process.terminalView, data: [])
                process.send(source: process.terminalView, data: [65])
                let completed = expectation(description: "Return write completed")
                var observedInsidePermission = false
                process.commitContextContinuationReturn({ write in
                    guard permitted else { return false }
                    write()
                    let deadline = Date().addingTimeInterval(1)
                    while Date() < deadline {
                        if (try? Data(contentsOf: received)) == Data([65, 13]) {
                            observedInsidePermission = true
                            break
                        }
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    return true
                }, completion: { written in
                    XCTAssertEqual(written, permitted)
                    completed.fulfill()
                })
                wait(for: [completed], timeout: 2)
                XCTAssertEqual(observedInsidePermission, permitted)
                let expected = Data(permitted ? [65, 13] : [65])
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline, (try? Data(contentsOf: received)) != expected {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                XCTAssertEqual(try Data(contentsOf: received), expected)
            }
        }
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
        // provider_session_start is Claude's SessionStart hook; Codex ignores it.
        try """
        {"stage":"provider_spawn","outcome":"started"}
        {"stage":"provider_session_start","outcome":"ready"}
        """.write(
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

    func testTrackerIgnoresTerminalNavigationSequences() {
        var tracker = RelayTerminalInputTracker()

        tracker.record(data: ArraySlice(Array("\u{1B}[D".utf8)))
        tracker.record(data: ArraySlice(Array("\u{1B}[D".utf8)))
        tracker.record(data: ArraySlice(Array("\u{1B}[D".utf8)))

        XCTAssertFalse(tracker.hasUnsubmittedInput)
        XCTAssertEqual(tracker.pendingByteCount, 0)
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

    func testTrackerTreatsWordDeletionAsAnEditInRawAndKittyModes() {
        for deleteWord in ["\u{1B}\u{7F}", "\u{17}", "\u{1B}[127;3u", "\u{1B}[119;5u"] {
            var tracker = RelayTerminalInputTracker()
            tracker.record(data: ArraySlice(Array("aaa bbb ".utf8)))

            XCTAssertEqual(tracker.record(data: ArraySlice(Array(deleteWord.utf8))), .draftChanged, deleteWord)
            XCTAssertEqual(tracker.pendingByteCount, 4, deleteWord)
            XCTAssertEqual(tracker.record(data: ArraySlice(Array(deleteWord.utf8))), .draftChanged, deleteWord)
            XCTAssertFalse(tracker.hasUnsubmittedInput, deleteWord)
        }
    }

    func testTrackerClearsTheDraftForDeleteToLineStartInRawAndKittyModes() {
        for deleteLine in ["\u{15}", "\u{1B}[117;5u", "\u{1B}[127;9u"] {
            var tracker = RelayTerminalInputTracker()
            tracker.record(data: ArraySlice(Array("aaa bbb".utf8)))

            XCTAssertEqual(
                tracker.record(data: ArraySlice(Array(deleteLine.utf8))),
                .cleared(pendingByteCount: 7),
                deleteLine
            )
            XCTAssertFalse(tracker.hasUnsubmittedInput, deleteLine)
        }
    }

    func testTrackerTreatsForwardWordDeletionAsAnEdit() {
        for deleteNextWord in ["\u{1B}d", "\u{1B}[3;3~", "\u{1B}[3~", "\u{1B}[100;3u"] {
            var tracker = RelayTerminalInputTracker()
            tracker.record(data: ArraySlice(Array("aaa".utf8)))

            XCTAssertEqual(tracker.record(data: ArraySlice(Array(deleteNextWord.utf8))), .draftChanged, deleteNextWord)
            XCTAssertTrue(tracker.hasUnsubmittedInput, deleteNextWord)
        }
    }

    func testTrackerIgnoresModifiedNavigationAndSelectionKeys() {
        let keys = [
            "\u{1B}b", "\u{1B}f", "\u{1B}x", "\u{01}", "\u{05}",
            "\u{1B}[1;3D", "\u{1B}[1;2D", "\u{1B}[1;4C", "\u{1B}[1;10D", "\u{1B}OD",
            "\u{1B}[97;5u", "\u{1B}[101;5u", "\u{1B}[98;3u", "\u{1B}[102;3u", "\u{1B}[99;9u",
        ]
        var tracker = RelayTerminalInputTracker()
        for key in keys {
            XCTAssertEqual(tracker.record(data: ArraySlice(Array(key.utf8))), .none, key.debugDescription)
        }
        XCTAssertFalse(tracker.hasUnsubmittedInput)

        tracker.record(data: ArraySlice(Array("aaa".utf8)))
        for key in keys {
            tracker.record(data: ArraySlice(Array(key.utf8)))
        }
        XCTAssertEqual(tracker.pendingByteCount, 3, "Moving or selecting does not edit the draft")
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

    func testNativeFocusReportsCoalesceOnlyInsideProtectedBoundaries() {
        let view = RelayTerminalView(frame: .zero)
        let delegate = TerminalInputOriginCapturingDelegate(view: view)
        view.terminalDelegate = delegate
        view.deferFocusReports(true)
        view.getTerminal().feed(text: "\u{1B}[?1004h")
        view.getTerminal().setTerminalFocus(false)
        view.getTerminal().setTerminalFocus(true)
        XCTAssertTrue(delegate.payloads.isEmpty)

        view.send(source: view.getTerminal(), data: ArraySlice([27, 91, 49, 59, 49, 82]))
        view.send(data: ArraySlice([27, 91, 73]))
        XCTAssertEqual(delegate.payloads, [[27, 91, 49, 59, 49, 82], [27, 91, 73]])
        XCTAssertEqual(delegate.terminalResponseFlags, [true, false], "Literal user input and other replies are preserved")
        view.deferFocusReports(false)
        view.getTerminal().setTerminalFocus(false)
        XCTAssertEqual(Array(delegate.payloads.suffix(2)), [[27, 91, 73], [27, 91, 79]])

        // A paste can defer again; only the latest actual focus is replayed
        // when Return or cancellation has completed its transport write.
        view.deferFocusReports(true)
        view.getTerminal().setTerminalFocus(true)
        view.getTerminal().setTerminalFocus(false)
        let beforeReturn = delegate.payloads.count
        view.send(data: ArraySlice([13]))
        XCTAssertEqual(delegate.payloads.count, beforeReturn + 1)
        view.deferFocusReports(false)
        XCTAssertEqual(Array(delegate.payloads.suffix(2)), [[13], [27, 91, 79]])
        view.getTerminal().setTerminalFocus(true)
        XCTAssertEqual(delegate.payloads.last, [27, 91, 73], "Normal focus reporting resumes")
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

    func testEditingKeysEncodeEveryTableKeyWithoutKeyboardProtocol() {
        for option in [leftOption, rightOption] {
            XCTAssertEqual(editingKey(123, option), .navigation([27, 98]))
            XCTAssertEqual(editingKey(124, option), .navigation([27, 102]))
            XCTAssertEqual(editingKey(51, option), .edit([27, 127]))
            XCTAssertEqual(editingKey(117, option.union(.function)), .edit([27, 100]))
            XCTAssertEqual(editingKey(123, option.union(.shift)), .navigation(bytes("\u{1B}[1;4D")))
            XCTAssertEqual(editingKey(124, option.union(.shift)), .navigation(bytes("\u{1B}[1;4C")))
        }
        XCTAssertEqual(editingKey(123, .command), .navigation([1]))
        XCTAssertEqual(editingKey(124, .command), .navigation([5]))
        XCTAssertEqual(editingKey(51, .command), .edit([21]))
        XCTAssertEqual(editingKey(123, .shift), .navigation(bytes("\u{1B}[1;2D")))
        XCTAssertEqual(editingKey(124, .shift), .navigation(bytes("\u{1B}[1;2C")))
        XCTAssertEqual(editingKey(123, [.shift, .command]), .navigation(bytes("\u{1B}[1;10D")))
        XCTAssertEqual(editingKey(124, [.shift, .command]), .navigation(bytes("\u{1B}[1;10C")))
        // Laptop arrows carry Fn and keypad flags; they do not change the key.
        XCTAssertEqual(editingKey(123, [.command, .function, .numericPad]), .navigation([1]))
    }

    func testEditingKeysUseKittyEncodingsWhenTheProtocolIsActive() {
        for option in [leftOption, rightOption] {
            XCTAssertEqual(editingKey(123, option, kitty: true), .navigation(bytes("\u{1B}[1;3D")))
            XCTAssertEqual(editingKey(124, option, kitty: true), .navigation(bytes("\u{1B}[1;3C")))
            XCTAssertEqual(editingKey(51, option, kitty: true), .edit(bytes("\u{1B}[127;3u")))
            XCTAssertEqual(editingKey(117, option.union(.function), kitty: true), .edit(bytes("\u{1B}[100;3u")))
            XCTAssertEqual(editingKey(123, option.union(.shift), kitty: true), .navigation(bytes("\u{1B}[1;4D")))
            XCTAssertEqual(editingKey(124, option.union(.shift), kitty: true), .navigation(bytes("\u{1B}[1;4C")))
        }
        XCTAssertEqual(editingKey(123, .command, kitty: true), .navigation(bytes("\u{1B}[97;5u")))
        XCTAssertEqual(editingKey(124, .command, kitty: true), .navigation(bytes("\u{1B}[101;5u")))
        XCTAssertEqual(editingKey(51, .command, kitty: true), .edit(bytes("\u{1B}[117;5u")))
        XCTAssertEqual(editingKey(123, .shift, kitty: true), .navigation(bytes("\u{1B}[1;2D")))
        XCTAssertEqual(editingKey(124, .shift, kitty: true), .navigation(bytes("\u{1B}[1;2C")))
        XCTAssertEqual(editingKey(123, [.shift, .command], kitty: true), .navigation(bytes("\u{1B}[1;10D")))
        XCTAssertEqual(editingKey(124, [.shift, .command], kitty: true), .navigation(bytes("\u{1B}[1;10C")))
    }

    func testShiftEditingKeysMoveWithoutSelectingWhenTheProviderIgnoresShiftArrows() {
        for kitty in [false, true] {
            XCTAssertEqual(editingKey(123, .shift, kitty: kitty, shiftSelects: false), .navigation(bytes("\u{1B}[D")))
            XCTAssertEqual(editingKey(124, .shift, kitty: kitty, shiftSelects: false), .navigation(bytes("\u{1B}[C")))
            XCTAssertEqual(
                editingKey(123, leftOption.union(.shift), kitty: kitty, shiftSelects: false),
                editingKey(123, leftOption, kitty: kitty)
            )
            XCTAssertEqual(
                editingKey(124, [.shift, .command], kitty: kitty, shiftSelects: false),
                editingKey(124, .command, kitty: kitty)
            )
        }
        XCTAssertEqual(
            RelayTerminalView.editingKey(
                keyCode: 123, modifierFlags: .shift, kitty: false,
                applicationCursor: true, sendsShiftSelectionKeys: false
            ),
            .navigation(bytes("\u{1B}OD"))
        )
    }

    func testEditingKeysLeaveOtherKeysToSwiftTerm() {
        for kitty in [false, true] {
            XCTAssertNil(editingKey(123, [], kitty: kitty), "Plain arrows")
            XCTAssertNil(editingKey(51, [], kitty: kitty), "Backspace")
            XCTAssertNil(editingKey(117, .function, kitty: kitty), "Fn-Delete")
            XCTAssertNil(editingKey(115, [], kitty: kitty), "Home")
            XCTAssertNil(editingKey(119, [], kitty: kitty), "End")
            XCTAssertNil(editingKey(115, .command, kitty: kitty), "Cmd-Home scrolls")
            XCTAssertNil(editingKey(116, .shift, kitty: kitty), "Shift-PageUp scrolls")
            XCTAssertNil(editingKey(123, .control, kitty: kitty))
            XCTAssertNil(editingKey(123, [.command, .option], kitty: kitty))
            XCTAssertNil(editingKey(125, leftOption, kitty: kitty))
            XCTAssertNil(editingKey(8, .command, kitty: kitty), "Cmd-C")
        }
    }

    func testEditingKeysFollowTheNegotiatedKeyboardProtocol() {
        let view = RelayTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = TerminalInputOriginCapturingDelegate(view: view)
        view.terminalDelegate = delegate

        view.feed(text: "\u{1B}[>7u")
        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(keyCode: 123, modifiers: .command)))
        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(keyCode: 51, modifiers: .command)))
        view.feed(text: "\u{1B}[<u")
        XCTAssertTrue(view.performKeyEquivalent(with: keyEvent(keyCode: 123, modifiers: .command)))

        XCTAssertEqual(delegate.payloads, [bytes("\u{1B}[97;5u"), bytes("\u{1B}[117;5u"), [1]])
        XCTAssertEqual(delegate.navigationShortcutFlags, [true, false, true], "Deletions reach the prompt tracker")
    }

    func testKeyCommandsMapGhosttyStyleShortcuts() {
        func command(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> RelayTerminalView.KeyCommand? {
            RelayTerminalView.keyCommand(keyCode: keyCode, charactersIgnoringModifiers: characters, modifierFlags: flags)
        }
        XCTAssertEqual(command(8, "c", .command), .copy)
        XCTAssertEqual(command(9, "v", .command), .paste)
        XCTAssertEqual(command(0, "a", .command), .selectAll)
        XCTAssertEqual(command(3, "f", .command), .find)
        XCTAssertEqual(command(5, "g", .command), .findNext)
        XCTAssertEqual(command(5, "G", [.command, .shift]), .findPrevious)
        XCTAssertEqual(command(40, "k", .command), .clearScrollback)
        XCTAssertEqual(command(24, "=", .command), .zoomIn)
        XCTAssertEqual(command(24, "+", [.command, .shift]), .zoomIn)
        XCTAssertEqual(command(27, "-", .command), .zoomOut)
        XCTAssertEqual(command(29, "0", .command), .zoomReset)
        XCTAssertEqual(command(116, "", .shift), .scrollPageUp)
        XCTAssertEqual(command(121, "", .shift), .scrollPageDown)
        XCTAssertEqual(command(115, "", .command), .scrollToTop)
        XCTAssertEqual(command(119, "", .command), .scrollToBottom)
        // Layout-aware: the character decides, not the physical key.
        XCTAssertEqual(command(47, "v", .command), .paste)
        // Plain keys, Ctrl and Option combinations stay with the provider.
        XCTAssertNil(command(8, "c", .control))
        XCTAssertNil(command(8, "c", []))
        XCTAssertNil(command(8, "c", [.command, .option]))
        XCTAssertNil(command(116, "", []))
        XCTAssertNil(command(17, "t", .command))
    }

    func testKeyCommandsDoNotWriteToTheProvider() {
        let view = RelayTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let delegate = TerminalInputOriginCapturingDelegate(view: view)
        view.terminalDelegate = delegate

        for command: RelayTerminalView.KeyCommand in [
            .selectAll, .copy, .clearScrollback, .zoomIn, .zoomOut, .zoomReset,
            .scrollPageUp, .scrollPageDown, .scrollToTop, .scrollToBottom,
        ] {
            view.perform(command)
        }

        XCTAssertEqual(delegate.payloads, [])
    }

    func testZoomStepsAndClampsFontSize() {
        XCTAssertEqual(RelayTerminalView.zoomedFontSize(from: 13, command: .zoomIn), 14)
        XCTAssertEqual(RelayTerminalView.zoomedFontSize(from: 13, command: .zoomOut), 12)
        XCTAssertEqual(RelayTerminalView.zoomedFontSize(from: 20, command: .zoomReset), 13)
        XCTAssertEqual(RelayTerminalView.zoomedFontSize(from: 24, command: .zoomIn), 24)
        XCTAssertEqual(RelayTerminalView.zoomedFontSize(from: 9, command: .zoomOut), 9)
        XCTAssertEqual(RelayTerminalView.zoomedFontSize(from: 15, command: .copy), 15)
    }

    func testOnlyLeftOptionActsAsMeta() {
        let option = NSEvent.ModifierFlags.option.rawValue
        XCTAssertTrue(RelayTerminalView.optionActsAsMeta(rawModifierFlags: option | 0x20))
        XCTAssertFalse(RelayTerminalView.optionActsAsMeta(rawModifierFlags: option | 0x40))
        XCTAssertTrue(RelayTerminalView.optionActsAsMeta(rawModifierFlags: option | 0x20 | 0x40))
        XCTAssertTrue(RelayTerminalView.optionActsAsMeta(rawModifierFlags: 0))
    }

    func testDroppedPathsAreShellEscapedAndBracketed() {
        XCTAssertEqual(
            RelayTerminalView.shellEscapedPath("/Users/me/My Files/a(1)&'b'.png"),
            "/Users/me/My\\ Files/a\\(1\\)\\&\\'b\\'.png"
        )
        XCTAssertEqual(
            RelayTerminalView.dropPayload(paths: ["/tmp/a b", "/tmp/c"], bracketedPaste: false),
            "/tmp/a\\ b /tmp/c "
        )
        XCTAssertEqual(
            RelayTerminalView.dropPayload(paths: ["/tmp/c"], bracketedPaste: true),
            "\u{1B}[200~/tmp/c \u{1B}[201~"
        )
    }

    func testOSC777AndOSC9Notifications() {
        func bytes(_ text: String) -> ArraySlice<UInt8> { ArraySlice(Array(text.utf8)) }
        typealias Attention = RelayTerminalAttention

        XCTAssertEqual(
            Attention.parseOSC777(bytes("notify;Build;Done; all green")),
            Attention.Notification(title: "Build", body: "Done; all green")
        )
        XCTAssertNil(Attention.parseOSC777(bytes("other;x;y")))
        XCTAssertNil(Attention.parseOSC777(bytes("notify;;")))

        XCTAssertEqual(
            Attention.parseOSC9(bytes("Tests finished")),
            .notification(Attention.Notification(title: "Relay session", body: "Tests finished"))
        )
        XCTAssertEqual(
            Attention.parseOSC9(bytes("4;1;42")),
            .progress(Terminal.ProgressReport(state: .set, progress: 42))
        )
        XCTAssertEqual(
            Attention.parseOSC9(bytes("4;0;")),
            .progress(Terminal.ProgressReport(state: .remove, progress: nil))
        )
        XCTAssertEqual(
            Attention.parseOSC9(bytes("4;1;250")),
            .progress(Terminal.ProgressReport(state: .set, progress: 100))
        )
        XCTAssertNil(Attention.parseOSC9(bytes("9;/tmp")))
        XCTAssertNil(Attention.parseOSC9(bytes("4;7;1")))
        XCTAssertNil(Attention.parseOSC9(bytes("")))
    }

    func testAttentionNotificationsAreRateLimited() {
        var limiter = RelayTerminalAttention.RateLimiter()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(limiter.allows(now: start))
        XCTAssertFalse(limiter.allows(now: start.addingTimeInterval(4)))
        XCTAssertTrue(limiter.allows(now: start.addingTimeInterval(5)))
    }

    func testProcessUsesLongScrollbackAndPanelBackground() {
        let process = SwiftTermEmbeddedProcess()
        XCTAssertEqual(process.terminalView.getTerminal().options.scrollback, RelayTerminalView.scrollbackLines)
        XCTAssertEqual(process.terminalView.nativeBackgroundColor, BoardDarkSurfaceStyle.panelFillNSColor)
    }
}

final class RelayVoiceCommandDeliveryTests: XCTestCase {
    func testPersistedInboxBlockerSurfacesBeforeSubmissionAndSkipUsesExactIdentity() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let blocker = InboxRecoveryBlocker(intent_id: "old:item:1", command_seq: 94, command_id: "old", recovered_at: 123)
            let encoded = try JSONEncoder().encode(blocker)
            let blockerObject = try JSONSerialization.jsonObject(with: encoded)
            let state: [String: Any] = ["inbox_recovery_blocker": blockerObject]
            try JSONSerialization.data(withJSONObject: state).write(to: fixture.commandState)
            try Data().write(to: fixture.voiceInput)
            var notices: [InboxRecoveryBlocker?] = []
            var sent: [String] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { sent.append(String(decoding: $0, as: UTF8.self)) },
                onInboxRecoveryBlocked: { notices.append($0) },
                isRunning: { true }, provider: provider
            )
            XCTAssertFalse(delivery.claimAndSendIfPossible())
            XCTAssertEqual(notices, [blocker])
            XCTAssertTrue(sent.isEmpty, "No terminal submission or automatic replay")
            XCTAssertTrue(delivery.skipUncertainMessage(blocker))
            let control = try String(contentsOf: fixture.voiceInput, encoding: .utf8)
            XCTAssertTrue(control.hasPrefix("__SKIP_UNCERTAIN__:"))
            let payload = String(control.dropFirst("__SKIP_UNCERTAIN__:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(try JSONDecoder().decode(InboxRecoveryBlocker.self, from: Data(payload.utf8)), blocker)
            XCTAssertEqual(notices, [blocker], "A successful write is not a recovery acknowledgement")
            try "{}".write(to: fixture.commandState, atomically: true, encoding: .utf8)
            XCTAssertFalse(delivery.skipUncertainMessage(blocker), "Reject stale confirmation after a late acknowledgement")
            XCTAssertFalse(delivery.claimAndSendIfPossible())
            XCTAssertEqual(notices.count, 2)
            XCTAssertNil(notices.last!)
        }
    }

    func testRecoveryDeadlineBlocksWithoutReplayAndExactLateAckReleasesQueuedCommand() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let first = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-94\",\"relay_command_seq\":94}"
            try "First message\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try first.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try first.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            var clock = Date()
            var scheduled: [() -> Void] = []
            var blocked: [Bool] = []
            var sent: [String] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { sent.append(String(decoding: $0, as: UTF8.self)) },
                recoveryTimeout: 10,
                onDeliveryBlocked: { blocked.append($0) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true }, now: { clock }
            )
            XCTAssertTrue(delivery.claimAndSendIfPossible())
            scheduled[0]()
            scheduled[1]()
            clock.addTimeInterval(10)
            scheduled[2]()
            XCTAssertTrue(delivery.isDeliveryBlocked)
            XCTAssertEqual(blocked, [true])
            XCTAssertEqual(scheduled.count, 3, "Recovery must stop scheduling endless polls")

            let second = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-95\",\"relay_command_seq\":95}"
            try "Second message\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try second.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try second.write(to: fixture.commandState, atomically: true, encoding: .utf8)
            try writeProviderTurns([providerTurn(seq: 93, id: "cmd-93", provider: provider, state: "completed_final")], to: fixture.providerTurns)
            XCTAssertFalse(delivery.claimAndSendIfPossible())
            XCTAssertTrue(delivery.isDeliveryBlocked)
            XCTAssertEqual(sent, ["First message", "\r"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.command.path))

            try writeProviderTurns([providerTurn(seq: 94, id: "cmd-94", provider: provider, state: "completed_final")], to: fixture.providerTurns)
            XCTAssertTrue(delivery.claimAndSendIfPossible())
            XCTAssertFalse(delivery.isDeliveryBlocked)
            XCTAssertEqual(blocked, [true, false])
            XCTAssertTrue(delivery.claimAndSendIfPossible())
            XCTAssertEqual(sent, ["First message", "\r", "Second message"])
        }
    }

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
            XCTAssertTrue(scheduled.isEmpty, "Return delay must not start while the prompt is still waiting on the main queue")
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

    func testManualReturnPublishesExactAppOwnedBoundaryForBothProviders() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { _ in },
                isRunning: { true },
                now: { Date(timeIntervalSince1970: 348) },
                providerSessionID: "embedded-\(provider)",
                provider: provider,
                appSessionID: "app-session",
                recoveryGeneration: "generation-348",
                foregroundGateHandle: "gate-348"
            )

            delivery.recordUserInput(ArraySlice(Array("private manual draft".utf8)))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.manualSubmissions.path),
                provider
            )
            delivery.recordUserInput(ArraySlice([13]))

            let data = try Data(contentsOf: fixture.manualSubmissions)
            let evidence = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            XCTAssertEqual(evidence["version"] as? Int, 1, provider)
            XCTAssertEqual(evidence["state"] as? String, "pending", provider)
            XCTAssertEqual(
                evidence["evidence_source"] as? String,
                "relay_terminal_manual_submit",
                provider
            )
            XCTAssertEqual(evidence["provider"] as? String, provider, provider)
            XCTAssertEqual(
                evidence["provider_session_id"] as? String,
                "embedded-\(provider)",
                provider
            )
            XCTAssertEqual(evidence["app_session_id"] as? String, "app-session", provider)
            XCTAssertEqual(
                evidence["recovery_generation"] as? String,
                "generation-348",
                provider
            )
            XCTAssertEqual(evidence["actor_role"] as? String, "foreground_pm", provider)
            XCTAssertEqual(
                evidence["foreground_gate_handle"] as? String,
                "gate-348",
                provider
            )
            XCTAssertNotNil(evidence["submission_id"] as? String, provider)
            XCTAssertEqual(evidence["observed_at"] as? Double, 348, provider)

            let stored = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(stored.contains("private manual draft"), provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertTrue(events.contains(#""event":"manual_submit_boundary_published""#), provider)
            XCTAssertTrue(events.contains(#""manual_submit_evidence_source":"relay_terminal_manual_submit""#), provider)
            XCTAssertFalse(events.contains("private manual draft"), provider)
        }
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
        XCTAssertTrue(delivery.claimAndSendIfPossible())
        XCTAssertEqual(sent, ["Do the queued work"])
        currentTime = Date(timeIntervalSince1970: 101)
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

    func testVoiceSteersAfterManualSubmissionForCodexAndClaude() throws {
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
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Queued voice work"], provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path), provider)

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

            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            XCTAssertLessThanOrEqual(currentTime.timeIntervalSince1970 - 100.1, 0.5, provider)
            XCTAssertEqual(scheduled.count, 1, provider)
            XCTAssertLessThan(scheduled[0].delay, 0.5, provider)
            scheduled[0].work()
            let expected = provider == "claude"
                ? ["Queued voice work", "\r", String(decoding: [24, 19], as: UTF8.self)]
                : ["Queued voice work", "\r"]
            XCTAssertEqual(sent, expected, provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)

            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertTrue(events.contains(#""event":"deferred_terminal_draft""#), provider)
            XCTAssertTrue(events.contains(#""event":"manual_submit_barrier_started""#), provider)
            XCTAssertTrue(events.contains(#""event":"safe_boundary_wait""#), provider)
            XCTAssertTrue(events.contains(#""event":"safe_boundary_verified""#), provider)
            XCTAssertTrue(events.contains(#""next_drain_decision":"claim_oldest_eligible""#), provider)
            XCTAssertTrue(events.contains(#""event":"provider_steering_requested""#), provider)
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

    func testAppOwnedVoiceSteersActiveTurnOnceForCodexAndClaude() throws {
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
                isRunning: { true },
                provider: provider
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Second request"], provider)
            XCTAssertEqual(scheduled.count, 1, provider)
            scheduled[0]()

            let expected = provider == "claude"
                ? ["Second request", "\r", String(decoding: [24, 19], as: UTF8.self)]
                : ["Second request", "\r"]
            XCTAssertEqual(sent, expected, provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), secondMetadata, provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.command.path), provider)

            try writeProviderTurns([
                providerTurn(seq: 2, id: "cmd-2", provider: provider, state: "active"),
            ], to: fixture.providerTurns)

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, expected, provider)

            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertEqual(countEvent("provider_steering_requested", in: events), 1, provider)
            XCTAssertFalse(events.contains(#""event":"safe_boundary_wait""#), provider)
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
            var sent: [String] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { sent.append(String(decoding: $0, as: UTF8.self)) },
                schedule: { _, _, _ in },
                isRunning: { true },
                providerSessionID: expected.providerSessionID,
                provider: provider,
                appSessionID: expected.appSessionID,
                recoveryGeneration: expected.recoveryGeneration,
                foregroundGateHandle: expected.foregroundGateHandle
            )
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Wait for current owner"], provider)
        }
    }

    func testGenuineScopedManualTurnAcceptsVoiceSteering() throws {
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
            let currentTime = Date(timeIntervalSince1970: 101.0)
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
                providerSessionID: providerSessionID,
                provider: provider
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Queued after manual turn"], provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertTrue(events.contains(#""event":"provider_steering_requested""#), provider)
            XCTAssertFalse(events.contains("Queued after manual turn"), provider)
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
            let currentTime = Date(timeIntervalSince1970: 500.2)
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
            var sent: [String] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(String(decoding: data, as: UTF8.self)) },
                schedule: { _, _, _ in },
                isRunning: { true },
                now: { currentTime },
                providerSessionID: providerSessionID
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, ["Queued after reconciled stop"], provider)
            let events = try String(contentsOf: fixture.deliveryEvents)
            XCTAssertFalse(events.contains(#""event":"provider_steering_requested""#), provider)
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
            var scheduled: [() -> Void] = []
            let delivery = RelayVoiceCommandDelivery(
                paths: fixture.paths,
                send: { data in sent.append(Array(data)) },
                schedule: { _, _, work in scheduled.append(work) },
                isRunning: { true },
                provider: provider
            )

            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent, [Array("Cancel login".utf8)], provider)
            XCTAssertEqual(scheduled.count, 1, provider)
            scheduled[0]()
            let expected = provider == "claude"
                ? [Array("Cancel login".utf8), [13], [24, 19]]
                : [Array("Cancel login".utf8), [13]]
            XCTAssertEqual(sent, expected, provider)
            XCTAssertFalse(sent.contains([3]), provider)
            XCTAssertEqual(try String(contentsOf: fixture.claimed), metadata, provider)
        }
    }

    func testInterruptedClaudeTurnWithoutStopHookReleasesOnceIdleForEachInterrupt() throws {
        let results = try runInterruptWithoutStopHook(provider: "claude")
        XCTAssertEqual(results.cancelledTurns, ["prompt-1", "prompt-2"])
        XCTAssertEqual(Set(results.eventIDs).count, 2)
        XCTAssertEqual(results.delivered, ["Next task 1", "Next task 2"])
    }

    func testInterruptedCodexTurnStillWaitsForItsStopHook() throws {
        let results = try runInterruptWithoutStopHook(provider: "codex")
        XCTAssertEqual(results.cancelledTurns, [])
        XCTAssertEqual(results.delivered, [])
    }

    /// Interrupts two active turns in one session. No Stop hook ever fires; the
    /// test plays the bridge by projecting a published cancellation.
    private func runInterruptWithoutStopHook(
        provider: String
    ) throws -> (cancelledTurns: [String], eventIDs: [String], delivered: [String]) {
        let fixture = try makeFixture()
        XCTAssertEqual(Darwin.mkfifo(fixture.voiceInput.path, 0o600), 0)
        let reader = Darwin.open(fixture.voiceInput.path, O_RDONLY | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { Darwin.close(reader) }
        var currentTime = Date(timeIntervalSince1970: 100)
        var sent: [String] = []
        var scheduled: [() -> Void] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { sent.append(String(decoding: $0, as: UTF8.self)) },
            schedule: { _, _, work in scheduled.append(work) },
            isRunning: { true },
            now: { currentTime },
            providerSessionID: "provider-session",
            provider: provider,
            appSessionID: "app-session",
            recoveryGeneration: "generation",
            foregroundGateHandle: "gate"
        )
        func turn(_ number: Int, state: String) -> [String: Any] {
            [
                "app_session_id": "app-session",
                "recovery_generation": "generation",
                "actor_role": "foreground_pm",
                "foreground_gate_handle": "gate",
                "provider": provider,
                "provider_session_id": "provider-session",
                "session_id": "native-session",
                "turn_id": "prompt-\(number)",
                "relay_command_seq": number * 10,
                "relay_command_id": "work-\(number)",
                "state": state,
                "updated_at": currentTime.timeIntervalSince1970,
            ]
        }
        func queue(_ text: String, seq: Int, extra: String = "") throws {
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-\(seq)\",\"relay_command_seq\":\(seq)\(extra)}"
            try "\(text)\n".write(to: fixture.command, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
            try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)
        }
        func drainCancellations() -> [[String: Any]] {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(reader, &buffer, buffer.count)
            let lines = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
                .split(separator: "\n")
            return lines.compactMap { line in
                guard line.hasPrefix("__PROVIDER_TURN_EVENT__:"),
                      let object = try? JSONSerialization.jsonObject(
                        with: Data(line.dropFirst("__PROVIDER_TURN_EVENT__:".count).utf8)
                      ) as? [String: Any],
                      object["event"] as? String == "provider_turn_cancelled" else { return nil }
                return object
            }
        }

        var cancelledTurns: [String] = []
        var eventIDs: [String] = []
        var delivered: [String] = []
        var projected: [[String: Any]] = []
        for number in 1...2 {
            projected.append(turn(number, state: "active"))
            try writeProviderTurnRecords(projected, to: fixture.providerTurns)
            try queue("__INTERRUPT__", seq: number * 10 + 1, extra: ",\"preempt_provider\":true")
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            XCTAssertEqual(sent.last, "\u{3}", provider)

            try queue("Next task \(number)", seq: number * 10 + 2)
            currentTime += 0.5
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            // The provider redraws its prompt after the interrupt.
            delivery.recordProviderOutputProgress()
            currentTime += 1.0
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            XCTAssertTrue(drainCancellations().isEmpty, provider)

            currentTime += 1.0
            XCTAssertFalse(delivery.claimAndSendIfPossible(), provider)
            let cancellations = drainCancellations()
            guard let cancellation = cancellations.first else { break }
            XCTAssertEqual(cancellations.count, 1, provider)
            XCTAssertEqual(cancellation["release_reason"] as? String, "provider_interrupted")
            XCTAssertEqual(cancellation["session_id"] as? String, "native-session")
            XCTAssertEqual(cancellation["provider_session_id"] as? String, "provider-session")
            cancelledTurns.append(cancellation["turn_id"] as? String ?? "")
            eventIDs.append(cancellation["event_id"] as? String ?? "")

            projected[projected.count - 1] = turn(number, state: "cancelled")
            try writeProviderTurnRecords(projected, to: fixture.providerTurns)
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
            scheduled.removeLast()()
            XCTAssertEqual(Array(sent.suffix(2)), ["Next task \(number)", "\r"], provider)
            delivered.append("Next task \(number)")

            // The delivered prompt's own turn acknowledges it and completes.
            var acknowledged = turn(number, state: "completed_final")
            acknowledged["turn_id"] = "prompt-\(number)-next"
            acknowledged["relay_command_seq"] = number * 10 + 2
            acknowledged["relay_command_id"] = "cmd-\(number * 10 + 2)"
            projected.append(acknowledged)
            try writeProviderTurnRecords(projected, to: fixture.providerTurns)
            XCTAssertTrue(delivery.claimAndSendIfPossible(), provider)
        }
        return (cancelledTurns, eventIDs, delivered)
    }

    func testHooklessClaudeManualSubmitReleasesVoiceDeliveryAfterTimeout() throws {
        for input in ["/model", "!ls"] {
            let results = try runHooklessManualSubmit(input, provider: "claude")
            XCTAssertEqual(results, [false, false, false, true], input)
        }
    }

    func testCodexManualSubmitBarrierStillWaitsForItsHookRecord() throws {
        let results = try runHooklessManualSubmit("/model", provider: "codex")
        XCTAssertEqual(results, [false, false, false, false])
    }

    /// Claims at 5s, 10s (timeout, but output 0.6s ago), 10.5s (still not
    /// quiet) and 11.1s (quiet) after a manual submit that never gets a hook.
    private func runHooklessManualSubmit(_ input: String, provider: String) throws -> [Bool] {
        let fixture = try makeFixture()
        var currentTime = Date(timeIntervalSince1970: 100)
        var sent: [String] = []
        let delivery = RelayVoiceCommandDelivery(
            paths: fixture.paths,
            send: { sent.append(String(decoding: $0, as: UTF8.self)) },
            schedule: { _, _, _ in },
            isRunning: { true },
            now: { currentTime },
            provider: provider
        )
        delivery.recordUserInput(ArraySlice(Array(input.utf8)))
        delivery.recordUserInput(ArraySlice([13]))
        let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-9\",\"relay_command_seq\":9}"
        try "Voice task\n".write(to: fixture.command, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.metadata, atomically: true, encoding: .utf8)
        try metadata.write(to: fixture.commandState, atomically: true, encoding: .utf8)

        var results: [Bool] = []
        for (offset, outputAt) in [(5.0, nil), (10.0, 9.4), (10.5, nil), (11.1, nil)] as [(Double, Double?)] {
            if let outputAt {
                currentTime = Date(timeIntervalSince1970: 100 + outputAt)
                delivery.recordProviderOutputProgress()
            }
            currentTime = Date(timeIntervalSince1970: 100 + offset)
            results.append(delivery.claimAndSendIfPossible())
        }
        XCTAssertEqual(sent == ["Voice task"], results.last == true, input)
        return results
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

    func testPromptPasteFramingKeepsMultilineTextSeparateFromReturn() {
        let bytes = Array("Reply exactly: Recovery test one.\n\nRelay disposition: continue_current".utf8)
        XCTAssertEqual(SwiftTermEmbeddedProcess.promptBytes(bytes, bracketedPaste: false), bytes)
        XCTAssertEqual(
            SwiftTermEmbeddedProcess.promptBytes(bytes, bracketedPaste: true),
            [27, 91, 50, 48, 48, 126] + bytes + [27, 91, 50, 48, 49, 126]
        )
        XCTAssertEqual(
            RelayVoiceCommandDelivery.providerInputEvents(for: String(decoding: bytes, as: UTF8.self))?.last,
            [13], "Submit is one separate Return, never part of the paste"
        )
    }

    func testSessionSpoolDeliveriesNeverClaimEachOthersCommandForBothProviders() throws {
        for provider in ["codex", "claude"] {
            let fixture = try makeFixture()
            let spoolA = VoiceSessionSpool(key: "session-a", rootDirectory: fixture.root.path)
            let spoolB = VoiceSessionSpool(key: "session-b", rootDirectory: fixture.root.path)
            try spoolA.prepare()
            try spoolB.prepare()
            let metadata = "{\"provider\":\"\(provider)\",\"relay_command_id\":\"cmd-a\",\"relay_command_seq\":7}"
            try "Only for A\n".write(toFile: spoolA.command, atomically: true, encoding: .utf8)
            try metadata.write(toFile: spoolA.metadata, atomically: true, encoding: .utf8)
            try metadata.write(toFile: spoolA.commandState, atomically: true, encoding: .utf8)
            var sentA: [String] = [], sentB: [String] = []
            var scheduled: [() -> Void] = []
            func delivery(_ spool: VoiceSessionSpool, _ sink: @escaping (String) -> Void) -> RelayVoiceCommandDelivery {
                RelayVoiceCommandDelivery(
                    paths: spool.deliveryPaths(sharing: fixture.paths),
                    send: { sink(String(decoding: $0, as: UTF8.self)) },
                    schedule: { _, _, work in scheduled.append(work) },
                    isRunning: { true }, provider: provider
                )
            }
            let deliveryA = delivery(spoolA) { sentA.append($0) }
            let deliveryB = delivery(spoolB) { sentB.append($0) }

            XCTAssertFalse(deliveryB.claimAndSendIfPossible(), provider)
            XCTAssertTrue(sentB.isEmpty, provider)
            XCTAssertTrue(FileManager.default.fileExists(atPath: spoolA.command), provider)
            XCTAssertTrue(deliveryA.claimAndSendIfPossible(), provider)
            scheduled.forEach { $0() }
            XCTAssertEqual(sentA, ["Only for A", "\r"], provider)
            XCTAssertTrue(sentB.isEmpty, provider)
            XCTAssertEqual(try String(contentsOfFile: spoolA.claimed), metadata, provider)
            XCTAssertFalse(FileManager.default.fileExists(atPath: spoolB.claimed), provider)
        }
    }

    private func makeFixture() throws -> (
        root: URL,
        command: URL,
        metadata: URL,
        claimed: URL,
        consumerAcknowledgement: URL,
        commandState: URL,
        providerTurns: URL,
        manualSubmissions: URL,
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
        let manualSubmissions = root.appendingPathComponent("relay_terminal_manual_submission.json")
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
            manualSubmissions: manualSubmissions,
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
                manualSubmissions: manualSubmissions.path,
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

/// RR-409 regression: AppKit editing keys travel the real window event path.
/// Before the fix SwiftTerm turned Shift-arrows, non-meta Option-Delete and
/// Cmd-Delete into `moveLeftAndModifySelection:`, `deleteWordBackward:` and
/// `deleteToBeginningOfLine:` and dropped them as "Unhandle selector", so the
/// hosted CLI received nothing.
final class RelayTerminalEditingKeyEventPathTests: XCTestCase {
    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private struct Key {
        let name: String
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let raw: [UInt8]
        let kitty: [UInt8]
    }

    func testEveryEditingKeyReachesTheHostedCLIExactlyOnce() throws {
        let app = NSApplication.shared
        let panel = KeyPanel(
            contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let host = EmbeddedTerminalHostNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        panel.contentView = host
        let view = RelayTerminalView(frame: host.bounds)
        let delegate = TerminalInputOriginCapturingDelegate(view: view)
        view.terminalDelegate = delegate
        host.install(view)
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        panel.makeFirstResponder(view)
        guard panel.isKeyWindow, panel.firstResponder === view else {
            throw XCTSkip("The test panel could not become the key window")
        }

        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        var keys: [Key] = []
        for (side, option) in [("left", leftOption), ("right", rightOption)] {
            keys += [
                Key(name: "\(side) Option-Left", keyCode: 123, modifiers: arrow.union(option),
                    raw: [27, 98], kitty: bytes("\u{1B}[1;3D")),
                Key(name: "\(side) Option-Right", keyCode: 124, modifiers: arrow.union(option),
                    raw: [27, 102], kitty: bytes("\u{1B}[1;3C")),
                Key(name: "\(side) Option-Delete", keyCode: 51, modifiers: option,
                    raw: [27, 127], kitty: bytes("\u{1B}[127;3u")),
                Key(name: "\(side) Fn-Option-Delete", keyCode: 117, modifiers: option.union(.function),
                    raw: [27, 100], kitty: bytes("\u{1B}[100;3u")),
                Key(name: "\(side) Shift-Option-Left", keyCode: 123, modifiers: arrow.union(option).union(.shift),
                    raw: bytes("\u{1B}[1;4D"), kitty: bytes("\u{1B}[1;4D")),
            ]
        }
        keys += [
            Key(name: "Cmd-Left", keyCode: 123, modifiers: arrow.union(.command),
                raw: [1], kitty: bytes("\u{1B}[97;5u")),
            Key(name: "Cmd-Right", keyCode: 124, modifiers: arrow.union(.command),
                raw: [5], kitty: bytes("\u{1B}[101;5u")),
            Key(name: "Cmd-Delete", keyCode: 51, modifiers: .command,
                raw: [21], kitty: bytes("\u{1B}[117;5u")),
            Key(name: "Shift-Left", keyCode: 123, modifiers: arrow.union(.shift),
                raw: bytes("\u{1B}[1;2D"), kitty: bytes("\u{1B}[1;2D")),
            Key(name: "Shift-Right", keyCode: 124, modifiers: arrow.union(.shift),
                raw: bytes("\u{1B}[1;2C"), kitty: bytes("\u{1B}[1;2C")),
            Key(name: "Shift-Cmd-Left", keyCode: 123, modifiers: arrow.union([.shift, .command]),
                raw: bytes("\u{1B}[1;10D"), kitty: bytes("\u{1B}[1;10D")),
        ]

        func press(_ key: Key) -> [[UInt8]] {
            let before = delegate.payloads.count
            let characters: String
            switch key.keyCode {
            case 123: characters = String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)
            case 124: characters = String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!)
            case 117: characters = String(UnicodeScalar(UInt16(NSDeleteFunctionKey))!)
            default: characters = "\u{7F}"
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: key.modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: key.keyCode
                )!
                app.postEvent(event, atStart: false)
                while let next = app.nextEvent(
                    matching: .any,
                    until: Date(timeIntervalSinceNow: 0.05),
                    inMode: .default,
                    dequeue: true
                ) {
                    app.sendEvent(next)
                }
            }
            return Array(delegate.payloads[before...])
        }

        for key in keys {
            XCTAssertEqual(press(key), [key.raw], "Raw \(key.name)")
        }
        // Kitty flags 7 include event-type reporting; a key the app encoded
        // must not leak a SwiftTerm release event for the swallowed press.
        view.feed(text: "\u{1B}[>7u")
        for key in keys {
            XCTAssertEqual(press(key), [key.kitty], "Kitty \(key.name)")
        }
        view.feed(text: "\u{1B}[<u")

        // Keys the app does not own still reach SwiftTerm unchanged.
        XCTAssertEqual(
            press(Key(name: "Backspace", keyCode: 51, modifiers: [], raw: [], kitty: [])),
            [[127]]
        )
        XCTAssertEqual(
            press(Key(name: "Fn-Delete", keyCode: 117, modifiers: .function, raw: [], kitty: [])),
            [bytes("\u{1B}[3~")]
        )
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

private let leftOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
private let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func editingKey(
    _ keyCode: UInt16,
    _ modifiers: NSEvent.ModifierFlags,
    kitty: Bool = false,
    shiftSelects: Bool = true
) -> RelayTerminalView.EditingKey? {
    RelayTerminalView.editingKey(
        keyCode: keyCode,
        modifierFlags: modifiers,
        kitty: kitty,
        sendsShiftSelectionKeys: shiftSelects
    )
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
    var onDeliveryBlocked: ((Bool) -> Void)?
    var onInboxRecoveryBlocked: ((InboxRecoveryBlocker?) -> Void)?
    var skipped: [InboxRecoveryBlocker] = []
    func skipUncertainMessage(_ blocker: InboxRecoveryBlocker) -> Bool {
        skipped.append(blocker)
        return true
    }
    var recoveryCount = 0
    func requestDeliveryRecovery() -> Bool {
        recoveryCount += 1
        return true
    }
    let view = NSView()
    var isRunning = false
    var hasFocus = false
    var childPID: Int? = 123
    var onExit: ((Int32?) -> Void)?
    var onReady: (() -> Void)?
    var onInteractive: (() -> Void)?
    var onTitle: ((String) -> Void)?
    var startError: Error?
    var autoReady = true
    var startCount = 0
    var terminateCount = 0
    var terminateStopsImmediately = true

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
        if terminateStopsImmediately {
            isRunning = false
        }
    }

    func emitExit(rawStatus: Int32?) {
        isRunning = false
        onExit?(rawStatus)
    }
}

final class EmbeddedSessionRegistryTests: XCTestCase {
    private var processes: [FakeEmbeddedTerminalProcess] = []

    private func makeRegistry() -> EmbeddedSessionRegistry {
        EmbeddedSessionRegistry(makeSession: { [unowned self] in
            EmbeddedTerminalSession(processFactory: {
                let process = FakeEmbeddedTerminalProcess()
                self.processes.append(process)
                return process
            })
        })
    }

    private func launch(_ registry: EmbeddedSessionRegistry, _ contextID: String, provider: String = "Codex") throws -> EmbeddedTerminalSession {
        guard case .start(let session) = registry.admit(contextID: contextID) else {
            XCTFail("\(contextID) was not admitted")
            throw CancellationError()
        }
        try session.beginPreparing(providerName: provider, workingDirectory: "/repo/\(contextID)")
        try session.start(ProcessManager.PreparedSessionLaunch(
            executable: "/bin/bash", arguments: [], launcherPath: "/tmp/launcher",
            workingDirectory: "/repo/\(contextID)", target: provider == "Codex" ? .codex : .claude,
            voiceDelivery: .appOwned
        ))
        return session
    }

    func testStartingOrFocusingAnotherContextNeverEndsTheFirst() throws {
        let registry = makeRegistry()
        let a = try launch(registry, "a")
        let b = try launch(registry, "b", provider: "Claude")
        XCTAssertEqual(registry.focusedContextID, "b")
        XCTAssertTrue(registry.focused === b)
        XCTAssertEqual(a.phase, .running)
        registry.focus(contextID: "a")
        XCTAssertTrue(registry.focused === a)
        XCTAssertEqual(b.phase, .running)
        XCTAssertEqual(registry.liveContextIDs, ["a", "b"])
        XCTAssertEqual(processes.map(\.terminateCount), [0, 0])
    }

    func testLiveContextIsFocusedInsteadOfStartedTwice() throws {
        let registry = makeRegistry()
        let a = try launch(registry, "a")
        _ = try launch(registry, "b")
        guard case .focusedExisting(let existing) = registry.admit(contextID: "a") else {
            return XCTFail("A live context must not start a second process")
        }
        XCTAssertTrue(existing === a)
        XCTAssertEqual(registry.focusedContextID, "a")
        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(processes[0].startCount, 1)
    }

    func testEndingOneContextStopsOnlyItsSessionAndSpool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rr-registry-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry()
        let a = try launch(registry, "a")
        let b = try launch(registry, "b")
        let spoolA = VoiceSessionSpool(key: "a", rootDirectory: root.path)
        let spoolB = VoiceSessionSpool(key: "b", rootDirectory: root.path)
        try spoolA.prepare(); try spoolB.prepare()
        registry.setSpool(spoolA, for: "a")
        registry.setSpool(spoolB, for: "b")

        registry.end(contextID: "a")
        XCTAssertEqual(a.phase, .ended)
        XCTAssertEqual(b.phase, .running)
        XCTAssertEqual(processes.map(\.terminateCount), [1, 0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: spoolA.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: spoolB.directory))
        XCTAssertEqual(registry.liveContextIDs, ["b"])
        XCTAssertTrue(registry.hasLiveSessions)
    }

    func testEndingTheVoiceTargetedContextCanRetainItsSpoolForTheBridge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rr-registry-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry()
        let a = try launch(registry, "a")
        let b = try launch(registry, "b", provider: "Claude")
        let spoolA = VoiceSessionSpool(key: "a", rootDirectory: root.path)
        let spoolB = VoiceSessionSpool(key: "b", rootDirectory: root.path)
        try spoolA.prepare(); try spoolB.prepare()
        registry.setSpool(spoolA, for: "a")
        registry.setSpool(spoolB, for: "b")

        let retained = registry.end(contextID: "a", retainingSpool: true)
        XCTAssertEqual(retained, spoolA)
        XCTAssertTrue(FileManager.default.fileExists(atPath: spoolA.directory),
                      "The bridge still publishes here until it is retargeted")
        XCTAssertEqual(a.phase, .ended)
        XCTAssertEqual(b.phase, .running)
        XCTAssertEqual(registry.liveContextIDs, ["b"])
        XCTAssertNil(registry.spool(for: "a"))
        XCTAssertEqual(registry.spool(for: "b"), spoolB, "The retarget destination")
        retained?.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spoolA.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: spoolB.directory))
    }

    func testExitAndReadyCallbacksCarryTheirOwnContext() throws {
        let registry = makeRegistry()
        var exits: [String] = [], readies: [String] = []
        let exited = expectation(description: "exit handled")
        registry.setHandlers(exit: { id, _ in exits.append(id); exited.fulfill() }, ready: { readies.append($0) })
        let a = try launch(registry, "a")
        let b = try launch(registry, "b")
        let drained = expectation(description: "ready drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(readies, ["a", "b"])

        processes[0].emitExit(rawStatus: 0)
        wait(for: [exited], timeout: 1)
        XCTAssertEqual(exits, ["a"])
        XCTAssertFalse(a.phase.isActive)
        XCTAssertEqual(b.phase, .running)
        XCTAssertEqual(registry.liveContextIDs, ["b"])
    }

    func testFifthConcurrentSessionIsRefusedWithTheCap() throws {
        let registry = makeRegistry()
        for id in ["a", "b", "c", "d"] { _ = try launch(registry, id) }
        guard case .refused(let message) = registry.admit(contextID: "e") else {
            return XCTFail("A fifth session must be refused")
        }
        XCTAssertTrue(message.contains("\(EmbeddedSessionRegistry.maxConcurrentSessions)"))
        XCTAssertEqual(EmbeddedSessionRegistry.maxConcurrentSessions, 4)
        XCTAssertEqual(registry.focusedContextID, "d", "A refusal changes nothing")
        XCTAssertNil(registry.sessions["e"])

        registry.end(contextID: "b")
        guard case .start = registry.admit(contextID: "e") else {
            return XCTFail("Ending a session frees a slot")
        }
    }

    func testShutdownAllEndsEverySessionAndSpool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rr-registry-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry()
        _ = try launch(registry, "a")
        _ = try launch(registry, "b")
        let spool = VoiceSessionSpool(key: "a", rootDirectory: root.path)
        try spool.prepare()
        registry.setSpool(spool, for: "a")
        registry.shutdownAll()
        XCTAssertEqual(processes.map(\.terminateCount), [1, 1])
        XCTAssertFalse(registry.hasLiveSessions)
        XCTAssertNil(registry.focusedContextID)
        XCTAssertTrue(registry.focused === registry.placeholder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.directory))
    }
}

final class VoiceSessionSpoolTests: XCTestCase {
    func testSpoolPathsAndEnvironmentArePerSession() {
        let spool = VoiceSessionSpool(key: "ABC-123/../x", rootDirectory: "/tmp/relay-sessions")
        XCTAssertEqual(spool.key, "abc-123x")
        XCTAssertEqual(spool.directory, "/tmp/relay-sessions/abc-123x")
        XCTAssertEqual(spool.command, "/tmp/relay-sessions/abc-123x/voice_cmd_ready")
        XCTAssertEqual(spool.claimed, "/tmp/relay-sessions/abc-123x/voice_cmd_claimed.json")
        XCTAssertEqual(spool.commandState, "/tmp/relay-sessions/abc-123x/voice_command_state.json")
        XCTAssertEqual(spool.launcher, "/tmp/relay-sessions/abc-123x/voice_bridge_launch.command")
        XCTAssertEqual(spool.authorizations, VoiceSessionSpool.sharedAuthorizationsPath)
        let environment = Dictionary(uniqueKeysWithValues: spool.environment.map { ($0.name, $0.value) })
        XCTAssertEqual(environment["RELAY_SESSION_KEY"], "abc-123x")
        XCTAssertEqual(environment["RELAY_SESSION_SPOOL_DIR"], spool.directory)
        XCTAssertEqual(environment["VOICE_COMMAND_CLAIM_FILE"], spool.claimed)
        XCTAssertEqual(Set(VoiceSessionSpool.environmentNames), Set(environment.keys))
        XCTAssertEqual(VoiceSessionSpool(key: "///").key, "session")

        let other = VoiceSessionSpool(key: "other")
        let a = spool.deliveryPaths(), b = other.deliveryPaths()
        XCTAssertNotEqual(a.command, b.command)
        XCTAssertNotEqual(a.claimed, b.claimed)
        XCTAssertNotEqual(a.commandState, b.commandState)
        XCTAssertEqual(a.voiceInput, b.voiceInput, "The voice FIFO stays shared")
        XCTAssertEqual(a.providerTurns, b.providerTurns)

        XCTAssertEqual(VoiceSessionSpool.legacy.command, "/tmp/voice_cmd_ready")
        XCTAssertEqual(VoiceSessionSpool.legacy.deliveryPaths(), RelayVoiceCommandDelivery.Paths())
    }

    func testBridgeTargetAcceptsOnlyADirectChildOfTheRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rr-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target").path
        func resolve(_ contents: String?) throws -> VoiceSessionSpool {
            if let contents { try contents.write(toFile: target, atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(atPath: target) }
            return VoiceSessionSpool.bridgeTarget(targetFile: target, rootDirectory: root.path)
        }
        XCTAssertEqual(try resolve(nil), .legacy)
        XCTAssertEqual(try resolve(root.appendingPathComponent("abc").path + "\n"),
                       VoiceSessionSpool(key: "abc", rootDirectory: root.path))
        XCTAssertEqual(try resolve("/tmp"), .legacy)
        XCTAssertEqual(try resolve(root.appendingPathComponent("a/b").path), .legacy)
        XCTAssertEqual(try resolve(root.appendingPathComponent("ABC").path), .legacy)
    }

    func testPrepareIsPrivateAndRemoveDeletesOnlyThatSpool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rr-spool-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let a = VoiceSessionSpool(key: "a", rootDirectory: root.path)
        let b = VoiceSessionSpool(key: "b", rootDirectory: root.path)
        try a.prepare(); try b.prepare()
        let mode = try FileManager.default.attributesOfItem(atPath: a.directory)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        a.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.directory))

        let planted = VoiceSessionSpool(key: "planted", rootDirectory: root.path)
        try FileManager.default.createSymbolicLink(atPath: planted.directory, withDestinationPath: b.directory)
        XCTAssertThrowsError(try planted.prepare())
    }
}
