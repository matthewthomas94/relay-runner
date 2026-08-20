import XCTest
@testable import relay_runner

final class ContinuityRecoveryBoundaryTests: XCTestCase {
    private let sessionID = "session-1234567890abcdef12345678"
    private let commandID = "command-1234567890abcdef12345678"

    func testEveryAppOwnedComponentHasExecutableProductionAction() throws {
        let cases: [(
            capability: String,
            component: String,
            provider: String,
            phase: String,
            commandPhase: String,
            liveness: String,
            postcondition: String,
            action: AppState.ContinuityRecoveryComponentAction
        )] = [
            (
                "reinitialize_speech_capture", "speech_capture", "none", "capture",
                "before_command", "unhealthy", "capture_progress_observed", .restartSpeechCapture
            ),
            (
                "reinitialize_transcription_delivery", "transcription", "none", "transcription",
                "captured", "unhealthy", "transcription_completed", .restartTranscriptionDelivery
            ),
            (
                "restart_bridge", "bridge", "none", "delivery", "undelivered",
                "unhealthy", "bridge_process_alive", .recoverBridge
            ),
            (
                "restart_daemon", "daemon", "none", "component_liveness", "none",
                "confirmed_dead", "daemon_process_alive", .restartDaemon
            ),
            (
                "launch_foreground_provider", "foreground_provider", "codex", "provider_turn",
                "in_flight", "confirmed_dead", "provider_process_alive", .launchForegroundProvider
            ),
        ]

        for item in cases {
            let request = try makeRequest(
                capability: item.capability,
                component: item.component,
                provider: item.provider,
                incidentPhase: item.phase,
                commandPhase: item.commandPhase,
                liveness: item.liveness,
                postcondition: item.postcondition
            )
            XCTAssertEqual(
                AppState.continuityRecoveryDecision(
                    for: request,
                    boundary: boundary(),
                    nowMonotonic: 150,
                    nowEpoch: 1_050
                ),
                .apply(item.action),
                "Missing app production action for \(item.capability):\(item.component)"
            )
        }
    }

    func testExactAppOwnedBridgeRecoveryIsAllowed() throws {
        let request = try makeRequest()

        XCTAssertEqual(
            AppState.continuityRecoveryDecision(
                for: request,
                boundary: boundary(),
                nowMonotonic: 150,
                nowEpoch: 1_050
            ),
            .apply(.recoverBridge)
        )
    }

    func testExactAppOwnedDaemonReconnectUsesDaemonAction() throws {
        let request = try makeRequest(
            capability: "reconnect_ipc",
            component: "daemon",
            incidentPhase: "component_liveness",
            commandPhase: "none",
            liveness: "confirmed_dead",
            postcondition: "ipc_connection_restored"
        )

        XCTAssertEqual(
            AppState.continuityRecoveryDecision(
                for: request,
                boundary: boundary(),
                nowMonotonic: 150,
                nowEpoch: 1_050
            ),
            .apply(.restartDaemon)
        )
    }

    func testDeadForegroundOwnerReleaseDoesNotMapToBridgeRecovery() throws {
        let request = try makeRequest(
            capability: "release_dead_ownership",
            component: "foreground_provider",
            provider: "codex",
            incidentPhase: "provider_turn",
            commandPhase: "in_flight",
            liveness: "confirmed_dead",
            postcondition: "dead_ownership_released"
        )

        XCTAssertEqual(
            AppState.continuityRecoveryDecision(
                for: request,
                boundary: boundary(bridgeAlive: true),
                nowMonotonic: 150,
                nowEpoch: 1_050
            ),
            .apply(.releaseForegroundProviderOwnership)
        )
    }

