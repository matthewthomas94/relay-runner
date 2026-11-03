import Foundation

// Forced command for a paired Relay Remote device (docs/specs/relay-remote.md).
// Copies NDJSON lines between the SSH channel (stdin/stdout) and a local Unix
// socket. It holds no protocol logic: it only enforces the 64 KiB line limit,
// checks that each line is a JSON object, and reports failures as `error` frames.
//
// RR-456 routing for `--device`: the voice bridge's socket when a session is
// running; otherwise the app's session-control socket, which reports the
// session and starts or stops one. While attached to the bridge, the phone's
// `session_command` lines go to the app socket instead. With neither socket
// listening the helper reports `session_state` with `app_running: false`.

let maxLineBytes = 64 * 1024
let deviceSocketPath = ProcessInfo.processInfo.environment["RELAY_REMOTE_SOCKET_PATH"] ?? "/tmp/relay_remote.sock"
let pairSocketPath = ProcessInfo.processInfo.environment["RELAY_REMOTE_PAIR_SOCKET_PATH"] ?? "/tmp/relay_remote_pair.sock"
let controlSocketPath = ProcessInfo.processInfo.environment["RELAY_SESSION_CONTROL_SOCKET_PATH"]
    ?? "/tmp/relay_session_control.sock"

signal(SIGPIPE, SIG_IGN)

func jsonLine(_ object: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    data.append(0x0A)
    return data
}

@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { raw -> Bool in
        while offset < data.count {
            let n = write(fd, raw.baseAddress! + offset, data.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }
}

func fail(_ code: String, _ message: String, exitCode: Int32) -> Never {
    writeAll(STDOUT_FILENO, jsonLine(["type": "error", "code": code, "message": message]))
    exit(exitCode)
}

func connectSocket(_ path: String) -> Int32? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 {
        close(fd)
        return nil
    }
    return fd
}

enum LineCheck {
    case ok
    case tooLong
    case invalid
}

func frameType(_ line: Data) -> String? {
    ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["type"] as? String
}

func check(line: Data) -> LineCheck {
    if line.count > maxLineBytes { return .tooLong }
    guard (try? JSONSerialization.jsonObject(with: line)) is [String: Any] else { return .invalid }
    return .ok
}

/// Accumulates bytes and yields complete lines (without the newline).
struct LineBuffer {
    private var buffer = Data()

    /// Returns complete lines, or the violation that must end the session.
    mutating func feed(_ chunk: Data) -> (lines: [Data], violation: LineCheck?) {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if line.isEmpty { continue }
            let verdict = check(line: Data(line))
            if verdict != .ok { return (lines, verdict) }
            lines.append(Data(line))
        }
        if buffer.count > maxLineBytes { return (lines, .tooLong) }
        return (lines, nil)
    }
}

func violationExit(_ violation: LineCheck) -> Never {
    switch violation {
    case .tooLong: fail("line_too_long", "frame exceeds 65536 bytes", exitCode: 1)
    default: fail("invalid_json", "frame is not a JSON object", exitCode: 1)
    }
}

func validID(_ value: String) -> Bool {
    guard (1...128).contains(value.utf8.count) else { return false }
    return value.utf8.allSatisfy { c in
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x2E || c == 0x5F
    }
}

