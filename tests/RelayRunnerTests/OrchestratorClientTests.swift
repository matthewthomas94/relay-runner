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
            port: 8123
        ))

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://127.0.0.1:8123/v1/program/dashboard?limit=0&trigger=program-board-refresh"
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
        XCTAssertEqual(message.body, "No active workers or tickets awaiting merge.")
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
            awaitingMerge: response(query: "awaiting_merge", message: "Awaiting merge")
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
