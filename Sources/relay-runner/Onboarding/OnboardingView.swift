import AppKit
import SwiftUI

/// First-launch onboarding flow. Walks through agent choice, workspace folder, microphone
/// access, optional Input Monitoring, optional parent-app permission guidance,
/// local Python setup, and agent sign-in.
struct OnboardingView: View {
    static let workspaceFolderTitle = "Workspace folder"
    static let workspaceFolderHelpText = "New voice sessions start in this folder. Program Manager discovers child git repositories when this is a workspace."

    @Bindable var permissions: PermissionsManager
    let simplified: Bool
    /// Optional setup-progress string (e.g. "Loading speech model…"). When
    /// non-nil on the Ready step, shown in place of "all set" so the user
    /// knows the app isn't fully ready yet.
    let setupStatus: () -> String?
    /// Currently-configured workspace folder at the moment the window
    /// opens. Used to preload the Ready-step path picker so a returning
    /// user sees their last choice.
    let initialWorkingDirectory: String
    /// Configured primary coding agent at the moment the window opens.
    let initialAgentProvider: GeneralConfig.AgentProvider
    let initialModel: String
    /// When true in the simplified upgrade flow, ask for the provider choice
    /// even if no other setup is missing.
    let requiresAgentChoice: Bool
    let requiresParentPermissionGuidance: Bool
    /// Persists the selected primary coding agent back to AppConfig.
    let onSetAgentProvider: (GeneralConfig.AgentProvider) -> Void
    let onSetModel: (String) -> Void
    /// Persists the user's workspace-folder pick to AppConfig. Called
    /// from the Ready step's Done button.
    let onSetWorkingDirectory: (String) -> Void
    /// Starts a voice session immediately. Wired to `AppState.newSession`.
    /// Used by the Start Session CTA on the Ready step so the user can
    /// kick off a session without going back to the menu bar.
    let onStartSession: () -> Void
    let onFinish: () -> Void

    @State private var step: Step
    /// Drives the Python venv bootstrap. Held at view scope so the
    /// provider-choice CTA can start the guided setup run, and the
    /// pythonSetup step can surface live progress.
    @State private var venvInstaller = VenvInstaller()
    /// Cached "is the configured agent signed in" state. Polled by a
    /// 1-second timer while on the agentLogin step so we can auto-advance
    /// the moment the provider's local auth marker appears.
    @State private var agentSignedIn: Bool
    /// Working directory the user picks on the Ready step. Initialized
    /// from `initialWorkingDirectory` so a returning user sees their
    /// previous choice; an empty string means "use the home folder."
    @State private var workingDirectory: String
    @State private var selectedAgentProvider: GeneralConfig.AgentProvider
    @State private var selectedModel: String
    /// True once the user has actively chosen a workspace folder on
    /// this opening of the onboarding window — by clicking Browse… or
    /// Use Home Folder. The Done button stays disabled until then so we
    /// can guarantee an explicit pick rather than silently inheriting
    /// whatever was already in config.
    @State private var hasConfirmedWorkingDirectory: Bool = false
    /// True when the user has walked through the parent-app permission
    /// guidance for this setup run. macOS does not let Relay Runner verify
    /// another app's TCC grants here; the session-time parent wizard still
    /// reappears if Relay Actions or Relay Vision report a missing grant.
    @State private var parentPermissionsReviewed: Bool = false
    /// Tracks permission panes opened automatically in this view lifetime,
    /// so resuming the step can be helpful without repeatedly yanking focus
    /// back to System Settings every time polling updates.
    @State private var autoOpenedPermissionKinds: Set<PermissionKind> = []
    @State private var autoOpenedParentPermissionSteps: Set<OnboardingStepID> = []

    init(permissions: PermissionsManager,
         simplified: Bool,
         setupStatus: @escaping () -> String? = { nil },
         initialWorkingDirectory: String = "",
         initialAgentProvider: GeneralConfig.AgentProvider = .codex,
         initialModel: String = GeneralConfig.defaultModel,
         requiresAgentChoice: Bool = false,
         requiresParentPermissionGuidance: Bool = false,
         resumeState: OnboardingResumeState.Snapshot? = nil,
         onSetAgentProvider: @escaping (GeneralConfig.AgentProvider) -> Void = { _ in },
         onSetModel: @escaping (String) -> Void = { _ in },
         onSetWorkingDirectory: @escaping (String) -> Void = { _ in },
         onStartSession: @escaping () -> Void = {},
         onFinish: @escaping () -> Void) {
        self.permissions = permissions
        self.simplified = simplified
        self.setupStatus = setupStatus
        self.initialWorkingDirectory = initialWorkingDirectory
        self.initialAgentProvider = initialAgentProvider
        self.initialModel = initialModel
        self.requiresAgentChoice = requiresAgentChoice
        self.requiresParentPermissionGuidance = requiresParentPermissionGuidance
        self.onSetAgentProvider = onSetAgentProvider
        self.onSetModel = onSetModel
        self.onSetWorkingDirectory = onSetWorkingDirectory
        self.onStartSession = onStartSession
        self.onFinish = onFinish
        let startingProvider = resumeState?.provider ?? initialAgentProvider
        let startingModel = GeneralConfig.isModel(initialModel, validFor: startingProvider)
            ? initialModel
            : GeneralConfig.defaultModel
        let startingParentReviewed = resumeState?.parentPermissionsReviewed ?? false
        // Simplified flow (re-prompt after initial onboarding): jump to the
        // first missing setup item. Full flow starts at the welcome screen.
        let initial = Self.initialStep(
            simplified: simplified,
            resumeStep: resumeState?.step,
            requiresAgentChoice: requiresAgentChoice,
            requiresParentPermissionGuidance: requiresParentPermissionGuidance,
            parentPermissionsReviewed: startingParentReviewed,
            permissionStatus: { permissions.status(for: $0) },
            venvInstalled: VenvInstaller.alreadyInstalled,
            agentSignedIn: AgentAuth.isAuthenticated(for: startingProvider)
        )
        _step = State(initialValue: initial)
        _workingDirectory = State(initialValue: initialWorkingDirectory)
        _selectedAgentProvider = State(initialValue: startingProvider)
        _selectedModel = State(initialValue: startingModel)
        _agentSignedIn = State(initialValue: AgentAuth.isAuthenticated(for: startingProvider))
        _parentPermissionsReviewed = State(initialValue: startingParentReviewed)
    }

