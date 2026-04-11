import Foundation

enum SocketClient {

    /// Send a command to the voice bridge control socket.
    @discardableResult
    static func bridgeSend(_ command: String) -> Bool {
        sendDatagram(command, to: "/tmp/voice_bridge.sock")
    }

    /// Send a command to the TTS worker control socket.
    @discardableResult
    static func ttsSend(_ command: String) -> Bool {
        sendDatagram(command, to: "/tmp/tts_control.sock")
    }

    // MARK: - Unix datagram send

    private static func sendDatagram(_ message: String, to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        guard let data = message.data(using: .utf8) else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    sendto(fd, buf.baseAddress!, buf.count, 0, sockPtr, addrLen)
                }
            }
        }

        return result >= 0
    }
}
