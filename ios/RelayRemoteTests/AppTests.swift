import CryptoKit
import RelayRemoteKit
import XCTest
@testable import RelayRemote

/// Runs hosted in the app on the simulator, so the Info.plist and Keychain
/// are the app's own.
final class AppTests: XCTestCase {
    func testInfoPlistDeclaresUsageStringsAndBonjourServices() {
        let info = Bundle.main.infoDictionary ?? [:]
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription",
                    "NSLocalNetworkUsageDescription", "NSCameraUsageDescription"] {
            XCTAssertFalse((info[key] as? String ?? "").isEmpty, key)
        }
        XCTAssertEqual(info["NSBonjourServices"] as? [String], ["_ssh._tcp"])
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["audio"],
                       "audio keeps a reply playing with the screen locked; the session is active only while recording or playing")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Relay Remote")
    }

    func testDeviceKeyAndPairingLiveInTheKeychain() throws {
        let store = KeychainStore(service: "com.relayrunner.remote.tests.\(UUID().uuidString)")
        defer {
            for account in ["device-key.ed25519", "device-key.secure-enclave-p256", "paired-mac"] {
                try? store.delete(account)
            }
        }
        let key = try DeviceKeyStore.loadOrCreate(in: store)
        let reloaded = try DeviceKeyStore.loadOrCreate(in: store)
        XCTAssertEqual(reloaded.openSSHPublicKey, key.openSSHPublicKey)
        XCTAssertEqual(key.kind, SecureEnclave.isAvailable ? .secureEnclaveP256 : .ed25519)

        let pairing = PairingStore(store: store)
        let mac = PairedMac(deviceID: "phone-1", deviceName: "iPhone", user: "me", hosts: ["Mac.local"], port: 22,
                            hostKeyFingerprints: ["SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"])
        try pairing.save(mac)
        XCTAssertEqual(pairing.load(), mac)
    }

    func testDebugSummariesShowFrameContent() {
        XCTAssertEqual(DebugView.summary(.error(.init(code: "no_session", message: "Relay Runner is not running a session"))),
                       "no_session: Relay Runner is not running a session")
        XCTAssertEqual(DebugView.summary(.control(.init(clientId: "c0ffee", action: .replay))), "replay")
        XCTAssertEqual(DebugView.activityLabel(.hearing), "Hearing you")
    }
}