    enum Step: Int, CaseIterable {
        case welcome
        case agentChoice
        case microphone
        case inputMonitoring
        case parentAccessibility
        case parentScreenRecording
        case pythonSetup
        case agentLogin
        case ready

        var kind: PermissionKind? {
            switch self {
            case .microphone:      return .microphone
            case .inputMonitoring: return .inputMonitoring
            default:               return nil
            }
        }

        var isParentPermissionStep: Bool {
            self == .parentAccessibility || self == .parentScreenRecording
        }

        var resumeID: OnboardingStepID {
            switch self {
            case .welcome:           return .welcome
            case .agentChoice:       return .agentChoice
            case .microphone:        return .microphone
            case .inputMonitoring:   return .inputMonitoring
            case .parentAccessibility: return .parentAccessibility
            case .parentScreenRecording: return .parentScreenRecording
            case .pythonSetup:       return .pythonSetup
            case .agentLogin:        return .agentLogin
            case .ready:             return .ready
            }
        }

        init?(resumeID: OnboardingStepID) {
            switch resumeID {
            case .welcome:           self = .welcome
            case .agentChoice:       self = .agentChoice
            case .microphone:        self = .microphone
            case .inputMonitoring:   self = .inputMonitoring
            case .parentAccessibility, .parentPermissions:
                self = .parentAccessibility
            case .parentScreenRecording:
                self = .parentScreenRecording
            case .pythonSetup:       self = .pythonSetup
            case .agentLogin:        self = .agentLogin
            case .ready:             self = .ready
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 680)
        .onAppear {
            persistResume()
            // Full first-run onboarding starts setup from the provider-choice
            // CTA. Focused re-prompt flows may open directly on a later step,
            // so start the automatable setup work there without another user
            // decision.
            if simplified && step != .agentChoice {
                venvInstaller.install()
            }
            advancePastGrantedPermissionIfNeeded()
            openPermissionPaneAutomaticallyIfNeeded()
        }
        .onChange(of: step) { _, new in
            persistResume()
            if new == .pythonSetup {
                venvInstaller.install()
            }
            advancePastGrantedPermissionIfNeeded()
            openPermissionPaneAutomaticallyIfNeeded()
        }
        .onChange(of: selectedAgentProvider) { _, _ in
            persistResume()
        }
        .onChange(of: selectedModel) { _, new in
            onSetModel(new)
            persistResume()
        }
        .onChange(of: parentPermissionsReviewed) { _, _ in
            persistResume()
        }
        .onChange(of: permissions.microphone) { _, new in
            autoAdvance(for: .microphone, status: new)
        }
        .onChange(of: permissions.inputMonitoring) { _, new in
            autoAdvance(for: .inputMonitoring, status: new)
        }
        .onChange(of: venvInstaller.status) { _, new in
            // Auto-advance off pythonSetup as soon as the bootstrap
            // succeeds so the user doesn't have to click through.
            if step == .pythonSetup, case .succeeded = new {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { advance() }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Poll only while we're on the agentLogin step — the
            // local auth check is cheap, but there's no reason to
            // run it forever. When the marker appears, mirror the
            // permission auto-advance pattern.
            guard step == .agentLogin else { return }
            let now = AgentAuth.isAuthenticated(for: selectedAgentProvider)
            guard now != agentSignedIn else { return }
            agentSignedIn = now
            if now {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { advance() }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.title2).bold()
            Spacer()
            if let progress = progressLabel {
                Text(progress)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 16)
        .padding(.horizontal, 24)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:          welcomeView
        case .agentChoice:      agentChoiceView
        case .microphone:       permissionView(for: .microphone)
        case .inputMonitoring:  permissionView(for: .inputMonitoring)
        case .parentAccessibility: parentPermissionStepView(for: .accessibility)
        case .parentScreenRecording: parentPermissionStepView(for: .screenRecording)
        case .pythonSetup:      pythonSetupView
        case .agentLogin:       agentLoginView
        case .ready:            readyView
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .ready && step != .agentChoice {
                Button("Skip") { advance() }
                    .buttonStyle(.link)
            }
            Spacer()
            primaryButton
        }
        .padding(.top, 16)
        .padding(.bottom, 32)
        .padding(.horizontal, 28)
    }

    // MARK: - Step bodies

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let's get Relay Runner set up.")
                .font(.title3)
            Text("First choose the coding agent, model, and workspace folder Relay Runner should use. Then we'll handle the small amount of setup needed for voice.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentChoiceView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which coding agent should Relay Runner start with?")
                .font(.title3).bold()
            Text("Start Session will open this agent and model by default. You can switch later in Settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                agentChoiceRow(
                    provider: .codex,
                    title: "Codex",
                    detail: "Use OpenAI Codex as the default voice-driven coding session."
                )
                agentChoiceRow(
                    provider: .claude,
                    title: "Claude",
                    detail: "Use Claude Code as the default voice-driven coding session."
                )
            }

