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
        return try await fetchProgramDashboardRefreshingStaleDaemon(
            limit: limit,
            fetch: { query, limit in
                try await fetchProgramStatus(query: query, limit: limit)
            },
            refreshDaemon: {
                await restartOrchestratorDaemonIfIdle()
            }
        )
    }

    static func fetchProgramDashboardRefreshingStaleDaemon(
        limit: Int = 0,
        fetch: @escaping (_ query: String, _ limit: Int) async throws -> ProgramStatusResponse,
        refreshDaemon: @escaping () async -> OrchestratorDaemonRefreshResult
    ) async throws -> ProgramDashboardSnapshot {
        do {
            return try await buildProgramDashboard(limit: limit, fetch: fetch)
        } catch {
            guard shouldRefreshDaemon(for: error) else { throw error }
            switch await refreshDaemon() {
            case .restarted:
                do {
                    return try await buildProgramDashboard(limit: limit, fetch: fetch)
                } catch {
                    if shouldRefreshDaemon(for: error) {
                        throw OrchestratorClientError.daemonRefreshFailed(
                            "Relay Runner restarted the orchestrator, but it still reports an older Program Board schema."
                        )
                    }
                    throw error
                }
            case .deferredActiveRuns:
                throw OrchestratorClientError.daemonRefreshDeferred
            case .notInstalled:
                throw OrchestratorClientError.daemonRefreshFailed(
                    "Relay Runner could not find the installed orchestrator launch agent."
                )
            case .failed(let message):
                throw OrchestratorClientError.daemonRefreshFailed(message)
            }
        }
    }

    static func fetchProgramStatusOverlay(limit: Int = 6) async throws -> ProgramStatusOverlayMessage {
        try await buildProgramStatusOverlay(limit: limit) { query, limit in
            try await fetchProgramStatus(query: query, limit: limit)
        }
    }

    static func refreshBundledOrchestratorDaemonIfIdle() async -> OrchestratorDaemonRefreshResult {
        guard orchestratorDaemonInstalled() else {
            return .notInstalled
        }
        return await restartOrchestratorDaemonIfIdle()
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

    private static func shouldRefreshDaemon(for error: Error) -> Bool {
        guard let clientError = error as? OrchestratorClientError,
              case OrchestratorClientError.badStatus(400, let body) = clientError else { return false }
        let lower = body.lowercased()
        guard lower.contains("unknown program status query") else { return false }
        return lower.contains("backlog_lane")
            || lower.contains("ready_lane")
            || lower.contains("in_progress_lane")
            || lower.contains("done_lane")
    }

    private static func restartOrchestratorDaemonIfIdle() async -> OrchestratorDaemonRefreshResult {
        await Task.detached {
            let script = relayOrchestratorScript()
            guard FileManager.default.isExecutableFile(atPath: script.path) else {
                return .failed("Relay Runner could not find the bundled relay-orchestrator launcher.")
            }

            let proc = Process()
            proc.executableURL = script
            proc.arguments = ["--restart-if-idle"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                return .failed("Relay Runner could not restart the orchestrator: \(error.localizedDescription)")
            }

            switch proc.terminationStatus {
            case 0:
                return .restarted
            case 75:
                return .deferredActiveRuns
            default:
                return .failed(
                    "relay-orchestrator --restart-if-idle failed with exit code \(proc.terminationStatus)."
                )
            }
        }.value
    }

    private static func relayOrchestratorScript() -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/scripts/relay-orchestrator")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/relay-orchestrator")
    }

    private static func orchestratorDaemonInstalled() -> Bool {
        if FileManager.default.fileExists(atPath: portFile) {
            return true
        }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.relay.orchestrator.plist")
        return FileManager.default.fileExists(atPath: plist.path)
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

enum OrchestratorDaemonRefreshResult: Equatable {
    case restarted
    case deferredActiveRuns
    case notInstalled
    case failed(String)
}

enum OrchestratorClientError: Error, LocalizedError, Equatable {
    case invalidRequest
    case badStatus(Int, String)
    case decodeFailed(String)
    case daemonRefreshDeferred
    case daemonRefreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build orchestrator request."
        case .badStatus(let status, let body):
            let detail = body.isEmpty ? "No response body." : body
            return "Orchestrator returned HTTP \(status). \(detail)"
        case .decodeFailed(let message):
            return "Could not decode orchestrator response: \(message)"
        case .daemonRefreshDeferred:
            return (
                "Relay Runner needs to restart the orchestrator to load the bundled Program Board schema, "
                + "but active workers are running. Refresh again after those workers finish."
            )
        case .daemonRefreshFailed(let message):
            return message.isEmpty
                ? "Relay Runner could not restart the orchestrator."
                : message
        }
    }
}
