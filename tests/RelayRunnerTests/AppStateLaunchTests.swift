import XCTest
@testable import relay_runner

final class AppStateLaunchTests: XCTestCase {
    func testInterruptedManagedBridgeOffersStartWithoutChangingRecoveredWork() throws {
        for provider in GeneralConfig.AgentProvider.allCases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-restart-header-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = AssistantSessionStore(directory: directory)
            let context = AssistantSessionContext(kind: .project, projectID: "confirmed", repositoryPath: "/confirmed/repo")
            let transport = UUID().uuidString.lowercased()
            try store.begin(context: context, provider: provider.rawValue, model: "fixture", transportSessionID: transport)
            try store.append(AssistantConversationEntry(id: "public-turn", contextID: context.id, role: .user,
                text: "Keep the completed request in history", createdAt: Date()))
            let sidecar = store.bindingURL(transportSessionID: transport)
            try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["context_id": context.id, "provider": provider.rawValue,
                "provider_session_id": transport, "working_directory": context.workingDirectory,
                "provider_pid": 90596, "provider_process_identity": "previous owned provider birth"])
                .write(to: sidecar)
            try store.reconcile(context: context, activeRunIDs: [79, 80], pendingIntentIDs: ["canonical-existing-intent"])
            try store.mark(.running, context: context)
            let documentURL = directory.appendingPathComponent("conversation-v1.json")
            let persisted = try Data(contentsOf: documentURL)

