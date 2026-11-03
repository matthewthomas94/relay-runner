import Foundation

// `tool_fired` to the menu-bar app's ActionsConfirmBus listener on
// /tmp/relay_actions.sock, so ActionGlow pulses for Relay App like every
// other Relay server. Fire-and-forget: a missing listener is not an error.
enum ConfirmationClient {
    static let socketPath = "/tmp/relay_actions.sock"

    static func notifyToolFired(toolName: String) {
        guard var data = try? JSONSerialization.data(withJSONObject: ["type": "tool_fired", "tool": toolName]),
              let fd = UnixSocket.connect(socketPath) else { return }
        defer { close(fd) }
        data.append(0x0A)
        _ = UnixSocket.writeAll(fd, data)
    }
}

enum UnixSocket {
    /// A connected stream socket, or nil when nothing listens at `path`.
    static func connect(_ path: String) -> Int32? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