// MARK: - Argument and SSH_ORIGINAL_COMMAND handling (no socket is opened before this passes)

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, args[0] == "--device" || args[0] == "--pair", validID(args[1]) else {
    fail("bad_arguments", "usage: relay-remote-shell --device <id> | --pair <id>", exitCode: 2)
}
let isPair = args[0] == "--pair"
let originalCommand = (ProcessInfo.processInfo.environment["SSH_ORIGINAL_COMMAND"] ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
let wantsStatus = originalCommand == "status"
if !originalCommand.isEmpty && !wantsStatus {
    fail("command_not_allowed", "only the status command is allowed", exitCode: 2)
}
if wantsStatus && isPair {
    fail("command_not_allowed", "status is not available while pairing", exitCode: 2)
}

// MARK: - Connect and identify

var identify: [String: Any] = ["type": "identify"]
identify[isPair ? "pairing_id" : "device_id"] = args[1]
if wantsStatus { identify["command"] = "status" }
let identifyLine = jsonLine(identify)

let sock: Int32
/// True when `sock` is the voice bridge rather than the app's session-control socket.
var attachedToBridge = true
if let bridge = connectSocket(isPair ? pairSocketPath : deviceSocketPath) {
    sock = bridge
} else if isPair || wantsStatus {
    fail("bridge_unavailable", "Relay Runner is not running", exitCode: 1)
} else if let app = connectSocket(controlSocketPath) {
    sock = app
    attachedToBridge = false
} else {
    // The same bytes FrameCodec writes for SessionState(appRunning: false, session: .noSession).
    writeAll(STDOUT_FILENO, jsonLine(["type": "session_state", "app_running": false, "session": "none"]))
    exit(1)
}
guard writeAll(sock, identifyLine) else {
    fail("bridge_unavailable", "Relay Runner closed the connection", exitCode: 1)
}

/// The app's session-control socket beside the bridge, opened by the first
/// `session_command` so its replies always follow the bridge's `welcome`.
var control: Int32?

func openControl() -> Int32? {
    guard let fd = connectSocket(controlSocketPath) else { return nil }
    guard writeAll(fd, identifyLine) else {
        close(fd)
        return nil
    }
    return fd
}

func closeControl() {
    if let control { close(control) }
    control = nil
}

/// Sends a phone line to the socket it belongs to. False when the line could
/// not be delivered and the session must end.
func route(_ line: Data) -> Bool {
    guard attachedToBridge, frameType(line) == "session_command" else { return writeAll(sock, line) }
    if control == nil { control = openControl() }
    if let fd = control, writeAll(fd, line) { return true }
    closeControl()
    return writeAll(STDOUT_FILENO, jsonLine([
        "type": "error",
        "code": "app_unavailable",
        "message": "Relay Runner is not running, so this session cannot be started or stopped from the phone",
    ]))
}

// MARK: - Copy loop

func readChunk(_ fd: Int32) -> Data? {
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return nil }
        return Data(chunk[0..<n])
    }
}

var fromClient = LineBuffer()
var fromBridge = LineBuffer()
var fromControl = LineBuffer()
var clientOpen = !wantsStatus

while true {
    var fds = [pollfd(fd: sock, events: Int16(POLLIN), revents: 0)]
    let clientIndex = clientOpen ? fds.count : nil
    if clientOpen { fds.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)) }
    let controlIndex = control.map { _ in fds.count }
    if let control { fds.append(pollfd(fd: control, events: Int16(POLLIN), revents: 0)) }
    if poll(&fds, nfds_t(fds.count), -1) < 0 {
        if errno == EINTR { continue }
        exit(1)
    }
    let ready = Int16(POLLIN | POLLHUP | POLLERR)
    if fds[0].revents & ready != 0 {
        guard let chunk = readChunk(sock) else {
            if wantsStatus { fail("bridge_unavailable", "Relay Runner closed the connection", exitCode: 1) }
            exit(0)
        }
        let (lines, violation) = fromBridge.feed(chunk)
        for line in lines {
            var out = line
            out.append(0x0A)
            if !writeAll(STDOUT_FILENO, out) { exit(0) }
            if wantsStatus { exit(0) }
        }
        if let violation { violationExit(violation) }
    }
    if let clientIndex, fds[clientIndex].revents & ready != 0 {
        guard let chunk = readChunk(STDIN_FILENO) else { exit(0) }
        let (lines, violation) = fromClient.feed(chunk)
        for line in lines {
            var out = line
            out.append(0x0A)
            if !route(out) { exit(0) }
        }
        if let violation { violationExit(violation) }
    }
    if let controlIndex, let fd = control, fds[controlIndex].revents & ready != 0 {
        // The app closing its side ends only the control link, not the bridge session.
        guard let chunk = readChunk(fd) else {
            closeControl()
            fromControl = LineBuffer()
            continue
        }
        let (lines, violation) = fromControl.feed(chunk)
        for line in lines {
            var out = line
            out.append(0x0A)
            if !writeAll(STDOUT_FILENO, out) { exit(0) }
        }
        if let violation { violationExit(violation) }
    }
}
