import CryptoKit
import XCTest
@testable import relay_runner

/// `authorized_keys` writer tests against a temporary HOME. Every key is
/// generated at test time.
final class RelayRemoteAuthorizedKeysTests: XCTestCase {
    private var home: URL!
    private var file: AuthorizedKeysFile!
    private let shim = URL(fileURLWithPath: "/Users/test/Library/Application Support/relay-runner/bin/relay-remote-shell")

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("rr-keys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        file = AuthorizedKeysFile(home: home)
    }

    override func tearDownWithError() throws {
        chmod(file.sshDirectory.path, 0o700)
        try? FileManager.default.removeItem(at: home)
    }

    private func ed25519Key() -> SSHPublicKey {
        SSHPublicKey(ed25519: Curve25519.Signing.PrivateKey().publicKey)
    }

    private func p256Key() -> SSHPublicKey {
        let point = P256.Signing.PrivateKey().publicKey.x963Representation
        var blob = Data()
        blob.appendSSHString(Data("ecdsa-sha2-nistp256".utf8))
        blob.appendSSHString(Data("nistp256".utf8))
        blob.appendSSHString(point)
        return SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 \(blob.base64EncodedString())")!
    }

    private func deviceLine(_ id: String, key: SSHPublicKey? = nil) throws -> String {
        try RelayRemoteKeyLine.device(shim: shim, deviceID: id, key: key ?? p256Key())
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    private func contents() -> Data {
        FileManager.default.contents(atPath: file.fileURL.path) ?? Data()
    }

    private func writeForeign(_ text: String, mode fileMode: mode_t = 0o600) throws {
        try FileManager.default.createDirectory(at: file.sshDirectory, withIntermediateDirectories: true)
        chmod(file.sshDirectory.path, 0o700)
        try Data(text.utf8).write(to: file.fileURL)
        chmod(file.fileURL.path, fileMode)
    }

    // A mix of real-world shapes: comments, blank lines, options with quoted
    // spaces, CRLF, a foreign comment mentioning the marker mid-line.
    private let foreign = """
    # personal keys
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOf00000000000000000000000000000000000000000 me@laptop

    command="/usr/bin/backup --run",no-pty ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ backup\r
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBar00000000000000000000000000000000000000000 relay-remote:dev1 not-ours
    # ssh-ed25519 AAAA relay-remote:dev1

    """

    func testMissingSSHDirectoryIsCreatedWithStrictModes() throws {
        umask(0o022)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.sshDirectory.path))
        try file.replace([.device("dev1")], with: [deviceLine("dev1")])
        XCTAssertEqual(mode(file.sshDirectory), 0o700)
        XCTAssertEqual(mode(file.fileURL), 0o600)
        XCTAssertEqual(try file.deviceKeys().map(\.deviceID), ["dev1"])
    }

    func testRemovingFromMissingFileCreatesNothing() throws {
        try file.replace([.device("dev1")], with: [])
        try file.removeAllPairingLines()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.sshDirectory.path))
    }

    func testRewriteIsIdempotent() throws {
        try writeForeign(foreign)
        let line = try deviceLine("dev1")
        try file.replace([.device("dev1")], with: [line])
        let first = contents()
        var before = stat()
        lstat(file.fileURL.path, &before)

        try file.replace([.device("dev1")], with: [line])
        var after = stat()
        lstat(file.fileURL.path, &after)
        XCTAssertEqual(contents(), first)
        XCTAssertEqual(before.st_ino, after.st_ino, "an unchanged result is not rewritten")
        XCTAssertEqual(try file.deviceKeys().count, 1)
    }

    func testForeignLinesArePreservedByteForByte() throws {
        try writeForeign(foreign, mode: 0o644)
        let original = contents()

        try file.replace([.device("dev2")], with: [deviceLine("dev2")])
        let withDevice = contents()
        XCTAssertTrue(withDevice.starts(with: original), "foreign bytes come first, unchanged")
        XCTAssertEqual(mode(file.fileURL), 0o644, "an existing safe mode is kept")

        try file.replace([.device("dev2")], with: [])
        XCTAssertEqual(contents(), original)
    }

    func testFileWithoutTrailingNewlineKeepsItsBytes() throws {
        try writeForeign("ssh-ed25519 AAAA one\nssh-ed25519 AAAA two")
        try file.replace([.device("dev1")], with: [deviceLine("dev1")])
        let text = String(decoding: contents(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("ssh-ed25519 AAAA one\nssh-ed25519 AAAA two\n"))
        XCTAssertTrue(text.hasSuffix(" relay-remote:dev1\n"))
    }

    func testReplacementStaysInPlace() throws {
        try writeForeign("first\n")
        try file.replace([.device("a")], with: [deviceLine("a")])
        try file.replace([.device("b")], with: [deviceLine("b")])
        let replacement = try deviceLine("a")
        try file.replace([.device("a")], with: [replacement])
        let lines = String(decoding: contents(), as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "first")
        XCTAssertEqual(lines[1], replacement)
        XCTAssertTrue(lines[2].hasSuffix("relay-remote:b"))
    }

    func testUnpairRemovesOnlyThatDevice() throws {
        try writeForeign(foreign)
        let original = contents()
        try file.replace([.device("dev1")], with: [deviceLine("dev1")])
        try file.replace([.device("dev10")], with: [deviceLine("dev10")])
        try file.replace([.device("dev2")], with: [deviceLine("dev2")])

        try file.replace([.device("dev1")], with: [])

        XCTAssertEqual(try file.deviceKeys().map(\.deviceID), ["dev10", "dev2"])
        let text = String(decoding: contents(), as: UTF8.self)
        XCTAssertTrue(contents().starts(with: original), "foreign lines, including ones naming dev1 mid-line, stay")
        XCTAssertFalse(text.hasSuffix("relay-remote:dev1\n"))
    }

    func testDirectoryWritableByOthersIsRefusedAndLeftAlone() throws {
        try writeForeign(foreign)
        chmod(file.sshDirectory.path, 0o775)
        XCTAssertThrowsError(try file.replace([.device("dev1")], with: [deviceLine("dev1")])) { error in
            XCTAssertEqual(error as? AuthorizedKeysError, .unsafeDirectory(path: file.sshDirectory.path))
        }
        XCTAssertEqual(mode(file.sshDirectory), 0o775, "permissions are surfaced, not fixed")
        XCTAssertEqual(contents(), Data(foreign.utf8))
    }

    func testFileWritableByOthersIsRefusedAndLeftAlone() throws {
        try writeForeign(foreign, mode: 0o664)
        XCTAssertThrowsError(try file.replace([.device("dev1")], with: [deviceLine("dev1")])) { error in
            XCTAssertEqual(error as? AuthorizedKeysError, .unsafeFile(path: file.fileURL.path))
        }
        XCTAssertThrowsError(try file.deviceKeys())
        XCTAssertEqual(mode(file.fileURL), 0o664)
        XCTAssertEqual(contents(), Data(foreign.utf8))
    }

    func testSymlinkedFileIsRefused() throws {
        try FileManager.default.createDirectory(at: file.sshDirectory, withIntermediateDirectories: true)
        chmod(file.sshDirectory.path, 0o700)
        let target = home.appendingPathComponent("keys")
        try Data(foreign.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file.fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try file.replace([.device("dev1")], with: [deviceLine("dev1")]))
        XCTAssertEqual(FileManager.default.contents(atPath: target.path), Data(foreign.utf8))
    }

    func testPairingLinesAreScopedAndRemovable() throws {
        try writeForeign(foreign)
        let pairing = try RelayRemoteKeyLine.pairing(
            shim: shim,
            pairingID: "p1",
            key: ed25519Key(),
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertTrue(pairing.hasPrefix(
            "command=\"'\(shim.path)' --pair p1\",restrict,expiry-time=\"20270115080000Z\" ssh-ed25519 "
        ))
        try file.replace([.pairing("p1")], with: [pairing])
        try file.replace([.device("dev1")], with: [deviceLine("dev1")])
        try file.removeAllPairingLines()
        let text = String(decoding: contents(), as: UTF8.self)
        XCTAssertFalse(text.contains("relay-remote-pair:"))
        XCTAssertEqual(try file.deviceKeys().map(\.deviceID), ["dev1"])
    }

    func testDeviceLineFormat() throws {
        let key = p256Key()
        let line = try RelayRemoteKeyLine.device(shim: shim, deviceID: "dev1", key: key, fromRanges: ["192.168.1.0/24", "100.64.0.0/10"])
        XCTAssertEqual(
            line,
            "command=\"'\(shim.path)' --device dev1\",restrict,from=\"192.168.1.0/24,100.64.0.0/10\" \(key.openSSH) relay-remote:dev1"
        )
        XCTAssertThrowsError(try RelayRemoteKeyLine.device(shim: shim, deviceID: "dev 1", key: key))
        XCTAssertThrowsError(try RelayRemoteKeyLine.device(shim: shim, deviceID: "dev1", key: key, fromRanges: ["*"]))
        XCTAssertThrowsError(try RelayRemoteKeyLine.device(shim: URL(fileURLWithPath: "/tmp/it's"), deviceID: "dev1", key: key))
    }

    func testPublicKeyParsingRejectsMalformedKeys() {
        let key = ed25519Key()
        XCTAssertEqual(SSHPublicKey(openSSH: key.openSSH + " comment"), key)
        XCTAssertNil(SSHPublicKey(openSSH: "ssh-rsa \(key.blob.base64EncodedString())"))
        XCTAssertNil(SSHPublicKey(openSSH: "ecdsa-sha2-nistp256 \(key.blob.base64EncodedString())"))
        XCTAssertNil(SSHPublicKey(openSSH: "ssh-ed25519 \(key.blob.dropLast().base64EncodedString())"))
        XCTAssertNil(SSHPublicKey(openSSH: "ssh-ed25519 not-base64"))
        XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
        XCTAssertFalse(key.fingerprint.hasSuffix("="))
    }

    func testShimExecsTheBundledHelper() throws {
        let shimURL = home.appendingPathComponent("Application Support/relay-runner/bin/relay-remote-shell")
        let helper = URL(fileURLWithPath: "/Applications/Relay Runner's.app/Contents/MacOS/relay-remote-shell")
        try RelayRemoteShim.install(helper: helper, at: shimURL)
        XCTAssertEqual(mode(shimURL), 0o755)
        let script = try String(contentsOf: shimURL, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("exec '/Applications/Relay Runner'\\''s.app/Contents/MacOS/relay-remote-shell' \"$@\"\n"))

        let moved = URL(fileURLWithPath: "/Users/test/Applications/Relay Runner.app/Contents/MacOS/relay-remote-shell")
        try RelayRemoteShim.install(helper: moved, at: shimURL)
        XCTAssertTrue(try String(contentsOf: shimURL, encoding: .utf8).contains(moved.path))
    }
}
