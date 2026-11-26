import Network
import RelayRemoteKit
import RelayRemoteProtocol
import SwiftUI
import UIKit

/// Owns the device key, the pairing record, the session and the voice layer.
/// The app is foreground-first (docs/specs/relay-remote.md, "Foreground and
/// background"): the channel is closed when the app leaves the foreground,
/// unless the phone is still recording or speaking under the audio background
/// mode, in which case it closes once the audio ends. It is reopened with
/// `resume_after_seq` when the app returns.
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
    private(set) var voice: VoiceController?
    /// The Agents tab's chats, selection and per-agent state (RR-540).
    let agents: AgentsModel
    private(set) var pairingState = PairingState.idle
    private(set) var startupError: String?
    /// The Workspace tab's selected project tab (RR-543); nil is All. Lives
    /// here so it lasts for the app session, not just while the tab is shown.
    var workspaceProject: String?
    /// RR-551: the ticket in the Workspace tab's modal. It stays set while the
    /// modal fades out, so the panel keeps its text as it leaves.
    private(set) var shownTicket: WorkspaceTicket?
    private(set) var isTicketOpen = false
    /// Counts the asks for the open ticket's text; each one sends a `get`.
    private(set) var ticketRequests = 0
    /// The Remote mode switch (RR-454). On: this phone owns the microphone and
    /// speaker and the Mac stays quiet. Off: the Mac listens and speaks and the
    /// phone shows the text. Persisted, and sent to the Mac on connect and change.
    var remoteMode: Bool {
        didSet {
            guard remoteMode != oldValue else { return }
            remoteModePreference.isOn = remoteMode
            session?.setRemoteMode(remoteMode)
            voice?.remoteMode = remoteMode
        }
    }

    /// Auto-play or play on demand (RR-458). Persisted.
    var playbackMode: PlaybackMode {
        didSet {
            guard playbackMode != oldValue else { return }
            playbackModePreference.mode = playbackMode
            voice?.playbackMode = playbackMode
        }
    }

    @ObservationIgnored private let secrets = KeychainStore()
    @ObservationIgnored private var pairingStore: PairingStore { PairingStore(store: secrets) }
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private let remoteModePreference: RemoteModePreference
    @ObservationIgnored private let playbackModePreference: PlaybackModePreference

    init(remoteModePreference: RemoteModePreference = RemoteModePreference(),
         playbackModePreference: PlaybackModePreference = PlaybackModePreference(),
         agents: AgentsModel? = nil) {
        self.remoteModePreference = remoteModePreference
        self.playbackModePreference = playbackModePreference
        self.agents = agents ?? AgentsModel()
        remoteMode = remoteModePreference.isOn
        playbackMode = playbackModePreference.mode
    }

    /// RR-551: opens a Workspace row in the ticket modal. Text held from an
    /// earlier open is dropped, so the body loads fresh.
    func openTicket(_ row: WorkspaceTicket) {
        session?.forgetWorkspaceTicket(projectID: row.projectId, ticketID: row.id)
        shownTicket = row
        isTicketOpen = true
        ticketRequests += 1
    }

    func closeTicket() { isTicketOpen = false }

    /// Debug only: shows a sample row in the modal without asking the Mac.
    func showSampleTicket(_ row: WorkspaceTicket) {
        shownTicket = row
        isTicketOpen = true
    }

    /// Asks the Mac for the open ticket's text again, keeping what is shown.
    func refreshTicket() {
        guard isTicketOpen else { return }
        ticketRequests += 1
    }

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
            try Task.checkCancellation()
            try pairingStore.save(mac)
            pairingState = .idle
            activate(mac)
        } catch let failure as RemoteFailure {
            pairingState = .failed(failure.userMessage)
        } catch is CancellationError {
            pairingState = .idle
        } catch {
            pairingState = .failed("Pairing could not be saved on this iPhone.")
        }
    }

    /// Forgets the Mac on this phone. The Mac keeps its `authorized_keys`
    /// line until the device is unpaired in Relay Runner's Settings.
    func forget() {
        voice?.shutdown()
        voice = nil
        session?.stop()
        session = nil
        agents.session = nil
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
            // A reply still playing, or an utterance still recording, keeps the
            // channel open; `audioBecameIdle` closes it afterwards.
            if voice?.isAudioActive != true { session?.stop() }
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
            resumeAfterSeq: UserDefaults.standard.object(forKey: Self.resumeKey(mac)) as? Int,
            remoteMode: remoteMode
        )
        let session = RemoteSession(configuration: configuration, transport: SSHTransport(),
                                    endpoints: MacEndpointResolver(mac: mac))
        self.session = session
        let voice = VoiceController(session: session)
        voice.remoteMode = remoteMode
        voice.playbackMode = playbackMode
        voice.onAudioIdle = { [weak self] in self?.audioBecameIdle() }
        self.voice = voice
        // Each reply is filed under its agent's chat before it plays, and a
        // spoken request goes to the selected agent like a typed one.
        agents.session = session
        session.onInbound = { [weak self] frame in
            self?.agents.receive(frame)
            self?.voice?.receive(frame)
        }
        voice.onSpokenRequest = { [weak self] text in self?.agents.send(text) }
        if isForeground { session.start() }
    }

    private func audioBecameIdle() {
        guard !isForeground else { return }
        saveResumePoint()
        session?.stop()
    }

    private func saveResumePoint() {
        guard let mac = paired, let seq = session?.resumeAfterSeq else { return }
        UserDefaults.standard.set(seq, forKey: Self.resumeKey(mac))
    }

    private static func resumeKey(_ mac: PairedMac) -> String {
        "resumeAfterSeq.\(mac.deviceID)"
    }
}
