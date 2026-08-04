import XCTest
@testable import relay_runner

final class OrchestratorClientTests: XCTestCase {
    func testDispatchRequestUsesRunsEndpointForReadyTransition() throws {
        let request = try XCTUnwrap(OrchestratorClient.dispatchRequest(
            ticketId: "RR-1",
            repoPath: "/repo",
            source: "board-drop",
            port: 8123
        ))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8123/v1/runs")
        let body = try jsonBody(request)
        XCTAssertEqual(body["ticket_id"] as? String, "RR-1")
        XCTAssertEqual(body["repo_path"] as? String, "/repo")
        XCTAssertEqual(body["source"] as? String, "board-drop")
    }

    func testReadySweepRequestUsesSweepEndpoint() throws {
        let request = try XCTUnwrap(OrchestratorClient.readySweepRequest(
            repoPath: "/repo",
            trigger: "bridge-watchdog",
            port: 8123
        ))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8123/v1/ready-sweep")
        let body = try jsonBody(request)
        XCTAssertEqual(body["repo_path"] as? String, "/repo")
        XCTAssertEqual(body["trigger"] as? String, "bridge-watchdog")
    }

    func testReadySweepRequestCarriesConfirmedProjectScope() throws {
        let request = try XCTUnwrap(OrchestratorClient.readySweepRequest(
            repoPath: "/repo",
            trigger: "board-drop",
            port: 8123,
            projectScopeToken: "confirmed-scope"
        ))

        let body = try jsonBody(request)
        XCTAssertEqual(body["project_scope_token"] as? String, "confirmed-scope")
    }

    func testProgramReadySweepRequestUsesProgramSweepEndpoint() throws {
        let request = try XCTUnwrap(OrchestratorClient.programReadySweepRequest(
            trigger: "program-board-refresh",
            port: 8123
        ))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8123/v1/program/ready-sweep")
        let body = try jsonBody(request)
        XCTAssertEqual(body["trigger"] as? String, "program-board-refresh")
    }

    func testSpikeFollowupRequestsSeparateProposalFromPerTicketConfirmation() throws {
        let propose = try XCTUnwrap(OrchestratorClient.proposeSpikeFollowupsRequest(
            originRepoPath: "/repo",
            originTicketID: "RR-7",
            originRunID: 42,
            port: 8123
        ))
        XCTAssertEqual(
            propose.url?.absoluteString,
            "http://127.0.0.1:8123/v1/spikes/follow-ups/propose"
        )
        let proposalBody = try jsonBody(propose)
        XCTAssertEqual(proposalBody["origin_repo_path"] as? String, "/repo")
        XCTAssertEqual(proposalBody["origin_ticket_id"] as? String, "RR-7")
        XCTAssertEqual(proposalBody["origin_run_id"] as? Int, 42)

        let review = try XCTUnwrap(OrchestratorClient.reviewSpikeFollowupRequest(
            batchID: "spike-abc",
            proposalID: "proposal-1",
            decision: "accept",
            updates: ["title": "Refined title"],
            port: 8123
        ))
        XCTAssertEqual(
            review.url?.absoluteString,
            "http://127.0.0.1:8123/v1/spikes/follow-ups/spike-abc/proposals/proposal-1/review"
        )
        let reviewBody = try jsonBody(review)
        XCTAssertEqual(reviewBody["decision"] as? String, "accept")
        XCTAssertEqual((reviewBody["updates"] as? [String: Any])?["title"] as? String, "Refined title")
    }