    func testConfirmedDeadProviderAndSessionLaunchPreserveLiveBridgeForBothProviders() throws {
        let generation = "12345678-1234-4abc-8def-1234567890ab"
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            let provider = target.providerMetadataValue
            for component in ["foreground_provider", "session"] {
                let request = try makeRequest(
                    capability: "launch_foreground_provider",
                    component: component,
                    provider: provider,
                    incidentPhase: component == "session" ? "session_liveness" : "provider_turn",
                    commandPhase: component == "session" ? "none" : "in_flight",
                    liveness: "confirmed_dead",
                    postcondition: "provider_process_alive",
                    generation: generation
                )
                XCTAssertEqual(
                    AppState.continuityRecoveryDecision(
                        for: request,
                        boundary: boundary(
                            generation: generation,
                            provider: provider,
                            bridgeAlive: true
                        ),
                        nowMonotonic: 150,
                        nowEpoch: 1_050
                    ),
                    .apply(.launchForegroundProvider),
                    "\(provider):\(component)"
                )
            }

            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            let launcher = ProcessManager.launchScript(
                relayBridge: "/Relay Runner/scripts/relay-bridge",
                target: target,
                agentBinary: "/usr/local/bin/agent",
                config: config,
                voiceDelivery: .appOwned,
                appSessionID: "app-session",
                recoveryGeneration: generation,
                foregroundGateHandle: "foreground-gate",
                startsVoiceBridge: false
            )
            XCTAssertTrue(
                launcher.contains("export RELAY_RECOVERY_GENERATION='\(generation)'")
            )
            XCTAssertFalse(launcher.contains("--start-daemon"), provider)
            XCTAssertTrue(launcher.contains("Preserve the active Relay voice bridge"), provider)
        }
    }

    func testProviderAndSessionLaunchRejectStaleUnrelatedLiveAndRunningTargets() throws {
        for provider in ["codex", "claude"] {
            for component in ["foreground_provider", "session"] {
                let request = try makeRequest(
                    capability: "launch_foreground_provider",
                    component: component,
                    provider: provider,
                    incidentPhase: component == "session" ? "session_liveness" : "provider_turn",
                    commandPhase: component == "session" ? "none" : "in_flight",
                    liveness: "confirmed_dead",
                    postcondition: "provider_process_alive"
                )
                let label = "\(provider):\(component)"
                XCTAssertEqual(
                    AppState.continuityRecoveryDecision(
                        for: request,
                        boundary: boundary(generation: "generation-5", provider: provider),
                        nowMonotonic: 150,
                        nowEpoch: 1_050
                    ),
                    .reject("stale_recovery_generation"),
                    label
                )
                XCTAssertEqual(
                    AppState.continuityRecoveryDecision(
                        for: request,
                        boundary: boundary(
                            currentCommandID: "command-abcdefabcdefabcdefabcdef",
                            provider: provider
                        ),
                        nowMonotonic: 150,
                        nowEpoch: 1_050
                    ),
                    .reject("unrelated_command_target"),
                    label
                )
                XCTAssertEqual(
                    AppState.continuityRecoveryDecision(
                        for: request,
                        boundary: boundary(liveWorkActive: true, provider: provider),
                        nowMonotonic: 150,
                        nowEpoch: 1_050
                    ),
                    .reject("live_work_active"),
                    label
                )
                XCTAssertEqual(
                    AppState.continuityRecoveryDecision(
                        for: request,
                        boundary: boundary(provider: provider, providerProcessRunning: true),
                        nowMonotonic: 150,
                        nowEpoch: 1_050
                    ),
                    .reject("live_session_must_not_be_replaced"),
                    label
                )
            }
        }
    }

    func testStaleGenerationIsRejectedAtComponentBoundary() throws {
        let request = try makeRequest(generation: "generation-4")

        XCTAssertEqual(
            AppState.continuityRecoveryDecision(
                for: request,
                boundary: boundary(generation: "generation-5"),
                nowMonotonic: 150,
                nowEpoch: 1_050
            ),
            .reject("stale_recovery_generation")
        )
    }

    func testTamperedIncidentContextIsRejectedAtComponentBoundary() throws {
        let request = try makeRequest(idempotencyIncidentID: "inc-abcdefabcdef")

        XCTAssertEqual(
            AppState.continuityRecoveryDecision(
                for: request,
                boundary: boundary(),
                nowMonotonic: 150,
                nowEpoch: 1_050
            ),
            .reject("idempotency_context_mismatch")
        )
    }

    func testUnrelatedCommandIsRejectedAtComponentBoundary() throws {
        let request = try makeRequest()

        XCTAssertEqual(
            AppState.continuityRecoveryDecision(
                for: request,
                boundary: boundary(currentCommandID: "command-abcdefabcdefabcdefabcdef"),
                nowMonotonic: 150,
                nowEpoch: 1_050
            ),
            .reject("unrelated_command_target")
        )
    }

    func testDisruptiveRecoveryCannotCancelLiveWork() throws {
        let request = try makeRequest()

        XCTAssertEqual(
            AppState.continuityRecoveryDecision(
                for: request,
                boundary: boundary(liveWorkActive: true),
                nowMonotonic: 150,
                nowEpoch: 1_050
            ),
            .reject("live_work_active")
        )
    }

    func testBridgeAndDaemonOwnedReleaseMappingsFailClosedInApp() throws {
        for component in ["session", "orchestrator", "command"] {
            let request = try makeRequest(
                capability: "release_dead_ownership",
                component: component,
                incidentPhase: component == "command"
                    ? "command_processing"
                    : "session_liveness",
                commandPhase: component == "command" ? "in_flight" : "none",
                liveness: "confirmed_dead",
                postcondition: "dead_ownership_released"
            )

            XCTAssertEqual(
                AppState.continuityRecoveryDecision(
                    for: request,
                    boundary: boundary(),
                    nowMonotonic: 150,
                    nowEpoch: 1_050
                ),
                .reject("unsupported_component_action")
            )
        }
    }

    func testSocketEnvelopePreservesValidatedExecutionContext() throws {
        let request = try makeRequest()

        XCTAssertEqual(request.incidentID, "inc-123456789abc")
        XCTAssertEqual(request.sessionID, sessionID)
        XCTAssertEqual(request.commandID, commandID)
        XCTAssertEqual(request.recoveryGeneration, "generation-4")
        XCTAssertEqual(request.incidentPhase, "delivery")
        XCTAssertEqual(request.attempt, 1)
        XCTAssertEqual(
            request.idempotencyKey,
            ContinuityRecoveryRequest.idempotencyKey(
                incidentID: request.incidentID,
                recoveryGeneration: request.recoveryGeneration,
                capability: request.capability,
                component: request.component,
                sessionID: request.sessionID,
                commandID: request.commandID
            )
        )
        XCTAssertEqual(request.cooldownRemaining, 0)
        XCTAssertTrue(request.exactTargetOwned)
        XCTAssertTrue(request.generationMatches)
    }

    func testPreparedSessionLaunchUUIDGenerationAllowsOnlyCurrentExecution() throws {
        let current = "12345678-1234-4abc-8def-1234567890ab"
        let stale = "abcdefab-1234-4abc-8def-1234567890ab"
        for target in [ProcessManager.AgentTarget.codex, .claude] {
            let launch = ProcessManager.PreparedSessionLaunch(
                executable: "/bin/bash",
                arguments: ["/tmp/voice_bridge_launch.command"],
                launcherPath: "/tmp/voice_bridge_launch.command",
                workingDirectory: "/tmp",
                target: target,
                voiceDelivery: .appOwned,
                recoveryGeneration: current
            )
            var config = AppConfig()
            config.general.provider = target == .codex ? .codex : .claude
            let launcher = ProcessManager.launchScript(
                relayBridge: "/Relay Runner/scripts/relay-bridge",
                target: target,
                agentBinary: "/usr/local/bin/agent",
                config: config,
                voiceDelivery: .appOwned,
                appSessionID: "app-session",
                recoveryGeneration: try XCTUnwrap(launch.recoveryGeneration),
                foregroundGateHandle: "foreground-gate"
            )
            XCTAssertTrue(launcher.contains(
                "export RELAY_RECOVERY_GENERATION='\(current)'"
            ))

            let bridgeState = ["recovery_generation": try XCTUnwrap(launch.recoveryGeneration)]
            let request = try makeRequest(
                generation: try XCTUnwrap(bridgeState["recovery_generation"])
            )

            XCTAssertEqual(
                AppState.continuityRecoveryDecision(
                    for: request,
                    boundary: boundary(generation: current),
                    nowMonotonic: 150,
                    nowEpoch: 1_050
                ),
                .apply(.recoverBridge),
                target.providerMetadataValue
            )
            XCTAssertEqual(
                AppState.continuityRecoveryDecision(
                    for: request,
                    boundary: boundary(generation: stale),
                    nowMonotonic: 150,
                    nowEpoch: 1_050
                ),
                .reject("stale_recovery_generation"),
                target.providerMetadataValue
            )
        }
    }

    func testSocketEnvelopeRejectsLossyNumericGeneration() throws {
        var payload = requestPayload(generation: "generation-4")
        payload["recovery_generation"] = 4
        XCTAssertNil(ContinuityRecoveryRequest(payload))
    }

    func testProjectSessionIdentityMatchesDaemonContract() {
        XCTAssertEqual(
            ContinuityRecoveryRequest.projectSessionIdentifier(
                repositoryPath: "/tmp"
            ),
            "session-7d69f3a8b8e392d95b388e4d"
        )
    }

    private func makeRequest(
        capability: String = "restart_bridge",
        component: String = "bridge",
        provider: String = "none",
        incidentPhase: String = "delivery",
        commandPhase: String = "undelivered",
        liveness: String = "unhealthy",
        postcondition: String = "bridge_process_alive",
        generation: String = "generation-4",
        idempotencyIncidentID: String? = nil
    ) throws -> ContinuityRecoveryRequest {
        let idempotencyKey = ContinuityRecoveryRequest.idempotencyKey(
            incidentID: idempotencyIncidentID ?? "inc-123456789abc",
            recoveryGeneration: generation,
            capability: capability,
            component: component,
            sessionID: sessionID,
            commandID: commandID
        )
        return try XCTUnwrap(ContinuityRecoveryRequest(requestPayload(
            capability: capability,
            component: component,
            provider: provider,
            incidentPhase: incidentPhase,
            commandPhase: commandPhase,
            liveness: liveness,
            postcondition: postcondition,
            generation: generation,
            idempotencyKey: idempotencyKey
        )))
    }

    private func requestPayload(
        capability: String = "restart_bridge",
        component: String = "bridge",
        provider: String = "none",
        incidentPhase: String = "delivery",
        commandPhase: String = "undelivered",
        liveness: String = "unhealthy",
        postcondition: String = "bridge_process_alive",
        generation: String = "generation-4",
        idempotencyKey: String? = nil
    ) -> [String: Any] {
        [
            "capability": capability,
            "incident_id": "inc-123456789abc",
            "session_id": sessionID,
            "command_id": commandID,
            "component": component,
            "provider": provider,
            "recovery_generation": generation,
            "incident_phase": incidentPhase,
            "process_identity": "continuity-1234567890abcdef1234567890abcdef",
            "attempt": 1,
            "idempotency_key": idempotencyKey ?? ContinuityRecoveryRequest.idempotencyKey(
                incidentID: "inc-123456789abc",
                recoveryGeneration: generation,
                capability: capability,
                component: component,
                sessionID: sessionID,
                commandID: commandID
            ),
            "expected_postcondition": postcondition,
            "incident_observed_at": 1_000.0,
            "deadline": 200.0,
            "validation_token": "live_continuity_watch",
            "exact_target_owned": true,
            "liveness": liveness,
            "incident_active": true,
            "generation_matches": true,
            "command_phase": commandPhase,
            "command_phase_matches": true,
            "idempotency_state": "new",
            "compensation_available": false,
            "cooldown_remaining": 0.0,
        ]
    }

    private func boundary(
        generation: String = "generation-4",
        currentCommandID: String? = nil,
        liveWorkActive: Bool = false,
        provider: String = "codex",
        providerProcessRunning: Bool = false,
        bridgeAlive: Bool = false
    ) -> AppState.ContinuityRecoveryBoundary {
        AppState.ContinuityRecoveryBoundary(
            currentSessionID: sessionID,
            currentRecoveryGeneration: generation,
            currentCommandID: currentCommandID ?? commandID,
            provider: provider,
            liveWorkActive: liveWorkActive,
            providerProcessRunning: providerProcessRunning,
            bridgeAlive: bridgeAlive,
            idempotencyAlreadyApplied: false,
            cooldownActive: false
        )
    }
}
