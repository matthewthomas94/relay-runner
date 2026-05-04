import Foundation

// HTTP client for talking to the orchestrator daemon (services/orchestrator.py).
//
// Port discovery: the daemon writes its bound port to /tmp/relay_orchestrator.port
// at startup, and clears the file on clean shutdown. We re-read the file on each
// request so a daemon restart on a different port doesn't strand us.

enum DaemonError: Error {
    case daemonNotRunning(String)
    case requestFailed(Int, String)
    case decodingFailed(String)
}

extension DaemonError {
    var asMCPToolError: MCPToolError {
        switch self {
        case .daemonNotRunning(let msg):
            return MCPToolError(message: "Orchestrator daemon is not reachable: \(msg). Start it via the relay-runner menu bar app or `scripts/relay-orchestrator`.")
        case .requestFailed(let status, let msg):
            return MCPToolError(message: "Orchestrator returned HTTP \(status): \(msg)")
        case .decodingFailed(let msg):
            return MCPToolError(message: "Could not decode orchestrator response: \(msg)")
        }
    }
}

struct DaemonClient {
    static let portFile = "/tmp/relay_orchestrator.port"
    static let defaultPort = 7634
    static let timeout: TimeInterval = 10

    static func currentPort() throws -> Int {
        // Prefer the port file the daemon wrote at startup; fall back to the default
        // for first-run scenarios where the file may not yet exist when the MCP
        // server is queried.
        if let raw = try? String(contentsOfFile: portFile, encoding: .utf8),
           let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           port > 0 {
            return port
        }
        return defaultPort
    }

    static func request(method: String, path: String, body: [String: Any]? = nil) async throws -> Any {
        let port = try currentPort()
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw DaemonError.requestFailed(0, "invalid URL: \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout

        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])
            } catch {
                throw DaemonError.requestFailed(0, "could not encode body: \(error)")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw DaemonError.daemonNotRunning("\(error.localizedDescription) (port \(port))")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload: Any
        do {
            payload = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
            throw DaemonError.decodingFailed("HTTP \(status): \(raw.prefix(200))")
        }

        if status >= 400 {
            let msg: String
            if let dict = payload as? [String: Any], let err = dict["error"] as? String {
                msg = err
            } else {
                msg = String(data: data, encoding: .utf8) ?? "(no body)"
            }
            throw DaemonError.requestFailed(status, msg)
        }
        return payload
    }
}

func toolTextContent(_ payload: Any) throws -> [[String: Any]] {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .withoutEscapingSlashes])
    guard let str = String(data: data, encoding: .utf8) else {
        throw MCPToolError(message: "could not stringify orchestrator response")
    }
    return [["type": "text", "text": str]]
}
