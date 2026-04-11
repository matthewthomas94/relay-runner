import Foundation

/// Listens on /tmp/voice_state.sock for JSON state updates from Python services.
/// Dispatches parsed events to the StateMachine on the main actor.
actor StateEventBus {

    static let socketPath = "/tmp/voice_state.sock"

    private var fd: Int32 = -1
    private var receiveTask: Task<Void, Never>?
    private weak var stateMachine: StateMachine?

    init(stateMachine: StateMachine) {
        self.stateMachine = stateMachine
    }

    func start() {
        stop()

        // Clean up stale socket
        unlink(StateEventBus.socketPath)

        // Create Unix datagram socket
        let sock = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            NSLog("[StateEventBus] Failed to create socket: \(errno)")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = StateEventBus.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            NSLog("[StateEventBus] Failed to bind socket: \(errno)")
            close(sock)
            return
        }

        self.fd = sock
        NSLog("[StateEventBus] Listening on \(StateEventBus.socketPath)")

        // Receive loop
        receiveTask = Task { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                guard let self else { return }
                let currentFd = await self.fd
                guard currentFd >= 0 else { return }

                // Use poll to avoid blocking indefinitely
                var pfd = pollfd(fd: currentFd, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pfd, 1, 200)  // 200ms timeout

                if pollResult <= 0 { continue }

                let n = recv(currentFd, &buffer, buffer.count, 0)
                guard n > 0 else { continue }

                let data = Data(bytes: buffer, count: n)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let source = json["source"] as? String,
                      let state = json["state"] as? String
                else { continue }

                let text = json["text"] as? String

                NSLog("[StateEventBus] \(source):\(state)\(text.map { " text=\($0.prefix(40))" } ?? "")")

                let sm = await self.stateMachine
                await MainActor.run {
                    sm?.handleServiceEvent(source: source, newState: state, text: text)
                }
            }
        }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        unlink(StateEventBus.socketPath)
    }
}