            modelPicker
            workingDirectoryPicker
            setupPlanView

            Text("macOS privacy permissions cannot be granted silently. The setup run opens the right prompt or Settings pane for each manual step, polls for Relay Runner permission changes, and continues when macOS reports the grant.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var setupPlanView: some View {
        let plan = GuidedSetupPlan(provider: selectedAgentProvider)
        return VStack(alignment: .leading, spacing: 8) {
            Text("One guided setup run will:")
                .font(.callout).bold()
            ForEach(plan.items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private var modelPicker: some View {
        HStack {
            Text("Model")
                .font(.callout).bold()
            Spacer()
            Picker("Model", selection: $selectedModel) {
                ForEach(GeneralConfig.modelOptions(for: selectedAgentProvider)) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(width: 180)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private func agentChoiceRow(provider: GeneralConfig.AgentProvider,
                                title: String,
                                detail: String) -> some View {
        Button {
            selectAgentProvider(provider)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedAgentProvider == provider ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedAgentProvider == provider ? Color.accentColor : Color.secondary)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selectedAgentProvider == provider
                            ? Color.accentColor.opacity(0.55)
                            : Color.secondary.opacity(0.25))
            )
        }
        .buttonStyle(.plain)
    }

    private func selectAgentProvider(_ provider: GeneralConfig.AgentProvider) {
        selectedAgentProvider = provider
        if !GeneralConfig.isModel(selectedModel, validFor: provider) {
            selectedModel = GeneralConfig.defaultModel
        }
        agentSignedIn = AgentAuth.isAuthenticated(for: provider)
        onSetAgentProvider(provider)
        onSetModel(selectedModel)
    }

    private func permissionView(for kind: PermissionKind) -> some View {
        let status = permissions.status(for: kind)
        let restricted = permissions.likelyRestricted.contains(kind)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                statusBadge(for: status)
                Text(permissionTitle(for: kind))
                    .font(.title3).bold()
            }
            Text(permissionExplanation(for: kind))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The instruction box explains "find me in the list and toggle
            // me on". Skip it for fresh microphone (.notDetermined) where
            // the system prompt handles the grant directly — but show it
            // for .denied/.restricted, where the only path is Settings.
            if kind != .microphone || status == .denied || status == .restricted {
                Text(permissionInstruction(for: kind, status: status))
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            }
            if kind == .inputMonitoring {
                PermissionAppDragGuide(
                    title: "Drag Relay Runner into the list",
                    settingsPane: "Input Monitoring",
                    targets: [Self.relayRunnerAppTarget]
                )
            }
            if restricted {
                mdmRestrictionBox(for: kind)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Yellow warning box shown when the MDM-restriction heuristic fires —
    /// communicates what the user should do next and what still works.
    private func mdmRestrictionBox(for kind: PermissionKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac may be blocking \(kind.displayName).")
                    .font(.callout).bold()
                Text(mdmBody(for: kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.35))
        )
    }

    private func mdmBody(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "Your organisation's security policy appears to be blocking microphone access. You'll need your IT team to allow Relay Runner — voice input isn't available until they do."
        case .accessibility:
            return "Your organisation's security policy appears to be blocking Accessibility access. You'll need your IT team to allow Relay Runner. Voice input still works via the menu-bar Record button — only auto-pause of media during recording is affected."
        case .inputMonitoring:
            return "Your organisation's security policy appears to be blocking keyboard capture. You'll need your IT team to allow Relay Runner. Voice still works via the menu-bar Record button or always-on mode in Settings — only the global trigger key is affected."
        case .screenRecording:
            return "Your organisation's security policy appears to be blocking Screen Recording. You'll need your IT team to allow Relay Runner. Only the optional Relay Actions voice tools (UAT, dashboard automation) are affected — voice transcription and speech still work."
        }
    }

    private func parentPermissionStepView(for kind: PermissionKind) -> some View {
        let title = parentPermissionStepTitle(for: kind)
        let actionTitle = "Open \(title) Settings"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: parentPermissionStepIcon(for: kind))
                    .foregroundStyle(.tint)
                    .font(.title3)
                Text(title)
                    .font(.title3).bold()
            }

            Text(parentPermissionStepExplanation(for: kind))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(actionTitle) {
                openParentPermissionSettings(for: kind)
            }

            PermissionAppDragGuide(
                title: "Drag \(selectedParentTargetNameList) into \(title)",
                settingsPane: title,
                targets: selectedParentAppTargets,
                highlightTargets: true
            )

            parentPermissionVerificationNote(for: kind)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parentPermissionVerificationNote(for kind: PermissionKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .screenRecording ? "arrow.clockwise.circle.fill" : "checkmark.seal")
                .foregroundStyle(kind == .screenRecording ? .orange : .secondary)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(parentPermissionVerificationTitle(for: kind))
                    .font(.callout).bold()
                Text(parentPermissionVerificationDetail(for: kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private func parentPermissionStepTitle(for kind: PermissionKind) -> String {
        kind == .screenRecording ? "Screen Recording" : "Accessibility"
    }

    private func parentPermissionStepIcon(for kind: PermissionKind) -> String {
        kind == .screenRecording ? "rectangle.dashed" : "hand.tap"
    }

    private func parentPermissionStepExplanation(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            return "For clicks, typing, and scrolling, macOS grants control to the app running \(selectedAgentProvider.displayName). Turn on \(selectedParentTargetNameList) in Accessibility."
        case .screenRecording:
            return "For screenshots and visual grounding, macOS grants screen access to the app running \(selectedAgentProvider.displayName). Turn on \(selectedParentTargetNameList) in Screen Recording."
        default:
            return ""
        }
    }

    private func parentPermissionVerificationTitle(for kind: PermissionKind) -> String {
        kind == .screenRecording ? "Restart after granting" : "Verified when tools start"
    }

    private func parentPermissionVerificationDetail(for kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            return "macOS only exposes this check to the parent process. Relay Actions verifies Accessibility inside the next \(selectedAgentProvider.displayName) session before it clicks, types, or scrolls."
        case .screenRecording:
            return "macOS applies Screen Recording to new processes only. After turning it on, quit and reopen the parent app; Relay Vision verifies it inside the next \(selectedAgentProvider.displayName) session."
        default:
            return ""
        }
    }

    private var selectedParentTargetList: String {
        ParentPermissionGuidance.targetList(for: selectedAgentProvider)
    }

    private var selectedParentTargetNameList: String {
        ParentPermissionGuidance.targetNameList(for: selectedAgentProvider)
    }

    private var selectedParentAppTargets: [PermissionAppTarget] {
        ParentPermissionGuidance.appTargets(for: selectedAgentProvider)
    }

    private var pythonSetupView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                pythonStatusBadge
                Text("Python environment")
                    .font(.title3).bold()
            }
            Text("Relay Runner uses a small Python helper for text-to-speech and the voice bridge. Setting up the environment takes about 30 seconds and only happens once per install.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            pythonStatusDetail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pythonStatusBadge: some View {
        switch venvInstaller.status {
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
        case .idle, .running:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var pythonStatusDetail: some View {
        switch venvInstaller.status {
        case .idle:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .running(let message, let progress):
            VStack(alignment: .leading, spacing: 8) {
                // Determinate bar once relay-bridge has emitted at least
                // one phase marker; falls back to indeterminate spinner
                // so the very first moments of "Starting setup…" still
                // signal activity. `.animation` smooths the per-package
                // ticks so the bar doesn't visibly jump.
                if let progress {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .animation(.easeOut(duration: 0.25), value: progress)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .succeeded:
            Text("Done — Python environment ready.")
                .font(.callout)
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("Setup failed.")
                    .font(.callout).bold()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can retry now, or skip this step — Relay Runner will retry on the first voice session, but voice replies won't work until it succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.35))
            )
        }
    }

    private var agentLoginView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if agentSignedIn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                Text("Sign in to your agent")
                    .font(.title3).bold()
            }
            Text("Relay Runner will start \(selectedAgentProvider.displayName) for voice sessions. Sign in once so sessions can connect without an authentication stop.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if agentSignedIn {
                Text("Signed in — you're ready to go.")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text("Click the button below. A Terminal window will open and prompt you to sign in. This window will update automatically when you're done.")
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readyView: some View {
        let status = setupStatus()
        let isLoading = status != nil
        let readiness = currentReadiness
        let voiceReady = readiness.voiceReady
        let inputMonitoringSummary = Self.inputMonitoringSummary(status: permissions.inputMonitoring)
        return VStack(spacing: 16) {
            Spacer(minLength: 4)
            if isLoading {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: readinessIcon(for: readiness.mode))
                    .font(.system(size: 44))
                    .foregroundStyle(readinessColor(for: readiness.mode))
            }
            Text(isLoading ? "Almost ready\u{2026}" : readiness.title)
                .font(.title2).bold()
            if isLoading, let status {
                Text(status)
                    .foregroundStyle(.secondary)
            } else if !voiceReady {
                Text(readiness.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                workingDirectoryPicker
                Text(readiness.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let inputMonitoringSummary {
                    inputMonitoringDeferredNotice(detail: inputMonitoringSummary)
                }
                if readiness.deferredItems.contains(where: { $0.contains("Parent-app") }) {
                    parentPermissionsDeferredNotice
                }
                Text("Two ways to start a voice session:")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    sessionMethodRow(
                        icon: "menubar.rectangle",
                        title: "From the menu bar",
                        detail: "Click the Relay Runner icon, then choose \u{201C}Start Session\u{2026}\u{201D}. A terminal opens with the configured agent already listening."
                    )
                    sessionMethodRow(
                        icon: "terminal",
                        title: "From an Agent",
                        detail: "Run Codex or Claude in any terminal and start the relay-bridge skill or command. Install Relay Skills from Settings \u{2192} General if needed."
                    )
                }
                Text("Already running Codex, Claude Code, or a terminal? Restart it to load the Relay Runner skill or command.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tap Caps Lock to start and stop recording in either mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func inputMonitoringDeferredNotice(detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "keyboard.badge.eye")
                .foregroundStyle(.orange)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Input Monitoring deferred")
                    .font(.callout).bold()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Open Settings") {
                requestInputMonitoringPermission()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.35))
        )
    }

    private var parentPermissionsDeferredNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(.orange)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Parent app permissions deferred")
                    .font(.callout).bold()
                Text("Voice sessions can start. Relay Actions and Relay Vision may still need Accessibility and Screen Recording for \(selectedParentTargetList); Relay Runner will surface that guide again after the provider session starts if the MCP tools report a missing grant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.35))
        )
    }

    /// Path picker used by first-run setup and the Ready step. The user must actively click
    /// Browse… or Use Home Folder before the Done button enables —
    /// the requirement is that every session start has a deliberate
    /// workspace choice, not silently inherit whatever was last in
    /// config. An empty `workingDirectory` string maps to "home" and
    /// is what `ProcessManager` already treats as the default.
    private var workingDirectoryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.workspaceFolderTitle)
                    .font(.callout).bold()
                if !hasConfirmedWorkingDirectory {
                    Text("(required)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(Self.workspaceFolderHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(workingDirectoryDisplay)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(hasConfirmedWorkingDirectory ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(hasConfirmedWorkingDirectory
                            ? Color.secondary.opacity(0.25)
                            : Color.orange.opacity(0.45))
            )
            HStack(spacing: 8) {
                Button("Choose Workspace\u{2026}") { pickWorkingDirectory() }
                Button("Use Home Folder") { useHomeWorkingDirectory() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Human-readable label for the path field. "(none chosen)" when
    /// the user hasn't actively confirmed yet — the orange copy that
    /// goes with it is what tells them they need to click one of the
    /// buttons below.
    private var workingDirectoryDisplay: String {
        if !hasConfirmedWorkingDirectory {
            return "(none chosen)"
        }
        if workingDirectory.isEmpty {
            return "Home folder (~)"
        }
        return workingDirectory
    }

    private func pickWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the workspace folder where Relay Runner should start sessions"
        if panel.runModal() == .OK, let url = panel.url {
            workingDirectory = url.path
            hasConfirmedWorkingDirectory = true
        }
    }

    private func useHomeWorkingDirectory() {
        // Empty string is the existing "default to home" sentinel
        // ProcessManager and config use — keep it consistent so the
        // Settings UI keeps showing the "~ (home)" placeholder rather
        // than a literal `/Users/<name>` path.
        workingDirectory = ""
        hasConfirmedWorkingDirectory = true
    }

    /// One row in the "how to start a session" summary on the Ready step.
    /// Icon + title + an explanatory line, laid out so the title aligns
    /// with the top of the icon for scannability.
    private func sessionMethodRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout).bold()
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    // MARK: - Button

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get Started") { advance() }
                .keyboardShortcut(.defaultAction)
        case .agentChoice:
            Button(GuidedSetupPlan(provider: selectedAgentProvider).primaryActionTitle) {
                beginGuidedSetup()
            }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasConfirmedWorkingDirectory)
        case .microphone:
            switch permissions.microphone {
            case .granted:
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            case .notDetermined:
                // First-ever ask: AVCaptureDevice.requestAccess shows the
                // standard system prompt.
                Button("Grant Microphone Access") {
                    permissions.requestMicrophonePrompt { _ in }
                }.keyboardShortcut(.defaultAction)
            case .denied:
                Button("Ask Again") {
                    permissions.requestMicrophonePrompt { _ in }
                }.keyboardShortcut(.defaultAction)
            case .restricted:
                Button("Open System Settings") {
                    persistResume()
                    permissions.openSettings(for: .microphone)
                }.keyboardShortcut(.defaultAction)
            }
        case .inputMonitoring:
            switch permissions.inputMonitoring {
            case .granted:
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            case .notDetermined, .denied:
                Button("Open Input Monitoring Settings") {
                    requestInputMonitoringPermission()
                }.keyboardShortcut(.defaultAction)
            case .restricted:
                Button("Open System Settings") {
                    persistResume()
                    permissions.openSettings(for: .inputMonitoring)
                }.keyboardShortcut(.defaultAction)
            }
        case .parentAccessibility:
            Button("Continue to Screen Recording") {
                advance()
            }
            .keyboardShortcut(.defaultAction)
        case .parentScreenRecording:
            Button("Continue") {
                parentPermissionsReviewed = true
                OnboardingResumeState.save(
                    step: step.resumeID,
                    provider: selectedAgentProvider,
                    parentPermissionsReviewed: true
                )
                advance()
            }
            .keyboardShortcut(.defaultAction)
        case .pythonSetup:
            switch venvInstaller.status {
            case .succeeded:
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            case .failed:
                Button("Retry") { venvInstaller.install() }.keyboardShortcut(.defaultAction)
            case .idle, .running:
                // Disabled while the install is in flight — auto-advance
                // fires on success. Footer Skip remains available.
                Button("Continue") { advance() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(true)
            }
        case .agentLogin:
            if agentSignedIn {
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Sign in") {
                    persistResume()
                    AgentAuth.openLoginInTerminal(for: selectedAgentProvider)
                }.keyboardShortcut(.defaultAction)
            }
        case .ready:
            // The picker is only shown when setup is finished and every
            // permission is granted. In that branch we offer two CTAs —
            // Dismiss (closes the window without launching anything) and
            // Start Session (saves the path and kicks off the voice
            // session immediately). The "Almost ready…" loading state
            // and the "permissions missing" warning state fall back to
            // a single Done button.
            //
            // The two CTAs are wrapped in an explicit HStack rather than
            // emitted as siblings into the @ViewBuilder. Multi-view
            // conditional branches inside @ViewBuilder occasionally
            // misrender on macOS — being explicit about the container
            // sidesteps that.
            let pickerVisible = setupStatus() == nil && currentReadiness.voiceReady
            if pickerVisible {
                HStack {
                    // Dismiss is always enabled — the user can defer
                    // their first session indefinitely. If they picked
                    // a path before dismissing, persist it so the
                    // choice doesn't go to waste.
                    Button("Dismiss") {
                        if hasConfirmedWorkingDirectory {
                            onSetWorkingDirectory(workingDirectory)
                        }
                        onFinish()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Start Session") {
                        onSetWorkingDirectory(workingDirectory)
                        onStartSession()
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasConfirmedWorkingDirectory)
                }
            } else {
                Button("Done") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Advance

    private func advance() {
        if simplified {
            // Simplified re-prompt flow: finish as soon as every remaining
            // missing required setup item has been addressed (granted or skipped).
            if let next = nextMissingStep(after: step) {
                step = next
            } else {
                onFinish()
            }
            return
        }

        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        } else {
            onFinish()
        }
    }