    func testSpikeFollowupBatchRendersIndependentProposalStates() throws {
        let data = Data("""
        {
          "id": "spike-abc",
          "origin_repo_path": "/repo",
          "origin_ticket_id": "RR-7",
          "origin_run_id": 42,
          "proposals": [
            {
              "id": "proposal-1",
              "state": "accepted",
              "ticket_id": "RR-8",
              "error": null,
              "draft": {
                "title": "First",
                "description": "First implementation",
                "acceptance_criteria": ["First passes"],
                "priority": "high",
                "depends_on": [],
                "worker_model": "strong",
                "worker_effort": "high",
                "worker_sizing_rationale": "Broad change",
                "worker_provider_notes": "Provider neutral",
                "target_repo_path": "/repo"
              }
            },
            {
              "id": "proposal-2",
              "state": "draft",
              "ticket_id": null,
              "error": "Needs a target project",
              "draft": {
                "title": "Second",
                "description": "Second implementation",
                "acceptance_criteria": ["Second passes"],
                "priority": "medium",
                "depends_on": ["RR-8"],
                "worker_model": "balanced",
                "worker_effort": "medium",
                "worker_sizing_rationale": "Scoped change",
                "worker_provider_notes": "Provider neutral",
                "target_repo_path": "/other"
              }
            }
          ]
        }
        """.utf8)

        let batch = try JSONDecoder().decode(SpikeFollowupBatch.self, from: data)
        XCTAssertEqual(batch.proposals.map(\.state), ["accepted", "draft"])
        XCTAssertEqual(batch.proposals[0].ticketID, "RR-8")
        XCTAssertEqual(batch.proposals[1].draft.dependsOn, ["RR-8"])
        XCTAssertEqual(batch.proposals[1].error, "Needs a target project")
    }

    func testFollowupActionAppearsOnlyForCompletedSpikeWithReport() {
        XCTAssertTrue(ProgramSpikeFollowupActionPresentation.resolve(
            executionMode: .spike,
            status: .done,
            runID: 42,
            spikeReport: "Recommended next steps"
        ).isVisible)
        XCTAssertFalse(ProgramSpikeFollowupActionPresentation.resolve(
            executionMode: .implementation,
            status: .done,
            runID: 42,
            spikeReport: "Recommended next steps"
        ).isVisible)
        XCTAssertFalse(ProgramSpikeFollowupActionPresentation.resolve(
            executionMode: .spike,
            status: .done,
            runID: 42,
            spikeReport: nil
        ).isVisible)
    }

