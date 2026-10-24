import CryptoKit
import Foundation

/// What the QR code carries. It holds the one-time pairing key, so it is
/// rendered once, never logged and never persisted; its descriptions and
/// mirror are redacted so it cannot leak through string interpolation.
struct RelayRemotePairingPayload: Encodable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let protocolVersion = 1
    let user: String
    let hosts: [String]
    let port: Int
    let hostKeys: [String]
    let pairingID: String
    /// Base64 of the 32-byte Ed25519 private seed.
    let pairingKey: String
    /// Base64 of the 32-byte one-time token.
    let token: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case user, hosts, port
        case hostKeys = "host_keys"
        case pairingID = "pairing_id"
        case pairingKey = "pairing_key"
        case token
    }

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    var description: String { "RelayRemotePairingPayload(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

struct RelayRemotePairingRequest: Hashable, Sendable {
    let deviceID: String
    let deviceName: String
    let publicKey: SSHPublicKey

    var fingerprint: String { publicKey.fingerprint }
}

enum RelayRemotePairingDecision: Equatable, Sendable {
    case allow(restrictToNetwork: Bool)
    case deny
}

enum RelayRemotePairingOutcome: Hashable, Sendable {
    case paired(deviceName: String)
    case denied
    case expired
    case cancelled
    case failed(String)
}

/// One pairing attempt: the ephemeral `authorized_keys` line, the
/// `/tmp/relay_remote_pair.sock` listener the `--pair` helper connects to,
/// and the permanent line written once the user allows the device.
actor RelayRemotePairingSession {
    static let lifetime: TimeInterval = 10 * 60
    private static let maxFrameBytes = 64 * 1024

    private enum State { case idle, waiting, confirming, finished }

    private let environment: RelayRemoteEnvironment
    private let hostCandidates: @Sendable () -> [String]
    private let networkRanges: @Sendable () -> [String]
    private let confirm: @Sendable (RelayRemotePairingRequest) async -> RelayRemotePairingDecision
    private let onFinish: @Sendable (RelayRemotePairingOutcome) async -> Void

    private var state = State.idle
    private var pairingID = ""
    private var token = Data()
    private var pairingPublicKey: SSHPublicKey?
    private var acceptTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    init(
        environment: RelayRemoteEnvironment,
        hostCandidates: @escaping @Sendable () -> [String] = { RelayRemoteHostInfo.hostCandidates() },
        networkRanges: @escaping @Sendable () -> [String] = { RelayRemoteHostInfo.networkRanges() },
        confirm: @escaping @Sendable (RelayRemotePairingRequest) async -> RelayRemotePairingDecision,
        onFinish: @escaping @Sendable (RelayRemotePairingOutcome) async -> Void
    ) {
        self.environment = environment
        self.hostCandidates = hostCandidates
        self.networkRanges = networkRanges
        self.confirm = confirm
        self.onFinish = onFinish
    }

    /// Installs the pairing key, starts listening, and returns the QR payload.
    func start() throws -> RelayRemotePairingPayload {
        precondition(state == .idle, "a pairing session starts once")
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = SSHPublicKey(ed25519: key.publicKey)
        pairingID = UUID().uuidString.lowercased()
        token = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        pairingPublicKey = publicKey

        let listenFD = try Self.listen(at: environment.pairSocketPath)
        do {
            let line = try RelayRemoteKeyLine.pairing(
                shim: environment.shimURL,
                pairingID: pairingID,
                key: publicKey,
                expiresAt: Date().addingTimeInterval(Self.lifetime)
            )
            try environment.authorizedKeys.replace([.pairing(pairingID)], with: [line])
        } catch {
            close(listenFD)
            unlink(environment.pairSocketPath)
            throw error
        }

        state = .waiting
        acceptTask = Task.detached { [weak self] in
            await Self.acceptLoop(listenFD: listenFD, session: self)
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
            await self?.expire()
        }
        environment.log("pairing started")

        return RelayRemotePairingPayload(
            user: environment.userName,
            hosts: hostCandidates(),
            port: environment.sshPort,
            hostKeys: RelayRemoteHostInfo.hostKeyFingerprints(directory: environment.hostKeyDirectory),
            pairingID: pairingID,
            pairingKey: key.rawRepresentation.base64EncodedString(),
            token: token.base64EncodedString()
        )
    }

    func cancel() async {
        await finish(.cancelled)
    }

    private func expire() async {
        guard state == .waiting else { return }
        await finish(.expired)
    }

    private func finish(_ outcome: RelayRemotePairingOutcome) async {
        guard state == .waiting || state == .confirming else { return }
        state = .finished
        acceptTask?.cancel()
        expiryTask?.cancel()
        unlink(environment.pairSocketPath)
        do {
            try environment.authorizedKeys.replace([.pairing(pairingID)], with: [])
        } catch {
            environment.log("pairing line removal failed: \(error.localizedDescription)")
        }
        await onFinish(outcome)
    }

    // MARK: Pair requests

    private struct PairFrame: Decodable {
        let type: String
        let token: String
        let device_id: String
        let device_name: String
        let public_key: String
    }

    /// Handles the phone's `pair` frame and returns the reply line.
    func handle(pairingID presentedID: String, frame data: Data) async -> Data {
        guard state == .waiting else {
            return Self.errorFrame("pairing_unavailable", "This pairing code is no longer active")
        }
        guard presentedID == pairingID,
              let frame = try? JSONDecoder().decode(PairFrame.self, from: data),
              frame.type == "pair",
              let presentedToken = Data(base64Encoded: frame.token),
              Self.constantTimeEqual(presentedToken, token) else {
            environment.log("pairing request rejected")
            return Self.errorFrame("pairing_rejected", "The pairing request was not accepted")
        }
        guard RelayRemoteIdentifier.isValid(frame.device_id),
              let publicKey = SSHPublicKey(openSSH: frame.public_key),
              publicKey != pairingPublicKey,
              let name = Self.displayName(frame.device_name) else {
            environment.log("pairing request invalid")
            return Self.errorFrame("invalid_pair_request", "The device id, name or key is not valid")
        }

        state = .confirming
        let decision = await confirm(RelayRemotePairingRequest(deviceID: frame.device_id, deviceName: name, publicKey: publicKey))
        guard state == .confirming else {
            return Self.errorFrame("pairing_unavailable", "Pairing was cancelled on the Mac")
        }
        switch decision {
        case .deny:
            await finish(.denied)
            return Self.errorFrame("pairing_denied", "Pairing was declined on the Mac")
        case .allow(let restrictToNetwork):
            do {
                let line = try RelayRemoteKeyLine.device(
                    shim: environment.shimURL,
                    deviceID: frame.device_id,
                    key: publicKey,
                    fromRanges: restrictToNetwork ? networkRanges() : []
                )
                try environment.authorizedKeys.replace([.pairing(pairingID), .device(frame.device_id)], with: [line])
            } catch {
                await finish(.failed(error.localizedDescription))
                return Self.errorFrame("pairing_failed", "The Mac could not save the device key")
            }
            RelayRemoteDeviceNames.set(name, for: frame.device_id, environment: environment)
            environment.log("device paired")
            await finish(.paired(deviceName: name))
            return Self.jsonLine(["type": "paired", "device_id": frame.device_id])
        }
    }

    static func displayName(_ raw: String) -> String? {
        let cleaned = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(64))
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func errorFrame(_ code: String, _ message: String) -> Data {
        jsonLine(["type": "error", "code": code, "message": message])
    }

    private static func jsonLine(_ object: [String: String]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    // MARK: Socket

    private static func listen(at path: String) throws -> Int32 {
        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AuthorizedKeysError.io(operation: "listen for", code: ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AuthorizedKeysError.io(operation: "listen for", code: errno) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, S_IRUSR | S_IWUSR) == 0, Darwin.listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw AuthorizedKeysError.io(operation: "listen for", code: code)
        }
        return fd
    }

    private static func acceptLoop(listenFD: Int32, session: RelayRemotePairingSession?) async {
        defer { close(listenFD) }
        while !Task.isCancelled {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 200) > 0 else { continue }
            let connection = accept(listenFD, nil, nil)
            guard connection >= 0 else { continue }
            Task.detached { await serve(connection, session: session) }
        }
    }

    /// Reads the helper's `identify` line and the phone's `pair` frame, then
    /// writes the reply. Only processes owned by this user may connect.
    private static func serve(_ fd: Int32, session: RelayRemotePairingSession?) async {
        defer { close(fd) }
        var uid = uid_t()
        var gid = gid_t()
        guard let session, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        guard let identifyLine = readLine(fd, buffer: &buffer),
              let identify = try? JSONSerialization.jsonObject(with: identifyLine) as? [String: Any],
              identify["type"] as? String == "identify",
              let pairingID = identify["pairing_id"] as? String,
              let frame = readLine(fd, buffer: &buffer) else { return }
        let reply = await session.handle(pairingID: pairingID, frame: frame)
        reply.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { return }
                offset += n
            }
        }
    }

    private static func readLine(_ fd: Int32, buffer: inout Data) -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return line
            }
            guard buffer.count <= maxFrameBytes else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// Display names for paired devices. `authorized_keys` stays the source of
/// truth for which devices are paired; this file only labels them.
enum RelayRemoteDeviceNames {
    static func load(environment: RelayRemoteEnvironment) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: environment.deviceNamesURL.path),
              let names = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return names
    }

    static func set(_ name: String?, for deviceID: String, environment: RelayRemoteEnvironment) {
        var names = load(environment: environment)
        names[deviceID] = name
        do {
            try FileManager.default.createDirectory(at: environment.supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(names).write(to: environment.deviceNamesURL, options: .atomic)
        } catch {
            environment.log("device name update failed: \(error.localizedDescription)")
        }
    }
}

enum RelayRemoteDevices {
    /// Removes exactly that device's `authorized_keys` lines and its label.
    static func unpair(deviceID: String, environment: RelayRemoteEnvironment) throws {
        try environment.authorizedKeys.replace([.device(deviceID)], with: [])
        RelayRemoteDeviceNames.set(nil, for: deviceID, environment: environment)
    }
}