    private func beginGuidedSetup() {
        onSetAgentProvider(selectedAgentProvider)
        onSetModel(selectedModel)
        onSetWorkingDirectory(workingDirectory)
        agentSignedIn = AgentAuth.isAuthenticated(for: selectedAgentProvider)
        venvInstaller.install()
        advance()
    }

    private func autoAdvance(for kind: PermissionKind, status: PermissionStatus) {
        guard status == .granted, step.kind == kind else { return }
        // Small delay so the user sees the green check before the view flips
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { advance() }
    }

    /// The next step (after `from`) that still needs the user's attention —
    /// microphone/Input Monitoring if not granted, pythonSetup if the venv
    /// hasn't been bootstrapped, or agentLogin if the configured agent isn't
    /// signed in.
    /// Used by the simplified re-prompt flow to skip already-done items.
    private func nextMissingStep(after from: Step) -> Step? {
        Self.nextStepAfter(
            from,
            requiresAgentChoice: requiresAgentChoice,
            requiresParentPermissionGuidance: requiresParentPermissionGuidance,
            parentPermissionsReviewed: parentPermissionsReviewed,
            permissionStatus: { permissions.status(for: $0) },
            venvInstalled: VenvInstaller.alreadyInstalled,
            agentSignedIn: AgentAuth.isAuthenticated(for: selectedAgentProvider)
        )
    }

