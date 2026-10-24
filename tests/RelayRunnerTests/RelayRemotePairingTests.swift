import CryptoKit
import XCTest
@testable import relay_runner

/// Pairing against a temporary HOME and Application Support. The phone side
/// is scripted; every key is generated at test time.
final class RelayRemotePairingTests: XCTestCase {
    private var root: URL!
    private var environment: RelayRemoteEnvironment!
    private let logs = LockedLog()

    final class LockedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        func append(_ message: String) { lock.withLock { messages.append(message) } }
        var all: [String] { lock.withLock { messages } }
    }

    actor Outcomes {
        var values: [RelayRemotePairingOutcome] = []
        func append(_ outcome: RelayRemotePairingOutcome) { values.append(outcome) }
    }

    override func setUpWithError() throws {
        // Short path: the pair socket must fit in sockaddr_un.
        root = URL(fileURLWithPath: "/tmp/rrp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("Application Support/relay-runner", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let logs = self.logs
        environment = RelayRemoteEnvironment(
            home: home,
            supportDirectory: support,
            pairSocketPath: root.appendingPathComponent("pair.sock").path,
            hostKeyDirectory: root,
            sshPort: 22,
            userName: NSUserName(),
            log: { logs.append($0) }
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(
        decision: RelayRemotePairingDecision,
        outcomes: Outcomes,
        seen: (@Sendable (RelayRemotePairingRequest) -> Void)? = nil
    ) -> RelayRemotePairingSession {
        RelayRemotePairingSession(
            environment: environment,
            hostCandidates: { ["mac.local", "192.168.1.5"] },
            networkRanges: { ["192.168.1.0/24", "100.64.0.0/10"] },
            confirm: { request in
                seen?(request)
                return decision
            },
            onFinish: { await outcomes.append($0) }
        )
    }

    private func phoneKey() -> SSHPublicKey {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        var blob = Data()
        blob.appendSSHString(Data("ecdsa-sha2-nistp256".utf8))
        blob.appendSSHString(Data("nistp256".utf8))
        blob.appendSSHString(point)
        return SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 \(blob.base64EncodedString())")!
    }

    private func pairFrame(token: String, deviceID: String, key: SSHPublicKey) -> String {
        let object: [String: String] = [
            "type": "pair", "token": token, "device_id": deviceID,
            "device_name": "Test iPhone", "public_key": key.openSSH,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Plays the `--pair` helper: identify, then the phone's frame, then the reply.
    private func sendThroughPairSocket(_ lines: [String]) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in environment.pairSocketPath.utf8.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw NSError(domain: "connect", code: Int(errno)) }
        let out = Data((lines.joined(separator: "\n") + "\n").utf8)
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, out.count) }
        var reply = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != 0x0A { reply.append(byte) }
        return String(decoding: reply, as: UTF8.self)
    }

    private func authorizedKeys() -> String {
        String(decoding: FileManager.default.contents(atPath: environment.authorizedKeys.fileURL.path) ?? Data(), as: UTF8.self)
    }

    private func assertNoSecretsLeaked(_ payload: RelayRemotePairingPayload, file: StaticString = #filePath, line: UInt = #line) throws {
        let secrets = [payload.pairingKey, payload.token, String(decoding: payload.encoded(), as: UTF8.self)]
        for message in logs.all {
            for secret in secrets {
                XCTAssertFalse(message.contains(secret), "log line carries pairing secret", file: file, line: line)
            }
        }
        let enumerator = FileManager.default.enumerator(at: environment.supportDirectory, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator {
            guard let data = FileManager.default.contents(atPath: url.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for secret in secrets {
                XCTAssertFalse(text.contains(secret), "\(url.lastPathComponent) carries pairing secret", file: file, line: line)
            }
            XCTAssertNil(data.range(of: Data(base64Encoded: payload.pairingKey)!), file: file, line: line)
        }
        XCTAssertFalse(String(describing: payload).contains(payload.token))
        XCTAssertFalse(String(reflecting: payload).contains(payload.pairingKey))
        var dumped = ""
        dump(payload, to: &dumped)
        XCTAssertFalse(dumped.contains(payload.token))
        XCTAssertFalse(dumped.contains(payload.pairingKey))
    }

    func testAllowedPairingWritesOnePermanentLineAndRemovesThePairingLine() async throws {
        let outcomes = Outcomes()
        let session = makeSession(decision: .allow(restrictToNetwork: true), outcomes: outcomes)
        let payload = try await session.start()

        XCTAssertEqual(payload.pairingKey.count, 44)
        XCTAssertTrue(authorizedKeys().contains("relay-remote-pair:\(payload.pairingID)"))
        XCTAssertTrue(authorizedKeys().contains("--pair \(payload.pairingID)\",restrict,expiry-time=\""))
        let socketInfo = try FileManager.default.attributesOfItem(atPath: environment.pairSocketPath)
        XCTAssertEqual((socketInfo[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let key = phoneKey()
        let reply = try sendThroughPairSocket([
            #"{"type":"identify","pairing_id":"\#(payload.pairingID)"}"#,
            pairFrame(token: payload.token, deviceID: "phone-1", key: key),
        ])
        XCTAssertEqual(reply, #"{"device_id":"phone-1","type":"paired"}"#)

        let lines = authorizedKeys().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "command=\"'\(environment.shimURL.path)' --device phone-1\",restrict,from=\"192.168.1.0/24,100.64.0.0/10\" \(key.openSSH) relay-remote:phone-1",
        ])
        let outcome = await outcomes.values
        XCTAssertEqual(outcome, [.paired(deviceName: "Test iPhone")])
        XCTAssertEqual(RelayRemoteDeviceNames.load(environment: environment), ["phone-1": "Test iPhone"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.pairSocketPath))
        try assertNoSecretsLeaked(payload)
    }

    func testWrongTokenIsRejectedWithoutConsumingTheCode() async throws {
        let outcomes = Outcomes()
        let session = makeSession(decision: .allow(restrictToNetwork: false), outcomes: outcomes)
        let payload = try await session.start()
        let key = phoneKey()

        let wrong = Data(repeating: 7, count: 32).base64EncodedString()
        let rejected = try sendThroughPairSocket([
            #"{"type":"identify","pairing_id":"\#(payload.pairingID)"}"#,
            pairFrame(token: wrong, deviceID: "phone-1", key: key),
        ])
        XCTAssertTrue(rejected.contains(#""code":"pairing_rejected""#))
        let otherID = try sendThroughPairSocket([
            #"{"type":"identify","pairing_id":"someone-else"}"#,
            pairFrame(token: payload.token, deviceID: "phone-1", key: key),
        ])
        XCTAssertTrue(otherID.contains(#""code":"pairing_rejected""#))
        XCTAssertTrue(authorizedKeys().contains("relay-remote-pair:"))

        let accepted = try sendThroughPairSocket([
            #"{"type":"identify","pairing_id":"\#(payload.pairingID)"}"#,
            pairFrame(token: payload.token, deviceID: "phone-1", key: key),
        ])
        XCTAssertTrue(accepted.contains(#""type":"paired""#))
        XCTAssertFalse(authorizedKeys().contains("from="))
        try assertNoSecretsLeaked(payload)
    }

    func testDeniedPairingLeavesNoLines() async throws {
        let outcomes = Outcomes()
        let session = makeSession(decision: .deny, outcomes: outcomes)
        let payload = try await session.start()
        let reply = try sendThroughPairSocket([
            #"{"type":"identify","pairing_id":"\#(payload.pairingID)"}"#,
            pairFrame(token: payload.token, deviceID: "phone-1", key: phoneKey()),
        ])
        XCTAssertTrue(reply.contains(#""code":"pairing_denied""#))
        XCTAssertEqual(authorizedKeys(), "")
        let outcome = await outcomes.values
        XCTAssertEqual(outcome, [.denied])
    }

    func testCancelRemovesThePairingLine() async throws {
        let outcomes = Outcomes()
        let session = makeSession(decision: .deny, outcomes: outcomes)
        _ = try await session.start()
        await session.cancel()
        XCTAssertEqual(authorizedKeys(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.pairSocketPath))
        let outcome = await outcomes.values
        XCTAssertEqual(outcome, [.cancelled])
    }

    func testInvalidDeviceDetailsAreRejected() async throws {
        let outcomes = Outcomes()
        let session = makeSession(decision: .allow(restrictToNetwork: false), outcomes: outcomes)
        let payload = try await session.start()
        let reply = try sendThroughPairSocket([
            #"{"type":"identify","pairing_id":"\#(payload.pairingID)"}"#,
            pairFrame(token: payload.token, deviceID: "../phone", key: phoneKey()),
        ])
        XCTAssertTrue(reply.contains(#""code":"invalid_pair_request""#))
        XCTAssertFalse(authorizedKeys().contains("relay-remote:"))
        await session.cancel()
    }

    func testDisplayNameDropsControlCharacters() {
        XCTAssertEqual(RelayRemotePairingSession.displayName("  Matt's\u{1B}[31m iPhone\n"), "Matt's[31m iPhone")
        XCTAssertNil(RelayRemotePairingSession.displayName("\n\t"))
        XCTAssertEqual(RelayRemotePairingSession.displayName(String(repeating: "a", count: 100))?.count, 64)
    }

    // MARK: Remote Login hint

    func testRemoteLoginHintAppearsWhenTheBannerProbeFails() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        // Bound but not listening: nothing answers, like Remote Login being off.
        environment.sshPort = port
        let controller = await RelayRemoteController(environment: environment)
        await controller.refresh()
        let state = await controller.remoteLogin
        XCTAssertEqual(state, .unavailable)
        let hint = RelayRemoteLoginPresentation.resolve(state)
        XCTAssertTrue(hint.showsSettingsLink)
        XCTAssertTrue(hint.description.contains("key authentication only"))
        XCTAssertFalse(RelayRemoteLoginPresentation.resolve(.available).showsSettingsLink)
    }

    func testBannerProbeRecognisesAnSSHServer() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        DispatchQueue.global().async {
            let connection = accept(listener, nil, nil)
            let banner = "SSH-2.0-OpenSSH_10.3\r\n"
            _ = banner.withCString { write(connection, $0, strlen($0)) }
            usleep(200_000)
            close(connection)
        }
        XCTAssertTrue(RemoteLoginProbe.hasSSHBanner(port: port))
    }

    func testSettingsSectionUsesRelayMotion() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/relay-runner/Settings/RelayRemoteSettingsTab.swift"),
            encoding: .utf8
        )
        // Swaps go through RelaySwap so the outgoing state leaves before the next arrives.
        XCTAssertTrue(source.contains("RelaySwap(controller.remoteLogin, style: .text"))
        XCTAssertTrue(source.contains("RelaySwap(controller.phase"))
        XCTAssertTrue(source.contains(".transition(.relayElement)"))
        XCTAssertTrue(source.contains(".transition(.relayText)"))
        XCTAssertTrue(source.contains("RelayMotion.change(reduceMotion: reduceMotion), value: controller.devices"))
        for banned in [".sheet(", ".transition(.opacity", ".transition(.move", ".transition(.slide", "withAnimation(.default", ".spring("] {
            XCTAssertFalse(source.contains(banned), banned)
        }
    }

    // MARK: End to end over sshd

    /// A per-user sshd on a high loopback port (as in RR-425's script) runs the
    /// real helper through the installed shim; a scripted phone pairs with the
    /// QR payload, then authenticates with its own key only.
    func testScriptedPhonePairsOverTemporarySSHD() async throws {
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("relay-remote-shell")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "relay-remote-shell not built")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd"), "sshd unavailable")

        try RelayRemoteShim.install(helper: helper, at: environment.shimURL)
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", root.appendingPathComponent("ssh_host_ed25519_key").path])
        let phoneKeyPath = root.appendingPathComponent("phone_key").path
        try run("/usr/bin/ssh-keygen", ["-q", "-t", "ecdsa", "-b", "256", "-N", "", "-f", phoneKeyPath])
        let phonePublic = SSHPublicKey(openSSH: try String(contentsOfFile: phoneKeyPath + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        let hostPublic = try String(contentsOf: root.appendingPathComponent("ssh_host_ed25519_key.pub"), encoding: .utf8)

        let port = freePort()
        environment.sshPort = port
        let outcomes = Outcomes()
        let session = makeSession(decision: .allow(restrictToNetwork: false), outcomes: outcomes)
        let payload = try await session.start()

        // The phone pins the host key from the QR payload.
        let hostFields = hostPublic.split(separator: " ")
        XCTAssertEqual(payload.hostKeys, [SSHPublicKey.fingerprint(of: Data(base64Encoded: String(hostFields[1]))!)])
        let knownHosts = root.appendingPathComponent("known_hosts")
        try "[127.0.0.1]:\(port) \(hostFields[0]) \(hostFields[1])\n".write(to: knownHosts, atomically: true, encoding: .utf8)

        let pairingKeyPath = root.appendingPathComponent("pairing_key")
        try Self.openSSHPrivateKey(seed: Data(base64Encoded: payload.pairingKey)!)
            .write(to: pairingKeyPath, atomically: true, encoding: .utf8)
        chmod(pairingKeyPath.path, 0o600)

        let config = root.appendingPathComponent("sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(root.appendingPathComponent("ssh_host_ed25519_key").path)
        AuthorizedKeysFile \(environment.authorizedKeys.fileURL.path)
        PidFile \(root.appendingPathComponent("sshd.pid").path)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        SetEnv RELAY_REMOTE_PAIR_SOCKET_PATH=\(environment.pairSocketPath) RELAY_REMOTE_SOCKET_PATH=\(root.appendingPathComponent("none.sock").path)
        LogLevel ERROR

        """.write(to: config, atomically: true, encoding: .utf8)
        let sshd = Process()
        sshd.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        sshd.arguments = ["-D", "-f", config.path]
        try sshd.run()
        defer { sshd.terminate() }
        try waitForPort(port)

        func ssh(_ key: URL) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-F", "/dev/null", "-p", String(port), "-i", key.path, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(knownHosts.path)",
                "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-l", NSUserName(), "127.0.0.1",
            ]
            return process
        }

        let pairing = ssh(pairingKeyPath)
        let reply = try exchange(pairing, send: pairFrame(token: payload.token, deviceID: "phone-1", key: phonePublic))
        XCTAssertEqual(reply, #"{"device_id":"phone-1","type":"paired"}"#)

        let lines = authorizedKeys().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first, "command=\"'\(environment.shimURL.path)' --device phone-1\",restrict \(phonePublic.openSSH) relay-remote:phone-1")
        XCTAssertFalse(authorizedKeys().contains("relay-remote-pair:"))

        // The device key now runs the helper in --device mode (no bridge here).
        let device = ssh(URL(fileURLWithPath: phoneKeyPath))
        let deviceReply = try exchange(device, send: #"{"type":"ping","t":1}"#)
        XCTAssertTrue(deviceReply.contains(#""code":"bridge_unavailable""#), deviceReply)

        // The pairing key no longer authenticates.
        let reused = ssh(pairingKeyPath)
        _ = try? exchange(reused, send: "{}")
        XCTAssertEqual(reused.terminationStatus, 255)

        try assertNoSecretsLeaked(payload)
    }

    // MARK: Helpers

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func freePort() -> Int {
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

    private func waitForPort(_ port: Int) throws {
        for _ in 0..<50 {
            if RemoteLoginProbe.hasSSHBanner(port: port, timeout: 0.2) { return }
            usleep(100_000)
        }
        XCTFail("sshd did not start")
    }

    /// Sends one line on the channel, returns the first reply line, then
    /// closes stdin so the helper exits.
    private func exchange(_ process: Process, send line: String) throws -> String {
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((line + "\n").utf8))

        let received = DispatchSemaphore(value: 0)
        let buffer = LockedLog()
        DispatchQueue.global().async {
            var data = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if data.contains(0x0A) { break }
            }
            buffer.append(String(decoding: data.prefix(while: { $0 != 0x0A }), as: UTF8.self))
            received.signal()
        }
        let timedOut = received.wait(timeout: .now() + 20) == .timedOut
        try? input.fileHandleForWriting.close()
        if timedOut { process.terminate() }
        process.waitUntilExit()
        return buffer.all.first ?? ""
    }

    /// An unencrypted `openssh-key-v1` file for the scripted phone's copy of
    /// the pairing key.
    static func openSSHPrivateKey(seed: Data) throws -> String {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let publicKey = SSHPublicKey(ed25519: key.publicKey)
        var privateBlock = Data()
        let check = UInt32.random(in: 0...UInt32.max).bigEndian
        withUnsafeBytes(of: check) { privateBlock.append(contentsOf: $0) }
        withUnsafeBytes(of: check) { privateBlock.append(contentsOf: $0) }
        privateBlock.appendSSHString(Data("ssh-ed25519".utf8))
        privateBlock.appendSSHString(key.publicKey.rawRepresentation)
        privateBlock.appendSSHString(seed + key.publicKey.rawRepresentation)
        privateBlock.appendSSHString(Data())
        var pad: UInt8 = 1
        while privateBlock.count % 8 != 0 {
            privateBlock.append(pad)
            pad += 1
        }
        var body = Data("openssh-key-v1".utf8) + Data([0])
        body.appendSSHString(Data("none".utf8))
        body.appendSSHString(Data("none".utf8))
        body.appendSSHString(Data())
        withUnsafeBytes(of: UInt32(1).bigEndian) { body.append(contentsOf: $0) }
        body.appendSSHString(publicKey.blob)
        body.appendSSHString(privateBlock)
        let encoded = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(encoded)\n-----END OPENSSH PRIVATE KEY-----\n"
    }
}
