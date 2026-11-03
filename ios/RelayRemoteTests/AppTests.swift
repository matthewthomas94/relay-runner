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
        XCTAssertEqual(DebugView.summary(.remoteMode(.init(clientId: "c0ffee", enabled: false))), "off")
        XCTAssertEqual(DebugView.summary(.speech(.init(seq: 3, kind: .final, source: .orchestrator, text: "Hi",
                                                       spokenBy: .mac))), "#3 final (Mac) · Hi")
    }

    @MainActor
    func testRemoteModeSwitchDefaultsOnAndPersists() throws {
        let suite = "com.relayrunner.remote.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteModePreference: RemoteModePreference(defaults: defaults))
        XCTAssertTrue(model.remoteMode)
        model.remoteMode = false
        XCTAssertFalse(AppModel(remoteModePreference: RemoteModePreference(defaults: defaults)).remoteMode)
    }

    @MainActor
    func testPlaybackModeDefaultsToAutoPlayAndPersists() throws {
        let suite = "com.relayrunner.remote.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = PlaybackModePreference(defaults: defaults)
        let model = AppModel(remoteModePreference: RemoteModePreference(defaults: defaults),
                             playbackModePreference: preference)
        XCTAssertEqual(model.playbackMode, .autoPlay)
        model.playbackMode = .onDemand
        XCTAssertEqual(AppModel(remoteModePreference: RemoteModePreference(defaults: defaults),
                                playbackModePreference: preference).playbackMode, .onDemand)
        XCTAssertEqual(DebugView.playbackLabel(.onDemand), "Play on demand")
        XCTAssertEqual(DebugView.activityLabel(.buffering), "Buffering")
    }

    @MainActor
    func testMicrophoneDoesNotOpenWhileRemoteModeIsOff() throws {
        let store = KeychainStore(service: "com.relayrunner.remote.tests.\(UUID().uuidString)")
        defer { try? store.delete("device-key.ed25519"); try? store.delete("device-key.secure-enclave-p256") }
        let key = try DeviceKeyStore.loadOrCreate(in: store)
        let mac = PairedMac(deviceID: "phone-1", deviceName: "iPhone", user: "me", hosts: ["Mac.local"], port: 22,
                            hostKeyFingerprints: ["SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"])
        let configuration = SessionConfiguration(
            deviceID: mac.deviceID, deviceName: mac.deviceName, appVersion: "0.1",
            credentials: SSHCredentials(user: mac.user, privateKey: key.privateKey,
                                        pinnedHostKeys: Set(mac.hostKeyFingerprints)),
            remoteMode: false
        )
        let session = RemoteSession(configuration: configuration, transport: SSHTransport(),
                                    endpoints: MacEndpointResolver(mac: mac))
        let voice = VoiceController(session: session)
        voice.remoteMode = false
        voice.pressToTalkBegan()
        XCTAssertFalse(voice.isListening)
        voice.mode = .handsFree
        voice.startListening()
        XCTAssertFalse(voice.isListening)
        XCTAssertFalse(voice.isAudioActive)
    }
}