    static func nextStepAfter(_ from: Step,
                              requiresAgentChoice: Bool,
                              requiresParentPermissionGuidance: Bool,
                              parentPermissionsReviewed: Bool,
                              permissionStatus: (PermissionKind) -> PermissionStatus,
                              venvInstalled: Bool,
                              agentSignedIn: Bool) -> Step? {
        let remaining = Step.allCases.filter {
            $0.rawValue > from.rawValue
        }
        for candidate in remaining {
            if candidate == .agentChoice, requiresAgentChoice {
                return candidate
            }
            if candidate.isParentPermissionStep,
               (requiresAgentChoice || requiresParentPermissionGuidance),
               !parentPermissionsReviewed {
                return candidate
            }
            if let kind = candidate.kind, permissionStatus(kind) != .granted {
                return candidate
            }
            if candidate == .pythonSetup, !venvInstalled {
                return candidate
            }
            if candidate == .agentLogin, !agentSignedIn {
                return candidate
            }
        }
        // Always end on Ready (not directly via onFinish) so the user
        // sees the All Set summary and explicitly picks a working
        // directory. Without this, the simplified flow's `advance()`
        // would call onFinish() the moment all other gates pass —
        // silently skipping the Ready step the user hasn't visited yet.
        if from != .ready {
            return .ready
        }
        return nil
    }

