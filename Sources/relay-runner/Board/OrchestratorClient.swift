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
