import Foundation
import RelayRemoteProtocol

/// What the session-control socket needs from the app (RR-456). `AppState`
/// supplies the live closures; tests inject fakes.
struct RelaySessionControlHost {
    struct Project: Equatable {
        let id: String
        let name: String
        let path: String
        /// `RegisteredProjectAvailability.rawValue`.
        let availability: String
    }

    struct LiveSession: Equatable {
        let projectID: String?
        let name: String
    }

    struct Snapshot: Equatable {
        /// Live embedded sessions, the focused one first.
        var live: [LiveSession] = []
        /// `newSession` accepted a launch that has not produced a live session yet.
        var launching = false
        /// Why Start is unavailable right now, worded as the session wheel words it.
        var startBlockedReason: String?
    }

    /// Registered projects in display order (`ProjectRegistryV2Service.projects()`).
    var projects: () -> [Project]
    var snapshot: () -> Snapshot
    /// The Workspace Start path, `AppState.newSession(workingDirectory:)`. False when it refused.
    var start: (_ path: String) -> Bool
    /// `AppState.endSession()`.
    var stop: () -> Void
    /// The app's current session message; one that appears during a refused start explains it.
    var message: () -> String?
}

/// The app's side of remote session control (RR-456), shared by every
/// connection on the session-control socket. The forced-command helper opens
/// each connection with `identify`; the phone then sends `hello`, `ping` and
/// `session_command` frames. Commands are answered, and changes pushed, as
/// `session_state`. The phone's provider, model and effort are not chosen
/// here: a session started from the phone uses the Mac's defaults and is
/// otherwise identical to one started from the Workspace. Main-thread only,
/// like the `AppState` it calls; the server hops there for every line.
final class RelaySessionControl {
    private let host: RelaySessionControlHost
    private var dedup = ClientIDDeduplicator()
    /// A start this socket requested that has not been seen ready yet.
    private var pendingStart: (id: String, name: String)?
    private var failure: (id: String, name: String, error: String)?
    /// Set by `stop` until the sessions are gone, so the phone sees `none` at once.
    private var stopRequested = false
    private var lastPushed: SessionState?
    /// Whether the voice bridge's Relay Remote socket answers `status` with
    /// `running`. The server probes it before every line and tick.
    var bridgeAccepting = false

    init(host: RelaySessionControlHost) {
        self.host = host
    }

