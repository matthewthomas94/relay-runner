import AppKit
import Foundation
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

@Observable
final class AppState {
    enum ContinuityRecoveryComponentAction: Equatable {
        case restartSpeechCapture
        case restartTranscriptionDelivery
        case recoverBridge
        case restartDaemon
        case releaseForegroundProviderOwnership
        case launchForegroundProvider
    }

    enum ContinuityRecoveryDecision: Equatable {
        case apply(ContinuityRecoveryComponentAction)
        case reject(String)
    }

    struct ContinuityRecoveryBoundary: Equatable {
        let currentSessionID: String
        let currentRecoveryGeneration: String
        let currentCommandID: String?
        let provider: String
        let liveWorkActive: Bool
        let providerProcessRunning: Bool
        let stalledProviderTargetOwned: Bool
        let bridgeAlive: Bool
        let idempotencyAlreadyApplied: Bool
        let cooldownActive: Bool
    }

    struct ContinuityProviderReadyContext: Equatable {
        let nativeCommandID: String
        let commandID: String
        let provider: String
        let recoveryGeneration: String
        let previousProviderSessionID: String
        let providerSessionID: String?
        let appSessionID: String?
        let foregroundGateHandle: String?
        var discardUnacknowledgedClaim = false

        func authorizingReplacement(
            providerSessionID: String?,
            appSessionID: String?,
            foregroundGateHandle: String?,
            provider: String
        ) -> Self? {
            guard provider == self.provider,
                  let providerSessionID, !providerSessionID.isEmpty,
                  providerSessionID != previousProviderSessionID,
                  let appSessionID, !appSessionID.isEmpty,
                  let foregroundGateHandle, !foregroundGateHandle.isEmpty else {
                return nil
            }
            return Self(
                nativeCommandID: nativeCommandID,
                commandID: commandID,
                provider: self.provider,
                recoveryGeneration: recoveryGeneration,
                previousProviderSessionID: previousProviderSessionID,
                providerSessionID: providerSessionID,
                appSessionID: appSessionID,
                foregroundGateHandle: foregroundGateHandle,
                discardUnacknowledgedClaim: discardUnacknowledgedClaim
            )
        }

        func controlMessage(
            currentClaimIdentity: [String: Any]?,
            currentProvider: String,
            currentRecoveryGeneration: String?,
            currentProviderSessionID: String?
        ) -> String? {
            guard let currentClaimIdentity,
                  (currentClaimIdentity["relay_command_id"] as? String) == nativeCommandID,
                  ContinuityRecoveryRequest.opaqueIdentifier(
                    kind: "command",
                    nativeValue: nativeCommandID
                  ) == commandID,
                  currentProvider == provider,
                  currentRecoveryGeneration == recoveryGeneration,
                  let providerSessionID,
                  currentProviderSessionID == providerSessionID,
                  providerSessionID != previousProviderSessionID,
                  let appSessionID,
                  let foregroundGateHandle
            else { return nil }
            var payload: [String: Any] = [
                "type": "continuity_provider_ready",
                "event": "provider_ready",
                "provider": provider,
                "recovery_generation": recoveryGeneration,
                "previous_provider_session_id": previousProviderSessionID,
                "provider_session_id": providerSessionID,
                "app_session_id": appSessionID,
                "actor_role": "foreground_pm",
                "foreground_gate_handle": foregroundGateHandle,
                "discard_unacknowledged_claim": discardUnacknowledgedClaim,
            ]
            for field in [
                "relay_command_seq",
                "relay_command_id",
                "intent_id",
                "intent_delivery_id",
                "intent_claim_id",
                "intent_ack_id",
            ] {
                guard let value = currentClaimIdentity[field] else { return nil }
                payload[field] = value
            }
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            ) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    enum SessionLaunchDestination: Equatable {
        case embedded
        case externalTerminal
    }

    enum MeetingNoteForegroundTransitionError: LocalizedError {
        case teardownTimedOut

        var errorDescription: String? {
            "The current work session did not release its foreground resources in time."
        }
    }

    struct SessionLaunchRequest: Equatable {
        let config: AppConfig
        let destination: SessionLaunchDestination
    }

    struct LaunchPlan: Equatable {
        let startsOverlay: Bool
        let startsAwareness: Bool
        let statusText: String?
    }

    struct NotchPresentation: Equatable {
        let status: NotchSessionStatus
        let activityLabels: [String]
        let workingProgressLabel: String?
    }

    struct BridgeRecoveryFailurePresentation: Equatable {
        let statusText: String
        let title: String
        let body: String
    }

    struct ProgramStatusPresentation: Equatable {
        let statusText: String
        let title: String
        let body: String
    }

    private struct BridgeWatchdogSample {
        let daemonAlive: Bool
        let consumerAlive: Bool
        let hasSessionContext: Bool
        let pendingDeliveryState: ProcessManager.PendingVoiceCommandDeliveryState
        let stopRequested: Bool
        let managedProviderState: (process: AssistantManagedProviderProcess, state: AssistantManagedProviderProcess.State)?
    }

    var config: AppConfig
    var isRunning = false
    var statusText = "Idle"
    private(set) var isFirstRunExperienceActive = false

    private(set) var sttEngine: STTEngine?
    private(set) var meetingNoteSnapshot = MeetingNoteCoordinatorSnapshot(
        phase: .idle,
        noteID: nil,
        project: nil,
        liveHypothesisCount: 0,
        durableSegmentCount: 0,
        syncState: nil,
        errorMessage: nil
    ) {
        didSet { syncCommandCaptureOwnership() }
    }
    @ObservationIgnored private let checkForUpdatesAction: @MainActor () -> Void
    @ObservationIgnored private let refreshBundledOrchestratorDaemon: () async -> OrchestratorDaemonRefreshResult
    @ObservationIgnored private let refreshBundledServicesOnLaunch: Bool
    @ObservationIgnored let keepAwake = KeepAwakeController()
    @ObservationIgnored private let keepAwakeApprovalGuide = KeepAwakeApprovalGuide()
    @ObservationIgnored private let workspaceActivityStore = WorkspaceActivitySnapshotStore()
    @ObservationIgnored private var workspaceActivityTimer: Timer?
    @ObservationIgnored private var workspaceActivityTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceActivityRefreshID = 0
    @ObservationIgnored private var workspaceDiscoveryTask: Task<Void, Never>?
    @ObservationIgnored private var appTerminationObserver: NSObjectProtocol?
    @ObservationIgnored private var meetingNoteCoordinator: MeetingNoteCoordinator?
    @ObservationIgnored private var meetingNoteCoordinatorNotificationID: UUID?
    @ObservationIgnored private var meetingNoteStartTask: Task<MeetingNoteCoordinatorSnapshot, Error>?
    @ObservationIgnored private var meetingNoteRecoveryTask: Task<MeetingNoteCoordinatorSnapshot, Error>?
    @ObservationIgnored private var meetingNoteOptionGesture: NoteOptionGesture?
    @ObservationIgnored private var meetingNoteGestureGeneration = 0
    @ObservationIgnored private var meetingNoteTransitionID = 0
    /// Model changes apply at the next recording: a restart waits here while
    /// a command capture is still recording or finalizing.
    @ObservationIgnored private var pendingSTTRestartTask: Task<Void, Never>?
    /// One-time Parakeet v2 → Phonon 2 migration, gated by
    /// `STTModelPolicy.phononDefaultActive`.
    private(set) var phononMigration: STTPhononMigration?

    var serviceLifecycleMessage: String?

    /// Populated when STTEngine.start() throws — surfaces a human-readable
    /// failure in the menu bar with a Retry Setup action. Nil when STT is
    /// healthy or still loading.
    private(set) var sttEngineError: String?
    private var sttSetupStartedAt: Date?
    private var sttSetupSucceeded = false

    /// Shared finite STT setup state for Settings and onboarding. Preparing
    /// status is allowed to be temporary only; success becomes Model ready
    /// (the mic is not claimed), while errors and timeouts become retryable failures.
    var setupRuntimeReadiness: SetupRuntimeReadiness {
        Self.setupRuntimeReadiness(
            engineStatusMessage: sttEngine?.statusMessage,
            engineError: sttEngineError,
            setupSucceeded: sttSetupSucceeded,
            startedAt: sttSetupStartedAt
        )
    }

    /// Translated version of `sttEngineError`, suitable for direct display.
    var sttEngineErrorTranslation: ErrorTranslator.Translation? {
        sttEngineError.map { ErrorTranslator.translate($0) }
    }

    let configManager = ConfigManager.shared
    let processManager = ProcessManager()
    /// RR-394: one embedded session per context; see `EmbeddedSessionRegistry`.
    let sessionRegistry = EmbeddedSessionRegistry()
    /// The focused context's session; a placeholder before any session starts.
    var embeddedTerminal: EmbeddedTerminalSession { sessionRegistry.focused }
    let permissions = PermissionsManager()
    var customVoiceNotice: String?
    private(set) var activeContext = AssistantSessionContext.general
    private(set) var conversationHistory: [AssistantConversationEntry] = []
    private(set) var conversationID = ""
    private(set) var contextSwitchMessage: String?
    var contextHistory: [AssistantConversationEntry] {
        conversationHistory.filter { $0.contextID == activeContext.id }
    }
    @ObservationIgnored private let assistantSessionStore = AssistantSessionStore()
    @ObservationIgnored private var pendingContextSelection: AssistantSessionContext?
    @ObservationIgnored private var pendingContextSelectionShowsTerminal = true
    /// The brief notch outcome of a session wheel switch.
    @ObservationIgnored private var sessionSwitchNotice: SessionSwitchNotice?
    @ObservationIgnored private var sessionSwitchNoticeExpiry: DispatchWorkItem?
    @ObservationIgnored private var continuationSourceReady = false
    @ObservationIgnored private var locallyCancelledContinuationID: String?
    /// Launch owner identity per context; a continuation is delivered to its
    /// destination context's own session, focused or not.
    @ObservationIgnored private var continuationDestinationOwners: [String: [String: String]] = [:]
    var canClearContextContinuation: Bool { assistantSessionStore.pendingContinuation != nil }
    @ObservationIgnored private var idleSessionSaved = false
    /// RR-394: the context whose spool the shared voice bridge publishes into.
    /// RR-398: it follows the focused live context via `__FOCUS__`. Voice
    /// delivery and continuity recovery act on it.
    @ObservationIgnored private var voiceContextID: String?
    /// The `__FOCUS__` datagrams the running bridge last accepted.
    @ObservationIgnored private var sentVoiceFocus: [String] = []
    /// RR-401: unheard reply and outcome counts per background live context.
    private(set) var sessionReplyBadges: [String: Int] = [:] {
        didSet { overlayController?.setReplyStackDepth(sessionReplyBadges.values.reduce(0, +)) }
    }
    @ObservationIgnored private var replyBadgeTimer: Timer?
    private var voiceContext: AssistantSessionContext {
        voiceContextID.flatMap { assistantSessionStore.document.bindings[$0]?.context } ?? activeContext
    }
    private var voiceSession: EmbeddedTerminalSession {
        voiceContextID.flatMap { sessionRegistry.sessions[$0] } ?? embeddedTerminal
    }
    @ObservationIgnored private var lastContextReconciliation = Date.distantPast

    var settingsAudioBusy: Bool {
        if meetingNoteSnapshot.phase.ownsForeground { return true }
        if sttEngine?.isRecording == true { return true }
        switch stateMachine.state {
        case .preparing, .speaking, .recording: return true
        default: return false
        }
    }
    // @ObservationIgnored: @Observable's macro expansion doesn't compose with
    // `lazy`. The controller is stateless from the UI's perspective — views
    // observe PermissionsManager directly — so hiding it from observation
    // costs nothing.
    @ObservationIgnored lazy var onboarding: OnboardingController = {
        OnboardingController(
            permissions: permissions,
            getWorkingDirectory: { [weak self] in self?.config.general.working_directory ?? "" },
            getAgentProvider: { [weak self] in self?.config.general.provider ?? .codex },
            setAgentProvider: { [weak self] provider in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.selectProvider(provider)
                self.saveConfig(newConfig)
            },
            setWorkingDirectory: { [weak self] path in
                guard let self else { return }
                var newConfig = self.config
                newConfig.general.working_directory = path
                self.saveConfig(newConfig, forceWorkspaceDiscovery: true)
            },
            usesProjectRegistryV2: ProjectRegistryV2Rollout.isEnabled(),
            setOnboardingNotchOverrideActive: { [weak self] active in
                self?.setOnboardingNotchOverrideActive(active)
            },
            setFirstRunExperienceActive: { [weak self] active in
                self?.setFirstRunExperienceActive(active)
            },
            requestPermissionSetup: { [weak self] kind, source, purpose in
                self?.requestPermissionSetup(kind, source: source, purpose: purpose)
            },
            cancelPermissionSetup: { [weak self] source in
                self?.cancelPermissionSetup(source: source)
            },
            shouldDeferPermissionAdvance: { [weak self] kind in
                self?.permissionSetupCoordinator.shouldDeferAutoAdvance(for: kind) ?? false
            },
            refreshAgentReadiness: { [weak self] provider, completion in
                let workingDirectory = WorkspaceFolder.url(
                    from: self?.config.general.working_directory ?? ""
                ).path
                AgentAuth.refreshReadiness(
                    for: provider,
                    workingDirectory: workingDirectory,
                    completion: completion
                )
            },
            onOpenExternalWindow: { [weak self] in
                self?.suspendWorkspaceForExternalWindow()
            },
            prepareTutorialSpeech: { [weak self] in
                self?.prepareOnboardingTutorialSpeech() ?? false
            },
            stopTutorialSpeech: { [weak self] in
                self?.stopOnboardingTutorialSpeech()
            },
            openWorkspaceAfterCompletion: { [weak self] in
                self?.showWorkspaceWork()
            }
        )
    }()
    @ObservationIgnored private let permissionNotifier = PermissionNotifier()
    @ObservationIgnored private let permissionRelaunchGuard = PermissionRelaunchGuard()
    @ObservationIgnored private lazy var permissionSetupCoordinator = PermissionSetupCoordinator(
        permissions: permissions,
        setSetupNotchState: { [weak self] state in
            self?.setPermissionSetupNotchState(state)
        },
        prepareForExternalWindow: { [weak self] permission in
            self?.prepareForPermissionExternalWindow(permission)
        }
    )

    /// One-shot wizard that fires when MCP detects a not-yet-onboarded
    /// parent terminal/IDE. AppState owns the controller; the bus calls into
    /// it via the closures wired in `startOverlay`. @ObservationIgnored
    /// because the controller's window lifecycle is imperative — UI doesn't
    /// observe it directly.
    @ObservationIgnored private let parentOnboardingController = ParentOnboardingController()

    // Phase 2: Awareness overlay
    let stateMachine = StateMachine()
    private var overlayController: OverlayController?
    @ObservationIgnored private let programBoardOverlay = ProgramBoardOverlayController()
    @ObservationIgnored private let sessionWheel = SessionWheelController()
    @ObservationIgnored private let notchStatusController = NotchStatusController()
    private var perimeterOverlay: PerimeterOverlayManager?
    private var eventBus: StateEventBus?
    /// `Remote: <device>` while a Relay Remote phone is connected.
    private(set) var remoteStatusLabel: String?
    @ObservationIgnored private lazy var remoteDeviceSession: RelayRemoteDeviceSession = {
        let session = RelayRemoteDeviceSession(
            gate: AppStateRemoteGate(owner: self),
            keepAwake: IOKitKeepAwake()
        )
        session.onChange = { [weak self] in
            guard let self else { return }
            self.remoteStatusLabel = self.remoteDeviceSession.statusLabel
            self.syncNotchActivitySurface()
        }
        return session
    }()
    private var actionsBus: ActionsConfirmBus?
    private var sttPollTimer: Timer?
    private var notchActivityPollingActive = false
    private var notchActivityRunStates: [RunState] = []
    private var notchActivityTickets: [Ticket] = []
    private var notchActivityTicketsByRunKey: [String: Ticket] = [:]
    private var workspaceActivitySnapshot = WorkspaceActivitySnapshot.empty
    private var onboardingNotchOverrideActive = false
    private var permissionSetupNotchState: PermissionSetupNotchState?
    private var bridgeWatchdog: Timer?
    private var bridgeWatchdogTask: Task<Void, Never>?
    private var programStatusTask: Task<Void, Never>?
    /// True while a menu-started terminal session owns the bridge.
    private var menuSessionActive = false {
        didSet {
            syncNotchStatusSurface()
            syncCommandCaptureOwnership()
        }
    }
    @ObservationIgnored private var activeSessionLaunchConfig: AppConfig?
    @ObservationIgnored private var continuityRecoveryGenerationBySession: [String: String] = [:]
    @ObservationIgnored private var appliedContinuityRecoveryKeys: Set<String> = []
    @ObservationIgnored private var releasedContinuityProviderTargets: Set<String> = []
    @ObservationIgnored private var continuityRecoveryCooldowns: [String: CFTimeInterval] = [:]
    @ObservationIgnored private var pendingContinuityProviderReady: ContinuityProviderReadyContext?
    @ObservationIgnored private var userDeliveryRecoveryPending = false
    @ObservationIgnored private let projectRegistryV2 = ProjectRegistryV2Service.makeIfEnabled()
    @ObservationIgnored private let projectScopeCoordinator = ProjectScopeCoordinator()
    @ObservationIgnored private var activeSessionProjectScopeToken: ConfirmedProjectScopeToken?
    /// Cached by the watchdog so the 20fps poll timer avoids spawning pgrep.
    private var bridgeAliveCache = false {
        didSet {
            // A restarted bridge forgets every target but its startup session.
            if bridgeAliveCache { syncVoiceFocus() } else { sentVoiceFocus = [] }
            syncNotchStatusSurface()
            syncCommandCaptureOwnership()
        }
    }
    private var bridgeManagedProviderState: (process: AssistantManagedProviderProcess, state: AssistantManagedProviderProcess.State)? {
        didSet {
            guard oldValue?.process != bridgeManagedProviderState?.process
                    || oldValue?.state != bridgeManagedProviderState?.state else { return }
            syncNotchStatusSurface()
            syncCommandCaptureOwnership()
        }
    }
    private var wasRecording = false
    private var onboardingTutorialSpeechActive = false
    private var observedRecordingStartedSerial = 0
    private var observedSpeechDetectedSerial = 0
    private var observedDeliveredTranscriptSerial = 0
    private var observedTutorialTranscriptSerial = 0
    private var observedCaptureOwnerRequestedSerial = 0
    /// Caps Lock state when the session prompt was shown — any toggle dismisses it.
    private var sessionPromptCapsState = false
    private var sessionPromptGate = SessionPromptGate()
    /// Grace period: don't let the watchdog revert a session before the bridge has time to start.
    private var sessionStartTime: Date = .distantPast
    @ObservationIgnored private var pendingSessionLaunchID: UUID?
    /// Has the bridge for the current menu-started session been observed alive at least once?
    /// Used to distinguish "still starting up" from "came up and then died".
    private var sessionBridgeSeen = false {
        didSet {
            guard oldValue != sessionBridgeSeen else { return }
            syncNotchStatusSurface()
        }
    }
    /// Session-level contract shared by the bridge and app overlay. Tutorial
    /// sessions suppress the bridge greeting, including after recovery.
    private var activeSessionSuppressesStartupGreeting = false
    private var bridgeRecoveryInFlight = false {
        didSet {
            syncNotchStatusSurface()
            syncCommandCaptureOwnership()
        }
    }
    private var programBoardLoadingState: ProgramBoardLoadingState = .idle
    private var lastBridgeRecoveryAt: Date = .distantPast
    private static let bridgeRecoveryCooldown: TimeInterval = 15
    private var bridgeRecoverySuppressedForUpdate = false
    @ObservationIgnored private var updateRelaunchObserver: NSObjectProtocol?
    /// Per-bridge-session flag for the per-parent permissions wizard. False at
    /// startup and after any bridge death; flipped true once the watchdog has
    /// either surfaced the wizard for this session or confirmed the parent is
    /// already onboarded. Without this, the watchdog's per-tick retry (needed
    /// to handle MCP's `parent_detected` arriving after the bridge transition)
    /// would re-open the wizard window every 3s while it's dismissed.
    private var wizardShownForCurrentBridgeSession = false

    /// Whether any voice session is active (for menu bar UI). Covers both
    /// menu-started Start Session terminals and externally-started bridges
    /// (the /relay-bridge slash command). The watchdog flips bridgeAliveCache
    /// within ~3 seconds of an external bridge coming up, so /relay-bridge
    /// users see the menu reflect their session promptly.
    var hasActiveSession: Bool {
        let binding = assistantSessionStore.binding(for: voiceContext)
        return Self.voiceSessionIsActive(
            menuSessionActive: menuSessionActive,
            bridgeAlive: bridgeAliveCache,
            bridgeMatchesContext: bridgeMatchesActiveContext,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            embeddedPhase: voiceSession.phase,
            managedBinding: binding,
            managedProviderState: bridgeManagedProviderState.flatMap { $0.process == binding?.managedProcess ? $0.state : nil },
            bridgeProviderSessionID: ProcessManager.currentProviderSessionID()
        )
    }

    static func voiceSessionIsActive(
        menuSessionActive: Bool,
        bridgeAlive: Bool,
        bridgeMatchesContext: Bool,
        bridgeRecoveryInFlight: Bool,
        embeddedPhase: EmbeddedTerminalSession.Phase,
        managedBinding: AssistantSessionStore.Binding?,
        managedProviderState: AssistantManagedProviderProcess.State?,
        bridgeProviderSessionID: String?
    ) -> Bool {
        if menuSessionActive || bridgeRecoveryInFlight { return true }
        guard bridgeAlive, bridgeMatchesContext else { return false }
        // A surviving app-owned bridge cannot reconnect its interrupted
        // provider by itself. Keep Start available for explicit recovery;
        // unrelated standalone bridges retain their existing session behavior.
        if !embeddedPhase.isActive, managedBinding?.lifecycle == .interrupted,
           let transport = managedBinding?.transportSessionID, !transport.isEmpty,
           transport == bridgeProviderSessionID {
            // An app-launched external Terminal provider may survive a restart.
            // A live or unverifiable owner remains active until proven absent.
            return managedProviderState != .exited && managedProviderState != .stale
        }
        return true
    }

    private var bridgeMatchesActiveContext: Bool {
        guard let bridge = processManager.bridgeRecoveryContext() else { return false }
        return AssistantSessionStore.samePath(bridge.workingDirectory, voiceContext.workingDirectory)
    }

    /// Session-level microphone owner policy. Command capture may run only for
    /// an active Claude or Codex voice session (embedded, external bridge, or a
    /// bridge retained through provider reconnect) or the projectless onboarding
    /// voice tutorial. Note Taker owns its own capture, so command capture yields.
    /// A session that is still starting up has nothing ready to accept a command.
    static func commandCaptureAllowed(
        hasActiveSession: Bool,
        sessionControlsTutorialActive: Bool,
        noteOwnsForeground: Bool,
        sessionStartingUp: Bool = false
    ) -> Bool {
        !noteOwnsForeground && (sessionControlsTutorialActive || (hasActiveSession && !sessionStartingUp))
    }

    /// Whether a Settings reference recording may open the microphone now.
    var referenceRecordingAllowed: Bool {
        hasActiveSession && !meetingNoteSnapshot.phase.ownsForeground
    }

    private func syncCommandCaptureOwnership() {
        guard let engine = sttEngine else { return }
        engine.setCaptureAllowed(Self.commandCaptureAllowed(
            hasActiveSession: hasActiveSession,
            sessionControlsTutorialActive: onboardingTutorialSpeechActive,
            noteOwnsForeground: meetingNoteSnapshot.phase.ownsForeground,
            // Never drop a recording already in flight for another session.
            sessionStartingUp: bridgeStartingUp && !engine.isRecording
        ))
    }

