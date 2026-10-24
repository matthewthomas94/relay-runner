import Network
import RelayRemoteKit
import SwiftUI
import UIKit

/// Owns the device key, the pairing record and the session. The app is
/// foreground-first (docs/specs/relay-remote.md, "Foreground and
/// background"): the channel is closed when the app leaves the foreground and
/// reopened with `resume_after_seq` when it returns.
@MainActor
@Observable
final class AppModel {
    enum PairingState: Equatable {
        case idle
        case pairing
        case failed(String)
    }

    private(set) var deviceKey: DeviceKey?
    private(set) var paired: PairedMac?
    private(set) var session: RemoteSession?
    private(set) var pairingState = PairingState.idle
    private(set) var startupError: String?

    @ObservationIgnored private let secrets = KeychainStore()
    @ObservationIgnored private var pairingStore: PairingStore { PairingStore(store: secrets) }
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var isForeground = true

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            deviceKey = try DeviceKeyStore.loadOrCreate(in: secrets)
        } catch {
            startupError = "The device key could not be created or read from the Keychain."
        }
        if let mac = pairingStore.load() { activate(mac) }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.session?.retryNow() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "relay-remote.path"))
    }

    func pair(code: String) async {
        guard let deviceKey else { return }
        pairingState = .pairing
        do {
            let payload = try PairingPayload.parse(code)
            let mac = try await PairingClient(transport: SSHTransport())
                .pair(payload, deviceKey: deviceKey, deviceID: UUID().uuidString.lowercased(),
                      deviceName: UIDevice.current.name)
            try pairingStore.save(mac)
            pairingState = .idle
            activate(mac)
        } catch let failure as RemoteFailure {
            pairingState = .failed(failure.userMessage)
        } catch {
            pairingState = .failed("Pairing could not be saved on this iPhone.")
        }
    }

    /// Forgets the Mac on this phone. The Mac keeps its `authorized_keys`
    /// line until the device is unpaired in Relay Runner's Settings.
    func forget() {
        session?.stop()
        session = nil
        if let mac = paired { UserDefaults.standard.removeObject(forKey: Self.resumeKey(mac)) }
        paired = nil
        try? pairingStore.clear()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isForeground = true
            // A refused host key or device key waits for "Try again".
            if let session, session.state != .failed(.hostKeyMismatch),
               session.state != .failed(.authenticationRejected) {
                session.start()
            }
        case .background:
            isForeground = false
            saveResumePoint()
            session?.stop()
        default:
            break
        }
    }

    private func activate(_ mac: PairedMac) {
        guard let deviceKey else { return }
        paired = mac
        let configuration = SessionConfiguration(
            deviceID: mac.deviceID,
            deviceName: mac.deviceName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            credentials: SSHCredentials(user: mac.user, privateKey: deviceKey.privateKey,
                                        pinnedHostKeys: Set(mac.hostKeyFingerprints)),
            resumeAfterSeq: UserDefaults.standard.object(forKey: Self.resumeKey(mac)) as? Int
        )
        let session = RemoteSession(configuration: configuration, transport: SSHTransport(),
                                    endpoints: MacEndpointResolver(mac: mac))
        self.session = session
        if isForeground { session.start() }
    }

    private func saveResumePoint() {
        guard let mac = paired, let seq = session?.resumeAfterSeq else { return }
        UserDefaults.standard.set(seq, forKey: Self.resumeKey(mac))
    }

    private static func resumeKey(_ mac: PairedMac) -> String {
        "resumeAfterSeq.\(mac.deviceID)"
    }
}
