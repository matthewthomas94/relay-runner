import Foundation
import XCTest
@testable import RelayRemoteKit

/// Nothing secret reaches the log sink: no key material, fingerprints,
/// tokens, pairing code or utterance text.
@MainActor
final class LogPrivacyTests: XCTestCase {
    func testPairingAndSessionLogsCarryNoSecrets() async throws {
        let capture = LogCapture()
        let deviceKey = try DeviceKeyStore.loadOrCreate(in: InMemorySecretStore(), secureEnclaveAvailable: false)
        let payload = try PairingPayload.parse(PairingTests.payloadJSON())

        let pairingTransport = FakeTransport(mac: nil)
        pairingTransport.onConnect = { connection in
            connection.onSend = { _ in connection.deliver(line: #"{"device_id":"phone-1","type":"paired"}"#) }
        }
        _ = try await PairingClient(transport: pairingTransport, log: capture.logger)
            .pair(payload, deviceKey: deviceKey, deviceID: "phone-1", deviceName: "Test iPhone")

        let mac = FakeMac()
        let clock = TestClock()
        clock.holdBackoff = true
        let transport = FakeTransport(mac: mac, outcomes: [.connect, .fail(.hostKeyMismatch)])
        let session = Fixtures.session(transport: transport, clock: clock, log: capture.logger)
        session.start()
        await eventually { session.state == .connected }
        session.send(text: "secret utterance text")
        mac.speak("secret reply text")
        await eventually { mac.acks.count == 1 }
        mac.dropConnection()
        await eventually { if case .waiting = session.state { return true } else { return false } }
        session.retryNow()
        await eventually { session.state == .failed(.hostKeyMismatch) }

        let log = capture.text
        XCTAssertTrue(log.contains("paired"))
        XCTAssertTrue(log.contains("host_key_mismatch"))
        let secrets = [
            PairingTests.token,
            PairingTests.seed.base64EncodedString(),
            Fixtures.hostPin,
            deviceKey.fingerprint,
            String(deviceKey.openSSHPublicKey.split(separator: " ")[1]),
            "secret utterance text",
            "secret reply text",
        ]
        for secret in secrets {
            XCTAssertFalse(log.contains(secret), "log leaked a secret")
        }
    }
}