    // MARK: - Text

    private var headerTitle: String {
        switch step {
        case .welcome:          return "Welcome to Relay Runner"
        case .agentChoice:      return "Coding Agent"
        case .microphone:       return "Microphone"
        case .inputMonitoring:  return "Input Monitoring"
        case .parentAccessibility: return "Accessibility"
        case .parentScreenRecording: return "Screen Recording"
        case .pythonSetup:      return "Python Environment"
        case .agentLogin:       return "\(selectedAgentProvider.displayName) Account"
        case .ready:            return "Setup Complete"
        }
    }

    private var progressLabel: String? {
        // Full flow always visits agent choice + microphone + optional
        // Input Monitoring + parent Accessibility + parent Screen Recording
        // + pythonSetup + agentLogin
        // (the last two briefly auto-advance when their state is already
        // ready, but they still get slots in the count). Simplified flow
        // only counts steps that actually need attention.
        Self.progressLabel(
            for: step,
            simplified: simplified,
            requiresAgentChoice: requiresAgentChoice,
            requiresParentPermissionGuidance: requiresParentPermissionGuidance,
            permissionStatus: { permissions.status(for: $0) },
            venvInstalled: VenvInstaller.alreadyInstalled,
            agentSignedIn: AgentAuth.isAuthenticated(for: selectedAgentProvider),
            parentPermissionsReviewed: parentPermissionsReviewed
        )
    }

