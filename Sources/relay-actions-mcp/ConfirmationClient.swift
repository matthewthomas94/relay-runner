import Foundation

// Client for the menu-bar app's ActionsConfirmBus listener.
//
// Two-call API:
// - notifyToolFired() — fire-and-forget. Sent after every successful tools/call
//   so the perimeter glow lights up on any tool, not just propose_action.
// - requestConfirmation(...) — blocking. Sends a propose payload and waits for
//   the user's double-tap reply (or 30s server-side timeout).
//
// Each call opens a fresh connection. The menu-bar listener can handle multiple
// concurrent connections so a tool_fired arriving while a propose is open does
// not deadlock.
//
// Connect failure (menu-bar app not running) is non-fatal:
// - tool_fired silently swallows it
// - requestConfirmation returns .menuBarUnavailable so propose_action can
//   surface a clear error to Claude

enum ConfirmationOutcome {
    case confirmed
    case rejected
    case timeout
    case menuBarUnavailable
}

enum ConfirmationClient {
    static let socketPath = "/tmp/relay_actions.sock"

    static func notifyToolFired(toolName: String) {
        let payload: [String: Any] = ["type": "tool_fired", "tool": toolName]
        guard let fd = openSocket() else { return }
        defer { close(fd) }
        _ = sendJSONLine(fd: fd, payload: payload)
    }

    static func requestConfirmation(summary: String, risk: String) -> ConfirmationOutcome {
        let id = UUID().uuidString
        let payload: [String: Any] = [
            "type": "propose",
            "id": id,
            "summary": summary,
            "risk": risk,
        ]
        guard let fd = openSocket() else { return .menuBarUnavailable }
        defer { close(fd) }

        guard sendJSONLine(fd: fd, payload: payload) else {
            return .menuBarUnavailable
        }

        // Block on read. The bus enforces a 30s server-side timeout and will
        // send back {"result": "timeout"} after that — so this read will
        // always terminate, no client-side timer needed. We add a generous
        // 60s safety read timeout in case the bus dies mid-wait.
        var tv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let line = readLine(fd: fd),
              let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let result = json["result"] as? String else {
            return .menuBarUnavailable
        }

        switch result {
        case "confirmed": return .confirmed
        case "rejected":  return .rejected
        case "timeout":   return .timeout
        default:          return .rejected
        }
    }

    // MARK: - Socket plumbing

    private static func openSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    private static func sendJSONLine(fd: Int32, payload: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return false
        }
        data.append(0x0A)
        return data.withUnsafeBytes { ptr -> Bool in
            let n = send(fd, ptr.baseAddress, data.count, 0)
            return n == data.count
        }
    }

    private static func readLine(fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var total = 0
        while total < buffer.count {
            let n = recv(fd, &buffer[total], buffer.count - total, 0)
            if n <= 0 { break }
            total += n
            if let nl = buffer[..<total].firstIndex(of: 0x0A) {
                return Data(buffer[..<nl])
            }
        }
        return total > 0 ? Data(buffer[..<total]) : nil
    }
}