    func testProgramStatusRequestUsesProgramEndpoint() throws {
        let request = try XCTUnwrap(OrchestratorClient.programStatusRequest(
            query: "ready_work",
            limit: 20,
            port: 8123
        ))

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://127.0.0.1:8123/v1/program/status?query=ready_work&limit=20"
        )
        XCTAssertNil(request.httpBody)
    }

    func testProgramDashboardRequestUsesDashboardEndpoint() throws {
        let request = try XCTUnwrap(OrchestratorClient.programDashboardRequest(
            limit: 0,
            trigger: "program-board-refresh",
            repoPaths: ["/repo/aurora-web", "/repo/harbor api"],
            port: 8123
        ))

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://127.0.0.1:8123/v1/program/dashboard?limit=0&trigger=program-board-refresh&repo_path=/repo/aurora-web&repo_path=/repo/harbor%20api"
        )
        XCTAssertNil(request.httpBody)
    }

    func testProgramDashboardFetchesCanonicalBoardLanes() async throws {
        let snapshot = try await OrchestratorClient.buildProgramDashboard(limit: 20) { query, _ in
            switch query {
            case "summary":
                return self.response(query: query, message: "Summary", projects: 2)
            case "backlog_lane", "ready_lane", "in_progress_lane", "done_lane", "awaiting_merge":
                return self.response(query: query, message: "Supported")
            default:
                XCTFail("Unexpected query: \(query)")
                return self.response(query: query, message: "Unexpected")
            }
        }

        XCTAssertEqual(snapshot.backlogWork.query, "backlog_lane")
        XCTAssertEqual(snapshot.readyWork.query, "ready_lane")
        XCTAssertEqual(snapshot.inProgressWork.query, "in_progress_lane")
        XCTAssertEqual(snapshot.doneWork.query, "done_lane")
    }

    func testProgramDashboardDefaultsToAllLaneItems() async throws {
        let recorder = LimitRecorder()
        _ = try await OrchestratorClient.buildProgramDashboard { query, limit in
            await recorder.append(limit)
            return self.response(query: query, message: "Supported")
        }

        let requestedLimits = await recorder.values()
        XCTAssertEqual(requestedLimits.count, 6)
        XCTAssertTrue(requestedLimits.allSatisfy { $0 == 0 })
    }

    func testProgramDashboardStillSurfacesNonQueryErrors() async throws {
        do {
            _ = try await OrchestratorClient.buildProgramDashboard(limit: 20) { query, _ in
                if query == "backlog_lane" {
                    throw OrchestratorClientError.badStatus(500, "daemon failed")
                }
                return self.response(query: query, message: "Supported")
            }
            XCTFail("Expected dashboard fetch to fail")
        } catch OrchestratorClientError.badStatus(let status, let body) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "daemon failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProgramDashboardRetriesTransientDaemonRestartFailures() async throws {
        let recorder = FetchAttemptRecorder()

        let snapshot = try await OrchestratorClient.fetchProgramDashboardRetryingTransientConnection(
            retryDelaysNanoseconds: [0, 0],
            fetchDashboard: {
                let attempt = await recorder.nextAttempt()
                if attempt < 3 {
                    throw URLError(.cannotConnectToHost)
                }
                return self.dashboardSnapshot()
            },
            sleep: { _ in }
        )

        let attemptCount = await recorder.count()
        XCTAssertEqual(attemptCount, 3)
        XCTAssertEqual(snapshot.summary.query, "summary")
    }

    func testProgramDashboardInstallsMissingDaemonAndRetries() async throws {
        let fetchRecorder = FetchAttemptRecorder()
        let ensureRecorder = DaemonEnsureRecorder(result: .ready)

        let snapshot = try await OrchestratorClient.fetchProgramDashboardEnsuringDaemon(
            retryDelaysNanoseconds: [0, 0, 0],
            fetchDashboard: {
                let attempt = await fetchRecorder.nextAttempt()
                if attempt < 4 {
                    throw URLError(.cannotConnectToHost)
                }
                return self.dashboardSnapshot()
            },
            ensureDaemon: {
                await ensureRecorder.ensure()
            },
            sleep: { _ in }
        )

        let fetchCount = await fetchRecorder.count()
        let ensureCount = await ensureRecorder.count()
        XCTAssertEqual(fetchCount, 4)
        XCTAssertEqual(ensureCount, 1)
        XCTAssertEqual(snapshot.summary.query, "summary")
    }

    func testProgramDashboardDoesNotEnsureDaemonForPermanentFailure() async throws {
        let ensureRecorder = DaemonEnsureRecorder(result: .ready)

        do {
            _ = try await OrchestratorClient.fetchProgramDashboardEnsuringDaemon(
                retryDelaysNanoseconds: [0],
                fetchDashboard: {
                    throw OrchestratorClientError.badStatus(500, "daemon failed")
                },
                ensureDaemon: {
                    await ensureRecorder.ensure()
                },
                sleep: { _ in }
            )
            XCTFail("Expected dashboard fetch to fail")
        } catch OrchestratorClientError.badStatus(let status, let body) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "daemon failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let ensureCount = await ensureRecorder.count()
        XCTAssertEqual(ensureCount, 0)
    }

    func testProgramDashboardSurfacesDaemonInstallFailure() async throws {
        let fetchRecorder = FetchAttemptRecorder()
        let ensureRecorder = DaemonEnsureRecorder(result: .failed("install failed"))

        do {
            _ = try await OrchestratorClient.fetchProgramDashboardEnsuringDaemon(
                retryDelaysNanoseconds: [0],
                fetchDashboard: {
                    _ = await fetchRecorder.nextAttempt()
                    throw URLError(.cannotConnectToHost)
                },
                ensureDaemon: {
                    await ensureRecorder.ensure()
                },
                sleep: { _ in }
            )
            XCTFail("Expected dashboard fetch to fail")
        } catch OrchestratorClientError.daemonRefreshFailed(let message) {
            XCTAssertEqual(message, "install failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let fetchCount = await fetchRecorder.count()
        let ensureCount = await ensureRecorder.count()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(ensureCount, 1)
    }

    func testProgramDashboardRetriesDelayedServiceReadinessBeyondInitialWindow() async throws {
        let recorder = FetchAttemptRecorder()

        let snapshot = try await OrchestratorClient.fetchProgramDashboardRetryingTransientConnection(
            fetchDashboard: {
                let attempt = await recorder.nextAttempt()
                if attempt < 7 {
                    throw URLError(.cannotConnectToHost)
                }
                return self.dashboardSnapshot()
            },
            sleep: { _ in }
        )

        let attemptCount = await recorder.count()
        XCTAssertEqual(attemptCount, 7)
        XCTAssertEqual(snapshot.summary.query, "summary")
        XCTAssertGreaterThanOrEqual(
            OrchestratorClient.programDashboardConnectionRetryDelaysNanoseconds.count,
            6
        )
    }

    func testProgramDashboardDoesNotRetryPermanentFailures() async throws {
        let recorder = FetchAttemptRecorder()

        do {
            _ = try await OrchestratorClient.fetchProgramDashboardRetryingTransientConnection(
                retryDelaysNanoseconds: [0, 0],
                fetchDashboard: {
                    _ = await recorder.nextAttempt()
                    throw OrchestratorClientError.badStatus(500, "daemon failed")
                },
                sleep: { _ in }
            )
            XCTFail("Expected dashboard fetch to fail")
        } catch OrchestratorClientError.badStatus(let status, let body) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "daemon failed")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let attemptCount = await recorder.count()
        XCTAssertEqual(attemptCount, 1)
    }

    func testProgramDashboardStopsAfterBoundedTransientRetries() async throws {
        let recorder = FetchAttemptRecorder()

        do {
            _ = try await OrchestratorClient.fetchProgramDashboardRetryingTransientConnection(
                retryDelaysNanoseconds: [0, 0],
                fetchDashboard: {
                    _ = await recorder.nextAttempt()
                    throw URLError(.networkConnectionLost)
                },
                sleep: { _ in }
            )
            XCTFail("Expected dashboard fetch to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let attemptCount = await recorder.count()
        XCTAssertEqual(attemptCount, 3)
    }

    func testProgramDashboardRetryStopsWhenBackoffIsCancelled() async throws {
        let recorder = FetchAttemptRecorder()

        do {
            _ = try await OrchestratorClient.fetchProgramDashboardRetryingTransientConnection(
                retryDelaysNanoseconds: [1, 1],
                fetchDashboard: {
                    _ = await recorder.nextAttempt()
                    throw URLError(.cannotConnectToHost)
                },
                sleep: { _ in
                    throw CancellationError()
                }
            )
            XCTFail("Expected dashboard fetch to be cancelled")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let attemptCount = await recorder.count()
        XCTAssertEqual(attemptCount, 1)
    }

    func testProgramDashboardRefreshesStaleDaemonSchemaAndRetries() async throws {
        let recorder = SchemaRefreshRecorder()

        let snapshot = try await OrchestratorClient.fetchProgramDashboardRefreshingStaleDaemon(
            limit: 20,
            fetch: { query, _ in
                if !(await recorder.wasRefreshed()), Self.isBoardLaneQuery(query) {
                    throw Self.staleSchemaError(query: query)
                }
                return self.response(query: query, message: "Supported")
            },
            refreshDaemon: {
                await recorder.refresh(with: .restarted)
            }
        )

        let refreshCount = await recorder.refreshCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(snapshot.backlogWork.query, "backlog_lane")
        XCTAssertEqual(snapshot.readyWork.query, "ready_lane")
        XCTAssertEqual(snapshot.inProgressWork.query, "in_progress_lane")
        XCTAssertEqual(snapshot.doneWork.query, "done_lane")
    }

    func testProgramDashboardRefreshesMissingDashboardEndpointAndRetries() async throws {
        let recorder = SchemaRefreshRecorder()

        let snapshot = try await OrchestratorClient.fetchProgramDashboardRefreshingStaleDaemon(
            limit: 0,
            fetchDashboard: { _ in
                if !(await recorder.wasRefreshed()) {
                    throw OrchestratorClientError.badStatus(
                        404,
                        #"{"error":"no route for GET /v1/program/dashboard"}"#
                    )
                }
                return self.dashboardSnapshot()
            },
            refreshDaemon: {
                await recorder.refresh(with: .restarted)
            }
        )

        let refreshCount = await recorder.refreshCount()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(snapshot.summary.query, "summary")
    }

    func testProgramDashboardDefersStaleDaemonRestartWhileWorkersAreActive() async throws {
        let recorder = SchemaRefreshRecorder()

        do {
            _ = try await OrchestratorClient.fetchProgramDashboardRefreshingStaleDaemon(
                limit: 20,
                fetch: { query, _ in
                    if Self.isBoardLaneQuery(query) {
                        throw Self.staleSchemaError(query: query)
                    }
                    return self.response(query: query, message: "Supported")
                },
                refreshDaemon: {
                    await recorder.refresh(with: .deferredActiveRuns)
                }
            )
            XCTFail("Expected stale daemon refresh to defer")
        } catch OrchestratorClientError.daemonRefreshDeferred {
            let refreshCount = await recorder.refreshCount()
            XCTAssertEqual(refreshCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProgramStatusOverlayFetchesLocalLanesWithoutProviderPromptOrTTS() async throws {
        let recorder = QueryRecorder()

        let message = try await OrchestratorClient.buildProgramStatusOverlay(limit: 6) { query, limit in
            await recorder.record(query: query, limit: limit)
            return self.response(query: query, message: "No work")
        }

        let queries = await recorder.queries
        XCTAssertEqual(Set(queries.map(\.query)), ["in_progress_lane", "awaiting_merge"])
        XCTAssertEqual(Set(queries.map(\.limit)), [6])
        XCTAssertEqual(message.body, "No active workers or tickets awaiting review.")
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(decoded as? [String: Any])
    }

    private func response(
        query: String,
        message: String,
        projects: Int = 1,
        itemCount: Int = 0
    ) -> ProgramStatusResponse {
        ProgramStatusResponse(
            query: query,
            provider: nil,
            message: message,
            items: [],
            counts: ProgramStatusCounts(projects: projects, items: itemCount)
        )
    }

    private func dashboardSnapshot() -> ProgramDashboardSnapshot {
        ProgramDashboardSnapshot(
            summary: response(query: "summary", message: "Summary"),
            backlogWork: response(query: "backlog_lane", message: "Backlog"),
            readyWork: response(query: "ready_lane", message: "Ready"),
            inProgressWork: response(query: "in_progress_lane", message: "In progress"),
            doneWork: response(query: "done_lane", message: "Done"),
            awaitingMerge: response(query: "awaiting_merge", message: "Awaiting review")
        )
    }

    private static func isBoardLaneQuery(_ query: String) -> Bool {
        ["backlog_lane", "ready_lane", "in_progress_lane", "done_lane"].contains(query)
    }

    private static func staleSchemaError(query: String) -> OrchestratorClientError {
        .badStatus(
            400,
            #"{"error":"unknown program status query "\#(query)"; expected one of active_work, ready_work, blocked_work, awaiting_merge, stale_runs, summary, next"}"#
        )
    }
}

private actor LimitRecorder {
    private var recorded: [Int] = []

    func append(_ value: Int) {
        recorded.append(value)
    }

    func values() -> [Int] {
        recorded
    }
}

private actor QueryRecorder {
    private(set) var queries: [(query: String, limit: Int)] = []

    func record(query: String, limit: Int) {
        queries.append((query, limit))
    }
}

private actor SchemaRefreshRecorder {
    private var count = 0

    func wasRefreshed() -> Bool {
        count > 0
    }

    func refresh(with result: OrchestratorDaemonRefreshResult) -> OrchestratorDaemonRefreshResult {
        count += 1
        return result
    }

    func refreshCount() -> Int {
        count
    }
}

private actor FetchAttemptRecorder {
    private var attempts = 0

    func nextAttempt() -> Int {
        attempts += 1
        return attempts
    }

    func count() -> Int {
        attempts
    }
}

private actor DaemonEnsureRecorder {
    private var calls = 0
    private let result: OrchestratorDaemonEnsureResult

    init(result: OrchestratorDaemonEnsureResult) {
        self.result = result
    }

    func ensure() -> OrchestratorDaemonEnsureResult {
        calls += 1
        return result
    }

    func count() -> Int {
        calls
    }
}