    static func progressLabel(for step: Step,
                              simplified: Bool,
                              requiresAgentChoice: Bool,
                              requiresParentPermissionGuidance: Bool = false,
                              permissionStatus: (PermissionKind) -> PermissionStatus,
                              venvInstalled: Bool,
                              agentSignedIn: Bool,
                              parentPermissionsReviewed: Bool = true) -> String? {
        let steps = progressSteps(
            simplified: simplified,
            requiresAgentChoice: requiresAgentChoice,
            requiresParentPermissionGuidance: requiresParentPermissionGuidance,
            permissionStatus: permissionStatus,
            venvInstalled: venvInstalled,
            agentSignedIn: agentSignedIn,
            parentPermissionsReviewed: parentPermissionsReviewed
        )
        guard let index = steps.firstIndex(of: step) else { return nil }
        return "\(index + 1) of \(steps.count)"
    }

    /// Steps that contribute to the header's "X of N" label.
    /// Simplified flow only includes items that still need attention so
    /// the numerator and denominator are always in the same sequence.
    private static func progressSteps(simplified: Bool,
                                      requiresAgentChoice: Bool,
                                      requiresParentPermissionGuidance: Bool,
                                      permissionStatus: (PermissionKind) -> PermissionStatus,
                                      venvInstalled: Bool,
                                      agentSignedIn: Bool,
                                      parentPermissionsReviewed: Bool) -> [Step] {
        if !simplified {
            return [.agentChoice, .microphone, .inputMonitoring, .parentAccessibility, .parentScreenRecording, .pythonSetup, .agentLogin]
        }
        var steps: [Step] = []
        for s in Step.allCases {
            if s == .agentChoice, requiresAgentChoice {
                steps.append(s)
            }
            if s.isParentPermissionStep,
               (requiresAgentChoice || requiresParentPermissionGuidance),
               !parentPermissionsReviewed {
                steps.append(s)
            }
            if let kind = s.kind, permissionStatus(kind) != .granted {
                steps.append(s)
            }
            if s == .pythonSetup, !venvInstalled {
                steps.append(s)
            }
            if s == .agentLogin, !agentSignedIn {
                steps.append(s)
            }
        }
        return steps
    }

    private func permissionTitle(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:      return "Allow microphone access"
        case .accessibility:   return "Allow Accessibility access"
        case .inputMonitoring: return "Allow Input Monitoring"
        // Screen Recording is intentionally not part of onboarding — it's
        // only needed by the optional Relay Actions voice tools and is
        // requested on first use (see PermissionsManager.promptScreenRecording).
        // Strings provided so the switch is exhaustive and the case is ready
        // to wire up if a future step adds it to onboarding.
        case .screenRecording: return "Allow Screen Recording"
        }
    }

