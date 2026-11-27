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
/// `resume_after_seq` when the app returns. RR-545: with Reply notifications on
/// and allowed, `ReplyNotifier` holds the audio session instead, the channel
/// stays open, and each reply posts a local notification.
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
    /// Set when the device key could not be created; pairing reports it.
    @ObservationIgnored private var keyFailure: String?
    /// The Workspace tab's selected project tab (RR-543); nil is All. Lives
    /// here so it lasts for the app session, not just while the tab is shown.
    var workspaceProject: String?
    /// RR-551: the ticket in the Workspace tab's modal. It stays set while the
    /// modal fades out, so the panel keeps its text as it leaves.
    private(set) var shownTicket: WorkspaceTicket?
    private(set) var isTicketOpen = false
    /// Where the open ticket's card was on screen, so the modal grows out of
    /// it and shrinks back into it (global coordinates).
    private(set) var ticketOrigin: CGRect?
    /// RR-545: counts the asks to show the Agents tab, as a tapped reply
    /// notification makes; the tab view switches on each change.
    private(set) var agentsTabRequests = 0
    /// Testing: counts the asks to walk onboarding again (Settings › Testing).
    private(set) var onboardingReplayRequests = 0
    /// RR-545: reply and lost-connection notifications in the background.
    @ObservationIgnored let notifier: ReplyNotifier
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
         agents: AgentsModel? = nil,
         notificationCenter: LocalNotificationCenter? = nil) {
        self.remoteModePreference = remoteModePreference
        self.playbackModePreference = playbackModePreference
        self.agents = agents ?? AgentsModel()
        notifier = ReplyNotifier(center: notificationCenter ?? SystemNotificationCenter())
        remoteMode = remoteModePreference.isOn
        playbackMode = playbackModePreference.mode
        notifier.holdAudio = { [weak self] on in
            self?.voice?.setKeepAlive(on, for: .replyNotifications) ?? false
        }
    }

    /// Testing: walk onboarding again from the splash, showing every
    /// permission step. iOS keeps the permissions already granted (an app
    /// cannot revoke its own), so those steps move on without a system prompt.
    func redoOnboarding() {
        let progress = OnboardingProgress()
        progress.isFinished = false
        progress.isReplaying = true
        onboardingReplayRequests += 1
    }

    /// RR-545: a tapped reply notification opens that agent's chat on the Agents tab.
    func openAgentChat(_ slug: String) {
        guard AgentsModel.slugs.contains(slug) else { return }
        agents.select(slug)
        closeTicket()
        agentsTabRequests += 1
        notifier.chatOpened(slug)
    }

    /// RR-551: opens a Workspace row in the ticket modal. Text held from an
    /// earlier open is dropped, so the body loads fresh.
    func openTicket(_ row: WorkspaceTicket, from origin: CGRect? = nil) {
        ticketOrigin = origin
        session?.forgetWorkspaceTicket(projectID: row.projectId, ticketID: row.id)
        shownTicket = row
        isTicketOpen = true
        ticketRequests += 1
    }

    func closeTicket() { isTicketOpen = false }

    /// Debug only: shows a sample row in the modal without asking the Mac.
    func showSampleTicket(_ row: WorkspaceTicket, from origin: CGRect? = nil) {
        ticketOrigin = origin
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
            keyFailure = "The device key could not be created or read from the Keychain."
        }
        #if DEBUG
        let launch = LaunchOptions.current
        if let every = launch.scriptedMacReplyEvery {
            activate(ScriptedMac.mac, transport: ScriptedMac(replyEvery: every, dropAfter: launch.scriptedMacDropAfter),
                     endpoints: ScriptedMac.endpoints)
        } else if let mac = pairingStore.load() {
            activate(mac)
        }
        #else
        if let mac = pairingStore.load() { activate(mac) }
        #endif
        Task { await notifier.refreshAuthorization() }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.session?.retryNow() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "relay-remote.path"))
    }

    func pair(code: String) async {
        guard let deviceKey else {
            pairingState = .failed(keyFailure ?? "This iPhone could not create its device key.")
            return
        }
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
            notifier.enteredForeground(showing: agents.selected)
            Task { await notifier.refreshAuthorization() }
            // A refused host key or device key waits for "Try again".
            if let session, session.state != .failed(.hostKeyMismatch),
               session.state != .failed(.authenticationRejected) {
                session.start()
            }
        case .background:
            isForeground = false
            saveResumePoint()
            // RR-545: Reply notifications hold the audio session and keep the
            // channel open. Otherwise a reply still playing, or an utterance
            // still recording, keeps it open and `audioBecameIdle` closes it afterwards.
            let keptAlive = notifier.enteredBackground(sessionUsable: isSessionUsable)
            if !keptAlive, voice?.isAudioActive != true { session?.stop() }
        default:
            break
        }
    }

    /// A session that can reach the Mac; a refused key waits for the user.
    private var isSessionUsable: Bool {
        guard let session, voice != nil else { return false }
        if case .failed = session.state { return false }
        return true
    }

    private func activate(_ mac: PairedMac, transport: RemoteTransport = SSHTransport(),
                          endpoints: EndpointProvider? = nil) {
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
        let session = RemoteSession(configuration: configuration, transport: transport,
                                    endpoints: endpoints ?? MacEndpointResolver(mac: mac))
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
            guard let self else { return }
            agents.receive(frame)
            if case .speech(let speech) = frame {
                notifier.receive(speech, agent: agents.owner(of: speech.agent))
            }
            self.voice?.receive(frame)
        }
        session.onStateChange = { [weak self, weak session] state in
            self?.notifier.sessionStateChanged(state)
            // The phone plays replies at the Mac's speech speed, so learn it on
            // every connect, not only when Settings opens.
            if state == .connected || state == .connectedToApp { _ = session?.requestSettings() }
        }
        voice.onSpokenRequest = { [weak self] text in self?.agents.send(text) }
        if isForeground { session.start() }
    }

    private func audioBecameIdle() {
        guard !isForeground, !notifier.isKeepingAlive else { return }
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
