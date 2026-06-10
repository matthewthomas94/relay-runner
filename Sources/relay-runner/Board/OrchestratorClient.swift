import Foundation

/// Fire-and-forget HTTP client for triggering orchestrator dispatches from
/// the menu-bar app. Mirrors the port-discovery logic in the relay-orchestrator-mcp
/// target's HTTPClient — they live in separate Swift modules and can't share
/// code without restructuring the package.
///
/// The daemon writes its bound port to `/tmp/relay_orchestrator.port` at startup.
/// We re-read on every request so a daemon restart on a different port doesn't
/// strand us. Failures are logged via NSLog; the board never blocks on them.
enum OrchestratorClient {

    private static let portFile = "/tmp/relay_orchestrator.port"
    private static let defaultPort = 7634

    /// Dispatch a ticket. Returns immediately; the request runs on URLSession's
    /// own queue. The daemon's `find_active` makes this idempotent — re-dispatching
    /// a ticket that's already running just returns `already_active: true`.
    static func dispatchTicket(ticketId: String, repoPath: String, source: String = "board-ready-transition") {
        guard let req = dispatchRequest(ticketId: ticketId, repoPath: repoPath, source: source, port: readPort()) else {
            NSLog("[orchestrator-client] could not build dispatch request for \(ticketId)")
            return
        }
        post(req, label: "dispatch \(ticketId)")
    }

    /// Ask the daemon to scan the active repo and dispatch stale ready tickets.
    /// This is intentionally repo-scoped and provider-neutral: the daemon still
    /// creates workers through the same dispatch path as board drag/save.
    static func sweepReadyTickets(repoPath: String, trigger: String) {
        guard let req = readySweepRequest(repoPath: repoPath, trigger: trigger, port: readPort()) else {
            NSLog("[orchestrator-client] could not build ready-sweep request for \(repoPath)")
            return
        }
        post(req, label: "ready-sweep")
    }

    /// Ask the daemon to scan every registered project and dispatch eligible
    /// ready tickets without opening each project board.
    static func sweepProgramReadyTickets(trigger: String) {
        guard let req = programReadySweepRequest(trigger: trigger, port: readPort()) else {
            NSLog("[orchestrator-client] could not build program ready-sweep request")
            return
        }
        post(req, label: "program-ready-sweep")
    }

    static func dispatchRequest(ticketId: String, repoPath: String, source: String, port: Int) -> URLRequest? {
        let payload: [String: Any] = [
            "ticket_id": ticketId,
            "repo_path": repoPath,
            "source": source,
        ]
        return postRequest(path: "/v1/runs", payload: payload, port: port)
    }

    static func readySweepRequest(repoPath: String, trigger: String, port: Int) -> URLRequest? {
        let payload: [String: Any] = [
            "repo_path": repoPath,
            "trigger": trigger,
        ]
        return postRequest(path: "/v1/ready-sweep", payload: payload, port: port)
    }

    static func programReadySweepRequest(trigger: String, port: Int) -> URLRequest? {
        postRequest(
            path: "/v1/program/ready-sweep",
            payload: ["trigger": trigger],
            port: port
        )
    }

    static func fetchProgramDashboard(limit: Int = 0) async throws -> ProgramDashboardSnapshot {
        await sweepProgramReadyTicketsBeforeDashboard(trigger: "program-board-refresh")
        return try await buildProgramDashboard(limit: limit) { query, limit in
            try await fetchProgramStatus(query: query, limit: limit)
        }
    }

    static func fetchProgramStatusOverlay(limit: Int = 6) async throws -> ProgramStatusOverlayMessage {
        try await buildProgramStatusOverlay(limit: limit) { query, limit in
            try await fetchProgramStatus(query: query, limit: limit)
        }
    }

    static func buildProgramDashboard(
        limit: Int = 0,
        fetch: @escaping (_ query: String, _ limit: Int) async throws -> ProgramStatusResponse
    ) async throws -> ProgramDashboardSnapshot {
        async let summary = fetch("summary", limit)
        async let backlog = fetch("backlog_lane", limit)
        async let ready = fetch("ready_lane", limit)
        async let inProgress = fetch("in_progress_lane", limit)
        async let done = fetch("done_lane", limit)
        async let awaitingMerge = fetch("awaiting_merge", limit)
        let summaryResponse = try await summary
        return try await ProgramDashboardSnapshot(
            summary: summaryResponse,
            backlogWork: backlog,
            readyWork: ready,
            inProgressWork: inProgress,
            doneWork: done,
            awaitingMerge: awaitingMerge
        )
    }

    static func buildProgramStatusOverlay(
        limit: Int = 6,
        fetch: @escaping (_ query: String, _ limit: Int) async throws -> ProgramStatusResponse
    ) async throws -> ProgramStatusOverlayMessage {
        async let active = fetch("in_progress_lane", limit)
        async let awaitingMerge = fetch("awaiting_merge", limit)
        return try await ProgramStatusOverlayFormatter.message(
            active: active,
            awaitingMerge: awaitingMerge
        )
    }

    private static func sweepProgramReadyTicketsBeforeDashboard(trigger: String) async {
        guard let req = programReadySweepRequest(trigger: trigger, port: readPort()) else {
            NSLog("[orchestrator-client] could not build program ready-sweep request")
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                let msg = String(data: data, encoding: .utf8) ?? "(no body)"
                NSLog("[orchestrator-client] program-ready-sweep HTTP \(status): \(msg.prefix(200))")
            }
        } catch {
            NSLog("[orchestrator-client] program-ready-sweep failed: \(error.localizedDescription)")
        }
    }

    static func fetchProgramStatus(query: String, limit: Int = 20) async throws -> ProgramStatusResponse {
        guard let req = programStatusRequest(query: query, limit: limit, port: readPort()) else {
            throw OrchestratorClientError.invalidRequest
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OrchestratorClientError.badStatus(status, body)
        }
        do {
            return try JSONDecoder().decode(ProgramStatusResponse.self, from: data)
        } catch {
            throw OrchestratorClientError.decodeFailed(error.localizedDescription)
        }
    }

    static func programStatusRequest(query: String, limit: Int, port: Int) -> URLRequest? {
        getRequest(
            path: "/v1/program/status",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ],
            port: port
        )
    }

    private static func postRequest(path: String, payload: [String: Any], port: Int) -> URLRequest? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)"),
              let body = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    private static func getRequest(path: String, query: [URLQueryItem], port: Int) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        components.queryItems = query
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        return req
    }

    private static func post(_ req: URLRequest, label: String) {
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                NSLog("[orchestrator-client] \(label) failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                let msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                NSLog("[orchestrator-client] \(label) HTTP \(status): \(msg.prefix(200))")
            }
        }.resume()
    }

    private static func readPort() -> Int {
        if let raw = try? String(contentsOfFile: portFile, encoding: .utf8),
           let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           port > 0 {
            return port
        }
        return defaultPort
    }
}

enum OrchestratorClientError: Error, LocalizedError, Equatable {
    case invalidRequest
    case badStatus(Int, String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build orchestrator request."
        case .badStatus(let status, let body):
            let detail = body.isEmpty ? "No response body." : body
            return "Orchestrator returned HTTP \(status). \(detail)"
        case .decodeFailed(let message):
            return "Could not decode orchestrator response: \(message)"
        }
    }
}