    private func permissionExplanation(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "Relay Runner needs to hear you so it can transcribe your speech. Audio stays completely local — nothing is sent off your Mac."
        case .accessibility:
            return "So Relay Runner can detect your Caps Lock (or configured trigger key) no matter which app you're using, it needs Accessibility access. This is also how it pauses media when you start talking."
        case .inputMonitoring:
            return "Input Monitoring lets Relay Runner capture global keyboard events. It enables non-Caps-Lock activation keys and the double-tap Shift board hotkey; voice still works with microphone permission alone if you skip it."
        case .screenRecording:
            return "Optional. Required only when you ask the agent to take a screenshot or walk through an app for UAT. Voice transcription and speech don't need it."
        }
    }

    private func permissionInstruction(for kind: PermissionKind, status: PermissionStatus) -> String {
        switch kind {
        case .microphone:
            // Only reached for .denied / .restricted — the .notDetermined
            // path uses the system prompt and skips the instruction box.
            if status == .denied {
                return "Click Ask Again below. Relay Runner will reset its previous microphone decision and show Apple's normal microphone prompt again."
            }
            return "This Mac is blocking microphone access. Open System Settings to inspect Relay Runner under Microphone."
        case .accessibility:
            return "Click the button below. In System Settings, find Relay Runner in the list and switch it on. This window will update automatically when you're done."
        case .inputMonitoring:
            return "Relay Runner opens Input Monitoring automatically. Drag the app icon below into the applications list if it is missing, then turn on the switch. If macOS asks to quit and reopen, approve it — Relay Runner resumes here."
        case .screenRecording:
            return "Click the button below. In System Settings, find Relay Runner under Screen Recording and switch it on."
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusBadge(for status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
        case .denied, .notDetermined:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.title3)
        case .restricted:
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .font(.title3)
        }
    }

    static func initialStep(simplified: Bool,
                            resumeStep: OnboardingStepID?,
                            requiresAgentChoice: Bool,
                            requiresParentPermissionGuidance: Bool,
                            parentPermissionsReviewed: Bool,
                            permissionStatus: (PermissionKind) -> PermissionStatus,
                            venvInstalled: Bool,
                            agentSignedIn: Bool) -> Step {
        if let resumeStep, let step = Step(resumeID: resumeStep) {
            return step
        }
        guard simplified else {
            return .welcome
        }
        return firstMissing(
            requiresAgentChoice: requiresAgentChoice,
            requiresParentPermissionGuidance: requiresParentPermissionGuidance,
            parentPermissionsReviewed: parentPermissionsReviewed,
            permissionStatus: permissionStatus,
            venvInstalled: venvInstalled,
            agentSignedIn: agentSignedIn
        ) ?? .ready
    }

    private static func firstMissing(requiresAgentChoice: Bool,
                                     requiresParentPermissionGuidance: Bool,
                                     parentPermissionsReviewed: Bool,
                                     permissionStatus: (PermissionKind) -> PermissionStatus,
                                     venvInstalled: Bool,
                                     agentSignedIn: Bool) -> Step? {
        for s in Step.allCases {
            if s == .agentChoice, requiresAgentChoice {
                return s
            }
            if s.isParentPermissionStep,
               (requiresAgentChoice || requiresParentPermissionGuidance),
               !parentPermissionsReviewed {
                return s
            }
            if let kind = s.kind, permissionStatus(kind) != .granted {
                return s
            }
            if s == .pythonSetup, !venvInstalled {
                return s
            }
            if s == .agentLogin, !agentSignedIn {
                return s
            }
        }
        return nil
    }

    static func inputMonitoringSummary(status: PermissionStatus) -> String? {
        switch status {
        case .granted:
            return nil
        case .notDetermined:
            return "Voice works with microphone permission alone. Grant Input Monitoring later to enable non-Caps-Lock activation keys and the double-tap Shift board hotkey."
        case .denied:
            return "Voice works with microphone permission alone. Restore Input Monitoring to re-enable non-Caps-Lock activation keys and the double-tap Shift board hotkey."
        case .restricted:
            return "Voice works with microphone permission alone, but a device policy appears to block Input Monitoring. Ask IT to allow Relay Runner before global activation keys and the double-tap Shift board hotkey can work."
        }
    }

    private func requestInputMonitoringPermission() {
        persistResume()
        permissions.registerForInputMonitoringList()
        permissions.promptInputMonitoring()
        permissions.openSettings(for: .inputMonitoring)
    }

    private var currentReadiness: GuidedSetupReadiness {
        GuidedSetupReadiness(
            provider: selectedAgentProvider,
            microphone: permissions.microphone,
            inputMonitoring: permissions.inputMonitoring,
            pythonInstalled: venvReady,
            agentSignedIn: agentSignedIn,
            parentPermissionsReviewed: parentPermissionsReviewed
        )
    }

    private var venvReady: Bool {
        if case .succeeded = venvInstaller.status {
            return true
        }
        return VenvInstaller.alreadyInstalled
    }

    private static var relayRunnerAppTarget: PermissionAppTarget {
        PermissionAppTarget(displayName: "Relay Runner.app", bundleURL: Bundle.main.bundleURL)
    }

    private func readinessIcon(for mode: GuidedSetupReadiness.Mode) -> String {
        switch mode {
        case .blocked: return "exclamationmark.triangle.fill"
        case .voiceOnly: return "mic.circle.fill"
        case .fullyArmed: return "checkmark.seal.fill"
        }
    }

    private func readinessColor(for mode: GuidedSetupReadiness.Mode) -> Color {
        switch mode {
        case .blocked: return .orange
        case .voiceOnly: return .green
        case .fullyArmed: return .green
        }
    }

    private func openParentPermissionSettings(for kind: PermissionKind) {
        persistResume()
        let urlString: String
        switch kind {
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        default:
            return
        }
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func persistResume() {
        OnboardingResumeState.save(
            step: step.resumeID,
            provider: selectedAgentProvider,
            parentPermissionsReviewed: parentPermissionsReviewed
        )
    }

    private func advancePastGrantedPermissionIfNeeded() {
        guard let kind = step.kind,
              permissions.status(for: kind) == .granted else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard step.kind == kind,
                  permissions.status(for: kind) == .granted else {
                return
            }
            advance()
        }
    }

    private func openPermissionPaneAutomaticallyIfNeeded() {
        if step == .inputMonitoring {
            guard permissions.inputMonitoring != .granted,
                  !autoOpenedPermissionKinds.contains(.inputMonitoring) else {
                return
            }
            autoOpenedPermissionKinds.insert(.inputMonitoring)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard step == .inputMonitoring,
                      permissions.inputMonitoring != .granted else {
                    return
                }
                requestInputMonitoringPermission()
            }
            return
        }

        guard let parentKind = parentPermissionKind(for: step),
              !autoOpenedParentPermissionSteps.contains(step.resumeID) else {
            return
        }
        autoOpenedParentPermissionSteps.insert(step.resumeID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard parentPermissionKind(for: step) == parentKind else {
                return
            }
            openParentPermissionSettings(for: parentKind)
        }
    }

    private func parentPermissionKind(for step: Step) -> PermissionKind? {
        switch step {
        case .parentAccessibility:
            return .accessibility
        case .parentScreenRecording:
            return .screenRecording
        default:
            return nil
        }
    }
}