            let restored = AssistantSessionStore(directory: directory)
            let recovered = restored.document
            let binding = try XCTUnwrap(restored.binding(for: context))
            XCTAssertEqual(binding.lifecycle, .interrupted)
            XCTAssertNotNil(binding.managedProcess)
            let terminal = EmbeddedTerminalSession()
            XCTAssertEqual(terminal.phase, .idle)
            for state in [AssistantManagedProviderProcess.State.exited, .stale] {
                let active = AppState.voiceSessionIsActive(menuSessionActive: false, bridgeAlive: true,
                    bridgeMatchesContext: true, bridgeRecoveryInFlight: false, embeddedPhase: terminal.phase,
                    managedBinding: binding, managedProviderState: state, bridgeProviderSessionID: transport)
                XCTAssertFalse(active)
                XCTAssertEqual(ProgramSessionToolbarPresentation.resolve(hasActiveSession: active, provider: provider).title,
                    "Start \(provider.displayName)")
            }
            XCTAssertEqual(restored.document, recovered)
            XCTAssertEqual(restored.binding(for: context)?.activeRunIDs, [79, 80])
            XCTAssertEqual(restored.binding(for: context)?.pendingIntentIDs, ["canonical-existing-intent"])
            XCTAssertEqual(restored.history(for: context).map(\.text), ["Keep the completed request in history"])
            XCTAssertEqual(try Data(contentsOf: documentURL), persisted)
        }
    }

    func testRecoveryHeaderPreservesLiveExternalProvidersAndExplicitLaunches() {
        let binding = AssistantSessionStore.Binding(context: .general, provider: "codex", model: "sol",
            transportSessionID: "managed-transport", managedProcess: AssistantManagedProviderProcess(pid: 42, identity: "owned birth"),
            lifecycle: .interrupted, lastActivity: Date(), activeRunIDs: [79], pendingIntentIDs: [])
        func active(state: AssistantManagedProviderProcess.State? = .exited,
                    phase: EmbeddedTerminalSession.Phase = .idle, bridgeID: String? = "managed-transport",
                    menu: Bool = false, recovery: Bool = false, alive: Bool = true, matches: Bool = true,
                    managed: AssistantSessionStore.Binding? = nil) -> Bool {
            AppState.voiceSessionIsActive(menuSessionActive: menu, bridgeAlive: alive, bridgeMatchesContext: matches,
                bridgeRecoveryInFlight: recovery, embeddedPhase: phase, managedBinding: managed ?? binding,
                managedProviderState: state, bridgeProviderSessionID: bridgeID)
        }
        // A provider in an external Terminal can survive the app. An unknown
        // live identity and an unsampled owner must also be retained safely.
        XCTAssertTrue(active(state: .matching))
        XCTAssertTrue(active(state: .unknown))
        XCTAssertTrue(active(state: nil))
        XCTAssertTrue(active(bridgeID: "standalone-transport"))
        XCTAssertTrue(active(bridgeID: nil))
        for phase in [EmbeddedTerminalSession.Phase.preparing, .starting, .running, .external] {
            XCTAssertTrue(active(phase: phase))
        }
        XCTAssertTrue(active(menu: true, alive: false, matches: false))
        XCTAssertTrue(active(recovery: true, alive: false, matches: false))
        XCTAssertFalse(active(state: .matching, alive: false))
        XCTAssertFalse(active(state: .matching, matches: false))
        var unowned = binding
        unowned.managedProcess = nil
        XCTAssertTrue(active(state: nil, managed: unowned))
        XCTAssertTrue(AppState.voiceSessionIsActive(menuSessionActive: false, bridgeAlive: true,
            bridgeMatchesContext: true, bridgeRecoveryInFlight: false, embeddedPhase: .idle,
            managedBinding: nil, managedProviderState: nil, bridgeProviderSessionID: "standalone-transport"))
    }

    func testSessionHeaderUsesBackgroundManagedProviderOwnershipSample() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"), encoding: .utf8)
        let headerStart = try XCTUnwrap(source.range(of: "    var hasActiveSession: Bool {"))
        let policyStart = try XCTUnwrap(source.range(of: "    static func voiceSessionIsActive(", range: headerStart.upperBound..<source.endIndex))
        let header = source[headerStart.lowerBound..<policyStart.lowerBound]
        XCTAssertTrue(header.contains("Self.voiceSessionIsActive("))
        XCTAssertTrue(header.contains("$0.process == binding?.managedProcess"))
        XCTAssertTrue(header.contains("ProcessManager.currentProviderSessionID()"))
        XCTAssertFalse(header.contains(".state()"))
        let watchdogStart = try XCTUnwrap(source.range(of: "    private func refreshBridgeWatchdog()"))
        let detached = try XCTUnwrap(source.range(of: "Task.detached(priority: .utility)", range: watchdogStart.upperBound..<source.endIndex))
        let sample = try XCTUnwrap(source.range(of: "managedProvider.map { (process: $0, state: $0.state()) }", range: detached.upperBound..<source.endIndex))
        XCTAssertLessThan(detached.lowerBound, sample.lowerBound)
    }

    func testSessionScopeAuthorityChangesOnlyAfterDurableContextSelection() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/relay-runner/App/AppState.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "    func newSession("))
        let commit = try XCTUnwrap(source.range(of: "try assistantSessionStore.select(", range: start.upperBound..<source.endIndex))
        let publish = try XCTUnwrap(source.range(of: "activeSessionProjectScopeToken = projectScopeToken", range: commit.upperBound..<source.endIndex))
        let confirm = try XCTUnwrap(source.range(of: "projectScopeCoordinator.confirm(projectScopeToken)", range: publish.upperBound..<source.endIndex))
        // Pending selection and failed persistence return before changing
        // inherited mutation authority, even while a survivor still runs.
        XCTAssertFalse(source[start.lowerBound..<commit.lowerBound].contains("projectScopeCoordinator.confirm("))
        XCTAssertFalse(source[start.lowerBound..<commit.lowerBound].contains("projectScopeCoordinator.cancel("))
        XCTAssertFalse(source[start.lowerBound..<commit.lowerBound].contains("confirmProject(matching:"))
        XCTAssertTrue(source[start.lowerBound..<commit.lowerBound].contains("Self.prepareSessionContext(workingDirectory: workingDirectory, registry: projectRegistryV2)"))
        let resolution = try XCTUnwrap(source.range(of: "    static func prepareSessionContext("))
        let launch = try XCTUnwrap(source.range(of: "    static func sessionLaunchRequest(", range: resolution.upperBound..<source.endIndex))
        XCTAssertTrue(source[resolution.lowerBound..<launch.lowerBound].contains("scopeToken(matching: requestedProject)"))
        XCTAssertTrue(source[resolution.lowerBound..<launch.lowerBound].contains("validateScopeToken(token)"))
        XCTAssertFalse(source[resolution.lowerBound..<launch.lowerBound].contains("confirmProject("))
        XCTAssertFalse(source[resolution.lowerBound..<launch.lowerBound].contains("projectScopeCoordinator"))
        XCTAssertTrue(source[commit.lowerBound..<publish.lowerBound].contains("savingPreviousContext: true"))
        XCTAssertTrue(source[commit.lowerBound..<publish.lowerBound].contains("return false"))
        XCTAssertTrue(source[publish.lowerBound..<confirm.lowerBound].contains("if let projectScopeToken"))
        XCTAssertTrue(source[confirm.upperBound...].hasPrefix("\n        } else if context.isGeneral {\n            projectScopeCoordinator.cancel()"))
    }

    func testOnlyUnfinishedRepositoryObligationsProtectAssistantLifecycle() {
        let context = AssistantSessionContext(kind: .project, projectID: "one", repositoryPath: "/confirmed/repo")
        let states = ["Claimed", "Running", "Reviewing", "AwaitingReview", "Succeeded", "IntegrationBlocked", "MergeConflict", "VerificationBlocked", "Stalled", "Merged", "Failed", "Canceled", "SpikeCompleted"]
        var runs = states.enumerated().map { index, state in
            RunState(ticketId: "T-\(index)", repoPath: "/confirmed/repo", runId: index, state: state,
                     lastError: nil, activity: nil, activityAt: nil)
        }
        runs.append(RunState(ticketId: "other", repoPath: "/other/repo", runId: 99, state: "Running", lastError: nil, activity: nil, activityAt: nil))
        XCTAssertEqual(AppState.assistantRunIDs(for: context, runs: runs), Array(0...8))
        XCTAssertEqual(AppState.assistantRunIDs(for: .general, runs: runs), [])
    }

    func testColdProjectRegistrationWorkRunsOffMainThread() async throws {
        let result = await AppState.performProjectRegistrationWork {
            Thread.isMainThread
        }

        XCTAssertFalse(try result.get())
    }

    func testLaunchPlanStartsOverlayWithoutMicrophonePermission() {
        let plan = AppState.launchPlan(for: .denied)

        XCTAssertTrue(plan.startsOverlay)
        XCTAssertFalse(plan.startsAwareness)
        XCTAssertEqual(plan.statusText, "Microphone permission needed")
    }

    func testLaunchPlanStartsOverlayAndAwarenessWhenMicrophoneGranted() {
        let plan = AppState.launchPlan(for: .granted)

        XCTAssertTrue(plan.startsOverlay)
        XCTAssertTrue(plan.startsAwareness)
        XCTAssertNil(plan.statusText)
    }

    func testSessionLaunchConfigCanUseScopedWorkingDirectoryWithoutMutatingSavedConfig() {
        var config = AppConfig()
        config.general.working_directory = "/Users/example/dev"

        let scoped = AppState.sessionLaunchConfig(
            from: config,
            workingDirectory: " /Users/example/dev/brain-stack "
        )
        let global = AppState.sessionLaunchConfig(from: config, workingDirectory: nil)
        let blank = AppState.sessionLaunchConfig(from: config, workingDirectory: "   ")

        XCTAssertEqual(scoped.general.working_directory, "/Users/example/dev/brain-stack")
        XCTAssertEqual(global.general.working_directory, "/Users/example/dev")
        XCTAssertEqual(blank.general.working_directory, "/Users/example/dev")
        XCTAssertEqual(config.general.working_directory, "/Users/example/dev")
    }

    func testSessionLaunchRequestDefaultsToEmbeddedAndPreservesExternalFallback() {
        var config = AppConfig()
        config.general.working_directory = "/Users/example/dev"

        let embedded = AppState.sessionLaunchRequest(
            from: config,
            workingDirectory: "/Users/example/dev/project"
        )
        let external = AppState.sessionLaunchRequest(
            from: config,
            workingDirectory: nil,
            destination: .externalTerminal
        )

        XCTAssertEqual(embedded.destination, .embedded)
        XCTAssertEqual(embedded.config.general.working_directory, "/Users/example/dev/project")
        XCTAssertEqual(external.destination, .externalTerminal)
        XCTAssertEqual(external.config.general.working_directory, "/Users/example/dev")
        XCTAssertEqual(config.general.working_directory, "/Users/example/dev")
    }

    func testStoppingMeetingNoteSnapshotClearsTakingNotesWithoutLosingIdentity() {
        let project = MeetingNoteProjectBinding(
            repositoryPath: "/Users/example/dev/project",
            expectedProjectID: "project-1",
            provider: "codex"
        )
        let recording = MeetingNoteCoordinatorSnapshot(
            phase: .recording,
            noteID: "RR-N12",
            project: project,
            liveHypothesisCount: 3,
            durableSegmentCount: 7,
            syncState: "pending",
            errorMessage: "stale"
        )

        let stopping = AppState.stoppingMeetingNoteSnapshot(from: recording)

        XCTAssertEqual(stopping.phase, .stopping)
        XCTAssertEqual(stopping.noteID, "RR-N12")
        XCTAssertEqual(stopping.project, project)
        XCTAssertEqual(stopping.liveHypothesisCount, 3)
        XCTAssertEqual(stopping.durableSegmentCount, 7)
        XCTAssertEqual(stopping.syncState, "pending")
        XCTAssertNil(stopping.errorMessage)
        XCTAssertEqual(stopping.notchPresentation?.status, .working)
        XCTAssertEqual(stopping.notchPresentation?.label, "Saving notes")
    }

    func testOnboardingTutorialAcceptsOnlyItsIsolatedTTSState() {
        XCTAssertTrue(AppState.shouldHandleServiceEvent(
            source: "tts",
            tutorial: true,
            tutorialActive: true
        ))
        XCTAssertFalse(AppState.shouldHandleServiceEvent(
            source: "tts",
            tutorial: false,
            tutorialActive: true
        ))
        XCTAssertFalse(AppState.shouldHandleServiceEvent(
            source: "tts",
            tutorial: true,
            tutorialActive: false
        ))
        XCTAssertTrue(AppState.shouldHandleServiceEvent(
            source: "bridge",
            tutorial: false,
            tutorialActive: true
        ))
    }

    func testOnboardingNotchOverrideUsesGlyphOnlyWorkingPresentation() {
        let presentation = AppState.onboardingNotchPresentation(active: true)

        XCTAssertEqual(presentation?.status, .working)
        XCTAssertEqual(presentation?.activityLabels, [])
        XCTAssertNil(presentation?.workingProgressLabel)
        XCTAssertNil(AppState.onboardingNotchPresentation(active: false))
    }

    func testFirstRunExperienceLocksOrdinaryAppShell() {
        XCTAssertTrue(AppState.allowsAppShellAccess(firstRunExperienceActive: false))
        XCTAssertFalse(AppState.allowsAppShellAccess(firstRunExperienceActive: true))
        XCTAssertFalse(AppState.allowsAppShellAccess(
            firstRunExperienceActive: false,
            sharedOnboardingInProgress: true
        ))
    }

    func testFinalTutorialWorkspaceToggleIsConsumedBeforeOrdinaryWorkspaceRouting() {
        var events: [String] = []

        AppState.routeWorkspaceToggleRequest(
            consumeForTutorial: true,
            toggleWorkspace: { events.append("toggleWorkspace") },
            completeTutorial: { events.append("completeTutorial") }
        )

        XCTAssertEqual(events, ["completeTutorial"])
    }

    func testWorkspaceToggleOutsideTutorialPreservesOrdinaryRouting() {
        var events: [String] = []

        AppState.routeWorkspaceToggleRequest(
            consumeForTutorial: false,
            toggleWorkspace: { events.append("toggleWorkspace") },
            completeTutorial: { events.append("completeTutorial") }
        )

        XCTAssertEqual(events, ["toggleWorkspace"])
    }

    func testCompletedSetupOverridesStaleCompilingStatus() {
        let readiness = AppState.setupRuntimeReadiness(
            engineStatusMessage: "Compiling parakeet-tdt-v2...",
            engineError: nil,
            setupSucceeded: true,
            startedAt: nil
        )

        XCTAssertEqual(readiness, .ready)
        XCTAssertEqual(readiness.statusDetail, "Loaded and listening")
    }
}
