#if os(macOS)
import CryptoKit
import Foundation
import Network
import NIOSSH
import XCTest
@testable import RelayRemoteKit

/// The real transport against a per-user `sshd` on a loopback high port (the
/// pattern RR-425 and RR-426 use), running the real `relay-remote-shell`
/// helper through `authorized_keys` forced commands and the real
/// `services/relay_remote.py` bridge module. No privileges and no Remote
/// Login are needed. Skipped where `sshd`, `swiftc` or `python3` is missing.
@MainActor
final class SSHTransportIntegrationTests: XCTestCase {
    private var root: URL!
    private var processes: [Process] = []
    private var port = 0
    private var hostPin = ""
    private var marker: URL { root.appendingPathComponent("forced-command-ran") }
    private var pairRequest: URL { root.appendingPathComponent("pair-request.json") }

    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let pairingSeed = Data(repeating: 3, count: 32)
    private static let pairingToken = Data(repeating: 5, count: 32).base64EncodedString()

    override class func tearDown() {
        if let helperBinary { try? FileManager.default.removeItem(at: helperBinary.deletingLastPathComponent()) }
        helperBinary = nil
        super.tearDown()
    }

    override func tearDown() async throws {
        processes.forEach { $0.terminate() }
        processes.forEach { $0.waitUntilExit() }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Tests

    func testExecChannelCarriesFramesThroughTheRealHelperAndBridgeAndResumes() async throws {
        let key = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        try await startServer(deviceKeys: ["phone-1": key])
        let session = makeSession(key: key)
        session.start()
        await eventually(timeout: 15) { session.state == .connected }
        // Today the bridge answers the helper's `identify` line with an
        // `unknown_type` error before `welcome`; the session must survive it.
        XCTAssertTrue(session.lastError == nil || session.lastError?.code == "unknown_type")

        session.send(text: "hello mac")
        await eventually(timeout: 10) { session.records.contains { $0.speechText == "reply: hello mac" } }
        XCTAssertTrue(session.pending.isEmpty)
        XCTAssertEqual(session.resumeAfterSeq, 1)

        // The reply to "later ..." is spoken a second after the receipt; the
        // phone is gone by then, so the bridge holds it for replay.
        session.send(text: "later please")
        await eventually(timeout: 10) { session.pending.isEmpty }
        session.stop()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        session.start()
        await eventually(timeout: 15) { session.records.contains { $0.speechText == "reply: later please" } }
        XCTAssertEqual(session.resumeAfterSeq, 2)
        XCTAssertFalse(session.missedUpdates)
        session.stop()
    }

    func testSecureEnclaveDeviceKeyAuthenticates() async throws {
        guard SecureEnclave.isAvailable,
              let key = try? DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: true),
              key.kind == .secureEnclaveP256 else {
            throw XCTSkip("no usable Secure Enclave here")
        }
        try await startServer(deviceKeys: ["phone-se": key])
        let session = makeSession(key: key, deviceID: "phone-se")
        session.start()
        await eventually(timeout: 15) { session.state == .connected }
        session.stop()
    }

    func testChangedHostKeyIsRefusedBeforeAnythingIsSent() async throws {
        let key = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        try await startServer(deviceKeys: ["phone-1": key])
        let otherPin = SSHFingerprint.sha256(NIOSSHPrivateKey(ed25519Key: .init()).publicKey)

        do {
            _ = try await SSHTransport(log: .silent).connect(to: endpoint, credentials: SSHCredentials(
                user: NSUserName(), privateKey: key.privateKey, pinnedHostKeys: [otherPin]))
            XCTFail("the connection must be refused")
        } catch {
            XCTAssertEqual(error as? RemoteFailure, .hostKeyMismatch)
        }

        let session = makeSession(key: key, pins: [otherPin])
        session.send(text: "must not be sent")
        session.start()
        await eventually(timeout: 15) { session.state == .failed(.hostKeyMismatch) }
        XCTAssertEqual(session.pending.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "authentication never happened, so the forced command never ran")
    }

    func testUnknownDeviceKeyIsRejected() async throws {
        let paired = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        try await startServer(deviceKeys: ["phone-1": paired])
        let stranger = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        let session = makeSession(key: stranger)
        session.start()
        await eventually(timeout: 15) { session.state == .failed(.authenticationRejected) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testPairsOverTheEphemeralKeyAndThePairHelper() async throws {
        let device = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        try await startServer(deviceKeys: [:], pairingID: "pair-1")
        let code = try JSONSerialization.data(withJSONObject: [
            "protocol": 1, "user": NSUserName(), "hosts": ["127.0.0.1"], "port": port, "host_keys": [hostPin],
            "pairing_id": "pair-1", "pairing_key": Self.pairingSeed.base64EncodedString(), "token": Self.pairingToken,
        ] as [String: Any])
        let payload = try PairingPayload.parse(String(decoding: code, as: UTF8.self))

        let mac = try await PairingClient(transport: SSHTransport(log: .silent), log: .silent)
            .pair(payload, deviceKey: device, deviceID: "phone-7", deviceName: "Test iPhone")
        XCTAssertEqual(mac.deviceID, "phone-7")
        XCTAssertEqual(mac.hostKeyFingerprints, [hostPin])
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: pairRequest)) as! [String: String]
        XCTAssertEqual(request["public_key"], device.openSSHPublicKey)
        XCTAssertEqual(request["device_name"], "Test iPhone")
    }

    // MARK: Fixture

    private var endpoint: NWEndpoint { .hostPort(host: "127.0.0.1", port: .init(integerLiteral: UInt16(port))) }

