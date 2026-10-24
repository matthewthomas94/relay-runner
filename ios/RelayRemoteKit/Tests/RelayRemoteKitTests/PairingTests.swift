import CryptoKit
import Foundation
import Network
import NIOSSH
import XCTest
@testable import RelayRemoteKit

final class PairingTests: XCTestCase {
    static let seed = Data(repeating: 7, count: 32)
    static let token = Data(repeating: 9, count: 32).base64EncodedString()

    /// The JSON RR-426's `RelayRemotePairingPayload.encoded()` produces.
    static func payloadJSON(protocol version: Int = 1, hosts: [String] = ["Mac.local", "192.168.1.20", "100.100.1.2"],
                            hostKeys: [String] = [Fixtures.hostPin], pairingID: String = "0b9c6d1e-pair",
                            seed: Data = seed) -> String {
        let object: [String: Any] = [
            "protocol": version, "user": "me", "hosts": hosts, "port": 22, "host_keys": hostKeys,
            "pairing_id": pairingID, "pairing_key": seed.base64EncodedString(), "token": token,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    func testParsesTheMacPairingCode() throws {
        let payload = try PairingPayload.parse(Self.payloadJSON())
        XCTAssertEqual(payload.user, "me")
        XCTAssertEqual(payload.hosts, ["Mac.local", "192.168.1.20", "100.100.1.2"])
        XCTAssertEqual(payload.port, 22)
        XCTAssertEqual(payload.hostKeys, [Fixtures.hostPin])
        XCTAssertEqual(payload.pairingID, "0b9c6d1e-pair")
    }

    func testRejectsAnythingElse() {
        for text in [
            "not json",
            Self.payloadJSON(protocol: 2),
            Self.payloadJSON(hosts: []),
            Self.payloadJSON(hosts: ["has space"]),
            Self.payloadJSON(hostKeys: []),
            Self.payloadJSON(hostKeys: ["MD5:aa"]),
            Self.payloadJSON(pairingID: "bad id"),
            Self.payloadJSON(seed: Data(repeating: 1, count: 16)),
        ] {
            XCTAssertThrowsError(try PairingPayload.parse(text)) { error in
                XCTAssertEqual(error as? RemoteFailure, .invalidPairingCode)
            }
        }
    }

    func testPayloadNeverPrintsItsSecrets() throws {
        let payload = try PairingPayload.parse(Self.payloadJSON())
        let printed = ["\(payload)", String(reflecting: payload), String(describing: Mirror(reflecting: payload).children.map { $0 })]
        for text in printed {
            XCTAssertFalse(text.contains(Self.token))
            XCTAssertFalse(text.contains(Self.seed.base64EncodedString()))
            XCTAssertFalse(text.contains(Fixtures.hostPin))
        }
    }

    func testPairsWithThePairingKeyAndPinsTheHostKeysFromTheCode() async throws {
        let transport = FakeTransport(mac: nil)
        let deviceKey = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        let payload = try PairingPayload.parse(Self.payloadJSON())
        let client = PairingClient(transport: transport, log: .silent)

        var request: [String: String] = [:]
        transport.onConnect = { connection in
            connection.onSend = { line in
                request = try! JSONSerialization.jsonObject(with: line) as! [String: String]
                connection.deliver(line: #"{"device_id":"phone-1","type":"paired"}"#)
            }
        }
        let mac = try await client.pair(payload, deviceKey: deviceKey, deviceID: "phone-1", deviceName: "Test iPhone")
        let connection = try XCTUnwrap(transport.lastConnection)

        XCTAssertEqual(request, [
            "type": "pair", "token": Self.token, "device_id": "phone-1", "device_name": "Test iPhone",
            "public_key": deviceKey.openSSHPublicKey,
        ])
        XCTAssertEqual(mac, PairedMac(deviceID: "phone-1", deviceName: "Test iPhone", user: "me",
                                      hosts: payload.hosts, port: 22, hostKeyFingerprints: [Fixtures.hostPin]))
        XCTAssertTrue(connection.closed, "the pairing connection is closed after the reply")

        let attempt = transport.attempts[0]
        XCTAssertEqual(attempt.endpoint, .hostPort(host: "Mac.local", port: 22))
        XCTAssertEqual(attempt.credentials.user, "me")
        XCTAssertEqual(attempt.credentials.pinnedHostKeys, [Fixtures.hostPin])
        let pairingKey = NIOSSHPrivateKey(ed25519Key: try .init(rawRepresentation: Self.seed))
        XCTAssertEqual(attempt.credentials.privateKey.publicKey, pairingKey.publicKey)
    }

    func testMacRefusalBecomesAPairingError() async throws {
        let transport = FakeTransport(mac: nil)
        let deviceKey = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        let client = PairingClient(transport: transport, log: .silent)
        transport.onConnect = { connection in
            connection.onSend = { _ in
                connection.deliver(line: #"{"code":"pairing_denied","message":"Pairing was declined on the Mac","type":"error"}"#)
            }
        }
        do {
            _ = try await client.pair(try PairingPayload.parse(Self.payloadJSON()), deviceKey: deviceKey,
                                      deviceID: "phone-1", deviceName: "Test iPhone")
            XCTFail("pairing should fail")
        } catch {
            XCTAssertEqual(error as? RemoteFailure,
                           .pairingRejected(code: "pairing_denied", message: "Pairing was declined on the Mac"))
        }
    }

    func testUnreachableHostsAreSkippedButAChangedHostKeyStopsPairing() async throws {
        let deviceKey = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        let payload = try PairingPayload.parse(Self.payloadJSON())

        let mismatch = FakeTransport(mac: nil, outcomes: [.fail(.unreachable), .fail(.hostKeyMismatch), .connect])
        do {
            _ = try await PairingClient(transport: mismatch, log: .silent)
                .pair(payload, deviceKey: deviceKey, deviceID: "phone-1", deviceName: "iPhone")
            XCTFail("pairing should fail")
        } catch {
            XCTAssertEqual(error as? RemoteFailure, .hostKeyMismatch)
        }
        XCTAssertEqual(mismatch.attemptCount, 2)
        XCTAssertTrue(mismatch.connections.isEmpty)

        let unreachable = FakeTransport(mac: nil, outcomes: [.fail(.unreachable)])
        do {
            _ = try await PairingClient(transport: unreachable, log: .silent)
                .pair(payload, deviceKey: deviceKey, deviceID: "phone-1", deviceName: "iPhone")
            XCTFail("pairing should fail")
        } catch {
            XCTAssertEqual(error as? RemoteFailure, .unreachable)
        }
        XCTAssertEqual(unreachable.attemptCount, 3)
    }

    func testPairingStoreRoundTripsAndRedacts() throws {
        let store = PairingStore(store: InMemorySecretStore())
        XCTAssertNil(store.load())
        let mac = PairedMac(deviceID: "phone-1", deviceName: "iPhone", user: "me", hosts: ["Mac.local"], port: 22,
                            hostKeyFingerprints: [Fixtures.hostPin])
        try store.save(mac)
        XCTAssertEqual(store.load(), mac)
        XCTAssertEqual(mac.bonjourHostName, "Mac.local")
        XCTAssertFalse("\(mac)".contains(Fixtures.hostPin))
        XCTAssertFalse(String(reflecting: mac).contains(Fixtures.hostPin))
        try store.clear()
        XCTAssertNil(store.load())
    }
}