    private var bridgeStartingUp: Bool {
        menuSessionActive && !sessionBridgeSeen && !bridgeRecoveryInFlight
    }

    private func syncNotchStatusSurface() {
        notchStatusController.setActive(overlayController != nil)
        syncNotchActivitySurface()
    }

    private func setOnboardingNotchOverrideActive(_ active: Bool) {
        guard onboardingNotchOverrideActive != active else { return }
        onboardingNotchOverrideActive = active
        syncNotchStatusSurface()
    }

    private func setFirstRunExperienceActive(_ active: Bool) {
        guard isFirstRunExperienceActive != active else { return }
        isFirstRunExperienceActive = active
        if active {
            programBoardOverlay.hide()
        }
    }

    static func allowsAppShellAccess(
        firstRunExperienceActive: Bool,
        sharedOnboardingInProgress: Bool = false
    ) -> Bool {
        !firstRunExperienceActive && !sharedOnboardingInProgress
    }

    static func routeWorkspaceToggleRequest(
        consumeForTutorial: Bool,
        toggleWorkspace: () -> Void,
        completeTutorial: () -> Void
    ) {
        if consumeForTutorial {
            completeTutorial()
        } else {
            toggleWorkspace()
        }
    }

    private var allowsAppShellAccess: Bool {
        Self.allowsAppShellAccess(
            firstRunExperienceActive: isFirstRunExperienceActive,
            sharedOnboardingInProgress: OnboardingController.sharedOnboardingInProgress()
        )
    }

    func requestPermissionSetup(_ kind: PermissionKind,
                                source: PermissionSetupSource,
                                purpose: String = "") {
        permissionSetupCoordinator.request(kind, source: source, purpose: purpose)
    }

    private func prepareForPermissionExternalWindow(_ kind: PermissionKind) {
        guard kind.opensSystemSettingsDuringSetup else { return }
        suspendWorkspaceForExternalWindow()
        permissionRelaunchGuard.armIfNeeded(for: kind)
    }

    /// Keep Awake's one-time approval opens Login Items, so the wheel and Workspace step
    /// aside like they do for a privacy permission, and a tile beside Settings shows the switch.
    private func keepAwakeStateChanged(from previous: KeepAwakeState, to next: KeepAwakeState) {
        if next == .awaitingApproval {
            sessionWheel.dismiss()
            suspendWorkspaceForExternalWindow()
            keepAwakeApprovalGuide.show()
        } else if previous == .awaitingApproval {
            if next == .enabling || next.isOn {
                keepAwakeApprovalGuide.showAllowed()
            } else {
                keepAwakeApprovalGuide.dismiss()
            }
        }
    }

    func cancelPermissionSetup(source: PermissionSetupSource? = nil) {
        permissionSetupCoordinator.cancel(source: source)
    }

    private func setPermissionSetupNotchState(_ state: PermissionSetupNotchState?) {
        guard permissionSetupNotchState != state else { return }
        permissionSetupNotchState = state
        syncNotchStatusSurface()
    }

    private func startNotchActivityPolling() {
        notchActivityPollingActive = true
        updateWorkspaceActivityPolling()
        refreshWorkspaceActivity()
    }

    private func stopNotchActivityPolling() {
        notchActivityPollingActive = false
        updateWorkspaceActivityPolling()
        notchActivityRunStates = []
        notchActivityTickets = []
        notchActivityTicketsByRunKey = [:]
        notchStatusController.clearWorkingActivity()
    }

    private func refreshWorkspaceActivity(
        invalidateRoute: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        if invalidateRoute {
            workspaceActivityRefreshID += 1
            workspaceActivityTask?.cancel()
            workspaceActivityTask = nil
            workspaceActivitySnapshot = .empty
        }
        guard workspaceActivityTask == nil else { return }
        let bridgeSessionAlive = hasActiveSession
        workspaceActivityRefreshID += 1
        let refreshID = workspaceActivityRefreshID
        workspaceActivityTask = Task { @MainActor [weak self, workspaceActivityStore] in
            if invalidateRoute {
                await workspaceActivityStore.cancel(invalidate: true)
            }
            let snapshot = await workspaceActivityStore.refresh(
                bridgeSessionAlive: bridgeSessionAlive
            )
            guard let self, self.workspaceActivityRefreshID == refreshID else { return }
            self.workspaceActivityTask = nil
            guard !Task.isCancelled else { return }
            self.workspaceActivitySnapshot = snapshot
            if self.hasActiveSession {
                self.notchActivityRunStates = snapshot.runStates
                self.notchActivityTickets = snapshot.tickets
                self.notchActivityTicketsByRunKey = snapshot.ticketsByRunKey
            } else {
                self.clearNotchActivityProjectState(cancelRefresh: false)
            }
            self.syncNotchActivitySurface()
            if invalidateRoute {
                self.programBoardOverlay.refreshProjectScopeAfterRegistryChange()
            } else {
                self.programBoardOverlay.refreshRouteIfNeeded()
            }
            completion?()
        }
    }

    private func cancelWorkspaceActivityRefresh(invalidate: Bool) {
        workspaceActivityRefreshID += 1
        workspaceActivityTask?.cancel()
        workspaceActivityTask = nil
        Task { [workspaceActivityStore] in
            await workspaceActivityStore.cancel(invalidate: invalidate)
        }
        if invalidate {
            workspaceActivitySnapshot = .empty
        }
    }

    private func clearNotchActivityProjectState(cancelRefresh: Bool = true) {
        if cancelRefresh {
            cancelWorkspaceActivityRefresh(invalidate: false)
        }
        notchActivityRunStates = []
        notchActivityTickets = []
        notchActivityTicketsByRunKey = [:]
        syncNotchActivitySurface()
    }

    private func syncNotchActivitySurface() {
        defer { sessionWheel.model.notchStatus = notchStatusController.status }
        if let presentation = Self.setupNotchPresentation(
            onboardingActive: onboardingNotchOverrideActive,
            permissionState: permissionSetupNotchState
        ) {
            notchStatusController.setPresentation(
                status: presentation.status,
                activityLabels: presentation.activityLabels,
                workingProgressLabel: presentation.workingProgressLabel
            )
            return
        }

        if let note = meetingNoteSnapshot.notchPresentation {
            notchStatusController.setPresentation(
                status: note.status,
                activityLabels: note.label.map { [$0] } ?? [],
                workingProgressLabel: note.label,
                pinsWorkingLabel: note.pinsLabel
            )
            return
        }

        let boardIsLoading = programBoardLoadingState != .idle
        let boardContentLoading = programBoardLoadingState == .loadingContent
        guard hasActiveSession || boardIsLoading || stateMachine.storyboardDemoEnabled else {
            notchStatusController.setPresentation(
                status: .notWorking,
                activityLabels: [],
                workingProgressLabel: nil
            )
            return
        }

        let foregroundActivityLabel =
            NotchActivityLabelPlanner.label(forWorkingProgress: stateMachine.currentWorkingProgress())
        let voiceTargetName = listeningVoiceTargetName
        let playbackTargetName = playingVoiceTargetName
        let switchNotice = sessionSwitchNotice
        let remoteDeviceLabel = remoteStatusLabel
        let labels = NotchActivityLabelPlanner.labels(
            for: stateMachine.state,
            foregroundActivity: foregroundActivityLabel,
            activeRuns: notchActivityRunStates,
            tickets: notchActivityTickets,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            bridgeStartingUp: bridgeStartingUp,
            boardContentLoading: boardContentLoading,
            voiceTargetName: voiceTargetName,
            playbackTargetName: playbackTargetName,
            switchNotice: switchNotice,
            remoteDeviceLabel: remoteDeviceLabel
        )
        let hoverActivityLabel = NotchActivityLabelPlanner.hoverLabel(
            for: stateMachine.state,
            foregroundActivity: foregroundActivityLabel,
            activeRuns: notchActivityRunStates,
            tickets: notchActivityTickets,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            bridgeStartingUp: bridgeStartingUp,
            boardContentLoading: boardContentLoading,
            voiceTargetName: voiceTargetName,
            playbackTargetName: playbackTargetName,
            switchNotice: switchNotice,
            remoteDeviceLabel: remoteDeviceLabel,
            ticketForRun: { [notchActivityTicketsByRunKey] run in
                let repoPath = URL(fileURLWithPath: run.repoPath).resolvingSymlinksInPath().path
                return notchActivityTicketsByRunKey[
                    Self.notchActivityRunKey(repoPath: repoPath, ticketId: run.ticketId)
                ]
            }
        )
        let hasActiveWork = NotchActivityLabelPlanner.hasActiveWork(
            state: stateMachine.state,
            foregroundActivity: foregroundActivityLabel,
            activeRuns: notchActivityRunStates,
            tickets: notchActivityTickets,
            bridgeRecoveryInFlight: bridgeRecoveryInFlight,
            bridgeStartingUp: bridgeStartingUp,
            boardIsLoading: boardIsLoading
        )
        notchStatusController.setPresentation(
            status: NotchSessionStatus.resolve(
                for: stateMachine.state,
                hasActivityLabels: hasActiveWork || switchNotice != nil || remoteDeviceLabel != nil,
                boardIsLoading: boardIsLoading
            ),
            activityLabels: labels,
            workingProgressLabel: hoverActivityLabel,
            pinsWorkingLabel: NotchVisualLabelAllowlist.presentation(
                for: stateMachine.state,
                bridgeStartingUp: bridgeStartingUp,
                boardContentLoading: boardContentLoading,
                switchNotice: switchNotice
            ).pinsLabel
        )
    }

    static func setupNotchPresentation(onboardingActive: Bool,
                                       permissionState: PermissionSetupNotchState?) -> NotchPresentation? {
        guard onboardingActive || permissionState != nil else { return nil }
        return NotchPresentation(
            status: .working,
            activityLabels: [],
            workingProgressLabel: nil
        )
    }

    static func onboardingNotchPresentation(active: Bool) -> NotchPresentation? {
        setupNotchPresentation(onboardingActive: active, permissionState: nil)
    }

    private static func notchActivityRunKey(repoPath: String, ticketId: String) -> String {
        "\(repoPath)|\(ticketId)"
    }

