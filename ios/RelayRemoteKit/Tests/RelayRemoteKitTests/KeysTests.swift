import CryptoKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Security
import XCTest
@testable import RelayRemoteKit

final class KeysTests: XCTestCase {
    private func sshString(_ bytes: Data) -> Data {
        var length = UInt32(bytes.count).bigEndian
        return Data(bytes: &length, count: 4) + bytes
    }

    private func expectedFingerprint(blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    func testFingerprintMatchesTheMacFormat() throws {
        let key = Curve25519.Signing.PrivateKey()
        let blob = sshString(Data("ssh-ed25519".utf8)) + sshString(key.publicKey.rawRepresentation)
        let nio = NIOSSHPrivateKey(ed25519Key: key).publicKey
        XCTAssertEqual(SSHFingerprint.sha256(nio), expectedFingerprint(blob: blob))
        XCTAssertEqual(String(openSSHPublicKey: nio), "ssh-ed25519 " + blob.base64EncodedString())
    }

    func testValidatorAcceptsOnlyPinnedHostKeys() throws {
        let loop = EmbeddedEventLoop()
        let host = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        let other = NIOSSHPrivateKey(p256Key: .init()).publicKey

        let pinned = FailureRecorder()
        let accept = loop.makePromise(of: Void.self)
        PinnedHostKeyValidator(pins: [SSHFingerprint.sha256(host)], failures: pinned)
            .validateHostKey(hostKey: host, validationCompletePromise: accept)
        XCTAssertNoThrow(try accept.futureResult.wait())
        XCTAssertNil(pinned.failure)

        for (pins, key) in [([SSHFingerprint.sha256(host)], other), ([], host)] {
            let failures = FailureRecorder()
            let refuse = loop.makePromise(of: Void.self)
            PinnedHostKeyValidator(pins: Set(pins), failures: failures)
                .validateHostKey(hostKey: key, validationCompletePromise: refuse)
            XCTAssertThrowsError(try refuse.futureResult.wait()) { error in
                XCTAssertEqual(error as? RemoteFailure, .hostKeyMismatch)
            }
            XCTAssertEqual(failures.failure, .hostKeyMismatch)
        }
    }

    func testAuthDelegateOffersTheKeyOnceThenGivesUp() throws {
        let loop = EmbeddedEventLoop()
        let failures = FailureRecorder()
        let key = NIOSSHPrivateKey(ed25519Key: .init())
        let delegate = PrivateKeyAuthDelegate(user: "me", key: key, failures: failures)

        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: first)
        let offer = try XCTUnwrap(try first.futureResult.wait())
        XCTAssertEqual(offer.username, "me")
        guard case .privateKey(let offered) = offer.offer else { return XCTFail("expected a key offer") }
        XCTAssertEqual(offered.publicKey, key.publicKey)

        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: second)
        XCTAssertThrowsError(try second.futureResult.wait())
        XCTAssertEqual(failures.failure, .authenticationRejected)

        let passwordOnly = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        PrivateKeyAuthDelegate(user: "me", key: key, failures: FailureRecorder())
            .nextAuthenticationType(availableMethods: .password, nextChallengePromise: passwordOnly)
        XCTAssertThrowsError(try passwordOnly.futureResult.wait())
    }

    func testEd25519FallbackIsCreatedOnceAndReloaded() throws {
        let store = InMemorySecretStore()
        let key = try DeviceKeyStore.loadOrCreate(in: store, secureEnclaveAvailable: false)
        XCTAssertEqual(key.kind, .ed25519)
        XCTAssertTrue(key.openSSHPublicKey.hasPrefix("ssh-ed25519 "))
        let again = try DeviceKeyStore.loadOrCreate(in: store, secureEnclaveAvailable: true)
        XCTAssertEqual(again.kind, .ed25519, "an existing key is kept")
        XCTAssertEqual(again.openSSHPublicKey, key.openSSHPublicKey)
        XCTAssertEqual("\(key)", "DeviceKey(ed25519, redacted)")
        XCTAssertFalse(String(reflecting: key).contains(key.openSSHPublicKey.split(separator: " ")[1]))
    }

    func testSecureEnclaveKeyExportsAnAuthorizedKeysLine() throws {
        guard SecureEnclave.isAvailable else { throw XCTSkip("no Secure Enclave on this machine") }
        let store = InMemorySecretStore()
        let key: DeviceKey
        do {
            key = try DeviceKeyStore.loadOrCreate(in: store, secureEnclaveAvailable: true)
        } catch {
            throw XCTSkip("Secure Enclave key creation unavailable here: \(type(of: error))")
        }
        guard key.kind == .secureEnclaveP256 else { throw XCTSkip("Secure Enclave refused key creation") }

        // The structure the Mac's SSHPublicKey(openSSH:) accepts.
        let fields = key.openSSHPublicKey.split(separator: " ")
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[0], "ecdsa-sha2-nistp256")
        let blob = try XCTUnwrap(Data(base64Encoded: String(fields[1])))
        XCTAssertEqual(blob.count, 4 + 19 + 4 + 8 + 4 + 65)
        XCTAssertEqual(blob.subdata(in: 4..<23), Data("ecdsa-sha2-nistp256".utf8))
        XCTAssertEqual(blob.subdata(in: 27..<35), Data("nistp256".utf8))
        XCTAssertEqual(blob[39], 0x04)

        let reloaded = try DeviceKeyStore.loadOrCreate(in: store)
        XCTAssertEqual(reloaded.kind, .secureEnclaveP256)
        XCTAssertEqual(reloaded.openSSHPublicKey, key.openSSHPublicKey)
    }

    func testKeychainStoreRoundTrip() throws {
        let store = KeychainStore(service: "com.relayrunner.remote.tests.\(UUID().uuidString)")
        do {
            try store.write(Data("one".utf8), account: "item")
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            throw XCTSkip("the data protection keychain needs an entitled host (simulator app tests)")
        }
        defer { try? store.delete("item") }
        XCTAssertEqual(try store.read("item"), Data("one".utf8))
        try store.write(Data("two".utf8), account: "item")
        XCTAssertEqual(try store.read("item"), Data("two".utf8))
        try store.delete("item")
        XCTAssertNil(try store.read("item"))
    }
}
