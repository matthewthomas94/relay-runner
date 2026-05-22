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
    static func dispatchTicket(ticketId: String, repoPath: String) {
        let port = readPort()
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/runs") else {
            NSLog("[orchestrator-client] invalid URL for port \(port)")
            return
        }

        let payload: [String: Any] = [
            "ticket_id": ticketId,
            "repo_path": repoPath,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else {
            NSLog("[orchestrator-client] could not encode dispatch payload for \(ticketId)")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                NSLog("[orchestrator-client] dispatch \(ticketId) failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                let msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                NSLog("[orchestrator-client] dispatch \(ticketId) HTTP \(status): \(msg.prefix(200))")
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