    @MainActor
    init(
        checkForUpdates: @escaping @MainActor () -> Void = {},
        updater: RelayUpdaterController? = nil,
        bundleURL: URL = Bundle.main.bundleURL,
        refreshBundledOrchestratorDaemon: @escaping () async -> OrchestratorDaemonRefreshResult = {
            await OrchestratorClient.refreshBundledOrchestratorDaemonIfIdle()
        }
    ) {
        self.checkForUpdatesAction = checkForUpdates
        programBoardOverlay.setUpdater(updater)
        self.refreshBundledOrchestratorDaemon = refreshBundledOrchestratorDaemon
        self.refreshBundledServicesOnLaunch = RelayUpdaterController.shouldStartAutomatically(
            installerContext: nil,
            bundleURL: bundleURL
        )
        EmbeddedAgentDiagnostics.finalizeInterruptedSessionIfNeeded()
        self.config = ConfigManager.shared.load()
        do {
            if let registry = projectRegistryV2 {
                let generalTasks = try registry.ensureGeneralTasksProject()
                if assistantSessionStore.activeContext.isGeneral {
                    let token = try registry.confirmProject(projectID: generalTasks.projectID)
                    try assistantSessionStore.select(.project(token), provider: config.general.provider.rawValue,
                                                     model: config.general.model)
                }
            }
        } catch {
            NSLog("[relay-runner] could not prepare general-tasks: \(error)")
        }
        activeContext = assistantSessionStore.activeContext
        conversationID = assistantSessionStore.conversationID
        conversationHistory = assistantSessionStore.document.history
        contextSwitchMessage = assistantSessionStore.pendingContinuation?.message ?? assistantSessionStore.loadError
        if let binding = assistantSessionStore.binding(for: activeContext), binding.lifecycle == .interrupted {
            contextSwitchMessage = "Conversation restored. Start Session to reconnect \(activeContext.displayName); saved actions are not replayed."
        }
        programBoardOverlay.setGeneralContextProvider { [weak self] in self?.activeContext.isGeneral ?? true }
        programBoardOverlay.setContextPathProvider { [weak self] in self?.activeContext.repositoryPath }
        programBoardOverlay.setWorkerSizingDefaultsProvider { [weak self] in
            guard let self else { return nil }
            return TicketWriter.WorkerSizingDefaults.from(self.config.general)
        }
        programBoardOverlay.setStartSessionHandler { [weak self] projectPath in
            self?.newSession(workingDirectory: projectPath)
        }
        programBoardOverlay.setEndSessionHandler { [weak self] in
            guard let self else { return }
            self.endSession(context: self.activeContext)
        }
        programBoardOverlay.setNoteTakerHandlers(
            start: { [weak self] projectPath in
                self?.startNoteTaker(workingDirectory: projectPath) ?? false
            },
            stop: { [weak self] in self?.stopNoteTaker() }
        )
        programBoardOverlay.setNoteRecoveryHandlers(
            offers: { [weak self] in
                await self?.interruptedMeetingNotes() ?? []
            },
            resolve: { [weak self] sessionID, resolution, transcriptionModel in
                guard let self else { throw MeetingNoteCoordinatorError.recoveryNotFound }
                return try await self.resolveInterruptedMeetingNote(
                    sessionID: sessionID,
                    resolution: resolution,
                    transcriptionModel: transcriptionModel
                )
            },
            resume: { [weak self] in
                guard let self else { throw MeetingNoteCoordinatorError.recoveryNotFound }
                return try await self.resumeRecoveredMeetingNote()
            }
        )
        programBoardOverlay.setSessionActiveProvider { [weak self] in
            self?.shownContextHasSession ?? false
        }
        programBoardOverlay.setRunningSessionPathsProvider { [weak self] in
            self?.runningSessionProjectPaths ?? []
        }
        programBoardOverlay.setSessionReplyBadgesProvider { [weak self] in
            self?.sessionReplyBadgeProjectPaths ?? [:]
        }
        programBoardOverlay.setSessionProvider { [weak self] in
            self?.config.general.provider ?? .codex
        }
        programBoardOverlay.setNoteCaptureSnapshotProvider { [weak self] in
            self?.meetingNoteSnapshot ?? MeetingNoteCoordinatorSnapshot(
                phase: .idle,
                noteID: nil,
                project: nil,
                liveHypothesisCount: 0,
                durableSegmentCount: 0,
                syncState: nil,
                errorMessage: nil
            )
        }
        programBoardOverlay.setBoardRouteResolver { [weak self] in
            guard let self else { return .unavailable }
            if let path = self.activeContext.repositoryPath {
                return .project(ProjectResolver.LinkedProject(
                    repoPath: URL(fileURLWithPath: path, isDirectory: true),
                    projectID: self.activeContext.projectID
                ))
            }
            return self.workspaceActivitySnapshot.route
        }
        programBoardOverlay.setProjectScopeProvider { [weak self] in
            self?.workspaceActivitySnapshot.projects.map(\.repoPath.path) ?? []
        }
        programBoardOverlay.setProjectManagementHandlers(
            addExisting: { [weak self] in self?.addExistingProject() },
            create: { [weak self] in self?.createProject() }
        )
        programBoardOverlay.setProjectSelectionHandler { [weak self] repoPath in
            guard let self else { return }
            // RR-396: a card focuses its project's running session, or only
            // browses its tickets; Start session is the one way to launch.
            let runs = self.runningSessionProjectPaths.contains { AssistantSessionStore.samePath($0, repoPath) }
            _ = self.selectProjectContext(repositoryPath: repoPath, startsSession: runs)
        }
        programBoardOverlay.setRequiresConfirmedProjectProvider { [weak self] in
            self?.projectRegistryV2 != nil
        }
        programBoardOverlay.setProjectScopeTokenProvider { [weak self] repoPath in
            guard let registry = self?.projectRegistryV2 else { return nil }
            return try? registry.scopeToken(matching: repoPath).encodedValue
        }
        sessionRegistry.setHandlers(
            exit: { [weak self] contextID, exitCode in
                self?.embeddedTerminalDidExit(contextID: contextID, exitCode: exitCode)
            },
            ready: { [weak self] contextID in
                self?.embeddedTerminalDidBecomeReady(contextID: contextID)
            }
        )
        notchStatusController.setGlyphClickHandler { [weak self] in
            self?.toggleBoard()
        }
        sessionWheel.refresh = { [weak self] model, includesProjects in
            self?.refreshSessionWheel(model, includesProjects: includesProjects)
        }
        sessionWheel.haptics.isEnabled = { [weak self] in self?.config.general.wheel_haptics ?? false }
        sessionWheel.toggleWorkspace = { [weak self] in self?.toggleWorkspace() }
        sessionWheel.openShortcut = { [weak self] shortcut in
            guard let self, self.allowsAppShellAccess else { return }
            if self.overlayController == nil { self.startOverlay() }
            switch shortcut {
            case .workspace: self.programBoardOverlay.showWork()
            case .noteTaker: self.programBoardOverlay.showNotes()
            case .settings: self.programBoardOverlay.showSettings()
            }
        }
        sessionWheel.noteAction = { [weak self] in self?.performNoteWheelAction($0) ?? false }
        sessionWheel.previewIntensity = { [weak self] value in
            guard let self else { return }
            var awareness = self.config.awareness
            awareness.glow_intensity = value
            self.overlayController?.updateConfig(awareness)
        }
        sessionWheel.commitIntensity = { [weak self] value in
            guard let self, self.config.awareness.glow_intensity != value else { return }
            var next = self.config
            next.awareness.glow_intensity = value
            self.saveConfig(next)
        }
        sessionWheel.previewParticles = { [weak self] in self?.overlayController?.setParticlePreview($0) }
        sessionWheel.keepAwakeAction = { [weak self] in self?.keepAwake.toggle() ?? false }
        keepAwake.onStateChange = { [weak self] previous, next in self?.keepAwakeStateChanged(from: previous, to: next) }
        sessionWheel.focusSession = { [weak self] in self?.switchSessionFromWheel(contextID: $0) }
        sessionWheel.startProject = { [weak self] path in
            self?.newSession(workingDirectory: path, showsWorkspaceOnLaunch: false) ?? false
        }
        sessionWheel.sessionAction = { [weak self] id, action in
            self?.performSessionWheelAction(contextID: id, action: action) ?? false
        }
        sessionWheel.recordingLevel = { [weak self] id in
            guard let self, let key = self.sessionRegistry.spool(for: id)?.key else { return 0 }
            return self.sttEngine?.recordingLevel(forSessionKey: key) ?? 0
        }
        self.updateRelaunchObserver = NotificationCenter.default.addObserver(
            forName: .relayRunnerWillRelaunchForUpdate,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.prepareForSparkleRelaunch()
        }
        self.appTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.keepAwake.shutdown()
        }
        refreshConfiguredWorkspaceDiscoveryIfNeeded(
            oldConfig: nil,
            newConfig: config,
            force: false
        )
        keepAwake.recoverIfNeeded()
        // Watch privacy permissions continuously — macOS doesn't notify us
        // when the user grants/revokes in Settings, so we poll.
        permissions.startMonitoring()
        // Hook permission transitions: notify on revoke, auto-recover STT
        // when mic/global-event access comes back (the STT engine binds to the
        // mic + installs NSEvent monitors at start, so neither recovers
        // without a restart).
        permissions.onChange = { [weak self] kind, old, new in
            guard let self else { return }
            self.permissionNotifier.recordChange(kind, from: old, to: new)
            self.permissionSetupCoordinator.permissionStatusChanged(kind, status: new)
            if new == .granted && old != .granted {
                if kind == .microphone {
                    if self.sttEngine == nil {
                        self.startAwareness()
                    } else {
                        self.restartSTTForRecovery()
                    }
                } else if kind == .accessibility || kind == .inputMonitoring {
                    self.programBoardOverlay.installGlobalDismissHotkey()
                    self.restartSTTForRecovery()
                }
            }
        }
        // Start awareness on next run loop tick (after app finishes launching)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let launchPlan = Self.launchPlan(for: self.permissions.microphone)
            if launchPlan.startsOverlay {
                // Keep Workspace routing and the no-session/Work surfaces
                // available even before STT starts.
                self.startOverlay()
            }
            // Don't touch the microphone at install/open time. Onboarding owns
            // the permission ask, and STT starts only after the grant applies.
            if launchPlan.startsAwareness {
                self.startAwareness()
            } else {
                self.statusText = launchPlan.statusText ?? self.statusText
            }
            self.onboarding.showIfNeeded()
            FourFingerTapMonitor.shared.onTap = { [weak self] in self?.toggleSessionWheel() }
            FourFingerTapMonitor.shared.start()
            if self.refreshBundledServicesOnLaunch {
                self.refreshBundledServicesAfterLaunch()
            }
        }
    }

    deinit {
        if let updateRelaunchObserver {
            NotificationCenter.default.removeObserver(updateRelaunchObserver)
        }
        if let appTerminationObserver {
            NotificationCenter.default.removeObserver(appTerminationObserver)
        }
        keepAwake.shutdown()
    }

    func checkForUpdates() {
        Task { @MainActor [checkForUpdatesAction] in
            checkForUpdatesAction()
        }
    }

    static func launchPlan(for microphone: PermissionStatus) -> LaunchPlan {
        if microphone == .granted {
            return LaunchPlan(startsOverlay: true, startsAwareness: true, statusText: nil)
        }
        return LaunchPlan(
            startsOverlay: true,
            startsAwareness: false,
            statusText: "Microphone permission needed"
        )
    }

    static func serviceLifecycleMessage(for result: OrchestratorDaemonRefreshResult) -> String? {
        switch result {
        case .restarted:
            return nil
        case .notInstalled:
            return nil
        case .deferredActiveRuns:
            return (
                "Bundled service refresh deferred until active orchestrator workers finish. "
                + "Quit and reopen Relay Runner after they finish."
            )
        case .failed(let message):
            return message.isEmpty
                ? "Bundled service refresh failed. Quit and reopen Relay Runner to retry."
                : "Bundled service refresh failed: \(message)"
        }
    }

    private func refreshBundledServicesAfterLaunch() {
        Task { [weak self, refreshBundledOrchestratorDaemon] in
            let result = await refreshBundledOrchestratorDaemon()
            let message = Self.serviceLifecycleMessage(for: result)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.serviceLifecycleMessage = message
                switch result {
                case .restarted:
                    NSLog("[RelayRunner] Bundled orchestrator daemon refreshed after app launch.")
                case .notInstalled:
                    NSLog("[RelayRunner] Bundled orchestrator refresh skipped; launch agent is not installed.")
                case .deferredActiveRuns:
                    NSLog("[RelayRunner] Bundled orchestrator refresh deferred because active workers are running.")
                case .failed(let message):
                    NSLog("[RelayRunner] Bundled orchestrator refresh failed: \(message)")
                }
            }
        }
    }

    static func setupRuntimeReadiness(
        engineStatusMessage: String?,
        engineError: String?,
        setupSucceeded: Bool = false,
        startedAt: Date?,
        now: Date = Date(),
        timeout: TimeInterval = SetupRuntimeReadiness.defaultTimeout
    ) -> SetupRuntimeReadiness {
        SetupRuntimeReadiness.resolve(
            engineStatusMessage: engineStatusMessage,
            engineError: engineError,
            setupSucceeded: setupSucceeded,
            startedAt: startedAt,
            now: now,
            timeout: timeout
        )
    }

    /// Recreate the STT engine so it re-binds to the microphone and reinstalls
    /// global key monitors. Called from `permissions.onChange` when a
    /// previously-denied permission gets granted.
    private func restartSTTForRecovery() {
        guard isRunning else { return }
        NSLog("[AppState] Permission restored — restarting STT for recovery")
        restartSTT(reason: "permission-recovery")
    }

    /// User-facing retry, e.g. from the menu's "Retry Setup" item after
    /// setupStatusFailed fired. Clears the prior error and recreates the
    /// engine so the statusMessage pipeline re-runs from scratch.
    func retrySTTSetup() {
        sttEngineError = nil
        restartSTT(reason: "user-retry")
    }

    private func restartSTT(reason: String) {
        guard !meetingNoteSnapshot.phase.ownsForeground else { return }
        sttEngine?.stop()
        startConfiguredSTT(reason: reason, failureLogPrefix: "STT restart (\(reason)) failed")
    }

    private func startConfiguredSTT(reason: String, failureLogPrefix: String) {
        guard !meetingNoteSnapshot.phase.ownsForeground else { return }
        let engine = STTEngine(config: config.stt)
        engine.tutorialActive = onboardingTutorialSpeechActive
        sttEngine = engine
        engine.onRemoteTakeover = { [weak self] in
            Task { @MainActor in self?.remoteDeviceSession.userTookOver() }
        }
        if remoteDeviceSession.activeDeviceID != nil { engine.suspendForRemoteDevice() }
        syncCommandCaptureOwnership()
        resetObservedTutorialSTTSerials()
        sttSetupStartedAt = Date()
        sttSetupSucceeded = false
        sttEngineError = nil
        Task { [weak self, engine] in
            do {
                try await engine.start()
                await MainActor.run { [weak self, engine] in
                    self?.completeSTTSetupIfCurrent(engine)
                }
            } catch {
                await MainActor.run { [weak self, engine] in
                    self?.failSTTSetupIfCurrent(engine, error: error)
                }
                NSLog("[AppState] \(failureLogPrefix): \(error)")
            }
        }
        NSLog("[AppState] STT setup started: \(reason)")
    }

    private func completeSTTSetupIfCurrent(_ engine: STTEngine) {
        guard sttEngine === engine else { return }
        sttEngineError = nil
        sttSetupStartedAt = nil
        sttSetupSucceeded = true
    }

    private func failSTTSetupIfCurrent(_ engine: STTEngine, error: Error) {
        guard sttEngine === engine else { return }
        sttEngineError = "\(error)"
        sttSetupStartedAt = nil
        sttSetupSucceeded = false
    }

    /// Start STT + overlay for gesture detection. No bridge — user must
    /// start a session or run /relay-bridge manually.
    private func startAwareness() {
        guard sttEngine == nil else { return }
        if STTModelPolicy.adoptsPhononWithoutParakeet(
            for: config.stt,
            parakeetV2Cached: STTModelPreparation.hasCachedParakeetAssets(.parakeetV2)
        ) {
            var next = config
            next.stt = next.stt.applyingPhononMigration()
            persistConfig(next)
        }

        startConfiguredSTT(reason: "awareness-start", failureLogPrefix: "STT engine failed to start")
        isRunning = true
        statusText = "Ready"
        startPhononMigrationIfEligible()

        startBridgeWatchdog()

        startOverlay()
    }

    /// Explicit user recovery preserves the bridge and waits for provider exit.
    func recoverBlockedVoiceDelivery() {
        guard !userDeliveryRecoveryPending else { return }
        guard voiceSession.deliveryBlocked,
              let launch = activeSessionLaunchConfig,
              processManager.bridgeAlive(),
              let claim = ProcessManager.currentRelayClaimIdentity(),
              let commandID = claim["relay_command_id"] as? String,
              let generation = continuityRecoveryGenerationBySession[
                ContinuityRecoveryRequest.projectSessionIdentifier(
                    repositoryPath: launch.general.working_directory
                )
              ],
              let previousSessionID = ProcessManager.currentProviderSessionID()
        else {
            voiceSession.deliveryRecoveryMessage = "Session delivery blocked. Recovery ownership is unavailable; the session and queued messages were left untouched."
            return
        }
        pendingContinuityProviderReady = ContinuityProviderReadyContext(
            nativeCommandID: commandID,
            commandID: ContinuityRecoveryRequest.opaqueIdentifier(kind: "command", nativeValue: commandID),
            provider: launch.general.provider.rawValue,
            recoveryGeneration: generation,
            previousProviderSessionID: previousSessionID,
            providerSessionID: nil,
            appSessionID: nil,
            foregroundGateHandle: nil
        )
        userDeliveryRecoveryPending = true
        pendingContinuityProviderReady?.discardUnacknowledgedClaim = true
        voiceSession.deliveryRecoveryMessage = "Restart requested. Waiting for the old provider to exit; queued messages are preserved."
        if !voiceSession.requestDeliveryRecovery() {
            userDeliveryRecoveryPending = false
            pendingContinuityProviderReady = nil
            voiceSession.deliveryRecoveryMessage = "The blocked session could not be stopped. No replacement was launched; queued messages are preserved."
        }
    }

    /// End every context's session and revert to awareness mode.
    func endSession() {
        saveLiveAssistantSessions()
        pendingContextSelection = nil
        try? assistantSessionStore.cancelContinuation()
        sessionRegistry.endAll()
        resetActiveSessionState()
    }

    /// RR-396: repository paths of projects with a live embedded session.
    var runningSessionProjectPaths: [String] {
        sessionRegistry.liveContextIDs.compactMap { assistantSessionStore.document.bindings[$0]?.context.repositoryPath }
    }

    /// RR-396: whether the context the board shows has its own session. With
    /// no embedded session live, an external bridge session still counts.
    var shownContextHasSession: Bool {
        sessionRegistry.hasLiveSessions ? sessionRegistry.isLive(activeContext.id) : hasActiveSession
    }

    /// RR-395: one Workspace terminal tab per live session, labelled with its context.
    var workspaceSessionTabs: [(id: String, name: String)] {
        sessionRegistry.liveContextIDs.map { id in
            (id, assistantSessionStore.document.bindings[id]?.context.displayName ?? id)
        }
    }

    /// RR-401: badge counts keyed by project path, for the board's project cards.
    var sessionReplyBadgeProjectPaths: [String: Int] {
        sessionReplyBadges.reduce(into: [:]) { paths, entry in
            if let path = assistantSessionStore.document.bindings[entry.key]?.context.repositoryPath {
                paths[path] = entry.value
            }
        }
    }

    /// RR-401: read each background session's badge file. The focused
    /// session shows none; the bridge clears its file on focus.
    private func refreshSessionReplyBadges() {
        let badges = sessionRegistry.liveContextIDs.reduce(into: [String: Int]()) { badges, contextID in
            guard contextID != activeContext.id,
                  let spool = sessionRegistry.spool(for: contextID), !spool.isLegacy else { return }
            let count = VoiceReplyBadge.load(path: spool.replyBadge).count
            if count > 0 { badges[contextID] = count }
        }
        if badges != sessionReplyBadges { sessionReplyBadges = badges }
    }

    /// RR-401: speak a session's latest stored reply on request. Replies are
    /// never replayed automatically.
    func readOutSessionReply(contextID: String) {
        guard let key = sessionRegistry.spool(for: contextID)?.key,
              let message = Self.voiceReplayMessage(sessionKey: key) else { return }
        _ = SocketClient.bridgeSend(message)
    }

    static func voiceReplayMessage(sessionKey: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["session_key": sessionKey]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "__REPLAY__:" + json
    }

    /// RR-395: a Workspace terminal tab was selected; focus that context's
    /// live session (which also routes voice there).
    func focusSessionTab(contextID: String, showsTerminal: Bool = true) {
        guard contextID != activeContext.id,
              let context = assistantSessionStore.document.bindings[contextID]?.context else { return }
        if context.isGeneral {
            selectGeneralContext(showsTerminal: showsTerminal)
        } else if let path = context.repositoryPath {
            selectProjectContext(repositoryPath: path, showsTerminal: showsTerminal)
        }
    }

    /// Selecting the focused session opens its terminal. Switching sessions
    /// retargets voice without raising Workspace; the notch reports the result.
    private func switchSessionFromWheel(contextID: String) {
        guard let name = workspaceSessionTabs.first(where: { $0.id == contextID })?.name else { return }
        if contextID == activeContext.id {
            programBoardOverlay.showTerminal()
            return
        }
        let recording = sttEngine?.isRecording == true
        focusSessionTab(contextID: contextID, showsTerminal: false)
        showSessionSwitchNotice(SessionSwitchNotice(
            switchingTo: name,
            focused: activeContext.id == contextID,
            pending: pendingContextSelection?.id == contextID,
            recording: recording
        ))
    }

    private func showSessionSwitchNotice(_ notice: SessionSwitchNotice?) {
        guard let notice else { return }
        sessionSwitchNoticeExpiry?.cancel()
        sessionSwitchNotice = notice
        syncNotchActivitySurface()
        let expiry = DispatchWorkItem { [weak self] in
            self?.sessionSwitchNotice = nil
            self?.syncNotchActivitySurface()
        }
        sessionSwitchNoticeExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionSwitchNotice.displayDuration, execute: expiry)
    }

    /// RR-395: closing a tab stops only that context's session, like Stop.
    func closeSessionTab(contextID: String) {
        guard let context = assistantSessionStore.document.bindings[contextID]?.context else { return }
        endSession(context: context)
    }

    /// RR-394: end only `context`'s session, PTY and spool. Other contexts keep
    /// running; the shared bridge stops only with the last live session.
    func endSession(context: AssistantSessionContext) {
        guard sessionRegistry.liveContextIDs.contains(where: { $0 != context.id }) else {
            endSession()
            return
        }
        saveAssistantSession(lifecycle: .saved, context: context)
        if pendingContextSelection == context { pendingContextSelection = nil }
        let bridgeTargetsContext = context.id == voiceContextID
        let retainedSpool = sessionRegistry.end(contextID: context.id, retainingSpool: bridgeTargetsContext)
        if context == activeContext { focusNextLiveContext() }
        if bridgeTargetsContext { retargetVoiceBridge(releasing: retainedSpool) }
        refreshWorkspaceActivity(invalidateRoute: true)
    }

    /// The bridge published into an ended context's spool: relaunch it into a
    /// live context's spool, and only then remove the ended spool.
    private func retargetVoiceBridge(releasing endedSpool: VoiceSessionSpool?) {
        let live = sessionRegistry.liveContextIDs
        let targetID = live.contains(activeContext.id) ? activeContext.id : live.first
        guard let targetID,
              let binding = assistantSessionStore.document.bindings[targetID],
              let spool = sessionRegistry.spool(for: targetID) else {
            voiceContextID = nil
            endedSpool?.remove()
            return
        }
        voiceContextID = targetID
        // RR-398: a running bridge moves with `__FOCUS__` and keeps its pid. It
        // hands the ended spool's queued command over before the spool goes.
        if processManager.bridgeAlive(), syncVoiceFocus(force: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.endedSpoolHandoffGrace) {
                endedSpool?.remove()
            }
            return
        }
        sentVoiceFocus = []
        let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
            repositoryPath: binding.context.workingDirectory
        )
        let recoveryContext = ProcessManager.BridgeRecoveryContext(
            workingDirectory: binding.context.workingDirectory,
            provider: binding.provider,
            recoveryGeneration: continuityRecoveryGenerationBySession[sessionID],
            sessionScope: binding.context.kind.rawValue,
            generalFilesRoot: AssistantSessionStore.filesDirectory.path,
            preservesContextAuthorization: true,
            spoolDirectory: spool.directory
        )
        bridgeRecoveryInFlight = true
        NSLog("[AppState] Retargeting voice bridge to \(recoveryContext.workingDirectory)")
        let processManager = self.processManager
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let retargeted = processManager.relaunchBridgeDaemon(
                context: recoveryContext,
                suppressStartupGreeting: true
            )
            DispatchQueue.main.async { [weak self] in
                endedSpool?.remove()
                guard let self else { return }
                self.bridgeRecoveryInFlight = false
                self.bridgeAliveCache = retargeted
                guard !retargeted, !self.processManager.bridgeStopRequested() else { return }
                self.statusText = "Voice bridge unavailable"
                self.stateMachine.showProgramStatus(
                    title: "Voice unavailable",
                    body: "Relay Runner could not move voice to the remaining session. Restart that session before speaking again."
                )
                self.syncNotchActivitySurface()
                NSLog("[AppState] Voice bridge retarget failed")
            }
        }
    }

    static let endedSpoolHandoffGrace: TimeInterval = 2

    /// RR-398: point the shared voice bridge at the focused live session
    /// without relaunching it. Every live session is registered, one datagram
    /// each with the focused one last, so the bridge can prune ended sessions;
    /// the next recording is stamped with the focused session's key.
    @discardableResult
    private func syncVoiceFocus(force: Bool = false) -> Bool {
        let live = sessionRegistry.liveContextIDs.filter { sessionRegistry.spool(for: $0)?.key != nil }
        guard let focusedID = [activeContext.id, voiceContextID].compactMap({ $0 }).first(where: live.contains)
                ?? live.first,
              let focusedKey = sessionRegistry.spool(for: focusedID)?.key else { return false }
        voiceContextID = focusedID
        sttEngine?.voiceTargetSessionKey = focusedKey
        let liveKeys = live.compactMap { sessionRegistry.spool(for: $0)?.key }
        let messages = (live.filter { $0 != focusedID } + [focusedID]).compactMap { contextID -> String? in
            guard let binding = assistantSessionStore.document.bindings[contextID],
                  let spool = sessionRegistry.spool(for: contextID), let key = spool.key else { return nil }
            let owner = continuationDestinationOwners[contextID] ?? [:]
            let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
                repositoryPath: binding.context.workingDirectory
            )
            return Self.voiceFocusMessage(
                sessionKey: key,
                provider: owner["provider"] ?? binding.provider,
                providerSessionID: owner["provider_session_id"] ?? "",
                workingDirectory: binding.context.workingDirectory,
                spoolDirectory: spool.directory,
                appSessionID: owner["app_session_id"] ?? "",
                recoveryGeneration: continuityRecoveryGenerationBySession[sessionID] ?? owner["recovery_generation"] ?? "",
                projectName: binding.context.displayName,
                focus: contextID == focusedID,
                liveSessionKeys: liveKeys
            )
        }
        guard force || messages != sentVoiceFocus else { return true }
        var delivered = true
        for message in messages where !SocketClient.bridgeSend(message) { delivered = false }
        sentVoiceFocus = delivered ? messages : []
        return delivered
    }

    /// One `__FOCUS__` control datagram for the shared voice bridge.
    static func voiceFocusMessage(
        sessionKey: String,
        provider: String,
        providerSessionID: String,
        workingDirectory: String,
        spoolDirectory: String,
        appSessionID: String,
        recoveryGeneration: String,
        projectName: String,
        focus: Bool,
        liveSessionKeys: [String]
    ) -> String? {
        let payload: [String: Any] = [
            "session_key": sessionKey,
            "provider": provider,
            "provider_session_id": providerSessionID,
            "cwd": workingDirectory,
            "spool_dir": spoolDirectory,
            "app_session_id": appSessionID,
            "recovery_generation": recoveryGeneration,
            "project_name": projectName,
            "focus": focus,
            "live_session_keys": liveSessionKeys,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "__FOCUS__:" + json
    }

    /// The project a recording is delivered to, shown while several sessions
    /// share the bridge.
    private var listeningVoiceTargetName: String? {
        let live = sessionRegistry.liveContextIDs
        guard live.count > 1, let sttEngine else { return nil }
        let key = sttEngine.isRecording
            ? sttEngine.recordingVoiceTargetSessionKey
            : sttEngine.voiceTargetSessionKey
        let contextID = live.first { key != nil && sessionRegistry.spool(for: $0)?.key == key } ?? voiceContextID
        return contextID.flatMap { assistantSessionStore.document.bindings[$0]?.context.displayName }
    }

    /// The project whose reply is playing, shown while several sessions share
    /// the bridge. Unknown or missing session keys show plain "Playing".
    private var playingVoiceTargetName: String? {
        playbackTargetName(
            sessionKey: stateMachine.speechPresentation?.sessionKey,
            liveContextIDs: sessionRegistry.liveContextIDs,
            spoolKey: { [sessionRegistry] in sessionRegistry.spool(for: $0)?.key },
            displayName: { [assistantSessionStore] in
                assistantSessionStore.document.bindings[$0]?.context.displayName
            }
        )
    }

    /// Save the focused context and every other context with a live session.
    private func saveLiveAssistantSessions() {
        for contextID in sessionRegistry.liveContextIDs where contextID != activeContext.id {
            if let context = assistantSessionStore.document.bindings[contextID]?.context {
                saveAssistantSession(lifecycle: .saved, context: context)
            }
        }
        saveAssistantSession(lifecycle: .saved)
    }

    /// After the focused context ends, show another live context's session.
    private func focusNextLiveContext() {
        guard let contextID = sessionRegistry.liveContextIDs.first,
              let binding = assistantSessionStore.document.bindings[contextID] else { return }
        do {
            try assistantSessionStore.select(binding.context, provider: binding.provider, model: binding.model)
            publishConversationState()
        } catch {
            contextSwitchMessage = "Could not save the conversation: \(error.localizedDescription)"
        }
    }

    /// Ends the existing work session, then starts project-independent note capture.
    @discardableResult
    func startNoteTaker(workingDirectory: String? = nil) -> Bool {
        guard allowsAppShellAccess else { return false }
        guard !meetingNoteSnapshot.phase.ownsForeground
                || meetingNoteSnapshot.phase == .error else { return true }
        guard let context = meetingNoteProjectContext(workingDirectory: workingDirectory) else {
            return false
        }

        meetingNoteTransitionID &+= 1
        let transitionID = meetingNoteTransitionID
        meetingNoteSnapshot = MeetingNoteCoordinatorSnapshot(
            phase: .preparing,
            noteID: nil,
            project: context.binding,
            liveHypothesisCount: 0,
            durableSegmentCount: 0,
            syncState: nil,
            errorMessage: nil
        )
        syncNotchActivitySurface()

        // End Session is the single work-mode teardown owner. Stopping the
        // awareness engine also removes its ordinary Caps Lock route before
        // note capture reads the actual key state.
        endSession()
        sttEngine?.stop()
        sttEngine = nil
        sttSetupStartedAt = nil
        sttSetupSucceeded = false
        stopMeetingNoteOptionGesture()
        startMeetingNoteOptionGesture()

        let coordinator = meetingNoteCoordinator ?? makeMeetingNoteCoordinator()
        meetingNoteCoordinator = coordinator
        let task = Task { @MainActor [weak self] () throws -> MeetingNoteCoordinatorSnapshot in
            guard let self else { throw MeetingNoteForegroundTransitionError.teardownTimedOut }
            try await self.waitForWorkSessionTeardownBeforeNote()
            return try await coordinator.start(
                project: context.binding,
                projectScopeToken: context.scopeToken,
                initiallyPaused: false
            )
        }
        meetingNoteStartTask = task
        Task { [weak self] in
            do {
                let snapshot = try await task.value
                await MainActor.run { [weak self] in
                    guard let self, transitionID == self.meetingNoteTransitionID else { return }
                    self.meetingNoteStartTask = nil
                    self.applyMeetingNoteSnapshot(snapshot)
                    self.startMeetingNoteOptionGesture()
                }
            } catch {
                let currentSnapshot = await coordinator.snapshot()
                let failureSnapshot: MeetingNoteCoordinatorSnapshot
                if currentSnapshot.phase == .idle {
                    failureSnapshot = MeetingNoteCoordinatorSnapshot(
                        phase: .error,
                        noteID: nil,
                        project: context.binding,
                        liveHypothesisCount: 0,
                        durableSegmentCount: 0,
                        syncState: nil,
                        errorMessage: error.localizedDescription
                    )
                } else {
                    failureSnapshot = currentSnapshot
                }
                await MainActor.run { [weak self] in
                    guard let self, transitionID == self.meetingNoteTransitionID else { return }
                    self.meetingNoteStartTask = nil
                    self.applyMeetingNoteSnapshot(failureSnapshot)
                    self.startMeetingNoteOptionGesture()
                }
            }
        }
        return true
    }

    private func waitForWorkSessionTeardownBeforeNote() async throws {
        let deadline = Date().addingTimeInterval(5)
        while sessionRegistry.hasLiveSessions || processManager.bridgeAlive() {
            guard Date() < deadline else {
                throw MeetingNoteForegroundTransitionError.teardownTimedOut
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Explicit note teardown without launching a provider. A successful save
    /// restores ordinary awareness/Caps Lock routing; failure leaves recovery
    /// ownership intact and does not restart the microphone.
    func stopNoteTaker() {
        if meetingNoteSnapshot.phase == .cancelling {
            cancelNoteTaker()
            return
        }
        guard let coordinator = meetingNoteCoordinator,
              meetingNoteSnapshot.phase.ownsForeground else { return }
        let pendingStartTask = meetingNoteStartTask
        let pendingRecoveryTask = meetingNoteRecoveryTask
        meetingNoteTransitionID &+= 1
        let transitionID = meetingNoteTransitionID
        stopMeetingNoteOptionGesture()
        applyMeetingNoteSnapshot(Self.stoppingMeetingNoteSnapshot(from: meetingNoteSnapshot))
        startMeetingNoteOptionGesture()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let startTask = pendingStartTask {
                    _ = try await startTask.value
                }
                if let recoveryTask = pendingRecoveryTask {
                    _ = try await recoveryTask.value
                }
                let snapshot = try await coordinator.stop()
                guard transitionID == self.meetingNoteTransitionID else { return }
                self.applyMeetingNoteSnapshot(snapshot)
                self.restoreOrdinaryAwarenessAfterNote()
            } catch {
                let snapshot = await coordinator.snapshot()
                guard transitionID == self.meetingNoteTransitionID else { return }
                self.meetingNoteRecoveryTask = nil
                self.applyMeetingNoteSnapshot(snapshot)
            }
        }
    }

    private func cancelNoteTaker() {
        guard let coordinator = meetingNoteCoordinator,
              SessionWheelNoteAction.cancel.isEnabled(for: meetingNoteSnapshot.phase) else { return }
        meetingNoteTransitionID &+= 1
        let transitionID = meetingNoteTransitionID
        stopMeetingNoteOptionGesture()
        applyMeetingNoteSnapshot(MeetingNoteCoordinatorSnapshot(
            phase: .cancelling, noteID: meetingNoteSnapshot.noteID,
            project: meetingNoteSnapshot.project, liveHypothesisCount: 0,
            durableSegmentCount: meetingNoteSnapshot.durableSegmentCount,
            syncState: meetingNoteSnapshot.syncState, errorMessage: nil
        ))
        startMeetingNoteOptionGesture()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await coordinator.cancel()
                guard transitionID == self.meetingNoteTransitionID else { return }
                self.applyMeetingNoteSnapshot(snapshot)
                self.restoreOrdinaryAwarenessAfterNote()
            } catch {
                let snapshot = await coordinator.snapshot()
                guard transitionID == self.meetingNoteTransitionID else { return }
                self.applyMeetingNoteSnapshot(snapshot)
                self.sessionWheel.model.notice = "Could not cancel the note. Try Cancel again."
            }
        }
    }

    func interruptedMeetingNotes() async -> [MeetingNoteRecoveryOffer] {
        let coordinator = meetingNoteCoordinator ?? makeMeetingNoteCoordinator()
        if meetingNoteCoordinator == nil { meetingNoteCoordinator = coordinator }
        return (try? await coordinator.recoveryOffers()) ?? []
    }

    @discardableResult
    func resolveInterruptedMeetingNote(
        sessionID: String,
        resolution: MeetingNoteRecoveryResolution,
        transcriptionModel: STTModel? = nil
    ) async throws -> MeetingNoteCoordinatorSnapshot {
        guard meetingNoteRecoveryTask == nil else {
            throw MeetingNoteCoordinatorError.foregroundBusy
        }
        let coordinator = meetingNoteCoordinator ?? makeMeetingNoteCoordinator()
        meetingNoteCoordinator = coordinator
        meetingNoteTransitionID &+= 1
        let transitionID = meetingNoteTransitionID
        stopMeetingNoteOptionGesture()
        let reservedSnapshot = MeetingNoteCoordinatorSnapshot(
            phase: .preparing,
            noteID: nil,
            project: nil,
            liveHypothesisCount: 0,
            durableSegmentCount: 0,
            syncState: nil,
            errorMessage: nil
        )
        applyMeetingNoteSnapshot(reservedSnapshot)
        endSession()
        sttEngine?.stop()
        sttEngine = nil
        startMeetingNoteOptionGesture()

        let task = Task { @MainActor [weak self] () throws -> MeetingNoteCoordinatorSnapshot in
            guard let self else {
                throw MeetingNoteForegroundTransitionError.teardownTimedOut
            }
            let offer = try await coordinator.recoveryOffers().first {
                $0.sessionID == sessionID
            }
            guard let offer,
                  let context = (offer.project.expectedProjectID == "global-notes"
                    ? self.meetingNoteProjectContext(workingDirectory: nil)
                    : self.legacyMeetingNoteProjectContext(workingDirectory: offer.project.repositoryPath)),
                  context.binding.repositoryPath == offer.project.repositoryPath,
                  context.binding.expectedProjectID == offer.project.expectedProjectID else {
                throw MeetingNoteCoordinatorError.projectIdentityChanged
            }

            try await self.waitForWorkSessionTeardownBeforeNote()
            return try await coordinator.resolveRecovery(
                sessionID: sessionID,
                projectScopeToken: context.scopeToken,
                resolution: resolution,
                transcriptionModel: transcriptionModel
            )
        }
        meetingNoteRecoveryTask = task

        do {
            let snapshot = try await task.value
            guard transitionID == meetingNoteTransitionID else { return snapshot }
            meetingNoteRecoveryTask = nil
            applyMeetingNoteSnapshot(snapshot)
            if snapshot.phase == .paused {
                startMeetingNoteOptionGesture()
            } else if snapshot.phase == .saved || snapshot.phase == .idle {
                restoreOrdinaryAwarenessAfterNote()
            }
            return snapshot
        } catch {
            guard transitionID == meetingNoteTransitionID else { throw error }
            meetingNoteRecoveryTask = nil
            let snapshot = await coordinator.snapshot()
            if snapshot.phase == .idle || snapshot.phase == .saved {
                applyMeetingNoteSnapshot(MeetingNoteCoordinatorSnapshot(
                    phase: .error,
                    noteID: reservedSnapshot.noteID,
                    project: reservedSnapshot.project,
                    liveHypothesisCount: reservedSnapshot.liveHypothesisCount,
                    durableSegmentCount: reservedSnapshot.durableSegmentCount,
                    syncState: reservedSnapshot.syncState,
                    errorMessage: error.localizedDescription
                ))
            } else {
                applyMeetingNoteSnapshot(snapshot)
            }
            startMeetingNoteOptionGesture()
            throw error
        }
    }

    @discardableResult
    func resumeRecoveredMeetingNote() async throws -> MeetingNoteCoordinatorSnapshot {
        guard let coordinator = meetingNoteCoordinator else {
            throw MeetingNoteCoordinatorError.captureUnavailable
        }
        let snapshot = try await coordinator.resumeRecoveredCapture()
        applyMeetingNoteSnapshot(snapshot)
        startMeetingNoteOptionGesture()
        return snapshot
    }

    private func meetingNoteProjectContext(
        workingDirectory: String?
    ) -> (binding: MeetingNoteProjectBinding, scopeToken: String?)? {
        return (
            MeetingNoteProjectBinding(
                repositoryPath: GlobalNoteStore.repositoryPath,
                expectedProjectID: "global-notes",
                provider: config.general.provider.rawValue
            ),
            nil
        )
    }

    private func legacyMeetingNoteProjectContext(
        workingDirectory: String?
    ) -> (binding: MeetingNoteProjectBinding, scopeToken: String?)? {
        let requested = (workingDirectory ?? config.general.working_directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            surfaceProjectScopeFailure("Select an available project in Workspace before taking notes.")
            return nil
        }
        if let projectRegistryV2 {
            do {
                let token = try projectRegistryV2.confirmProject(matching: requested)
                guard projectRegistryV2.validateScopeToken(token).isValid else {
                    throw ProjectRegistryV2Service.ServiceError.staleScope(token.projectID)
                }
                return (
                    MeetingNoteProjectBinding(
                        repositoryPath: token.repositoryPath,
                        expectedProjectID: token.projectID,
                        provider: config.general.provider.rawValue
                    ),
                    token.encodedValue
                )
            } catch {
                surfaceProjectScopeFailure(String(describing: error))
                return nil
            }
        }
        return (
            MeetingNoteProjectBinding(
                repositoryPath: WorkspaceFolder.url(from: requested).path,
                expectedProjectID: nil,
                provider: config.general.provider.rawValue
            ),
            nil
        )
    }

    private func applyMeetingNoteSnapshot(_ snapshot: MeetingNoteCoordinatorSnapshot) {
        meetingNoteSnapshot = snapshot
        sessionWheel.model.notePhase = snapshot.phase
        if snapshot.phase.ownsForeground {
            meetingNoteOptionGesture?.setOptionEnabled(
                snapshot.phase == .recording || snapshot.phase == .paused
            )
        } else {
            stopMeetingNoteOptionGesture()
        }
        statusText = switch snapshot.phase {
        case .recording: snapshot.captureStatusMessage ?? "Taking notes"
        case .paused: "Notes paused"
        case .preparing: "Preparing notes"
        case .transcribing: "Transcribing notes"
        case .stopping: snapshot.captureInterrupted ? "Recording interrupted" : "Saving notes"
        case .cancelling: snapshot.errorMessage == nil ? "Cancelling note" : "Note cancellation failed"
        case .saved: "Note saved"
        case .interrupted: "Note interrupted"
        case .error: snapshot.captureInterrupted ? "Recording interrupted" : "Note save failed"
        case .idle: "Ready"
        }
        syncNotchActivitySurface()
    }

    static func stoppingMeetingNoteSnapshot(
        from snapshot: MeetingNoteCoordinatorSnapshot
    ) -> MeetingNoteCoordinatorSnapshot {
        // Stop transcribes the recording before it saves the note.
        MeetingNoteCoordinatorSnapshot(
            phase: .transcribing,
            noteID: snapshot.noteID,
            project: snapshot.project,
            liveHypothesisCount: snapshot.liveHypothesisCount,
            durableSegmentCount: snapshot.durableSegmentCount,
            syncState: snapshot.syncState,
            errorMessage: nil
        )
    }

    private func makeMeetingNoteCoordinator() -> MeetingNoteCoordinator {
        let notificationID = UUID()
        meetingNoteCoordinatorNotificationID = notificationID
        return MeetingNoteCoordinator.live(
            modelName: config.stt.model,
            snapshotSink: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.meetingNoteCoordinatorNotificationID == notificationID,
                          self.meetingNoteSnapshot.phase.ownsForeground,
                          self.meetingNoteSnapshot.phase != .cancelling || snapshot.phase == .cancelling,
                          self.meetingNoteSnapshot.project == snapshot.project,
                          self.meetingNoteSnapshot.noteID == nil
                            || self.meetingNoteSnapshot.noteID == snapshot.noteID else { return }
                    self.applyMeetingNoteSnapshot(snapshot)
                }
            },
            scopeTokenRefresher: { [weak self] project in
                guard let self, let registry = self.projectRegistryV2 else {
                    throw MeetingNoteCoordinatorError.projectIdentityChanged
                }
                return try MeetingNoteProjectScopeResolver.renewedToken(
                    for: project,
                    registry: registry
                )
            }
        )
    }

    private func startMeetingNoteOptionGesture() {
        stopMeetingNoteOptionGesture()
        guard meetingNoteSnapshot.phase.ownsForeground, sttEngine == nil else {
            return
        }
        let transitionID = meetingNoteTransitionID
        let gestureGeneration = meetingNoteGestureGeneration
        let gesture = NoteOptionGesture(onToggle: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, transitionID == self.meetingNoteTransitionID,
                      gestureGeneration == self.meetingNoteGestureGeneration,
                      self.meetingNoteSnapshot.phase == .recording
                        || self.meetingNoteSnapshot.phase == .paused,
                      let coordinator = self.meetingNoteCoordinator else { return }
                await coordinator.togglePause()
            }
        }, onWorkspaceToggle: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, transitionID == self.meetingNoteTransitionID,
                      gestureGeneration == self.meetingNoteGestureGeneration,
                      self.meetingNoteSnapshot.phase.ownsForeground else { return }
                _ = self.toggleBoard(recognizedAt: CACurrentMediaTime())
            }
        })
        gesture.setOptionEnabled(
            meetingNoteSnapshot.phase == .recording || meetingNoteSnapshot.phase == .paused
        )
        meetingNoteOptionGesture = gesture
    }

    private func stopMeetingNoteOptionGesture() {
        meetingNoteGestureGeneration &+= 1
        meetingNoteOptionGesture?.stop()
        meetingNoteOptionGesture = nil
    }

    private func restoreOrdinaryAwarenessAfterNote() {
        stopMeetingNoteOptionGesture()
        meetingNoteCoordinator = nil
        meetingNoteCoordinatorNotificationID = nil
        meetingNoteStartTask = nil
        meetingNoteRecoveryTask = nil
        guard permissions.microphone == .granted, sttEngine == nil else { return }
        startConfiguredSTT(
            reason: "note-teardown",
            failureLogPrefix: "STT restart after note teardown failed"
        )
    }

    private func embeddedTerminalDidExit(contextID: String, exitCode: Int32?) {
        // RR-394: an exit marks only its own context. The shared voice state
        // resets only when the bridge's session exits and none remain live.
        if let exitedContext = assistantSessionStore.document.bindings[contextID]?.context {
            saveAssistantSession(lifecycle: .interrupted, context: exitedContext)
        }
        if contextID != voiceContextID, sessionRegistry.hasLiveSessions { return }
        if userDeliveryRecoveryPending {
            userDeliveryRecoveryPending = false
            if let launch = activeSessionLaunchConfig,
               let context = pendingContinuityProviderReady {
                let started = newSession(
                    workingDirectory: launch.general.working_directory,
                    suppressesStartupGreeting: true,
                    recoveryGeneration: context.recoveryGeneration,
                    preservesVoiceBridge: true
                )
                if !started {
                    stateMachine.showProgramStatus(
                        title: "Session recovery could not start",
                        body: "The old provider has exited. The voice bridge and queued messages were retained; review the session launch error before trying again."
                    )
                }
            }
            return
        }
        if sessionRegistry.hasLiveSessions { return }
        let earlyFailureMessage: String?
        if case .failed(let message) = sessionRegistry.sessions[contextID]?.phase {
            earlyFailureMessage = message
        } else {
            earlyFailureMessage = nil
        }
        resetActiveSessionState()
        if let earlyFailureMessage {
            statusText = "Session failed before provider readiness"
            stateMachine.showProgramStatus(
                title: "Session failed before provider readiness",
                body: earlyFailureMessage
            )
            syncNotchActivitySurface()
            NSLog("[AppState] Embedded provider exited before readiness code=\(exitCode.map(String.init) ?? "unknown")")
        }
    }

    private func resetActiveSessionState() {
        pendingSessionLaunchID = nil
        voiceContextID = nil
        userDeliveryRecoveryPending = false
        processManager.killBridge(stopRequested: true)
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        activeSessionProjectScopeToken = nil
        projectScopeCoordinator.cancel()
        bridgeAliveCache = false
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        activeSessionSuppressesStartupGreeting = false
        sessionStartTime = .distantPast
        wizardShownForCurrentBridgeSession = false
        statusText = "Ready"
        // Bridge events (processing/speaking/messageWaiting) are sticky on the
        // state machine — without an explicit reset, killing the bridge mid-
        // response leaves the overlay parked on the last state forever.
        // Cancel any in-flight recording too, so the mic indicator clears.
        sttEngine?.cancelRecording()
        stateMachine.reset()
        refreshWorkspaceActivity(invalidateRoute: true)
    }

    /// Full shutdown (for app quit).
    func stopServices() {
        sessionWheel.dismiss()
        FourFingerTapMonitor.shared.stop()
        saveLiveAssistantSessions()
        pendingSessionLaunchID = nil
        stopMeetingNoteOptionGesture()
        guard isRunning else {
            workspaceDiscoveryTask?.cancel()
            workspaceDiscoveryTask = nil
            cancelWorkspaceActivityRefresh(invalidate: true)
            keepAwake.shutdown()
            return
        }
        stopBridgeWatchdog()
        sessionRegistry.shutdownAll()
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        activeSessionProjectScopeToken = nil
        projectScopeCoordinator.cancel()
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        activeSessionSuppressesStartupGreeting = false
        stopOverlay()
        sttEngine?.stop()
        sttEngine = nil
        sttSetupStartedAt = nil
        sttSetupSucceeded = false
        sttEngineError = nil
        processManager.stopServices()
        isRunning = false
        statusText = "Idle"
        workspaceDiscoveryTask?.cancel()
        workspaceDiscoveryTask = nil
        cancelWorkspaceActivityRefresh(invalidate: true)
        keepAwake.shutdown()
    }

    func prepareForSparkleRelaunch() {
        sessionWheel.dismiss()
        FourFingerTapMonitor.shared.stop()
        saveLiveAssistantSessions()
        pendingSessionLaunchID = nil
        workspaceDiscoveryTask?.cancel()
        workspaceDiscoveryTask = nil
        cancelWorkspaceActivityRefresh(invalidate: true)
        keepAwake.shutdown()
        bridgeRecoverySuppressedForUpdate = true
        stopBridgeWatchdog()
        sessionRegistry.shutdownAll()
        menuSessionActive = false
        activeSessionLaunchConfig = nil
        activeSessionProjectScopeToken = nil
        projectScopeCoordinator.cancel()
        bridgeAliveCache = false
        bridgeRecoveryInFlight = false
        sessionBridgeSeen = false
        activeSessionSuppressesStartupGreeting = false
        statusText = "Updating"
        sttEngine?.cancelRecording()
        sttSetupStartedAt = nil
        sttSetupSucceeded = false
        processManager.stopServicesForBundleReplacement()
    }

    /// Saves a user edit (Settings or onboarding). A model change is recorded
    /// against the Phonon migration so relaunch or an OS upgrade never
    /// re-overrides an explicit choice or rollback.
    func saveConfig(_ newConfig: AppConfig, forceWorkspaceDiscovery: Bool = false) {
        var newConfig = newConfig
        newConfig.stt = newConfig.stt.recordingUserModelChange(from: config.stt)
        persistConfig(newConfig, forceWorkspaceDiscovery: forceWorkspaceDiscovery)
    }

    private func startPhononMigrationIfEligible() {
        if phononMigration == nil {
            phononMigration = STTPhononMigration(environment: .init(
                prepare: { model, progress in
                    let manager = try await STTModelPreparation.shared.prepareManager(for: model) { phase in
                        progress(phase.statusText(for: model))
                    }
                    await manager.cleanup()
                },
                currentConfig: { [weak self] in self?.config.stt ?? SttConfig() },
                isIdle: { [weak self] in self?.sttModelSwitchIsIdle ?? false },
                apply: { [weak self] stt in
                    guard let self else { return }
                    var next = self.config
                    next.stt = stt
                    self.persistConfig(next)
                },
                removeSupersededModel: { model in
                    await STTModelPreparation.shared.removeCachedAssets(for: model)
                }
            ))
        }
        phononMigration?.startIfEligible()
    }

    /// No command capture or Note Taker session (including a pending start or
    /// recovery tail) owns a model, so a model switch cannot cut one off.
    private var sttModelSwitchIsIdle: Bool {
        Self.sttModelSwitchIsIdle(
            commandRecording: sttEngine?.isRecording == true,
            notePhase: meetingNoteSnapshot.phase,
            noteStartPending: meetingNoteStartTask != nil,
            noteRecoveryPending: meetingNoteRecoveryTask != nil
        )
    }

    static func sttModelSwitchIsIdle(
        commandRecording: Bool,
        notePhase: MeetingNoteCoordinatorPhase,
        noteStartPending: Bool,
        noteRecoveryPending: Bool
    ) -> Bool {
        !commandRecording && !notePhase.ownsForeground && !noteStartPending && !noteRecoveryPending
    }

    /// An idle cached note coordinator captured the old model; drop it so the
    /// next note uses the new selection. An active note or recovery keeps its own.
    static func shouldInvalidateMeetingNoteCoordinator(
        oldModel: String,
        newModel: String,
        notePhase: MeetingNoteCoordinatorPhase,
        noteStartPending: Bool,
        noteRecoveryPending: Bool
    ) -> Bool {
        oldModel != newModel
            && !notePhase.ownsForeground && !noteStartPending && !noteRecoveryPending
    }

    private func persistConfig(_ newConfig: AppConfig, forceWorkspaceDiscovery: Bool = false) {
        let oldConfig = config
        config = newConfig

        do {
            try configManager.save(newConfig)
        } catch {
            NSLog("[RelayRunner] Failed to save config: \(error)")
        }

        refreshConfiguredWorkspaceDiscoveryIfNeeded(
            oldConfig: oldConfig,
            newConfig: newConfig,
            force: forceWorkspaceDiscovery
        )
        if Self.shouldInvalidateMeetingNoteCoordinator(
            oldModel: oldConfig.stt.model,
            newModel: newConfig.stt.model,
            notePhase: meetingNoteSnapshot.phase,
            noteStartPending: meetingNoteStartTask != nil,
            noteRecoveryPending: meetingNoteRecoveryTask != nil
        ) {
            meetingNoteCoordinator = nil
            meetingNoteCoordinatorNotificationID = nil
        }

        // Hot-reload running services
        guard isRunning else { return }

        // Always tell bridge to reload TTS settings
        SocketClient.bridgeSend("reload")

        // Update overlay config
        if oldConfig.awareness != newConfig.awareness {
            overlayController?.updateConfig(newConfig.awareness)
        }

        // Restart STT if settings changed, after any in-flight command capture.
        if oldConfig.stt != newConfig.stt {
            restartSTTAfterCurrentRecording()
        }
    }

    private func restartSTTAfterCurrentRecording() {
        pendingSTTRestartTask?.cancel()
        pendingSTTRestartTask = Task { @MainActor [weak self] in
            while self?.sttEngine?.isRecording == true {
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingSTTRestartTask = nil
            self.sttEngine?.stop()
            self.startConfiguredSTT(reason: "settings-change", failureLogPrefix: "STT engine restart failed")
        }
    }

    private func refreshConfiguredWorkspaceDiscoveryIfNeeded(
        oldConfig: AppConfig?,
        newConfig: AppConfig,
        force: Bool
    ) {
        guard shouldRefreshWorkspaceDiscovery(
            oldGeneral: oldConfig?.general,
            newGeneral: newConfig.general,
            force: force
        ) else {
            return
        }

        let url = WorkspaceFolder.url(from: newConfig.general.working_directory)
        let general = newConfig.general
        workspaceDiscoveryTask?.cancel()
        workspaceDiscoveryTask = Task { @MainActor [weak self] in
            let errorMessage = await Task.detached(priority: .utility) {
                do {
                    _ = try WorkspaceFolder.refreshDiscovery(for: general)
                    return nil as String?
                } catch {
                    return "\(error)"
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.workspaceDiscoveryTask = nil
            if let errorMessage {
                NSLog(
                    "[RelayRunner] Workspace folder discovery skipped for \(url.path): \(errorMessage)"
                )
                return
            }
            self.refreshWorkspaceActivity(invalidateRoute: true)
        }
    }

    private func shouldRefreshWorkspaceDiscovery(
        oldGeneral: GeneralConfig?,
        newGeneral: GeneralConfig,
        force: Bool
    ) -> Bool {
        guard projectRegistryV2 == nil else { return false }
        if force { return true }

        let hasExplicitWorkspace = !newGeneral.working_directory
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        guard let oldGeneral else {
            return hasExplicitWorkspace
        }
        if oldGeneral.working_directory != newGeneral.working_directory {
            return true
        }
        return hasExplicitWorkspace && oldGeneral.provider != newGeneral.provider
    }

    @discardableResult
    func selectGeneralContext(startsSession: Bool = true, showsTerminal: Bool = true) -> Bool {
        do {
            guard let registry = projectRegistryV2 else { return false }
            let project = try registry.ensureGeneralTasksProject()
            return selectProjectContext(repositoryPath: project.lastResolvedPath, startsSession: startsSession,
                                        showsTerminal: showsTerminal)
        } catch {
            contextSwitchMessage = "general could not be opened: \(error.localizedDescription)"
            return false
        }
    }

    /// `startsSession: false` browses: a context with a live session is
    /// focused, any other context is selected without launching a process.
    @discardableResult
    func selectProjectContext(repositoryPath: String, startsSession: Bool = true, showsTerminal: Bool = true) -> Bool {
        do {
            let context: AssistantSessionContext
            if let registry = projectRegistryV2 {
                let token = try registry.scopeToken(matching: repositoryPath)
                guard registry.validateScopeToken(token).isValid else {
                    throw ProjectRegistryV2Service.ServiceError.staleScope(token.projectID)
                }
                context = .project(token)
            } else {
                let path = WorkspaceFolder.url(from: repositoryPath).resolvingSymlinksInPath().path
                context = AssistantSessionContext(kind: .project, projectID: path, repositoryPath: path)
            }
            guard startsSession || sessionRegistry.isLive(context.id) else {
                try assistantSessionStore.select(context, provider: config.general.provider.rawValue, model: config.general.model)
                sessionRegistry.focus(contextID: context.id)
                publishConversationState()
                return true
            }
            return requestContextSelection(context, showsTerminal: showsTerminal)
        } catch {
            contextSwitchMessage = "This project's history is retained. Resolve its location before running work: \(error.localizedDescription)"
            surfaceProjectScopeFailure(String(describing: error))
            return false
        }
    }

    private var canReplaceContextProvider: Bool {
        let delivery = processManager.pendingVoiceCommandDeliveryState()
        let approval: Bool
        if case .actionGlow(let pending) = stateMachine.state { approval = pending != nil }
        else { approval = false }
        return AssistantSessionStore.canReplace(
            recording: sttEngine?.isRecording == true,
            noteCapture: meetingNoteSnapshot.phase.ownsForeground,
            foregroundTurn: ProcessManager.foregroundProviderTurnActive(),
            pendingCommand: delivery == .waiting || delivery == .claimed || delivery == .timedOut
                || embeddedTerminal.hasUnsubmittedInput || stateMachine.state == .speaking || stateMachine.state == .preparing,
            approval: approval || embeddedTerminal.deliveryBlocked || embeddedTerminal.inboxRecoveryBlocker != nil,
            launching: pendingSessionLaunchID != nil
        )
    }

    func clearContextContinuation() {
        do {
            let pendingID = assistantSessionStore.pendingContinuation?.id
            locallyCancelledContinuationID = pendingID
            if let pending = assistantSessionStore.pendingContinuation {
                sessionRegistry.sessions[pending.destination.id]?.cancelContextContinuation(id: pending.id)
            }
            try assistantSessionStore.cancelContinuation()
            pendingContextSelection = nil
            contextSwitchMessage = nil
        } catch { contextSwitchMessage = "Continuation could not be cleared: \(error.localizedDescription)" }
    }

    private func requestContextSelection(_ context: AssistantSessionContext, continuationID: String? = nil,
                                         showsTerminal: Bool = true) -> Bool {
        if continuationID == nil {
            do {
                let pending = assistantSessionStore.pendingContinuation
                if let pending, pending.destination != context {
                    locallyCancelledContinuationID = pending.id
                    sessionRegistry.sessions[pending.destination.id]?.cancelContextContinuation(id: pending.id)
                }
                try assistantSessionStore.cancelContinuation(unless: context)
            }
            catch { contextSwitchMessage = "Continuation could not be saved: \(error.localizedDescription)"; return false }
        }
        // RR-394: another context's session starts beside this one, so only a
        // forwarded continuation or a busy note capture waits.
        if continuationID != nil || (!canReplaceContextProvider && meetingNoteSnapshot.phase.ownsForeground) {
            pendingContextSelection = context
            pendingContextSelectionShowsTerminal = showsTerminal
            contextSwitchMessage = "Switching to \(context.displayName) after the current recording, command or approval finishes."
            return true
        }
        pendingContextSelection = nil
        return newSession(workingDirectory: context.repositoryPath, showsWorkspaceOnLaunch: showsTerminal)
    }

    private func reserveContextContinuation(_ request: [String: String], destination: AssistantSessionContext) throws -> String {
        try assistantSessionStore.reconcile(context: activeContext, activeRunIDs: assistantRunIDs(for: activeContext), pendingIntentIDs: assistantPendingIntentIDs())
        guard destination != activeContext, let text = request["text"],
              request["source_context_id"] == activeContext.id,
              let binding = assistantSessionStore.binding(for: activeContext),
              binding.transportSessionID == request["provider_session_id"],
              binding.nativeSessionID == request["native_session_id"] else {
            throw NSError(domain: "RelayContinuation", code: 6, userInfo: [NSLocalizedDescriptionKey: "Continuation requires a different confirmed destination and the current native request."])
        }
        let reply = try ProcessManager.contextContinuationAuthority(operation: "capture", source: request)
        guard reply["status"] as? String == "active", var source = reply["source"] as? [String: String] else {
            throw NSError(domain: "RelayContinuation", code: 7, userInfo: [NSLocalizedDescriptionKey: reply["message"] as? String ?? "The source request is not active."])
        }
        source["source_context_id"] = activeContext.id
        let pending = try assistantSessionStore.reserveContinuation(source: source, destination: destination, text: text)
        guard pending.state == .queued else {
            throw NSError(domain: "RelayContinuation", code: 8, userInfo: [NSLocalizedDescriptionKey: "This continuation was already submitted or needs review; it will not be replayed."])
        }
        continuationSourceReady = false
        return pending.id
    }

    private func reconcileContextContinuation(now: Date = Date()) {
        guard let continuation = assistantSessionStore.pendingContinuation else { return }
        if locallyCancelledContinuationID == continuation.id {
            contextSwitchMessage = "Continuation cancelled locally. Clear it to save that decision; it will not be submitted."
            return
        }
        if continuation.state == .recoveryRequired {
            contextSwitchMessage = continuation.message
            return
        }
        do {
            let operation = continuation.state == .submitting ? "ack" : "check"
            let reply = try ProcessManager.contextContinuationAuthority(operation: operation, source: continuation.source,
                submissionID: continuation.id, destination: continuation.destinationOwner)
            let status = reply["status"] as? String
            if status == "blocked" {
                try assistantSessionStore.updateContinuation(continuation.id, state: .recoveryRequired,
                    message: reply["message"] as? String ?? "Continuation was blocked. Clear it and issue a new request.")
                pendingContextSelection = nil
                contextSwitchMessage = assistantSessionStore.pendingContinuation?.message
                return
            }
            if continuation.state == .submitting {
                if status == "consumed" {
                    try assistantSessionStore.updateContinuation(continuation.id, state: .consumed)
                    contextSwitchMessage = nil
                } else if now.timeIntervalSince(continuation.submittedAt ?? .distantPast) > RelayVoiceCommandDelivery.manualSubmitHookTimeout {
                    try assistantSessionStore.updateContinuation(continuation.id, state: .recoveryRequired,
                        message: "Continuation delivery is uncertain. Clear it and issue a new request after checking the conversation; it will not be resent.")
                    contextSwitchMessage = assistantSessionStore.pendingContinuation?.message
                }
                return
            }
            continuationSourceReady = status == "ready"
            guard continuationSourceReady else { return }
            // RR-397: deliver to the destination's own session, existing or
            // newly started, whether or not it is focused.
            let destination = continuation.destination
            guard let session = sessionRegistry.sessions[destination.id],
                  session.phase == .running, !session.hasUnsubmittedInput, canReplaceContextProvider,
                  let binding = assistantSessionStore.binding(for: destination), let native = binding.nativeSessionID,
                  var owner = continuationDestinationOwners[destination.id],
                  owner["provider_session_id"] == binding.transportSessionID,
                  binding.context == continuation.destination else { return }
            if let registry = projectRegistryV2, let path = continuation.destination.repositoryPath {
                let token = try registry.scopeToken(matching: path)
                guard registry.validateScopeToken(token).isValid, AssistantSessionContext.project(token) == continuation.destination else {
                    throw ProjectRegistryV2Service.ServiceError.staleScope(continuation.destination.projectID ?? path)
                }
            }
            owner["native_session_id"] = native
            // Durable submitting wins before the first PTY byte. No timer,
            // restart or duplicate activation may replay an uncertain paste.
            guard let deliverable = try assistantSessionStore.prepareContinuationDelivery(sourceStatus: status, context: destination,
                ready: session.phase == .running, clearToSend: canReplaceContextProvider, owner: owner, now: now) else { return }
            guard session.submitContextContinuation(deliverable) else {
                try assistantSessionStore.updateContinuation(continuation.id, state: .recoveryRequired,
                    message: "Continuation was not submitted. Clear it and issue a new request; no automatic retry will occur.")
                contextSwitchMessage = assistantSessionStore.pendingContinuation?.message
                return
            }
            contextSwitchMessage = "Forwarding the explicit request to \(destination.displayName); waiting for its native acknowledgement."
        } catch {
            contextSwitchMessage = "Continuation needs review: \(error.localizedDescription). It will not be replayed automatically."
        }
    }

    private func publishConversationState() {
        activeContext = assistantSessionStore.activeContext
        conversationHistory = assistantSessionStore.document.history.sorted { $0.createdAt < $1.createdAt }
        // The Workspace terminal always shows the active context's session.
        sessionRegistry.focus(contextID: activeContext.id)
        syncVoiceFocus()
    }

    private func assistantRunIDs(for context: AssistantSessionContext) -> [Int] {
        Self.assistantRunIDs(for: context, runs: notchActivityRunStates)
    }

    static func assistantRunIDs(for context: AssistantSessionContext, runs: [RunState]) -> [Int] {
        guard let repository = context.repositoryPath else { return [] }
        return runs.filter {
            AssistantSessionStore.samePath($0.repoPath, repository)
                && !["Merged", "Failed", "Canceled", "SpikeCompleted"].contains($0.state)
        }.map(\.runId)
    }

    private func assistantPendingIntentIDs() -> [String] {
        let pending = processManager.pendingVoiceCommandDeliveryState()
        guard pending == .claimed || pending == .waiting || pending == .timedOut else { return [] }
        return [ProcessManager.currentRelayClaimIdentity()?["intent_id"] as? String].compactMap { $0 }
    }

    private func saveAssistantSession(lifecycle: AssistantSessionStore.Lifecycle, context: AssistantSessionContext? = nil) {
        let context = context ?? activeContext
        do {
            try assistantSessionStore.reconcile(context: context, activeRunIDs: assistantRunIDs(for: context),
                                                pendingIntentIDs: assistantPendingIntentIDs())
            try assistantSessionStore.importPublicHistory(context: context)
            try assistantSessionStore.mark(lifecycle, context: context)
            publishConversationState()
        } catch {
            contextSwitchMessage = "Conversation could not be saved: \(error.localizedDescription)"
        }
    }

    /// Reconcile links only; canonical daemon intent/run state is the recovery
    /// authority. A saved history entry is never submitted as another action.
    private func reconcileAssistantContext(now: Date = Date()) {
        guard now.timeIntervalSince(lastContextReconciliation) >= 3 else { return }
        lastContextReconciliation = now
        do {
            try assistantSessionStore.reconcile(context: activeContext, activeRunIDs: assistantRunIDs(for: activeContext),
                                                pendingIntentIDs: assistantPendingIntentIDs())
            try assistantSessionStore.importPublicHistory(context: activeContext)
            publishConversationState()
            reconcileContextContinuation(now: now)
            if let selection = pendingContextSelection, canReplaceContextProvider,
               assistantSessionStore.pendingContinuation == nil || continuationSourceReady {
                pendingContextSelection = nil
                _ = newSession(workingDirectory: selection.repositoryPath,
                               showsWorkspaceOnLaunch: pendingContextSelectionShowsTerminal)
                return
            }
            if try assistantSessionStore.saveIfIdle(context: activeContext, now: now,
                eligible: menuSessionActive && embeddedTerminal.phase == .running && canReplaceContextProvider
                    && assistantSessionStore.pendingContinuation == nil,
                end: { endSession(context: activeContext) }) {
                idleSessionSaved = true
                contextSwitchMessage = "\(activeContext.displayName) saved after 30 minutes idle. Start Session to resume."
            }
        } catch {
            contextSwitchMessage = "Conversation could not be saved. The active session was retained: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func newSession(
        workingDirectory: String? = nil,
        destination: SessionLaunchDestination = .embedded,
        allowDuringFirstRun: Bool = false,
        showsWorkspaceOnLaunch: Bool = true,
        suppressesStartupGreeting: Bool = false,
        recoveryGeneration: String? = nil,
        preservesVoiceBridge: Bool = false,
        bypassesNoteTransition: Bool = false
    ) -> Bool {
        if !bypassesNoteTransition, meetingNoteSnapshot.phase.ownsForeground {
            return transitionFromNoteToSession(
                workingDirectory: workingDirectory,
                destination: destination,
                allowDuringFirstRun: allowDuringFirstRun,
                showsWorkspaceOnLaunch: showsWorkspaceOnLaunch,
                suppressesStartupGreeting: suppressesStartupGreeting,
                recoveryGeneration: recoveryGeneration,
                preservesVoiceBridge: preservesVoiceBridge
            )
        }
        if !preservesVoiceBridge {
            pendingContinuityProviderReady = nil
        }
        guard allowsAppShellAccess || allowDuringFirstRun else { return false }
        if preservesVoiceBridge {
            guard destination == .embedded,
                  recoveryGeneration != nil,
                  !processManager.bridgeStopRequested()
            else { return false }
        }
        guard permissions.microphone == .granted else {
            onboarding.showAlways()
            return false
        }
        let projectScopeToken: ConfirmedProjectScopeToken?
        let context: AssistantSessionContext
        let contextWorkingDirectory: String
        let requestedProject = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let preparedContext = try Self.prepareSessionContext(workingDirectory: workingDirectory, registry: projectRegistryV2)
            projectScopeToken = preparedContext.projectScopeToken
            context = preparedContext.context
            contextWorkingDirectory = preparedContext.workingDirectory
        } catch {
            if requestedProject.isEmpty || AssistantSessionStore.samePath(requestedProject, AssistantSessionStore.filesDirectory.path) {
                contextSwitchMessage = "general could not be opened: \(error.localizedDescription)"
                statusText = "general unavailable"
            } else {
                surfaceProjectScopeFailure(String(describing: error))
            }
            return false
        }
        // RR-394: a context with a live session is focused, never replaced or
        // duplicated; other contexts' sessions keep running.
        if !preservesVoiceBridge, sessionRegistry.isLive(context.id) {
            do {
                try assistantSessionStore.select(context, provider: config.general.provider.rawValue,
                                                 model: config.general.model, savingPreviousContext: true)
                publishConversationState()
            } catch {
                contextSwitchMessage = "Could not save the conversation. The existing context was retained: \(error.localizedDescription)"
                return false
            }
            contextSwitchMessage = nil
            embeddedTerminal.focus()
            if showsWorkspaceOnLaunch { programBoardOverlay.showTerminal() }
            return true
        }
        guard pendingSessionLaunchID == nil else { return false }
        let previousContext = activeContext
        let session: EmbeddedTerminalSession
        switch sessionRegistry.admit(contextID: context.id) {
        case .start(let admitted):
            session = admitted
        case .focusedExisting:
            // Recovery relaunches only an exited provider.
            return false
        case .refused(let message):
            contextSwitchMessage = message
            stateMachine.showProgramStatus(title: "Session limit reached", body: message)
            return false
        }
        var previousProcesses: [AssistantManagedProviderProcess] = []
        do {
            try assistantSessionStore.reconcile(context: previousContext, activeRunIDs: assistantRunIDs(for: previousContext),
                                                pendingIntentIDs: assistantPendingIntentIDs())
            try assistantSessionStore.importPublicHistory(context: previousContext)
            // A crash can leave the source process alive after the destination
            // selection was saved. Reconcile every app-owned foreground binding;
            // detached daemon workers have separate ownership and are excluded.
            for binding in assistantSessionStore.document.bindings.values {
                try assistantSessionStore.reconcile(context: binding.context, activeRunIDs: binding.activeRunIDs,
                                                    pendingIntentIDs: binding.pendingIntentIDs)
            }
            // Only leftovers of contexts without a live session are stopped.
            previousProcesses = assistantSessionStore.document.bindings.values
                .filter { !sessionRegistry.isLive($0.context.id) }
                .compactMap(\.managedProcess)
            // A crash survivor mid-turn is never killed to make room.
            if !preservesVoiceBridge, AssistantSessionStore.shouldDeferReplacement(
                hasEmbeddedProvider: false,
                managedProcessStates: previousProcesses.map { $0.state() },
                canReplace: canReplaceContextProvider
            ) {
                sessionRegistry.focus(contextID: previousContext.id)
                pendingContextSelection = context
                pendingContextSelectionShowsTerminal = showsWorkspaceOnLaunch
                contextSwitchMessage = "Switching to \(context.displayName) after the current command or approval finishes."
                return true
            }
            try assistantSessionStore.select(context, provider: config.general.provider.rawValue,
                                             model: config.general.model, savingPreviousContext: true)
            publishConversationState()
        } catch {
            sessionRegistry.focus(contextID: previousContext.id)
            contextSwitchMessage = "Could not save the conversation. The existing context was retained: \(error.localizedDescription)"
            return false
        }
        let request = Self.sessionLaunchRequest(
            from: config,
            workingDirectory: contextWorkingDirectory,
            destination: destination
        )
        let launchConfig = request.config
        // Mark first-session-run before we do anything else — the
        // onboarding controller uses this flag to decide whether to
        // re-show the All Set screen on next launch. Marking on
        // attempt is fine: if the launch fails the user still
        // initiated a session, and the kill-bridge step below cleans
        // up so they can retry without onboarding nagging them again.
        onboarding.markSessionRun()
        // A confirmed-dead provider can be replaced without interrupting the
        // detached bridge that still owns the active voice session. Otherwise
        // the shared bridge is torn down only when no other session uses it.
        if !preservesVoiceBridge {
            processManager.clearBridgeStopRequested()
            if !sessionRegistry.hasLiveSessions { processManager.killBridge() }
        }
        menuSessionActive = true
        sessionStartTime = Date()
        sessionBridgeSeen = false
        activeSessionSuppressesStartupGreeting = suppressesStartupGreeting
        sessionPromptGate.reset()
        activeSessionLaunchConfig = launchConfig
        activeSessionProjectScopeToken = projectScopeToken
        if let projectScopeToken {
            projectScopeCoordinator.confirm(projectScopeToken)
        } else if context.isGeneral {
            projectScopeCoordinator.cancel()
        }
        contextSwitchMessage = nil
        idleSessionSaved = false
        // Bridge is about to launch — assume alive until watchdog says otherwise
        bridgeAliveCache = true
        refreshWorkspaceActivity(invalidateRoute: true)

        // Start STT if not already running
        if sttEngine == nil {
            startConfiguredSTT(reason: "session-start", failureLogPrefix: "STT engine session start failed")
        }

        let sessionDirectory = WorkspaceFolder.url(from: launchConfig.general.working_directory).path
        let launchID = UUID()
        pendingSessionLaunchID = launchID
        Task { @MainActor in
            guard pendingSessionLaunchID == launchID else { return }
            defer {
                if pendingSessionLaunchID == launchID { pendingSessionLaunchID = nil }
            }
            do {
                for process in previousProcesses {
                    guard process.requestTermination() else {
                        throw EmbeddedTerminalProcessError.alreadyRunning
                    }
                }
                let teardownDeadline = Date().addingTimeInterval(5)
                func previousProcessStillLives() -> Bool {
                    previousProcesses.contains { [.matching, .unknown].contains($0.state()) }
                }
                while session.hasLiveEmbeddedProcess || previousProcessStillLives(), Date() < teardownDeadline {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    guard pendingSessionLaunchID == launchID else { return }
                }
                guard !session.hasLiveEmbeddedProcess, !previousProcessStillLives() else {
                    contextSwitchMessage = "The previous provider is still running. No replacement was launched; close that session and try again."
                    throw EmbeddedTerminalProcessError.alreadyRunning
                }
                try session.beginPreparing(
                    providerName: launchConfig.general.provider.displayName,
                    providerKey: launchConfig.general.provider.rawValue,
                    workingDirectory: sessionDirectory,
                    recordDiagnostics: request.destination == .embedded
                )
                let voiceDelivery: ProcessManager.SessionVoiceDelivery =
                    (request.destination == .embedded) ? .appOwned : .agentSkill
                let updatedAgentBinary = try await Task.detached(priority: .userInitiated) {
                    try ProcessManager.updateHarness(config: launchConfig)
                }.value
                guard pendingSessionLaunchID == launchID,
                      session.phase == .preparing else { return }
                // RR-398: one shared bridge serves every session; a second
                // session joins it instead of restarting it.
                let joinsVoiceBridge = !preservesVoiceBridge
                    && sessionRegistry.liveContextIDs.contains { $0 != context.id }
                    && processManager.bridgeAlive()
                let prepared = try processManager.prepareNewSession(
                    config: launchConfig,
                    voiceDelivery: voiceDelivery,
                    suppressStartupGreeting: suppressesStartupGreeting,
                    sessionEventPath: session.diagnosticEventPath,
                    projectScopeToken: projectScopeToken,
                    recoveryGeneration: recoveryGeneration,
                    startsVoiceBridge: !preservesVoiceBridge,
                    joinsRunningVoiceBridge: joinsVoiceBridge,
                    updatedAgentBinary: updatedAgentBinary,
                    sessionContext: context,
                    conversationID: conversationID,
                    transportSessionID: launchID.uuidString.lowercased(),
                    nativeResumeID: assistantSessionStore.binding(for: context).flatMap {
                        $0.provider == launchConfig.general.provider.rawValue && $0.model == launchConfig.general.model ? $0.launchableNativeSessionID : nil
                    },
                    providerBindingPath: assistantSessionStore.bindingURL(transportSessionID: launchID.uuidString.lowercased()).path,
                    publicHandoff: assistantSessionStore.publicHandoff(for: context),
                    preservesContextAuthorization: assistantSessionStore.pendingContinuation.map { $0.state == .queued && $0.destination == context } == true
                )
                try assistantSessionStore.begin(context: context, provider: launchConfig.general.provider.rawValue,
                                               model: launchConfig.general.model, transportSessionID: launchID.uuidString.lowercased())
                continuationDestinationOwners[context.id] = ["provider": prepared.target.providerMetadataValue,
                    "provider_session_id": prepared.providerSessionID ?? "", "app_session_id": prepared.appSessionID ?? "",
                    "recovery_generation": prepared.recoveryGeneration ?? "", "foreground_gate_handle": prepared.foregroundGateHandle ?? ""]
                if preservesVoiceBridge {
                    guard let context = pendingContinuityProviderReady,
                          let authorized = context.authorizingReplacement(
                            providerSessionID: prepared.providerSessionID,
                            appSessionID: prepared.appSessionID,
                            foregroundGateHandle: prepared.foregroundGateHandle,
                            provider: prepared.target.providerMetadataValue
                          ) else {
                        throw ProcessManager.SessionLaunchPreparationError.invalidRecoveryLaunch
                    }
                    pendingContinuityProviderReady = authorized
                }
                if let generation = prepared.recoveryGeneration {
                    let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
                        repositoryPath: prepared.workingDirectory
                    )
                    continuityRecoveryGenerationBySession[sessionID] = generation
                }
                sessionStartTime = Date()
                switch request.destination {
                case .embedded:
                    sessionRegistry.setSpool(prepared.spool, for: context.id)
                    try session.start(prepared)
                case .externalTerminal:
                    guard processManager.launchPreparedSessionInTerminal(prepared) else {
                        throw ProcessManager.SessionLaunchPreparationError.externalTerminalLaunch
                    }
                    session.markExternal(
                        providerName: launchConfig.general.provider.displayName,
                        workingDirectory: prepared.workingDirectory
                    )
                }
                voiceContextID = context.id
                syncVoiceFocus(force: joinsVoiceBridge)
            } catch {
                guard pendingSessionLaunchID == launchID else { return }
                saveAssistantSession(lifecycle: .interrupted, context: context)
                pendingContinuityProviderReady = nil
                if !preservesVoiceBridge {
                    continuityRecoveryGenerationBySession.removeValue(
                        forKey: ContinuityRecoveryRequest.projectSessionIdentifier(
                            repositoryPath: launchConfig.general.working_directory
                        )
                    )
                }
                session.markFailed(error)
                if preservesVoiceBridge {
                    bridgeAliveCache = processManager.bridgeAlive()
                    menuSessionActive = bridgeAliveCache
                    statusText = bridgeAliveCache ? "Session reconnecting" : "Ready"
                } else if sessionRegistry.hasLiveSessions {
                    // Other contexts keep their sessions and the shared bridge.
                } else {
                    processManager.killBridge(stopRequested: true)
                    menuSessionActive = false
                    activeSessionLaunchConfig = nil
                    activeSessionProjectScopeToken = nil
                    projectScopeCoordinator.cancel()
                    bridgeAliveCache = false
                    sessionBridgeSeen = false
                    activeSessionSuppressesStartupGreeting = false
                    sessionStartTime = .distantPast
                    statusText = "Ready"
                }
                NSLog("[AppState] Failed to start session: \(error)")
                if showsWorkspaceOnLaunch { programBoardOverlay.showTerminal() }
                return
            }
        }
        isRunning = true
        if menuSessionActive {
            statusText = activeProviderInteractiveReady ? "Session" : "Starting session"
        }

        // Ensure overlay is running
        if overlayController == nil { startOverlay() }
        if !showsWorkspaceOnLaunch {
            return menuSessionActive
        }
        if request.destination == .externalTerminal && menuSessionActive {
            if programBoardOverlay.isVisible {
                programBoardOverlay.hide()
            }
        } else {
            programBoardOverlay.showTerminal()
        }
        return menuSessionActive
    }

    private func transitionFromNoteToSession(
        workingDirectory: String?,
        destination: SessionLaunchDestination,
        allowDuringFirstRun: Bool,
        showsWorkspaceOnLaunch: Bool,
        suppressesStartupGreeting: Bool,
        recoveryGeneration: String?,
        preservesVoiceBridge: Bool
    ) -> Bool {
        guard let coordinator = meetingNoteCoordinator else { return false }
        // The destination path is captured now. Later Workspace selection
        // changes cannot redirect the source note or this requested session.
        let destinationProject = (workingDirectory ?? projectRegistryV2?.generalTasksDirectory.path
            ?? AssistantSessionStore.filesDirectory.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingStartTask = meetingNoteStartTask
        let pendingRecoveryTask = meetingNoteRecoveryTask
        meetingNoteTransitionID &+= 1
        let transitionID = meetingNoteTransitionID
        stopMeetingNoteOptionGesture()
        applyMeetingNoteSnapshot(Self.stoppingMeetingNoteSnapshot(from: meetingNoteSnapshot))
        startMeetingNoteOptionGesture()

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let startTask = pendingStartTask {
                    _ = try await startTask.value
                }
                _ = try await Self.finalizeMeetingNoteBeforeWorkSession(
                    pendingRecovery: pendingRecoveryTask,
                    coordinator: coordinator
                ) { saved in
                    guard transitionID == self.meetingNoteTransitionID else { return false }
                    self.applyMeetingNoteSnapshot(saved)
                    self.meetingNoteCoordinator = nil
                    self.meetingNoteCoordinatorNotificationID = nil
                    self.meetingNoteStartTask = nil
                    self.meetingNoteRecoveryTask = nil
                    return self.newSession(
                        workingDirectory: destinationProject,
                        destination: destination,
                        allowDuringFirstRun: allowDuringFirstRun,
                        showsWorkspaceOnLaunch: showsWorkspaceOnLaunch,
                        suppressesStartupGreeting: suppressesStartupGreeting,
                        recoveryGeneration: recoveryGeneration,
                        preservesVoiceBridge: preservesVoiceBridge,
                        bypassesNoteTransition: true
                    )
                }
            } catch {
                guard transitionID == self.meetingNoteTransitionID else { return }
                self.meetingNoteRecoveryTask = nil
                let snapshot = await coordinator.snapshot()
                self.applyMeetingNoteSnapshot(snapshot)
                // A failed local save deliberately leaves STT stopped and does
                // not launch either provider or silently resume capture.
            }
        }
        return true
    }

    @MainActor
    static func finalizeMeetingNoteBeforeWorkSession(
        pendingRecovery: Task<MeetingNoteCoordinatorSnapshot, Error>? = nil,
        coordinator: MeetingNoteCoordinator,
        launch: (MeetingNoteCoordinatorSnapshot) -> Bool
    ) async throws -> Bool {
        if let pendingRecovery {
            _ = try await pendingRecovery.value
        }
        let saved = try await coordinator.stop()
        return launch(saved)
    }

    private func updateWorkspaceActivityPolling() {
        let shouldPoll = notchActivityPollingActive
        if shouldPoll, workspaceActivityTimer == nil {
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshWorkspaceActivity()
            }
            RunLoop.main.add(timer, forMode: .common)
            workspaceActivityTimer = timer
        } else if !shouldPoll {
            workspaceActivityTimer?.invalidate()
            workspaceActivityTimer = nil
            cancelWorkspaceActivityRefresh(invalidate: false)
        }
    }

    private func prepareOnboardingTutorialSpeech() -> Bool {
        guard processManager.startTutorialTTS() else {
            stopOnboardingTutorialSpeech()
            return false
        }
        onboardingTutorialSpeechActive = true
        sttEngine?.tutorialActive = true
        syncCommandCaptureOwnership()
        stateMachine.dismissSessionPrompt()
        return true
    }

    private func surfaceProjectScopeFailure(_ detail: String) {
        statusText = "Select a project"
        if overlayController == nil { startOverlay() }
        stateMachine.showProgramStatus(
            title: "Project selection required",
            body: detail
        )
        syncNotchActivitySurface()
        showWorkspaceWork()
    }

    private func stopOnboardingTutorialSpeech() {
        // The tutorial presentation can remain alive for its Workspace step.
        // Only the explicitly started speech lifecycle owns the microphone.
        onboardingTutorialSpeechActive = false
        sttEngine?.tutorialActive = false
        syncCommandCaptureOwnership()
        processManager.stopTutorialTTS()
    }

    static func prepareSessionContext(
        workingDirectory: String?,
        registry: ProjectRegistryV2Service?,
        filesDirectory: URL = AssistantSessionStore.filesDirectory
    ) throws -> (context: AssistantSessionContext, projectScopeToken: ConfirmedProjectScopeToken?, workingDirectory: String) {
        var requestedProject = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if requestedProject.isEmpty || AssistantSessionStore.samePath(requestedProject, filesDirectory.path) {
            if let registry {
                requestedProject = try registry.ensureGeneralTasksProject().lastResolvedPath
            } else {
                try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                return (.general, nil, filesDirectory.resolvingSymlinksInPath().path)
            }
        }
        if let registry {
            let token = try registry.scopeToken(matching: requestedProject)
            guard registry.validateScopeToken(token).isValid else {
                throw ProjectRegistryV2Service.ServiceError.staleScope(token.projectID)
            }
            let context = AssistantSessionContext.project(token)
            return (context, token, context.workingDirectory)
        }
        let path = WorkspaceFolder.url(from: requestedProject).resolvingSymlinksInPath().path
        return (AssistantSessionContext(kind: .project, projectID: path, repositoryPath: path), nil, path)
    }

    static func sessionLaunchRequest(
        from config: AppConfig,
        workingDirectory: String?,
        destination: SessionLaunchDestination = .embedded
    ) -> SessionLaunchRequest {
        SessionLaunchRequest(
            config: sessionLaunchConfig(from: config, workingDirectory: workingDirectory),
            destination: destination
        )
    }

    static func sessionLaunchConfig(from config: AppConfig, workingDirectory: String?) -> AppConfig {
        var launchConfig = config
        let trimmed = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            launchConfig.general.working_directory = trimmed
        }
        return launchConfig
    }

    func ttsCommand(_ cmd: String) {
        SocketClient.ttsSend(cmd)
    }

    func showProgramStatus() {
        if overlayController == nil { startOverlay() }
        stateMachine.showProgramStatus(title: "Program Status", body: "Loading program status...")
        syncNotchActivitySurface()

        programStatusTask?.cancel()
        programStatusTask = Task { [weak self] in
            do {
                let message = try await OrchestratorClient.fetchProgramStatusOverlay()
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self, title = message.title, body = message.body] in
                    self?.stateMachine.showProgramStatus(title: title, body: body)
                    self?.syncNotchActivitySurface()
                }
            } catch {
                guard !Task.isCancelled else { return }
                let message = ProgramStatusOverlayFormatter.errorMessage(for: error)
                await MainActor.run { [weak self, title = message.title, body = message.body] in
                    self?.stateMachine.showProgramStatus(title: title, body: body)
                    self?.syncNotchActivitySurface()
                }
            }
        }
    }

    func showServiceLifecycleDetail(_ message: String) {
        if overlayController == nil { startOverlay() }
        stateMachine.showProgramStatus(title: "Service Status", body: message)
        syncNotchActivitySurface()
    }

    func toggleRecording() {
        guard permissions.microphone == .granted else {
            permissions.requestMicrophonePrompt { _ in }
            return
        }
        remoteDeviceSession.userTookOver()
        sttEngine?.toggleRecording()
    }

    /// Show or hide the unified Workspace overlay. Single-repo sessions scope
    /// Work to that repo; workspace sessions aggregate discovered child repos.
    @discardableResult
    func toggleBoard(recognizedAt: CFTimeInterval? = nil) -> Bool {
        guard allowsAppShellAccess else { return false }
        return programBoardOverlay.toggle(recognizedAt: recognizedAt)
    }

    func toggleWorkspace() {
        _ = toggleBoard()
    }

    func toggleSessionWheel() {
        guard allowsAppShellAccess else { return }
        sessionWheel.toggle()
    }

    private func refreshSessionWheel(_ model: SessionWheelModel, includesProjects: Bool) {
        model.isWorkspaceVisible = programBoardOverlay.isVisible
        model.notchStatus = notchStatusController.status
        model.notePhase = meetingNoteSnapshot.phase
        model.keepAwake = keepAwake.state
        model.particleFieldEnabled = config.awareness.screen_glow
        if !model.isAdjustingIntensity { model.particleIntensity = config.awareness.glow_intensity }
        let recording = sttEngine?.isRecording == true
        let recordingKey = sttEngine?.recordingVoiceTargetSessionKey
        let ready = sttEngine != nil && sttSetupSucceeded && permissions.microphone == .granted
            && !meetingNoteSnapshot.phase.ownsForeground
        if includesProjects {
            let running = runningSessionProjectPaths
            model.projects = registeredProjectsV2()
                .filter { project in !running.contains { AssistantSessionStore.samePath($0, project.lastResolvedPath) } }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                .map { .init(id: $0.projectID, name: $0.displayName, path: $0.lastResolvedPath,
                             isAvailable: $0.availability == .available) }
        }
        if sessionRegistry.liveContextIDs.count >= EmbeddedSessionRegistry.maxConcurrentSessions {
            model.startUnavailableReason = "Session limit reached"
        } else if pendingSessionLaunchID != nil {
            model.startUnavailableReason = "Session starting"
        } else if meetingNoteSnapshot.phase.ownsForeground {
            model.startUnavailableReason = "Finish taking notes first"
        } else {
            model.startUnavailableReason = nil
        }
        model.refresh(sessions: workspaceSessionTabs.map { tab in
            let spool = sessionRegistry.spool(for: tab.id)
            let key = spool?.key
            let playback = sessionWheelPlayback(spool: spool)
            return SessionWheelSession(
                id: tab.id, name: tab.name, unreadCount: sessionReplyBadges[tab.id] ?? 0,
                isFocused: tab.id == activeContext.id,
                isRecording: recording && key != nil && key == recordingKey,
                canRecord: SessionWheelRecording.canToggle(targetKey: key, recording: recording,
                                                          recordingKey: recordingKey, ready: ready),
                canPlay: playback != nil,
                playback: playback ?? .replay
            )
        })
    }

    private func sessionWheelPlayback(spool: VoiceSessionSpool?) -> SessionVoicePlayback? {
        guard let spool, let key = spool.key else { return nil }
        return SessionVoicePlayback.resolve(
            live: stateMachine.sessionPlayback[key],
            unreadCount: VoiceReplyBadge.load(path: spool.replyBadge).unreadCount,
            hasStoredReply: VoiceReplyBadge.hasStoredReply(path: spool.replyBadge)
        )
    }

    static func sessionPlaybackMessage(sessionKey: String, action: SessionVoicePlayback) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["session_key": sessionKey, "action": action.rawValue]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "__SESSION_PLAYBACK__:" + json
    }

    private func performSessionWheelAction(contextID: String, action: SessionWheelAction) -> Bool {
        guard sessionRegistry.isLive(contextID),
              let context = assistantSessionStore.document.bindings[contextID]?.context else { return false }
        switch action {
        case .message:
            guard let spool = sessionRegistry.spool(for: contextID),
                  let playback = sessionWheelPlayback(spool: spool), let key = spool.key,
                  let message = Self.sessionPlaybackMessage(sessionKey: key, action: playback),
                  SocketClient.bridgeSend(message) else { return false }
            // Stopping a playing reply dismisses it at once, exactly like double-tap Control.
            if playback == .stop { stateMachine.cancelSpeechFromWheel() }
            return true
        case .recording:
            guard let engine = sttEngine,
                  let key = sessionRegistry.spool(for: contextID)?.key,
                  SessionWheelRecording.canToggle(targetKey: key, recording: engine.isRecording,
                                                  recordingKey: engine.recordingVoiceTargetSessionKey,
                                                  ready: sttSetupSucceeded && permissions.microphone == .granted
                                                    && !meetingNoteSnapshot.phase.ownsForeground) else { return false }
            remoteDeviceSession.userTookOver()
            if !engine.isRecording {
                guard newSession(workingDirectory: context.repositoryPath, showsWorkspaceOnLaunch: false),
                      activeContext.id == contextID, syncVoiceFocus(force: true) else { return false }
            }
            return engine.toggleRecording(forSessionKey: key)
        case .stop:
            if let key = sessionRegistry.spool(for: contextID)?.key,
               sttEngine?.recordingVoiceTargetSessionKey == key {
                sttEngine?.cancelRecording()
            }
            closeSessionTab(contextID: contextID)
            return true
        }
    }

    private func performNoteWheelAction(_ action: SessionWheelNoteAction) -> Bool {
        guard allowsAppShellAccess, action.isEnabled(for: meetingNoteSnapshot.phase) else { return false }
        switch action {
        case .recording:
            if !meetingNoteSnapshot.phase.ownsForeground {
                return startNoteTaker(workingDirectory: GlobalNoteStore.repositoryPath)
            }
            guard meetingNoteCoordinator != nil else { return false }
            stopNoteTaker()
        case .cancel:
            guard meetingNoteCoordinator != nil else { return false }
            cancelNoteTaker()
        case .pause:
            guard let coordinator = meetingNoteCoordinator else { return false }
            let paused = meetingNoteSnapshot.phase != .paused
            let transitionID = meetingNoteTransitionID
            Task { @MainActor [weak self] in
                guard let self, transitionID == self.meetingNoteTransitionID else { return }
                await coordinator.setPaused(paused)
                let snapshot = await coordinator.snapshot()
                guard transitionID == self.meetingNoteTransitionID else { return }
                self.applyMeetingNoteSnapshot(snapshot)
            }
        }
        return true
    }

    func showWorkspaceSettings() {
        guard allowsAppShellAccess else { return }
        if overlayController == nil { startOverlay() }
        programBoardOverlay.showSettings()
    }

    private func showWorkspaceWork() {
        guard allowsAppShellAccess else { return }
        if overlayController == nil { startOverlay() }
        programBoardOverlay.showWork()
    }

    var usesProjectRegistryV2: Bool {
        projectRegistryV2 != nil
    }

    func registeredProjectsV2() -> [RegisteredProjectV2] {
        (try? projectRegistryV2?.projects()) ?? []
    }

    func refreshRegisteredProject(_ projectID: String) throws -> RegisteredProjectV2 {
        guard let projectRegistryV2 else {
            throw ProjectRegistryV2Service.ServiceError.projectNotFound(projectID)
        }
        let project = try projectRegistryV2.refreshAvailability(projectID: projectID)
        invalidateConfirmedProjectScopeIfNeeded()
        refreshWorkspaceActivity(invalidateRoute: true)
        return project
    }

    func removeRegisteredProject(_ projectID: String) throws {
        guard let projectRegistryV2 else {
            throw ProjectRegistryV2Service.ServiceError.projectNotFound(projectID)
        }
        try projectRegistryV2.removeProject(projectID: projectID, confirmed: true)
        if activeSessionProjectScopeToken?.projectID == projectID {
            projectScopeCoordinator.cancel(projectID: projectID)
            activeSessionProjectScopeToken = nil
        }
        invalidateConfirmedProjectScopeIfNeeded()
        refreshWorkspaceActivity(invalidateRoute: true)
    }

    func chooseCustomVoiceAudio(completion: @escaping (URL?) -> Void) {
        let resumeWorkspace = programBoardOverlay.isVisible
        suspendWorkspaceForProjectPicker { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            defer {
                if resumeWorkspace { self.programBoardOverlay.showSettings() }
            }
            let panel = NSOpenPanel()
            panel.title = "Import Custom Voice"
            panel.message = "Choose a voice reference recording."
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.wav, .aiff, .mp3, .mpeg4Audio]
            completion(WorkspaceDirectoryPicker.runAppKitPanel(panel))
        }
    }

    func addExistingProject(
        resumeInSettings: Bool = false,
        completion: ((Result<RegisteredProjectV2, Error>) -> Void)? = nil
    ) {
        guard let projectRegistryV2 else { return }
        WorkspaceDirectoryPicker.pick(
            message: "Choose an existing project folder",
            onPrepareExternalWindow: { [weak self] ready in
                guard let self else {
                    ready()
                    return
                }
                self.suspendWorkspaceForProjectPicker(ready)
            },
            chooseDirectory: {
                WorkspaceDirectoryPicker.runAppKitDirectoryPanel(
                    message: "Choose an existing project folder"
                )
            },
            completion: { [weak self] path in
                guard let self else { return }
                guard let path else {
                    self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings)
                    return
                }
                self.performProjectRegistration(
                    resumeInSettings: resumeInSettings,
                    completion: completion
                ) {
                    let url = URL(fileURLWithPath: path, isDirectory: true)
                    return try projectRegistryV2.registerExistingProject(at: url)
                }
            }
        )
    }

    func createProject(
        resumeInSettings: Bool = false,
        completion: ((Result<RegisteredProjectV2, Error>) -> Void)? = nil
    ) {
        guard let projectRegistryV2 else { return }
        suspendWorkspaceForProjectPicker { [weak self] in
            guard let self else { return }
            let panel = NSSavePanel()
            panel.title = "Create Project"
            panel.message = "Choose a new folder for the Git repository."
            panel.nameFieldLabel = "Project name:"
            panel.nameFieldStringValue = "New Project"
            panel.canCreateDirectories = true
            let selectedURL = WorkspaceDirectoryPicker.runAppKitPanel(panel)
            guard let selectedURL else {
                self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings)
                return
            }
            self.performProjectRegistration(
                resumeInSettings: resumeInSettings,
                completion: completion
            ) {
                try projectRegistryV2.createProject(at: selectedURL)
            }
        }
    }

    private func performProjectRegistration(
        resumeInSettings: Bool,
        completion: ((Result<RegisteredProjectV2, Error>) -> Void)?,
        operation: @escaping () throws -> RegisteredProjectV2
    ) {
        Task { @MainActor [weak self] in
            let result = await Self.performProjectRegistrationWork(operation)
            guard let self else { return }
            switch result {
            case .success(let project):
                self.refreshWorkspaceActivity(invalidateRoute: true) {
                    self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings)
                    completion?(.success(project))
                }
            case .failure(let error):
                self.surfaceProjectManagementFailure(error)
                self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings)
                completion?(.failure(error))
            }
        }
    }

    static func performProjectRegistrationWork<T>(
        _ operation: @escaping () throws -> T
    ) async -> Result<T, Error> {
        await Task.detached(priority: .utility) {
            Result { try operation() }
        }.value
    }

    func locateRegisteredProject(
        _ projectID: String,
        resumeInSettings: Bool = true,
        completion: ((Result<RegisteredProjectV2, Error>) -> Void)? = nil
    ) {
        guard let projectRegistryV2 else { return }
        WorkspaceDirectoryPicker.pick(
            message: "Locate the registered Git repository",
            onPrepareExternalWindow: { [weak self] ready in
                guard let self else {
                    ready()
                    return
                }
                self.suspendWorkspaceForProjectPicker(ready)
            },
            chooseDirectory: {
                WorkspaceDirectoryPicker.runAppKitDirectoryPanel(
                    message: "Locate the registered Git repository"
                )
            },
            completion: { [weak self] path in
                guard let self else { return }
                defer { self.resumeWorkspace(afterProjectManagementInSettings: resumeInSettings) }
                guard let path else { return }
                do {
                    let project = try projectRegistryV2.locate(
                        projectID: projectID,
                        selectedURL: URL(fileURLWithPath: path, isDirectory: true)
                    )
                    self.invalidateConfirmedProjectScopeIfNeeded()
                    self.refreshWorkspaceActivity(invalidateRoute: true)
                    completion?(.success(project))
                } catch {
                    self.surfaceProjectManagementFailure(error)
                    completion?(.failure(error))
                }
            }
        )
    }

    private func resumeWorkspace(afterProjectManagementInSettings settings: Bool) {
        if settings {
            programBoardOverlay.showSettings()
        } else {
            programBoardOverlay.showWork()
        }
    }

    private func invalidateConfirmedProjectScopeIfNeeded() {
        guard let projectRegistryV2 else { return }
        projectScopeCoordinator.invalidateIfNeeded(using: projectRegistryV2.validateScopeToken)
        activeSessionProjectScopeToken = projectScopeCoordinator.inheritedToken()
    }

    private func surfaceProjectManagementFailure(_ error: Error) {
        statusText = "Project update failed"
        stateMachine.showProgramStatus(
            title: "Project update failed",
            body: String(describing: error)
        )
        syncNotchActivitySurface()
    }

    @MainActor
    func activateProject(pathOrAlias: String, provider: String?, continuation: [String: String]? = nil) async -> ProjectActivationReply {
        let reply = await Task.detached(priority: .utility) {
            do {
                let project = try ProjectResolver.activateProject(
                    matching: pathOrAlias,
                    provider: provider
                )
                return ProjectActivationReply.activated(repoPath: project.repoPath.path)
            } catch {
                return ProjectActivationReply.failed(message: "\(error)")
            }
        }.value
        if case .activated(let repoPath, _) = reply {
            let selected: Bool
            do {
                if let continuation {
                    guard let registry = projectRegistryV2 else { throw CocoaError(.fileNoSuchFile) }
                    let token = try registry.scopeToken(matching: repoPath)
                    guard registry.validateScopeToken(token).isValid else { throw ProjectRegistryV2Service.ServiceError.staleScope(token.projectID) }
                    let destination = AssistantSessionContext.project(token)
                    let id = try reserveContextContinuation(continuation, destination: destination)
                    selected = requestContextSelection(destination, continuationID: id)
                } else {
                    // RR-397: focus a running session or browse the board;
                    // never start a process or stop the source session.
                    selected = selectProjectContext(repositoryPath: repoPath, startsSession: false)
                }
            } catch { return .failed(message: error.localizedDescription) }
            guard selected else {
                return .failed(message: contextSwitchMessage ?? "Project context could not be selected.")
            }
            refreshWorkspaceActivity(invalidateRoute: true)
            if pendingContextSelection != nil {
                return .queued(repoPath: repoPath, message: "\(contextSwitchMessage ?? "Project switch queued.") Finish the current reply.\(continuation == nil ? "" : " The request is then delivered once to that project's session.")")
            }
            return .activated(repoPath: repoPath, message: browseOrFocusMessage(name: activeContext.displayName))
        }
        return reply
    }

    /// Reply for a focus-or-browse activation of the now-active context.
    private func browseOrFocusMessage(name: String) -> String {
        if sessionRegistry.isLive(activeContext.id) {
            return "Focused the running \(name) session; other sessions keep running."
        }
        programBoardOverlay.showWork()
        return "Opened the \(name) board without starting a session; other sessions keep running. Pass continuation to forward an unfinished request into \(name)'s session."
    }

    @MainActor
    func activateGeneral(continuation: [String: String]? = nil) -> GeneralActivationReply {
        let selected: Bool
        do {
            guard let registry = projectRegistryV2 else { throw CocoaError(.fileNoSuchFile) }
            let project = try registry.ensureGeneralTasksProject()
            let token = try registry.scopeToken(matching: project.lastResolvedPath)
            guard registry.validateScopeToken(token).isValid else {
                throw ProjectRegistryV2Service.ServiceError.staleScope(token.projectID)
            }
            if let continuation {
                let destination = AssistantSessionContext.project(token)
                let id = try reserveContextContinuation(continuation, destination: destination)
                selected = requestContextSelection(destination, continuationID: id)
            } else { selected = selectGeneralContext(startsSession: false) }
        } catch { return .failed(message: error.localizedDescription) }
        guard selected else {
            return .failed(message: contextSwitchMessage ?? "general could not be selected.")
        }
        refreshWorkspaceActivity(invalidateRoute: true)
        let message = pendingContextSelection != nil
            ? "\(contextSwitchMessage ?? "general selection queued.") Finish the current reply.\(continuation == nil ? "" : " The request is then delivered once to the general session.")"
            : browseOrFocusMessage(name: activeContext.displayName)
        return .selected(message: message)
    }

    // MARK: - Bridge watchdog

    private var bridgeRecoveryFallbackConfig: AppConfig? {
        guard menuSessionActive else { return nil }
        return activeSessionLaunchConfig ?? config
    }

    private func startBridgeWatchdog() {
        stopBridgeWatchdog()
        refreshBridgeWatchdog()
        bridgeWatchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshBridgeWatchdog()
        }
        replyBadgeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshSessionReplyBadges()
        }
    }

    private func refreshBridgeWatchdog() {
        guard isRunning, bridgeWatchdogTask == nil else { return }
        let processManager = processManager
        let fallbackConfig = bridgeRecoveryFallbackConfig
        let binding = assistantSessionStore.binding(for: voiceContext)
        let managedProvider = !menuSessionActive && !sessionRegistry.hasLiveSessions && binding?.lifecycle == .interrupted
            ? binding?.managedProcess : nil
        bridgeWatchdogTask = Task { @MainActor [weak self] in
            let sample = await Task.detached(priority: .utility) {
                let daemonAlive = processManager.bridgeAlive()
                let consumerAlive = daemonAlive && processManager.bridgeConsumerAlive()
                return BridgeWatchdogSample(
                    daemonAlive: daemonAlive,
                    consumerAlive: consumerAlive,
                    hasSessionContext: processManager.bridgeRecoveryContext(
                        fallbackConfig: fallbackConfig
                    ) != nil,
                    pendingDeliveryState: processManager.pendingVoiceCommandDeliveryState(),
                    stopRequested: processManager.bridgeStopRequested(),
                    managedProviderState: managedProvider.map { (process: $0, state: $0.state()) }
                )
            }.value
            guard let self else { return }
            self.bridgeWatchdogTask = nil
            guard !Task.isCancelled, self.isRunning else { return }
            self.applyBridgeWatchdogSample(sample)
        }
    }

    private func applyBridgeWatchdogSample(_ sample: BridgeWatchdogSample) {
        // The update preflight can take longer than the bridge launch grace.
        guard pendingSessionLaunchID == nil else { return }
        bridgeManagedProviderState = sample.managedProviderState
        reconcileAssistantContext()
        guard pendingSessionLaunchID == nil, !idleSessionSaved else { return }
        // A stale/external bridge cannot silently choose the conversation's
        // project. The chooser or Start Session establishes that authority.
        if !menuSessionActive, sample.daemonAlive, !bridgeMatchesActiveContext {
            bridgeAliveCache = false
            return
        }
        let daemonAlive = sample.daemonAlive
        let consumerAlive = sample.consumerAlive
        let hasSessionContext = sample.hasSessionContext
        let pendingDeliveryState = sample.pendingDeliveryState
        let pendingDeliveryTimedOut = pendingDeliveryState == .timedOut
        let alive = ProcessManager.relaySessionAlive(
            daemonAlive: daemonAlive,
            consumerAlive: consumerAlive,
            hasSessionContext: hasSessionContext
        )
        let wasAlive = bridgeAliveCache
        let elapsed = Date().timeIntervalSince(sessionStartTime)
        let action = Self.bridgeWatchdogAction(
            menuSessionActive: menuSessionActive,
            daemonAlive: daemonAlive,
            consumerAlive: consumerAlive,
            hasSessionContext: hasSessionContext,
            wasAlive: wasAlive,
            sessionBridgeSeen: sessionBridgeSeen,
            elapsedSinceSessionStart: elapsed,
            pendingDeliveryTimedOut: pendingDeliveryTimedOut,
            pendingDeliveryState: pendingDeliveryState,
            stopRequested: sample.stopRequested,
            recoverySuppressed: bridgeRecoverySuppressedForUpdate
        )

        if alive != wasAlive {
            refreshWorkspaceActivity(invalidateRoute: true)
        }

        switch action {
        case .reapOrphan:
            NSLog("[AppState] Relay bridge orphaned before any active session, killing")
            processManager.killBridge()
            bridgeAliveCache = false
            menuSessionActive = false
            activeSessionLaunchConfig = nil
            activeSessionProjectScopeToken = nil
            projectScopeCoordinator.cancel()
            sessionBridgeSeen = false
            activeSessionSuppressesStartupGreeting = false
            statusText = "Ready"
            return
        case .keepDaemon:
            // A busy Codex/Claude turn can stop touching the consumer
            // heartbeat while git/build work continues. A completed Codex
            // App turn can also leave a valid context-backed daemon idle.
            // Keep that session alive so TTS, the board, and queued voice
            // input can recover.
            bridgeAliveCache = true
            if !menuSessionActive || activeProviderInteractiveReady {
                statusText = "Session"
            } else {
                statusText = "Starting session"
            }
            return
        case .voiceCommandQueued:
            bridgeAliveCache = true
            if statusText != Self.voiceCommandQueuedPresentation.statusText {
                surfaceVoiceCommandQueued()
            }
        case .waitForConsumer:
            bridgeAliveCache = true
            if statusText != "Voice command waiting" {
                surfaceVoiceCommandWaiting()
            }
            return
        case .waitForLaunch:
            bridgeAliveCache = true
            return
        case .recoverDaemon:
            bridgeAliveCache = false
            let reason = pendingDeliveryTimedOut
                ? "voice-delivery-timeout"
                : (wasAlive ? "bridge-lost" : "menu-session-lost")
            if startBridgeRecovery(reason: reason) {
                return
            }
            NSLog("[AppState] Bridge died but no recovery context was available")
            menuSessionActive = false
            activeSessionLaunchConfig = nil
            activeSessionProjectScopeToken = nil
            projectScopeCoordinator.cancel()
            sessionBridgeSeen = false
            activeSessionSuppressesStartupGreeting = false
            surfaceBridgeRecoveryFailure(reason: reason)
            return
        case .markDead:
            bridgeAliveCache = false
        case .alive:
            bridgeAliveCache = true
            if menuSessionActive {
                statusText = activeProviderInteractiveReady ? "Session" : "Starting session"
            }
        }

        // Track externally-started bridges (e.g. /relay-bridge)
        if alive,
           action != .voiceCommandQueued,
           !menuSessionActive,
           statusText != "Session" {
            statusText = "Session"
            // External /relay-bridge counts as the first session run
            // for onboarding purposes — same as the menu Start Session
            // path. Without this, a user who only ever uses the slash
            // command would keep seeing the All Set re-prompt.
            onboarding.markSessionRun()
        }

        if alive {
            sweepReadyTicketsForActiveProject(
                trigger: wasAlive ? "bridge-watchdog" : "bridge-reconnect"
            )
        }

        if alive {
            // Legacy parent-permission metadata is ignored. Relay Runner
            // now hosts Relay Actions/Vision gated calls in the app
            // process, so Accessibility and Screen Recording belong to
            // Relay Runner rather than the agent parent.
            if !wasAlive { wizardShownForCurrentBridgeSession = true }
        } else if wasAlive {
            // Bridge died — reset the legacy session flag.
            wizardShownForCurrentBridgeSession = false
        }

        if menuSessionActive && alive {
            sessionBridgeSeen = true
        }

        if wasAlive && !alive && !menuSessionActive {
            // Relay-bridge session ended externally — same idea: update
            // status quietly, let the prompt fire on next Caps Lock.
            NSLog("[AppState] Relay bridge died, reverting to awareness")
            statusText = "Ready"
        }
    }

    private var activeProviderInteractiveReady: Bool {
        switch voiceSession.phase {
        case .running, .external:
            return true
        default:
            return false
        }
    }

    enum BridgeWatchdogAction: Equatable {
        case alive
        case voiceCommandQueued
        case keepDaemon
        case waitForConsumer
        case waitForLaunch
        case recoverDaemon
        case reapOrphan
        case markDead
    }

    static func bridgeWatchdogAction(
        menuSessionActive: Bool,
        daemonAlive: Bool,
        consumerAlive: Bool,
        hasSessionContext: Bool = false,
        wasAlive: Bool,
        sessionBridgeSeen: Bool,
        elapsedSinceSessionStart: TimeInterval,
        pendingDeliveryTimedOut: Bool = false,
        pendingDeliveryState: ProcessManager.PendingVoiceCommandDeliveryState = .none,
        stopRequested: Bool = false,
        recoverySuppressed: Bool = false
    ) -> BridgeWatchdogAction {
        if stopRequested {
            return daemonAlive ? .reapOrphan : .markDead
        }
        if recoverySuppressed {
            return .markDead
        }
        if daemonAlive && consumerAlive {
            if pendingDeliveryState == .waiting {
                return .voiceCommandQueued
            }
            return .alive
        }
        let deliveryTimedOut = pendingDeliveryTimedOut || pendingDeliveryState == .timedOut
        if daemonAlive && !consumerAlive {
            if deliveryTimedOut {
                return (menuSessionActive || wasAlive || hasSessionContext) ? .waitForConsumer : .reapOrphan
            }
            return (menuSessionActive || wasAlive || hasSessionContext) ? .keepDaemon : .reapOrphan
        }
        if menuSessionActive {
            if sessionBridgeSeen || elapsedSinceSessionStart > 90 {
                return .recoverDaemon
            }
            return .waitForLaunch
        }
        if hasSessionContext && wasAlive {
            return .recoverDaemon
        }
        return .markDead
    }

    enum RecordingStartBridgeAction: Equatable {
        case allowRecording
        case waitForBridgeRecovery
        case recoverBridge
        case promptForSession
        case waitForPendingCommand
        case waitForConsumer
    }

    static func recordingStartBridgeAction(
        bridgeRecoveryInFlight: Bool,
        daemonAlive: Bool,
        consumerAlive: Bool,
        hasSessionContext: Bool,
        pendingDeliveryState: ProcessManager.PendingVoiceCommandDeliveryState
    ) -> RecordingStartBridgeAction {
        if bridgeRecoveryInFlight {
            return .waitForBridgeRecovery
        }
        if !daemonAlive {
            return hasSessionContext ? .recoverBridge : .promptForSession
        }
        if pendingDeliveryState == .timedOut {
            return .waitForPendingCommand
        }
        if !consumerAlive {
            return hasSessionContext ? .waitForConsumer : .promptForSession
        }
        return .allowRecording
    }

    @discardableResult
    private func startBridgeRecovery(reason: String) -> Bool {
        if bridgeRecoverySuppressedForUpdate { return false }
        if processManager.bridgeStopRequested() { return false }
        if bridgeRecoveryInFlight { return true }
        guard let baseContext = processManager.bridgeRecoveryContext(fallbackConfig: bridgeRecoveryFallbackConfig) else {
            return false
        }
        guard AssistantSessionStore.samePath(baseContext.workingDirectory, voiceContext.workingDirectory) else { return false }
        let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
            repositoryPath: baseContext.workingDirectory
        )
        let context = ProcessManager.BridgeRecoveryContext(
            workingDirectory: baseContext.workingDirectory,
            provider: baseContext.provider,
            recoveryGeneration: continuityRecoveryGenerationBySession[sessionID],
            continuityRecoveryPending: reason.hasPrefix("continuity-"),
            sessionScope: voiceContext.kind.rawValue,
            generalFilesRoot: AssistantSessionStore.filesDirectory.path,
            preservesContextAuthorization: true,
            spoolDirectory: baseContext.spoolDirectory
        )
        let now = Date()
        if now.timeIntervalSince(lastBridgeRecoveryAt) < Self.bridgeRecoveryCooldown {
            return true
        }

        bridgeRecoveryInFlight = true
        lastBridgeRecoveryAt = now
        sentVoiceFocus = []
        statusText = "Session reconnecting"
        NSLog("[AppState] Relaunching voice bridge daemon for \(context.workingDirectory) reason=\(reason)")

        let processManager = self.processManager
        let suppressStartupGreeting = activeSessionSuppressesStartupGreeting
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recovered = processManager.relaunchBridgeDaemon(
                context: context,
                suppressStartupGreeting: suppressStartupGreeting
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bridgeRecoveryInFlight = false
                if self.processManager.bridgeStopRequested() {
                    if recovered {
                        self.processManager.killBridge(stopRequested: true)
                    }
                    self.bridgeAliveCache = false
                    self.menuSessionActive = false
                    self.activeSessionLaunchConfig = nil
                    self.activeSessionProjectScopeToken = nil
                    self.projectScopeCoordinator.cancel()
                    self.sessionBridgeSeen = false
                    self.activeSessionSuppressesStartupGreeting = false
                    self.statusText = "Ready"
                    NSLog("[AppState] Voice bridge recovery ignored because session stop was requested")
                    return
                }
                if recovered {
                    self.bridgeAliveCache = true
                    self.sessionStartTime = Date()
                    self.sessionBridgeSeen = false
                    self.statusText = "Session"
                    NSLog("[AppState] Voice bridge daemon recovery succeeded")
                } else {
                    self.bridgeAliveCache = false
                    self.menuSessionActive = false
                    self.activeSessionLaunchConfig = nil
                    self.activeSessionProjectScopeToken = nil
                    self.projectScopeCoordinator.cancel()
                    self.sessionBridgeSeen = false
                    self.activeSessionSuppressesStartupGreeting = false
                    self.surfaceBridgeRecoveryFailure(reason: reason)
                    NSLog("[AppState] Voice bridge daemon recovery failed")
                }
            }
        }
        return true
    }

    static func bridgeRecoveryFailurePresentation(reason: String) -> BridgeRecoveryFailurePresentation {
        let detail = reason == "voice-delivery-timeout"
            ? "a voice delivery timeout"
            : "the bridge stopped responding"
        return BridgeRecoveryFailurePresentation(
            statusText: "Voice bridge recovery failed",
            title: "Voice command not delivered",
            body: (
                "Relay Runner could not recover the active voice bridge after \(detail). "
                + "Start a new session before speaking again."
            )
        )
    }

    private func surfaceBridgeRecoveryFailure(reason: String) {
        if voiceSession.phase == .running {
            voiceSession.end()
        }
        let presentation = Self.bridgeRecoveryFailurePresentation(reason: reason)
        statusText = presentation.statusText
        stateMachine.showProgramStatus(title: presentation.title, body: presentation.body)
        syncNotchActivitySurface()
    }

    private func surfaceVoiceCommandWaiting() {
        statusText = "Voice command waiting"
        stateMachine.showProgramStatus(
            title: "Voice command waiting",
            body: "Relay Runner recorded a voice command, but the active Codex or Claude listener has not claimed it yet. Keep the agent turn running, or start a new session before speaking again."
        )
        syncNotchActivitySurface()
    }

    static let voiceCommandQueuedPresentation = ProgramStatusPresentation(
        statusText: "Command queued",
        title: "Command queued",
        body: "Relay Runner is holding the latest voice command until the active Codex or Claude turn can take it. Speak again to replace the queued command."
    )

    private func surfaceVoiceCommandQueued() {
        let presentation = Self.voiceCommandQueuedPresentation
        statusText = presentation.statusText
        stateMachine.showProgramStatus(title: presentation.title, body: presentation.body)
        syncNotchActivitySurface()
    }

    private func surfaceVoiceListenerIdle() {
        statusText = "Voice listener idle"
        stateMachine.showProgramStatus(
            title: "Voice listener idle",
            body: "The Relay bridge is still running, but the active Codex or Claude turn is not listening for new voice commands. Start a new session before speaking again."
        )
        syncNotchActivitySurface()
    }

    private func showSessionPromptIfAllowed(now: Date = Date()) {
        if case .sessionPrompt = stateMachine.state {
            return
        }
        guard sessionPromptGate.shouldShow(now: now) else {
            return
        }
        sessionPromptCapsState = CapsLockGesture.isCapsLockOn()
        stateMachine.showSessionPrompt()
    }

    private func stopBridgeWatchdog() {
        bridgeWatchdog?.invalidate()
        bridgeWatchdog = nil
        bridgeWatchdogTask?.cancel()
        bridgeWatchdogTask = nil
        replyBadgeTimer?.invalidate()
        replyBadgeTimer = nil
        sessionReplyBadges = [:]
    }

    private func sweepReadyTicketsForActiveProject(trigger: String) {
        guard case .project(let project) = workspaceActivitySnapshot.route else { return }
        let token = activeSessionProjectScopeToken
        OrchestratorClient.sweepReadyTickets(
            repoPath: project.repoPath.path,
            trigger: trigger,
            projectScopeToken: token?.repositoryPath == project.repoPath.path ? token?.encodedValue : nil
        )
    }

    /// Read the bus's most-recently-detected parent and open the wizard if
    /// this parent hasn't been onboarded yet. Called from the bridge
    /// watchdog on every tick the bridge is alive (until the per-session flag
    /// flips true). Skips when the bus hasn't yet received a
    /// `parent_detected` (MCP server still booting — the next tick retries),
    /// when the parent was unclassifiable (the wizard has nothing useful to
    /// say — flag set so we don't keep checking), and when the tracker has
    /// recorded an acknowledgement (flag set to stop polling).
    private func surfaceParentWizardIfNeeded() {
        guard let bus = actionsBus else { return }
        let controller = parentOnboardingController
        Task { [weak self] in
            guard let self else { return }
            // Parent unknown yet — leave the flag false so the next tick retries.
            guard let parent = await bus.currentParent() else { return }
            await MainActor.run {
                // We have a parent. Settle this session one way or another
                // so the watchdog stops polling.
                self.wizardShownForCurrentBridgeSession = true
                if parent == "unknown" { return }
                if ParentOnboardingTracker.isOnboarded(parent) { return }
                controller.show(parent: parent)
            }
        }
    }

    // MARK: - Overlay management

    private func startOverlay() {
        guard overlayController == nil else { return }

        // State event bus (listens for Python service state)
        let bus = StateEventBus(
            stateMachine: stateMachine,
            shouldHandleServiceEvent: { [weak self] source, tutorial in
                guard let self else { return false }
                return Self.shouldHandleServiceEvent(
                    source: source,
                    tutorial: tutorial,
                    tutorialActive: self.onboarding.isSessionControlsTutorialActive
                )
            },
            onServiceEvent: { [weak self] source, state, text, tutorial in
                if source == "tts", state == "custom_voice_fallback" {
                    self?.customVoiceNotice = "Custom voice unavailable. The remaining response used George. Preview the voice again to check its local runtime."
                }
                self?.handleOnboardingTutorialServiceEvent(
                    source: source,
                    state: state,
                    text: text,
                    tutorial: tutorial
                )
            },
            onRecoveryAction: { [weak self] request in
                self?.performContinuityRecoveryAction(request)
                    ?? .failed("component_action_unavailable")
            },
            onRemoteDeviceEvent: { [weak self] event in
                self?.remoteDeviceSession.apply(event)
            }
        )
        eventBus = bus
        Task { await bus.start() }

        // Relay Actions confirmation bus (request/reply socket between the
        // RelayActionsMCP helper and the menu-bar app — drives perimeter
        // glow + double-tap confirmation for propose_action).
        //
        let actions = ActionsConfirmBus(
            stateMachine: stateMachine,
            onParentPermissionRevoked: { _, _ in
                // Compatibility with older helper binaries. Current helpers
                // forward gated work to the app, so parent revocation is not
                // actionable.
            },
            onToggleBoard: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    _ = self.toggleBoard(recognizedAt: CACurrentMediaTime())
                }
            },
            onActivateProject: { [weak self] pathOrAlias, provider, continuation in
                guard let self else {
                    return .failed(message: "Relay Runner app state is unavailable.")
                }
                return await self.activateProject(pathOrAlias: pathOrAlias, provider: provider, continuation: continuation)
            },
            onActivateGeneral: { [weak self] continuation in
                guard let self else { return .failed(message: "Relay Runner app state is unavailable.") }
                return self.activateGeneral(continuation: continuation)
            },
            onHostedToolPermissionMissing: { [weak self] kind, purpose in
                guard let appState = self else { return }
                await MainActor.run {
                    appState.requestPermissionSetup(kind, source: .hostedTool, purpose: purpose)
                }
            }
        )
        actionsBus = actions
        Task { await actions.start() }
        // Wire CapsLockGesture's modal yes/no resolution back to the bus.
        // Gesture handler runs on the main thread; bridge to the actor via Task.
        sttEngine?.wireConfirmationGate(stateMachine: stateMachine) { [weak actions] confirmed in
            Task { _ = await actions?.resolveLatest(confirmed: confirmed) }
        }

        // Overlay controller (panel + glow + pill)
        let oc = OverlayController(config: config.awareness)
        oc.start(stateMachine: stateMachine)
        overlayController = oc
        oc.setReplyStackDepth(sessionReplyBadges.values.reduce(0, +))

        // Workspace overlay — install Esc dismissal once macOS has granted
        // either global-event permission. Accessibility is the normal setup
        // path; an existing Input Monitoring grant remains compatible. The
        // double-tap Shift board trigger is emitted by the STT gesture monitor
        // in voice mode and by the note gesture monitor while taking notes.
        if permissions.accessibility == .granted || permissions.inputMonitoring == .granted {
            programBoardOverlay.installGlobalDismissHotkey()
        }
        programBoardOverlay.setThemeResolver { [weak self] in
            guard let state = self?.stateMachine.state else { return nil }
            if case .actionGlow = state { return .stt }
            return state.particleTheme
        }
        programBoardOverlay.setNoSessionHandler { [weak self] in
            self?.showSessionPromptIfAllowed()
        }
        programBoardOverlay.setLoadingStateHandler { [weak self] loadingState in
            self?.setProgramBoardLoadingState(loadingState)
        }
        programBoardOverlay.setSettingsContentProvider { [weak self] in
            guard let self else { return nil }
            return AnyView(WorkspaceSettingsPanel(
                appState: self,
                onOpenExternalWindow: { [weak self] in
                    self?.suspendWorkspaceForExternalWindow()
                }
            ))
        }
        programBoardOverlay.setTerminalContentProvider { [weak self] _ in
            guard let self else { return nil }
            return AnyView(WorkspaceTerminalPanel(appState: self))
        }
        programBoardOverlay.setTerminalFocusProvider(
            hasFocus: { [weak self] in self?.embeddedTerminal.hasTerminalFocus ?? false },
            focus: { [weak self] in self?.embeddedTerminal.focus() }
        )
        // Perimeter overlay (purple band on every screen while
        // .actionGlow is active; pulses while a confirmation is pending).
        let perimeter = PerimeterOverlayManager()
        perimeter.start(stateMachine: stateMachine)
        perimeterOverlay = perimeter
        startNotchActivityPolling()
        syncNotchStatusSurface()

        // Poll STT engine state → state machine (STT is in-process, no socket needed)
        sttPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self, let engine = self.sttEngine else { return }
            // Re-assert live ownership, never infer it from a retained tutorial screen.
            self.syncCommandCaptureOwnership()

            let nowRecording = engine.isRecording
            let justStartedRecording = nowRecording && !self.wasRecording
            let captureOwnerRequested =
                engine.captureOwnerRequestedSerial != self.observedCaptureOwnerRequestedSerial
            self.observedCaptureOwnerRequestedSerial = engine.captureOwnerRequestedSerial
            self.publishOnboardingTutorialSTTEvents(from: engine, includeRecordingStart: false)

            if engine.boardToggleRequested {
                let recognizedAt = engine.boardToggleRequestedAt ?? CACurrentMediaTime()
                engine.boardToggleRequested = false
                engine.boardToggleRequestedAt = nil
                Self.routeWorkspaceToggleRequest(
                    consumeForTutorial: self.onboarding.shouldConsumeWorkspaceToggleRequest,
                    toggleWorkspace: {
                        _ = self.toggleBoard(recognizedAt: recognizedAt)
                    },
                    completeTutorial: {
                        self.onboarding.noteTutorialWorkspaceToggled()
                    }
                )
            }

            // Session prompt: handle responses
            if case .sessionPrompt = self.stateMachine.state,
               !self.onboarding.isSessionControlsTutorialActive {
                if engine.playRequested {
                    // Double-tap Alt → start new session
                    engine.playRequested = false
                    engine.playRequestedAt = nil
                    engine.playDetectedAt = nil
                    self.onboarding.noteTutorialPlaybackRequested()
                    self.stateMachine.dismissSessionPrompt()
                    self.newSession(workingDirectory: self.activeContext.workingDirectory)
                } else if CapsLockGesture.isCapsLockOn() != self.sessionPromptCapsState {
                    // Any Caps Lock toggle → dismiss prompt immediately
                    if engine.isRecording { engine.cancelRecording() }
                    self.stateMachine.dismissSessionPrompt()
                }
                self.wasRecording = nowRecording
                self.syncNotchActivitySurface()
                return
            }

            // No bridge alive: intercept recording and show prompt.
            // Real-time check on each recording start — the cached value
            // can be stale for up to 3s after a bridge dies.
            // Also detect orphaned relay bridges (process alive but no consumer).
            if justStartedRecording && self.onboarding.isSessionControlsTutorialActive {
                self.publishOnboardingTutorialSTTEvents(
                    from: engine,
                    includeRecordingStart: true
                )
            } else if captureOwnerRequested && self.bridgeStartingUp
                        && !self.onboarding.isSessionControlsTutorialActive {
                // The mic stayed closed: nothing is ready to accept a command yet.
                self.stateMachine.showProgramStatus(
                    title: "Session starting up",
                    body: "Relay Runner is still starting the session. Try again once it's ready."
                )
                self.syncNotchActivitySurface()
            } else if justStartedRecording
                        || (captureOwnerRequested && !self.onboarding.isSessionControlsTutorialActive) {
                // An out-of-session gesture never opened the mic; it takes the
                // same real-time bridge check so the session affordance matches.
                let daemonAlive = self.processManager.bridgeAlive() && self.bridgeMatchesActiveContext
                let pendingDeliveryState = self.processManager.pendingVoiceCommandDeliveryState()
                let consumerAlive = daemonAlive && self.processManager.bridgeConsumerAlive()
                let hasSessionContext = self.processManager.bridgeRecoveryContext(
                    fallbackConfig: self.bridgeRecoveryFallbackConfig
                ) != nil
                let bridgeAction = Self.recordingStartBridgeAction(
                    bridgeRecoveryInFlight: self.bridgeRecoveryInFlight,
                    daemonAlive: daemonAlive,
                    consumerAlive: consumerAlive,
                    hasSessionContext: hasSessionContext,
                    pendingDeliveryState: pendingDeliveryState
                )

                switch bridgeAction {
                case .allowRecording:
                    self.bridgeAliveCache = true
                    if justStartedRecording {
                        self.publishOnboardingTutorialSTTEvents(from: engine, includeRecordingStart: true)
                    } else {
                        // A live bridge the watchdog hadn't cached yet: capture
                        // opens now, after the gesture, so ask for a retry.
                        self.stateMachine.showProgramStatus(
                            title: "Voice session connected",
                            body: "The microphone is ready. Press your record key again to speak."
                        )
                        self.syncNotchActivitySurface()
                    }
                case .waitForBridgeRecovery:
                    engine.cancelRecording()
                    self.wasRecording = false
                    self.stateMachine.showProgramStatus(
                        title: "Voice session reconnecting",
                        body: "Relay Runner is recovering the active voice bridge. Try again in a moment."
                    )
                    self.syncNotchActivitySurface()
                    return
                case .waitForPendingCommand:
                    self.bridgeAliveCache = true
                    engine.cancelRecording()
                    self.wasRecording = false
                    self.surfaceVoiceCommandWaiting()
                    return
                case .waitForConsumer:
                    self.bridgeAliveCache = true
                    engine.cancelRecording()
                    self.wasRecording = false
                    self.surfaceVoiceListenerIdle()
                    return
                case .recoverBridge:
                    self.bridgeAliveCache = false
                    let recovering = self.startBridgeRecovery(reason: "recording-start")
                    if !recovering {
                        self.menuSessionActive = false
                        self.activeSessionSuppressesStartupGreeting = false
                        self.showSessionPromptIfAllowed()
                    }
                    engine.cancelRecording()
                    self.wasRecording = false
                    return
                case .promptForSession:
                    self.bridgeAliveCache = false
                    self.menuSessionActive = false
                    self.activeSessionSuppressesStartupGreeting = false
                    self.showSessionPromptIfAllowed()
                    engine.cancelRecording()
                    self.wasRecording = false
                    return
                }
            }

            // Clear stale play requests
            if engine.playRequested {
                engine.playRequested = false
                let recognizedAt = engine.playRequestedAt
                let detectedAt = engine.playDetectedAt
                engine.playRequestedAt = nil
                engine.playDetectedAt = nil
                self.stateMachine.setPlaybackRequested()
                if let detectedAt {
                    engine.recordPlaybackAcknowledgement(
                        detectedAt: detectedAt,
                        acknowledgedAt: Date()
                    )
                }
                if let recognizedAt {
                    let acknowledgementMs = (CACurrentMediaTime() - recognizedAt) * 1_000
                    NSLog("[AppState] Option playback acknowledged in %.1fms", acknowledgementMs)
                }
                let playbackActive: Bool
                switch self.stateMachine.state {
                case .preparing, .speaking:
                    playbackActive = true
                default:
                    playbackActive = false
                }
                if let command = self.onboarding.noteTutorialPlaybackRequested(
                    playbackActive: playbackActive
                ) {
                    switch command {
                    case .play:
                        self.processManager.tutorialTTSCommand("play")
                    case .replay:
                        self.processManager.tutorialTTSCommand("replay")
                    }
                }
            }

            if engine.wasCancelled {
                engine.wasCancelled = false
                self.stateMachine.setCancelled()
                self.onboarding.noteTutorialCancelRequested()
            } else {
                self.stateMachine.updateSTT(isRecording: nowRecording, partial: engine.partialTranscription)
            }
            self.wasRecording = nowRecording
            self.syncNotchActivitySurface()
        }
    }

    static func continuityRecoveryDecision(
        for request: ContinuityRecoveryRequest,
        boundary: ContinuityRecoveryBoundary,
        nowMonotonic: Double,
        nowEpoch: Double
    ) -> ContinuityRecoveryDecision {
        typealias Contract = (
            action: ContinuityRecoveryComponentAction,
            incidentPhases: Set<String>,
            commandPhases: Set<String>,
            liveness: Set<String>,
            postcondition: String,
            maxAttempts: Int,
            disruptive: Bool
        )
        let contract: Contract? = switch (request.capability, request.component) {
        case ("reinitialize_speech_capture", "speech_capture"):
            (
                .restartSpeechCapture, ["capture"], ["before_command"],
                ["unhealthy", "confirmed_dead"], "capture_progress_observed", 2, false
            )
        case ("reinitialize_transcription_delivery", "transcription"):
            (
                .restartTranscriptionDelivery, ["transcription", "delivery"],
                ["before_command", "captured", "undelivered"],
                ["unhealthy", "confirmed_dead"], "transcription_completed", 2, false
            )
        case ("restart_bridge", "bridge"):
            (
                .recoverBridge, ["delivery", "component_liveness"], ["none", "undelivered"],
                ["unhealthy", "confirmed_dead"], "bridge_process_alive", 2, true
            )
        case ("reconnect_ipc", "bridge"):
            (
                .recoverBridge, ["delivery", "component_liveness"], ["none", "undelivered"],
                ["unhealthy", "confirmed_dead"], "ipc_connection_restored", 2, true
            )
        case ("restart_daemon", "daemon"):
            (
                .restartDaemon, ["component_liveness"], ["none"],
                ["confirmed_dead"], "daemon_process_alive", 1, true
            )
        case ("reconnect_ipc", "daemon"):
            (
                .restartDaemon, ["component_liveness"], ["none"],
                ["unhealthy", "confirmed_dead"], "ipc_connection_restored", 2, true
            )
        case ("release_dead_ownership", "foreground_provider"):
            (
                .releaseForegroundProviderOwnership, ["provider_turn"], ["in_flight"],
                ["stalled", "confirmed_dead"], "dead_ownership_released", 1, true
            )
        case ("launch_foreground_provider", "foreground_provider"):
            (
                .launchForegroundProvider, ["provider_turn"], ["in_flight"],
                ["stalled", "confirmed_dead"], "provider_process_alive", 1, true
            )
        case ("launch_foreground_provider", "session"):
            (
                .launchForegroundProvider, ["session_liveness"], ["none"],
                ["confirmed_dead"], "provider_process_alive", 1, true
            )
        default:
            nil
        }

        guard let contract else { return .reject("unsupported_component_action") }
        guard request.validationToken == "live_continuity_watch",
              request.exactTargetOwned,
              request.incidentActive,
              request.generationMatches,
              request.commandPhaseMatches
        else { return .reject("stale_recovery_context") }
        guard request.sessionID == boundary.currentSessionID,
              request.recoveryGeneration == boundary.currentRecoveryGeneration
        else { return .reject("stale_recovery_generation") }
        guard contract.incidentPhases.contains(request.incidentPhase),
              contract.commandPhases.contains(request.commandPhase),
              contract.liveness.contains(request.liveness),
              request.expectedPostcondition == contract.postcondition,
              request.attempt <= contract.maxAttempts
        else { return .reject("recovery_contract_mismatch") }
        guard request.idempotencyState == "new",
              !boundary.idempotencyAlreadyApplied
        else { return .reject("idempotency_already_applied") }
        guard request.idempotencyKey == ContinuityRecoveryRequest.idempotencyKey(
                  incidentID: request.incidentID,
                  recoveryGeneration: request.recoveryGeneration,
                  capability: request.capability,
                  component: request.component,
                  sessionID: request.sessionID,
                  commandID: request.commandID
              ) else { return .reject("idempotency_context_mismatch") }
        guard request.cooldownRemaining == 0, !boundary.cooldownActive else {
            return .reject("component_cooldown_active")
        }
        guard request.provider == "none" || request.provider == boundary.provider else {
            return .reject("provider_target_mismatch")
        }
        guard nowMonotonic < request.deadline,
              request.incidentObservedAt <= nowEpoch + 5,
              nowEpoch - request.incidentObservedAt <= 300
        else { return .reject("stale_recovery_deadline") }
        if let commandID = request.commandID {
            guard boundary.currentCommandID == commandID else {
                return .reject("unrelated_command_target")
            }
        }
        let stalledProviderRecovery = request.component == "foreground_provider"
            && request.liveness == "stalled"
            && boundary.stalledProviderTargetOwned
        if request.component == "foreground_provider",
           request.liveness == "stalled",
           !stalledProviderRecovery {
            return .reject("stalled_provider_ownership_not_proven")
        }
        if contract.disruptive && boundary.liveWorkActive && !stalledProviderRecovery {
            return .reject("live_work_active")
        }
        if contract.action == .releaseForegroundProviderOwnership,
           boundary.providerProcessRunning,
           !stalledProviderRecovery {
            return .reject("live_provider_must_not_be_killed")
        }
        if contract.action == .launchForegroundProvider,
           boundary.providerProcessRunning,
           !stalledProviderRecovery {
            return .reject("live_session_must_not_be_replaced")
        }
        return .apply(contract.action)
    }

    private func performContinuityRecoveryAction(
        _ request: ContinuityRecoveryRequest
    ) -> ContinuityRecoveryResponse {
        let now = CACurrentMediaTime()
        let repositoryPath = activeSessionLaunchConfig?.general.working_directory
            ?? config.general.working_directory
        let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
            repositoryPath: repositoryPath
        )
        guard let currentGeneration = continuityRecoveryGenerationBySession[sessionID]
        else { return .failed("recovery_generation_unavailable") }
        let nativeCurrentCommandID = ProcessManager.currentRelayCommandID()
        let currentCommandID = nativeCurrentCommandID.map {
            ContinuityRecoveryRequest.opaqueIdentifier(kind: "command", nativeValue: $0)
        }
        let pendingDelivery = processManager.pendingVoiceCommandDeliveryState()
        let providerTurnActive = ProcessManager.foregroundProviderTurnActive()
        let liveWorkActive = providerTurnActive
            || pendingDelivery == .waiting
            || pendingDelivery == .claimed
        let cooldownKey = continuityRecoveryCooldownKey(request)
        let providerTargetKey = continuityProviderTargetKey(request)
        let stalledProviderTargetOwned = request.component == "foreground_provider"
            && request.liveness == "stalled"
            && (
                releasedContinuityProviderTargets.contains(providerTargetKey)
                || (
                    voiceSession.isEmbeddedProcessRunning
                    && ProcessManager.stalledForegroundProviderTurnOwned(
                        commandID: request.commandID,
                        provider: request.provider,
                        recoveryGeneration: request.recoveryGeneration,
                        incidentObservedAt: request.incidentObservedAt
                    )
                )
            )
        let boundary = ContinuityRecoveryBoundary(
            currentSessionID: sessionID,
            currentRecoveryGeneration: currentGeneration,
            currentCommandID: currentCommandID,
            provider: activeSessionLaunchConfig?.general.provider.rawValue
                ?? config.general.provider.rawValue,
            liveWorkActive: liveWorkActive,
            providerProcessRunning: voiceSession.phase.isActive
                || voiceSession.isEmbeddedProcessRunning,
            stalledProviderTargetOwned: stalledProviderTargetOwned,
            bridgeAlive: processManager.bridgeAlive(),
            idempotencyAlreadyApplied: appliedContinuityRecoveryKeys.contains(
                request.idempotencyKey
            ),
            cooldownActive: now < (continuityRecoveryCooldowns[cooldownKey] ?? 0)
        )
        let decision = Self.continuityRecoveryDecision(
            for: request,
            boundary: boundary,
            nowMonotonic: now,
            nowEpoch: Date().timeIntervalSince1970
        )
        guard case let .apply(action) = decision else {
            if case let .reject(code) = decision { return .failed(code) }
            return .failed("component_action_unavailable")
        }

        continuityRecoveryGenerationBySession[sessionID] = request.recoveryGeneration
        let applied: Bool
        switch action {
        case .restartSpeechCapture, .restartTranscriptionDelivery:
            guard isRunning, sttEngine?.isRecording != true else {
                return .failed("live_capture_must_not_be_interrupted")
            }
            restartSTT(reason: "continuity-\(request.capability)")
            applied = true
        case .recoverBridge:
            guard !ProcessManager.foregroundProviderTurnActive() else {
                return .failed("live_work_active")
            }
            applied = startBridgeRecovery(reason: "continuity-\(request.capability)")
        case .restartDaemon:
            Task { [refreshBundledOrchestratorDaemon] in
                _ = await refreshBundledOrchestratorDaemon()
            }
            applied = true
        case .releaseForegroundProviderOwnership:
            guard activeSessionLaunchConfig != nil else {
                return .failed("provider_session_unavailable")
            }
            if request.liveness == "stalled" {
                guard stalledProviderTargetOwned else {
                    return .failed("stalled_provider_ownership_not_proven")
                }
            } else {
                guard !voiceSession.phase.isActive,
                      !ProcessManager.foregroundProviderTurnActive()
                else { return .failed("live_provider_must_not_be_killed") }
            }
            voiceSession.end()
            releasedContinuityProviderTargets.insert(providerTargetKey)
            applied = true
        case .launchForegroundProvider:
            let delivery = processManager.pendingVoiceCommandDeliveryState()
            guard let launch = activeSessionLaunchConfig else {
                return .failed("provider_session_unavailable")
            }
            if request.liveness == "stalled" {
                guard stalledProviderTargetOwned else {
                    return .failed("stalled_provider_ownership_not_proven")
                }
                if voiceSession.phase.isActive || voiceSession.isEmbeddedProcessRunning {
                    voiceSession.end()
                    releasedContinuityProviderTargets.insert(providerTargetKey)
                }
            } else {
                guard !voiceSession.phase.isActive,
                      !voiceSession.isEmbeddedProcessRunning,
                      !ProcessManager.foregroundProviderTurnActive()
                else { return .failed("live_session_must_not_be_replaced") }
            }
            guard (delivery != .waiting && delivery != .claimed)
                    || stalledProviderTargetOwned else {
                return .failed("live_work_active")
            }
            guard let nativeCurrentCommandID,
                  let commandID = request.commandID,
                  ContinuityRecoveryRequest.opaqueIdentifier(
                    kind: "command",
                    nativeValue: nativeCurrentCommandID
                  ) == commandID else {
                return .failed("unrelated_command_target")
            }
            guard let previousProviderSessionID = ProcessManager.currentProviderSessionID(),
                  !previousProviderSessionID.isEmpty else {
                return .failed("provider_session_unavailable")
            }
            let preservesVoiceBridge = processManager.bridgeAlive()
            pendingContinuityProviderReady = ContinuityProviderReadyContext(
                nativeCommandID: nativeCurrentCommandID,
                commandID: commandID,
                provider: request.provider,
                recoveryGeneration: request.recoveryGeneration,
                previousProviderSessionID: previousProviderSessionID,
                providerSessionID: nil,
                appSessionID: nil,
                foregroundGateHandle: nil
            )
            applied = newSession(
                workingDirectory: launch.general.working_directory,
                suppressesStartupGreeting: true,
                recoveryGeneration: request.recoveryGeneration,
                preservesVoiceBridge: preservesVoiceBridge
            )
            if applied {
                releasedContinuityProviderTargets.remove(providerTargetKey)
            } else {
                pendingContinuityProviderReady = nil
            }
        }
        guard applied else { return .failed("component_action_unavailable") }
        appliedContinuityRecoveryKeys.insert(request.idempotencyKey)
        continuityRecoveryCooldowns[cooldownKey] = now + continuityRecoveryCooldown(request)
        return .applied()
    }

    private func embeddedTerminalDidBecomeReady(contextID: String) {
        if let readyContext = assistantSessionStore.document.bindings[contextID]?.context {
            do { try assistantSessionStore.mark(.running, context: readyContext) }
            catch { contextSwitchMessage = "Conversation could not be saved: \(error.localizedDescription)" }
        }
        reconcileContextContinuation()
        guard contextID == voiceContextID, let context = pendingContinuityProviderReady else { return }
        pendingContinuityProviderReady = nil
        guard let launch = activeSessionLaunchConfig else { return }
        let sessionID = ContinuityRecoveryRequest.projectSessionIdentifier(
            repositoryPath: launch.general.working_directory
        )
        guard let control = context.controlMessage(
            currentClaimIdentity: ProcessManager.currentRelayClaimIdentity(),
            currentProvider: launch.general.provider.rawValue,
            currentRecoveryGeneration: continuityRecoveryGenerationBySession[sessionID],
            currentProviderSessionID: ProcessManager.currentProviderSessionID()
        ) else { return }
        _ = SocketClient.bridgeSend(control)
    }

    private func continuityRecoveryCooldownKey(_ request: ContinuityRecoveryRequest) -> String {
        "\(request.sessionID)|\(request.component)|\(request.capability)"
    }

    private func continuityProviderTargetKey(_ request: ContinuityRecoveryRequest) -> String {
        [
            request.incidentID,
            request.sessionID,
            request.commandID ?? "none",
            request.provider,
            request.recoveryGeneration,
        ].joined(separator: "|")
    }

    private func continuityRecoveryCooldown(_ request: ContinuityRecoveryRequest) -> Double {
        switch request.capability {
        case "restart_daemon", "launch_foreground_provider": 15
        default: 5
        }
    }

    private func setProgramBoardLoadingState(_ loadingState: ProgramBoardLoadingState) {
        guard programBoardLoadingState != loadingState else { return }
        programBoardLoadingState = loadingState
        syncNotchActivitySurface()
    }

    private func resetObservedTutorialSTTSerials() {
        observedRecordingStartedSerial = 0
        observedSpeechDetectedSerial = 0
        observedDeliveredTranscriptSerial = 0
        observedTutorialTranscriptSerial = 0
        observedCaptureOwnerRequestedSerial = 0
    }

    private func publishOnboardingTutorialSTTEvents(from engine: STTEngine,
                                                   includeRecordingStart: Bool) {
        if includeRecordingStart && engine.recordingStartedSerial > observedRecordingStartedSerial {
            observedRecordingStartedSerial = engine.recordingStartedSerial
            onboarding.noteTutorialRecordingStarted()
        }
        if engine.speechDetectedSerial > observedSpeechDetectedSerial {
            observedSpeechDetectedSerial = engine.speechDetectedSerial
            onboarding.noteTutorialSpeechDetected()
        }
        if engine.deliveredTranscriptSerial > observedDeliveredTranscriptSerial {
            observedDeliveredTranscriptSerial = engine.deliveredTranscriptSerial
            _ = onboarding.noteTutorialRecordingSent()
        }
        if engine.tutorialTranscriptSerial > observedTutorialTranscriptSerial {
            observedTutorialTranscriptSerial = engine.tutorialTranscriptSerial
            if let reply = onboarding.noteTutorialRecordingSent() {
                if processManager.queueTutorialTTS(reply) {
                    onboarding.noteTutorialResponseReady(reply)
                    stateMachine.handleServiceEvent(
                        source: "tts",
                        newState: "message_waiting",
                        text: reply
                    )
                }
            }
        }
    }

    static func shouldHandleServiceEvent(
        source: String,
        tutorial: Bool,
        tutorialActive: Bool
    ) -> Bool {
        guard source == "tts" else { return true }
        return tutorial ? tutorialActive : !tutorialActive
    }

    private func handleOnboardingTutorialServiceEvent(
        source: String,
        state: String,
        text: String?,
        tutorial: Bool
    ) {
        guard source == "tts", tutorial else { return }
        switch state {
        case "message_waiting":
            onboarding.noteTutorialResponseReady(text)
        case "preparing", "speaking":
            onboarding.noteTutorialPlaybackStarted()
        case "idle":
            if let response = onboarding.noteTutorialPlaybackFinished() {
                stateMachine.handleServiceEvent(
                    source: "tts",
                    newState: "message_waiting",
                    text: response
                )
            }
        default:
            break
        }
    }

    private func suspendWorkspaceForExternalWindow() {
        programBoardOverlay.suspendForExternalWindow()
    }

    private func suspendWorkspaceForProjectPicker(_ completion: @escaping () -> Void) {
        programBoardOverlay.suspendForExternalWindowAnimated(completion: completion)
    }

    private func stopOverlay() {
        cancelPermissionSetup()

        programStatusTask?.cancel()
        programStatusTask = nil

        sttPollTimer?.invalidate()
        sttPollTimer = nil
        stopNotchActivityPolling()

        overlayController?.stop()
        overlayController = nil

        perimeterOverlay?.stop()
        perimeterOverlay = nil

        Task { await eventBus?.stop() }
        eventBus = nil

        Task { await actionsBus?.stop() }
        actionsBus = nil

        stateMachine.reset()
        syncNotchStatusSurface()
    }

}

/// Forwards the remote gate to whichever engine is current, so a restarted
/// engine does not strand the session.
private final class AppStateRemoteGate: RemoteMicrophoneGate {
    private weak var owner: AppState?
    init(owner: AppState) { self.owner = owner }
    func suspendForRemoteDevice() { owner?.sttEngine?.suspendForRemoteDevice() }
    func resumeAfterRemoteDevice(preservingGesture: Bool) {
        owner?.sttEngine?.resumeAfterRemoteDevice(preservingGesture: preservingGesture)
    }
}
