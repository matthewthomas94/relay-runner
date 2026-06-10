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
}