    /// The replies to one line from the helper, in order. `hello` and frames
    /// meant for a voice bridge get none: there is no bridge on this socket.
    func handle(line: Data) -> [Frame] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        switch type {
        case "identify":
            return [.sessionState(state(includingProjects: true))]
        case "ping", "session_command":
            let frame: Frame
            do {
                frame = try FrameCodec.decode(line)
            } catch {
                let code = (error as? FrameError)?.code ?? "invalid_json"
                return [.error(ErrorFrame(code: code, message: "Frame rejected"))]
            }
            switch frame {
            case .ping(let ping): return [.pong(Pong(t: ping.t))]
            case .sessionCommand(let command): return [.sessionState(perform(command))]
            default: return []
            }
        default:
            return []
        }
    }

    /// The state to push to every connection, when it changed since the last push.
    func pushIfChanged() -> SessionState? {
        let current = state()
        guard current != lastPushed else { return nil }
        lastPushed = current
        return current
    }

    func state(includingProjects: Bool = false, error: String? = nil) -> SessionState {
        let snapshot = host.snapshot()
        if stopRequested, snapshot.live.isEmpty, !snapshot.launching { stopRequested = false }
        var result = SessionState(appRunning: true, session: .noSession)
        if stopRequested {
            // Ending: the Mac's own controls revert at once, and so does the phone.
        } else if let running = snapshot.live.first {
            result.session = bridgeAccepting ? .ready : .starting
            result.projectId = running.projectID
            result.projectName = running.name
            failure = nil
            if bridgeAccepting { pendingStart = nil }
        } else if snapshot.launching {
            result.session = .starting
            result.projectId = pendingStart?.id
            result.projectName = pendingStart?.name
        } else {
            if let pending = pendingStart {
                failure = (pending.id, pending.name, "The session for \(pending.name) ended before it was ready.")
                pendingStart = nil
            }
            if let failure {
                result.session = .failed
                result.projectId = failure.id
                result.projectName = failure.name
                result.error = failure.error
            }
        }
        if let error { result.error = error }
        if includingProjects {
            result.projects = host.projects().map {
                ProjectSummary(projectId: $0.id, displayName: $0.name, availability: $0.availability)
            }
        }
        return result
    }

    private func perform(_ command: SessionCommand) -> SessionState {
        // A retry after a reconnect reports the current state instead of acting twice.
        if dedup.isDuplicate(command.clientId) { return state() }
        return perform(command.action, projectID: command.projectId)
    }

    /// One session action, shared by the phone's `session_command` and Relay App (RR-459).
    func perform(_ action: SessionAction, projectID: String? = nil) -> SessionState {
        switch action {
        case .listProjects: return state(includingProjects: true)
        case .state: return state()
        case .stop: return stop()
        case .start: return start(projectID: projectID)
        }
    }

    private func stop() -> SessionState {
        pendingStart = nil
        failure = nil
        let snapshot = host.snapshot()
        if !snapshot.live.isEmpty || snapshot.launching {
            host.stop()
            stopRequested = true
        }
        return state()
    }

    private func start(projectID: String?) -> SessionState {
        guard let projectID, !projectID.isEmpty else { return state(error: "Choose a project to start.") }
        guard let project = host.projects().first(where: { $0.id == projectID }) else {
            return state(includingProjects: true, error: "That project is no longer registered on this Mac.")
        }
        guard project.availability == "available" else {
            return state(error: "\(project.name) is not available on this Mac.")
        }
        let snapshot = host.snapshot()
        if let running = snapshot.live.first {
            // Starting the running project again is an attach; switching is not offered.
            if snapshot.live.contains(where: { $0.projectID == project.id }) { return state() }
            return state(error: "\(running.name) is already running on this Mac. Stop it before starting \(project.name).")
        }
        if let reason = snapshot.startBlockedReason ?? (snapshot.launching ? "A session is already starting on this Mac." : nil) {
            return state(error: reason)
        }
        failure = nil
        stopRequested = false
        let before = host.message()
        guard host.start(project.path) else {
            let after = host.message()
            let reason = after != before ? after : nil
            failure = (project.id, project.name, reason ?? "Relay Runner could not start \(project.name) on this Mac.")
            return state()
        }
        pendingStart = (project.id, project.name)
        return state()
    }
}

/// Listens on `/tmp/relay_session_control.sock` while the app runs (RR-456),
/// owner-only like the Relay Actions and pairing sockets, and accepts only
/// peers with this user's uid. It is the app's command surface with two kinds
/// of client, told apart by a connection's first line:
///
/// - `relay-remote-shell`, run by a paired device's forced `command=` key,
///   opens with `identify` and then relays the phone's `session_command`s.
/// - `relay-app-mcp` (RR-459) opens with `app_command` and gets `app_result`
///   replies from `RelayAppCommands`. A connection that began with anything
///   else is refused app commands, so a phone can never reach them.
final class RelaySessionControlServer: @unchecked Sendable {
    static let defaultSocketPath = "/tmp/relay_session_control.sock"
    static let defaultBridgeSocketPath = "/tmp/relay_remote.sock"

    /// Confined to `queue`; Relay App's main-actor hop only carries it back there.
    private final class Client: @unchecked Sendable {
        enum Role { case undecided, remote, app }

        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var role = Role.undecided

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    private let path: String
    private let bridgePath: String
    private let tickInterval: TimeInterval
    private let control: RelaySessionControl
    private let commands: RelayAppCommands?
    private let queue = DispatchQueue(label: "com.relayrunner.session-control")
    // Confined to `queue`.
    private var listenSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var clients: [ObjectIdentifier: Client] = [:]

    init(control: RelaySessionControl, commands: RelayAppCommands? = nil, path: String = defaultSocketPath,
         bridgePath: String = defaultBridgeSocketPath, tickInterval: TimeInterval = 1) {
        self.control = control
        self.commands = commands
        self.path = path
        self.bridgePath = bridgePath
        self.tickInterval = tickInterval
    }