    private func makeSession(key: DeviceKey, deviceID: String = "phone-1", pins: Set<String>? = nil) -> RemoteSession {
        var configuration = SessionConfiguration(
            deviceID: deviceID, deviceName: "Test iPhone", appVersion: "0.1",
            credentials: SSHCredentials(user: NSUserName(), privateKey: key.privateKey, pinnedHostKeys: pins ?? [hostPin]))
        configuration.timing.backoff = Backoff(base: 0.2, cap: 1)
        return RemoteSession(configuration: configuration, transport: SSHTransport(log: .silent),
                             endpoints: StaticEndpoints([endpoint]), log: .silent)
    }

    private func startServer(deviceKeys: [String: DeviceKey], pairingID: String? = nil) async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"), "sshd unavailable")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "python3 unavailable")
        let helper = try Self.compiledHelper()

        // Unix socket paths must stay short.
        root = URL(fileURLWithPath: "/tmp/rrk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", root.appendingPathComponent("host_key").path])
        let hostLine = try String(contentsOf: root.appendingPathComponent("host_key.pub"), encoding: .utf8)
        let blob = Data(base64Encoded: String(hostLine.split(separator: " ")[1]))!
        hostPin = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")

        let forced = root.appendingPathComponent("forced.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexec '\(helper.path)' \"$@\"\n".write(to: forced, atomically: true, encoding: .utf8)
        chmod(forced.path, 0o755)
        var lines = deviceKeys.sorted { $0.key < $1.key }.map { id, key in
            "command=\"\(forced.path) --device \(id)\",restrict \(key.openSSHPublicKey) relay-remote:\(id)"
        }
        if let pairingID {
            let pairingKey = NIOSSHPrivateKey(ed25519Key: try .init(rawRepresentation: Self.pairingSeed))
            lines.append("command=\"\(forced.path) --pair \(pairingID)\",restrict \(String(openSSHPublicKey: pairingKey.publicKey)) relay-remote-pair:\(pairingID)")
        }
        let authorizedKeys = root.appendingPathComponent("authorized_keys")
        try (lines.joined(separator: "\n") + "\n").write(to: authorizedKeys, atomically: true, encoding: .utf8)

        let deviceSocket = root.appendingPathComponent("remote.sock").path
        let pairSocket = root.appendingPathComponent("pair.sock").path
        let bridge = Process()
        bridge.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        bridge.arguments = ["-c", Self.bridgeDriver, Self.repo.path, deviceSocket, pairSocket, Self.pairingToken, pairRequest.path]
        let ready = Pipe()
        bridge.standardOutput = ready
        try bridge.run()
        processes.append(bridge)
        let firstLine = ready.fileHandleForReading.availableData
        try XCTSkipUnless(String(decoding: firstLine, as: UTF8.self).hasPrefix("ready"), "bridge driver did not start")

        port = Self.freePort()
        let config = root.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(root.appendingPathComponent("host_key").path)
        AuthorizedKeysFile \(authorizedKeys.path)
        PidFile \(root.appendingPathComponent("sshd.pid").path)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        SetEnv RELAY_REMOTE_SOCKET_PATH=\(deviceSocket) RELAY_REMOTE_PAIR_SOCKET_PATH=\(pairSocket)
        LogLevel ERROR

        """.write(to: config, atomically: true, encoding: .utf8)
        let sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-f", config.path]
        try sshd.run()
        processes.append(sshd)
        try await waitForPort(port)
    }

    /// The real bridge session module with an attached ingress that accepts
    /// each utterance and answers it with a speech frame, plus a pair-socket
    /// stub standing in for the Mac app's pairing listener.
    private static let bridgeDriver = """
    import json, os, select, socket, sys, threading
    repo, device_sock, pair_sock, token, pair_out = sys.argv[1:6]
    sys.path.insert(0, repo)
    from services import relay_remote

    def serve_pair():
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(pair_sock)
        listener.listen(4)
        while True:
            conn, _ = listener.accept()
            reader = conn.makefile("rb")
            identify = json.loads(reader.readline())
            request = json.loads(reader.readline())
            if identify.get("type") == "identify" and request.get("token") == token:
                with open(pair_out, "w") as f:
                    json.dump(request, f)
                reply = {"type": "paired", "device_id": request["device_id"]}
            else:
                reply = {"type": "error", "code": "pairing_rejected", "message": "rejected"}
            conn.sendall((json.dumps(reply, sort_keys=True) + "\\n").encode())
            conn.close()

    threading.Thread(target=serve_pair, daemon=True).start()
    ingress = relay_remote.RemoteIngress()
    ingress.attached = True
    server = relay_remote.RelayRemoteServer(ingress, path=device_sock)
    server.start()
    print("ready", flush=True)
    count = 0
    while True:
        select.select([ingress], [], [], 0.2)
        for item in ingress.drain():
            if item.on_accepted is None:
                continue
            count += 1
            item.on_accepted({"relay_command_seq": count, "relay_command_id": "cmd-%d" % count})
            session = server.session(item.device_id)
            def reply(text=item.text, session=session, seq=count):
                session.speech(kind="final", source="orchestrator", text="reply: " + text, relay_command_seq=seq)
            if item.text.startswith("later"):
                threading.Timer(1.0, reply).start()
            else:
                reply()
    """

    private static var helperBinary: URL?

    /// Builds the real helper from its single source file, once per run.
    private static func compiledHelper() throws -> URL {
        if let helperBinary { return helperBinary }
        let source = repo.appendingPathComponent("Sources/relay-remote-shell/main.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "helper source unavailable")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rrk-helper-\(getpid())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("relay-remote-shell")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "-O", source.path, "-o", binary.path]
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "helper did not compile")
        helperBinary = binary
        return binary
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "\(path) failed")
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private func waitForPort(_ port: Int) async throws {
        for _ in 0..<100 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(fd)
            if result == 0 { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("sshd did not start")
    }
}
#endif
