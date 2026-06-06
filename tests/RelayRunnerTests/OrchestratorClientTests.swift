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

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(decoded as? [String: Any])
    }
}