    func start() throws {
        let fd = try Self.listen(at: path)
        queue.sync {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptClient(listenFD: fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            listenSource = source
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + tickInterval, repeating: tickInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            listenSource?.cancel()
            listenSource = nil
            clients.values.forEach { $0.source.cancel() }
            clients.removeAll()
        }
        unlink(path)
    }

    // MARK: Connections

    private func acceptClient(listenFD: Int32) {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        Self.configure(fd)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let client = Client(fd: fd, source: source)
        source.setEventHandler { [weak self, weak client] in
            if let client { self?.read(client) }
        }
        source.setCancelHandler { close(fd) }
        clients[ObjectIdentifier(client)] = client
        source.resume()
    }

    private func drop(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        client.source.cancel()
    }

    private func read(_ client: Client) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(client.fd, &chunk, chunk.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { return drop(client) }
        client.buffer.append(contentsOf: chunk[0..<count])
        var lines: [Data] = []
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = Data(client.buffer[client.buffer.startIndex..<newline])
            client.buffer = Data(client.buffer[client.buffer.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        guard client.buffer.count <= RelayRemoteProtocol.maxLineBytes else { return drop(client) }
        guard !lines.isEmpty else { return }
        var sessionLines: [Data] = []
        for line in lines {
            let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            let isAppCommand = object?["type"] as? String == "app_command"
            if client.role == .undecided { client.role = isAppCommand ? .app : .remote }
            if isAppCommand { perform(object ?? [:], for: client) } else { sessionLines.append(line) }
        }
        lines = sessionLines
        guard !lines.isEmpty else { return }
        let accepting = Self.bridgeAccepting(at: bridgePath)
        DispatchQueue.main.async { [self] in
            control.bridgeAccepting = accepting
            let replies = lines.flatMap { control.handle(line: $0) }.compactMap { try? FrameCodec.encode($0) }
            queue.async { [self] in
                guard clients[ObjectIdentifier(client)] === client else { return }
                write(replies, to: client)
            }
        }
    }

    /// Runs one Relay App command on the main actor and answers with `app_result`.
    private func perform(_ object: [String: Any], for client: Client) {
        let id = object["id"] as? String ?? ""
        guard client.role == .app, let commands else {
            let reason = commands == nil ? "Relay App commands are not available." : "App commands are not accepted on this connection."
            return write([RelayAppCommands.encode(id: id, .failure(.init(reason)))], to: client)
        }
        Task { @MainActor [self] in
            let reply = RelayAppCommands.encode(id: id, await commands.handle(object))
            queue.async { [self] in
                guard clients[ObjectIdentifier(client)] === client else { return }
                write([reply], to: client)
            }
        }
    }

    private func tick() {
        guard clients.values.contains(where: { $0.role != .app }) else { return }
        let accepting = Self.bridgeAccepting(at: bridgePath)
        DispatchQueue.main.async { [self] in
            control.bridgeAccepting = accepting
            guard let line = control.pushIfChanged().flatMap({ try? FrameCodec.encode(.sessionState($0)) }) else { return }
            queue.async { [self] in
                for client in Array(clients.values) where client.role != .app { write([line], to: client) }
            }
        }
    }

    /// A client that cannot take a small line now is gone; the helper reconnects.
    private func write(_ lines: [Data], to client: Client) {
        for line in lines where !Self.writeAll(client.fd, line) {
            return drop(client)
        }
    }

    // MARK: Sockets

    private static func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
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

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    private static func listen(at path: String) throws -> Int32 {
        unlink(path)
        guard var addr = address(path) else { throw POSIXError(.ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, S_IRUSR | S_IWUSR) == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    /// True when the voice bridge's Relay Remote socket answers the helper's
    /// `status` identify with `running`: its loop is consuming commands, so a
    /// phone that reconnects now attaches and can send a request at once.
    static func bridgeAccepting(at path: String) -> Bool {
        guard var addr = address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        configure(fd)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0,
              writeAll(fd, Data(#"{"command":"status","device_id":"relay-runner-app","type":"identify"}"#.utf8 + [0x0A]))
        else { return false }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while !reply.contains(0x0A), reply.count < 4096 {
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            reply.append(contentsOf: chunk[0..<count])
        }
        guard let newline = reply.firstIndex(of: 0x0A),
              case .status(let status)? = try? FrameCodec.decode(reply[..<newline]) else { return false }
        return status.text == "running"
    }
}
