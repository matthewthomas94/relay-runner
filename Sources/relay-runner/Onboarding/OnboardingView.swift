import AppKit
import SwiftUI

struct OnboardingPermissionPromptPresentation: Equatable {
    let permission: PermissionKind
    let prompt: String
    let supportingCopy: String?
    let buttonTitle: String
    let isButtonEnabled: Bool
}

enum OnboardingPermissionTreatment {
    static let actionScale: CGFloat = 0.75
    static let buttonTitle = "Grant permission"
    static let buttonSize = CGSize(width: 195 * actionScale, height: 50 * actionScale)
    static let buttonCornerRadius: CGFloat = 12 * actionScale
    static let buttonHorizontalPadding: CGFloat = 32 * actionScale
    static let buttonVerticalPadding: CGFloat = 16 * actionScale
    static let buttonLineHeight: CGFloat = 18 * actionScale
    static let buttonLabelSize: CGFloat = 16 * actionScale
    static let buttonBorderColor = NSColor(srgbRed: 17 / 255, green: 22 / 255, blue: 29 / 255, alpha: 1)
    static let promptMaxWidth: CGFloat = 1180
    static let supportingMaxWidth: CGFloat = 620
    static let promptMinHeight: CGFloat = 560

    static func prompt(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "Let’s start with your mic /"
        case .accessibility:
            return "Next let’s set up Relay Actions with accessibility /"
        case .inputMonitoring:
            return "Next let’s set up your hotkeys with input monitoring /"
        case .screenRecording:
            return "Lastly we’re going to need screen recording /"
        }
    }

    static func explanation(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "Relay Runner needs to hear you so it can transcribe your speech. Audio stays completely local — nothing is sent off your Mac."
        case .accessibility:
            return "Accessibility lets Relay Runner host Relay Actions for clicking, typing, pressing keys, scrolling, and UI automation, and observe the global key events used for hotkeys."
        case .inputMonitoring:
            return "Input Monitoring is the listen-only alternative for global keyboard events when Accessibility is not granted. It enables non-Caps-Lock activation keys and the double-tap Shift Workspace hotkey; voice still works with microphone permission alone if you skip it."
        case .screenRecording:
            return "Screen Recording lets Relay Vision capture screenshots for visual grounding. Voice transcription and speech don't need it."
        }
    }

    static func presentation(permission: PermissionKind,
                             status: PermissionStatus,
                             explanation: String,
                             likelyRestricted: Bool) -> OnboardingPermissionPromptPresentation {
        return OnboardingPermissionPromptPresentation(
            permission: permission,
            prompt: prompt(for: permission),
            supportingCopy: likelyRestricted ? explanation : nil,
            buttonTitle: status == .granted ? "Continue" : buttonTitle,
            isButtonEnabled: true
        )
    }
}

/// Settings-hosted onboarding flow. First-run privacy prompts are owned by the
/// intro Workspace surface; this view handles provider, workspace, runtime, auth,
/// ready, and legacy resumed permission steps.
struct OnboardingView: View {
    static let workspaceFolderTitle = "Workspace folder"
    static let workspaceFolderHelpText = "New voice sessions start in this folder. Program Manager discovers child git repositories when this is a workspace."

    @Bindable var permissions: PermissionsManager
    let simplified: Bool
    /// Shared runtime readiness. `.ready` means the speech-to-text model has
    /// loaded and is listening; preparing and failed states block Done.
    let setupStatus: () -> SetupRuntimeReadiness
    /// Currently-configured workspace folder at the moment the window
    /// opens. Used to preload the Ready-step path picker so a returning
    /// user sees their last choice.
    let initialWorkingDirectory: String
    /// Configured primary coding agent at the moment the window opens.
    let initialAgentProvider: GeneralConfig.AgentProvider
    let initialModel: String
    let initialCodexReasoningEffort: String
    /// When true in the simplified upgrade flow, ask for the provider choice
    /// even if no other setup is missing.
    let requiresAgentChoice: Bool
    let requiresParentPermissionGuidance: Bool
    let showsWorkingDirectoryPicker: Bool
    let persistsWorkingDirectorySelection: Bool
    /// Persists the selected primary coding agent back to AppConfig.
    let onSetAgentProvider: (GeneralConfig.AgentProvider) -> Void
    let onSetModel: (String) -> Void
    let onSetCodexReasoningEffort: (String) -> Void
    /// Persists the user's workspace-folder pick to AppConfig. Called
    /// from the Ready step's Done button.
    let onSetWorkingDirectory: (String) -> Void
    /// Starts a voice session immediately. Wired to `AppState.newSession`.
    /// Used by the Start Session CTA on the Ready step so the user can
    /// kick off a session without going back to the menu bar.
    let onStartSession: () -> Void
    let onRetrySetup: () -> Void
    let requestPermissionSetup: (PermissionKind, PermissionSetupSource, String) -> Void
    let cancelPermissionSetup: (PermissionSetupSource?) -> Void
    let shouldDeferPermissionAdvance: (PermissionKind) -> Bool
    let onOpenExternalWindow: () -> Void
    let presentation: OnboardingPresentationState?
    let onSurfaceVisibilityChanged: (Bool) -> Void
    let onFinish: () -> Void
    let onHostDismissed: () -> Void

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
    @State private var selectedCodexReasoningEffort: String
    /// True once the user has actively chosen a workspace folder on
    /// this opening of the onboarding window — by clicking Browse… or
    /// Use Home Folder. The Done button stays disabled until then so we
    /// can guarantee an explicit pick rather than silently inheriting
    /// whatever was already in config.
    @State private var hasConfirmedWorkingDirectory: Bool = false
    /// Kept for legacy resume-state compatibility. Current Relay Actions and
    /// Relay Vision paths use Relay Runner app permissions.
    @State private var parentPermissionsReviewed: Bool = false
    @State private var autoOpenedParentPermissionSteps: Set<OnboardingStepID> = []
    @State private var autoAdvancedPermissionKinds: Set<PermissionKind> = []
    @State private var activePermissionSetupKind: PermissionKind?
    @State private var setupReadinessRefresh = Date.distantPast

    init(permissions: PermissionsManager,
         simplified: Bool,
         setupStatus: @escaping () -> SetupRuntimeReadiness = { .ready },
         initialWorkingDirectory: String = "",
         initialAgentProvider: GeneralConfig.AgentProvider = .codex,
         initialModel: String = GeneralConfig.defaultModel,
         initialCodexReasoningEffort: String = GeneralConfig.defaultCodexReasoningEffort,
         requiresAgentChoice: Bool = false,
         requiresParentPermissionGuidance: Bool = false,
         showsWorkingDirectoryPicker: Bool = true,
         initialWorkingDirectoryConfirmed: Bool = false,
         persistsWorkingDirectorySelection: Bool = true,
         initialStepOverride: Step? = nil,
         resumeState: OnboardingResumeState.Snapshot? = nil,
         onSetAgentProvider: @escaping (GeneralConfig.AgentProvider) -> Void = { _ in },
         onSetModel: @escaping (String) -> Void = { _ in },
         onSetCodexReasoningEffort: @escaping (String) -> Void = { _ in },
         onSetWorkingDirectory: @escaping (String) -> Void = { _ in },
         onStartSession: @escaping () -> Void = {},
         onRetrySetup: @escaping () -> Void = {},
         requestPermissionSetup: @escaping (PermissionKind, PermissionSetupSource, String) -> Void = { _, _, _ in },
         cancelPermissionSetup: @escaping (PermissionSetupSource?) -> Void = { _ in },
         shouldDeferPermissionAdvance: @escaping (PermissionKind) -> Bool = { _ in false },
         onOpenExternalWindow: @escaping () -> Void = {},
         presentation: OnboardingPresentationState? = nil,
         onSurfaceVisibilityChanged: @escaping (Bool) -> Void = { _ in },
         onFinish: @escaping () -> Void,
         onHostDismissed: @escaping () -> Void = {}) {
        self.permissions = permissions
        self.simplified = simplified
        self.setupStatus = setupStatus
        self.initialWorkingDirectory = initialWorkingDirectory
        self.initialAgentProvider = initialAgentProvider
        self.initialModel = initialModel
        self.initialCodexReasoningEffort = initialCodexReasoningEffort
        self.requiresAgentChoice = requiresAgentChoice
        self.requiresParentPermissionGuidance = requiresParentPermissionGuidance
        self.showsWorkingDirectoryPicker = showsWorkingDirectoryPicker
        self.persistsWorkingDirectorySelection = persistsWorkingDirectorySelection
        self.onSetAgentProvider = onSetAgentProvider
        self.onSetModel = onSetModel
        self.onSetCodexReasoningEffort = onSetCodexReasoningEffort
        self.onSetWorkingDirectory = onSetWorkingDirectory
        self.onStartSession = onStartSession
        self.onRetrySetup = onRetrySetup
        self.requestPermissionSetup = requestPermissionSetup
        self.cancelPermissionSetup = cancelPermissionSetup
        self.shouldDeferPermissionAdvance = shouldDeferPermissionAdvance
        self.onOpenExternalWindow = onOpenExternalWindow
        self.presentation = presentation
        self.onSurfaceVisibilityChanged = onSurfaceVisibilityChanged
        self.onFinish = onFinish
        self.onHostDismissed = onHostDismissed
        let startingProvider = resumeState?.provider ?? initialAgentProvider
        let startingSelection = Self.normalizedInitialSelection(
            provider: startingProvider,
            model: initialModel,
            effort: initialCodexReasoningEffort
        )
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
            agentSignedIn: AgentAuth.isAuthenticated(for: startingProvider),
            fullFlowInitialStep: initialStepOverride ?? .welcome
        )
        _step = State(initialValue: initial)
        _workingDirectory = State(initialValue: initialWorkingDirectory)
        _selectedAgentProvider = State(initialValue: startingProvider)
        _selectedModel = State(initialValue: startingSelection.model)
        _selectedCodexReasoningEffort = State(initialValue: startingSelection.effort)
        _agentSignedIn = State(initialValue: AgentAuth.isAuthenticated(for: startingProvider))
        _hasConfirmedWorkingDirectory = State(initialValue: initialWorkingDirectoryConfirmed)
        _parentPermissionsReviewed = State(initialValue: startingParentReviewed)
    }

    enum Step: Int, CaseIterable {
        case welcome
        case agentChoice
        case microphone
        case parentAccessibility
        case parentScreenRecording
        case pythonSetup
        case agentLogin
        case ready

        var kind: PermissionKind? {
            switch self {
            case .microphone:      return .microphone
            case .parentAccessibility: return .accessibility
            case .parentScreenRecording: return .screenRecording
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
            case .inputMonitoring:   return nil
            case .parentAccessibility, .parentPermissions:
                self = .parentAccessibility
            case .parentScreenRecording:
                self = .parentScreenRecording
            case .pythonSetup:       self = .pythonSetup
            case .agentLogin:        self = .agentLogin
            case .ready:             self = .ready
            case .tutorialIntro,
                 .tutorialRecording,
                 .tutorialRecordingActive,
                 .tutorialPlayback,
                 .tutorialCancellation,
                 .tutorialWorkspace,
                 .tutorialSessionRetry:
                return nil
            }
        }
    }

    var body: some View {
        Group {
            if let kind = step.kind {
                permissionView(for: kind)
            } else {
                SettingsStack {
                    SettingsSection {
                        content
                    }
                }
            }
        }
        .onAppear {
            publishPresentation()
            persistResume()
            // Full first-run onboarding starts setup from the provider-choice
            // CTA. Focused re-prompt flows may open directly on a later step,
            // so start the automatable setup work there without another user
            // decision.
            if simplified && step != .agentChoice {
                venvInstaller.install()
            }
            advancePastGrantedPermissionIfNeeded()
            syncSurfaceVisibility()
        }
        .onChange(of: step) { _, new in
            activePermissionSetupKind = nil
            cancelPermissionSetup(.onboarding)
            autoAdvancedPermissionKinds.removeAll()
            persistResume()
            if new == .pythonSetup {
                venvInstaller.install()
            }
            advancePastGrantedPermissionIfNeeded()
            syncSurfaceVisibility()
            publishPresentation()
        }
        .onChange(of: selectedAgentProvider) { _, _ in
            persistResume()
            publishPresentation()
        }
        .onChange(of: selectedModel) { _, new in
            onSetModel(new)
            normalizeSelectedEffortForCurrentChoice()
            persistResume()
            publishPresentation()
        }
        .onChange(of: selectedCodexReasoningEffort) { _, new in
            onSetCodexReasoningEffort(new)
            publishPresentation()
        }
        .onChange(of: parentPermissionsReviewed) { _, _ in
            persistResume()
            publishPresentation()
        }
        .onChange(of: permissions.microphone) { _, new in
            syncSurfaceVisibility()
            autoAdvance(for: .microphone, status: new)
            publishPresentation()
        }
        .onChange(of: permissions.accessibility) { _, new in
            syncSurfaceVisibility()
            autoAdvance(for: .accessibility, status: new)
            publishPresentation()
        }
        .onChange(of: permissions.screenRecording) { _, new in
            syncSurfaceVisibility()
            autoAdvance(for: .screenRecording, status: new)
            publishPresentation()
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayPermissionSetupGrantReady)) { notification in
            guard let raw = notification.object as? String,
                  let kind = PermissionKind(rawValue: raw) else {
                return
            }
            autoAdvance(for: kind, status: .granted)
        }
        .onReceive(NotificationCenter.default.publisher(for: .relayPermissionSetupEndedWithoutGrant)) { notification in
            guard let event = notification.object as? PermissionSetupLifecycleEvent,
                  event.source == .onboarding,
                  activePermissionSetupKind == event.permission else {
                return
            }
            activePermissionSetupKind = nil
            syncSurfaceVisibility()
            publishPresentation()
        }
        .onChange(of: venvInstaller.status) { _, new in
            // Auto-advance off pythonSetup as soon as the bootstrap
            // succeeds so the user doesn't have to click through.
            if step == .pythonSetup, case .succeeded = new {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { advance() }
            }
            publishPresentation()
        }
        .onChange(of: hasConfirmedWorkingDirectory) { _, _ in publishPresentation() }
        .onChange(of: agentSignedIn) { _, _ in publishPresentation() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if step == .ready {
                setupReadinessRefresh = Date()
                publishPresentation()
            }
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
        .onDisappear {
            activePermissionSetupKind = nil
            cancelPermissionSetup(.onboarding)
            presentation?.updateActions(primary: nil, secondary: nil)
            onHostDismissed()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:          welcomeView
        case .agentChoice:      agentChoiceView
        case .microphone:       permissionView(for: .microphone)
        case .parentAccessibility: permissionView(for: .accessibility)
        case .parentScreenRecording: permissionView(for: .screenRecording)
        case .pythonSetup:      pythonSetupView
        case .agentLogin:       agentLoginView
        case .ready:            readyView
        }
    }

    // MARK: - Step bodies

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let's get Relay Runner set up.")
                .font(AppTypography.font(.screenTitle))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentChoiceView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which coding agent should Relay Runner start with?")
                .font(AppTypography.font(.screenTitle))

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
            reasoningEffortPicker
            if showsWorkingDirectoryPicker {
                workingDirectoryPicker
            }
            setupPlanView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var setupPlanView: some View {
        let plan = GuidedSetupPlan(provider: selectedAgentProvider)
        return VStack(alignment: .leading, spacing: 8) {
            Text("One guided setup run will:")
                .font(AppTypography.font(.cardHeading))
            ForEach(plan.items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(AppTypography.symbolFont(size: 12))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(AppTypography.font(.body))
                        Text(item.detail)
                            .font(AppTypography.font(.caption))
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model")
                    .font(AppTypography.font(.cardHeading))
                Spacer()
                Picker("Model", selection: $selectedModel) {
                    ForEach(GeneralConfig.modelOptions(for: selectedAgentProvider)) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            if let note = GeneralConfig.accessNote(
                for: selectedModel,
                effort: selectedCodexReasoningEffort,
                provider: selectedAgentProvider
            ) {
                Text(note)
                    .font(AppTypography.font(.caption))
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

    private var reasoningEffortPicker: some View {
        HStack {
            Text("Reasoning effort")
                .font(AppTypography.font(.cardHeading))
            Spacer()
            Picker("Reasoning effort", selection: $selectedCodexReasoningEffort) {
                ForEach(GeneralConfig.reasoningEffortOptions(for: selectedAgentProvider, model: selectedModel)) { option in
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
                    .font(AppTypography.symbolFont(size: 17, weight: .semibold))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppTypography.font(.cardHeading))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(AppTypography.font(.body))
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
            selectedModel = GeneralConfig.defaultModel(for: provider)
        }
        normalizeSelectedEffortForCurrentChoice()
        agentSignedIn = AgentAuth.isAuthenticated(for: provider)
        onSetAgentProvider(provider)
        onSetModel(selectedModel)
        onSetCodexReasoningEffort(selectedCodexReasoningEffort)
    }

    private func normalizeSelectedEffortForCurrentChoice() {
        selectedCodexReasoningEffort = GeneralConfig.normalizedOrchestratorEffort(
            selectedCodexReasoningEffort,
            for: selectedAgentProvider,
            model: selectedModel
        )
    }

    private func permissionView(for kind: PermissionKind) -> some View {
        let status = permissions.status(for: kind)
        let restricted = permissions.likelyRestricted.contains(kind)
        let presentation = OnboardingPermissionTreatment.presentation(
            permission: kind,
            status: status,
            explanation: permissionExplanation(for: kind),
            likelyRestricted: restricted
        )
        return OnboardingPermissionPromptView(
            presentation: presentation,
            action: { permissionPromptAction(for: kind) }
        )
    }

    private func permissionAlternativeBox(for kind: PermissionKind) -> some View {
        let plan = PermissionCompanionFallbackPlan.make(
            permission: kind,
            purpose: permissionExplanation(for: kind),
            bundleURL: Bundle.main.bundleURL
        )
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(.secondary)
                .font(AppTypography.symbolFont(size: 17, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text("Keyboard alternative")
                    .font(AppTypography.font(.cardHeading))
                Text(plan.instructions)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsActionButton(
                    title: "Reveal in Finder",
                    systemImage: "folder",
                    prominence: .secondary
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([plan.revealURL])
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
        .accessibilityLabel(plan.accessibilityLabel)
        .accessibilityHint(plan.instructions)
    }

    /// Yellow warning box shown when the MDM-restriction heuristic fires —
    /// communicates what the user should do next and what still works.
    private func mdmRestrictionBox(for kind: PermissionKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
                .font(AppTypography.symbolFont(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac may be blocking \(kind.displayName).")
                    .font(AppTypography.font(.cardHeading))
                Text(mdmBody(for: kind))
                    .font(AppTypography.font(.body))
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
            return "Your organisation's security policy appears to be blocking Accessibility access. You'll need your IT team to allow Relay Runner. Voice input still works via the menu-bar Record button — only Relay Actions click, type, key, scroll, and UI automation are affected."
        case .inputMonitoring:
            return "Your organisation's security policy appears to be blocking keyboard capture. You'll need your IT team to allow Relay Runner. Voice still works via the menu-bar Record button or always-on mode in Settings — only the global trigger key is affected."
        case .screenRecording:
            return "Your organisation's security policy appears to be blocking Screen Recording. You'll need your IT team to allow Relay Runner. Only Relay Vision screenshots are affected — voice transcription and speech still work."
        }
    }

    private func parentPermissionStepView(for kind: PermissionKind) -> some View {
        let title = parentPermissionStepTitle(for: kind)
        let actionTitle = "Open \(title) Settings"
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: parentPermissionStepIcon(for: kind))
                    .foregroundStyle(.tint)
                    .font(AppTypography.symbolFont(size: 17, weight: .semibold))
                Text(title)
                    .font(AppTypography.font(.screenTitle))
            }

            Text(parentPermissionStepExplanation(for: kind))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsActionButton(
                title: actionTitle,
                systemImage: "gearshape",
                prominence: .secondary
            ) {
                startPermissionSetup(kind, purpose: parentPermissionStepExplanation(for: kind))
            }

            permissionAlternativeBox(for: kind)

            parentPermissionVerificationNote(for: kind)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parentPermissionVerificationNote(for kind: PermissionKind) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind == .screenRecording ? "arrow.clockwise.circle.fill" : "checkmark.seal")
                .foregroundStyle(kind == .screenRecording ? .orange : .secondary)
                .font(AppTypography.symbolFont(size: 17, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(parentPermissionVerificationTitle(for: kind))
                    .font(AppTypography.font(.cardHeading))
                Text(parentPermissionVerificationDetail(for: kind))
                    .font(AppTypography.font(.caption))
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
            return "For Relay Actions click, type, key, scroll, and UI automation, macOS grants control to Relay Runner's app-hosted tool process. Turn on Relay Runner in Accessibility."
        case .screenRecording:
            return "For screenshots and visual grounding, macOS grants screen access to Relay Runner's app-hosted tool process. Turn on Relay Runner in Screen Recording."
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
            return "Relay Runner verifies Accessibility in the app before it clicks, types, presses keys, scrolls, or automates UI for Codex or Claude."
        case .screenRecording:
            return "macOS may require Relay Runner to relaunch after Screen Recording is granted. Relay Vision verifies capture in the app before returning screenshots."
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
                    .font(AppTypography.font(.screenTitle))
            }

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
                .font(AppTypography.symbolFont(size: 17, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(AppTypography.font(.screenTitle))
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
                    .font(AppTypography.font(.body))
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
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .succeeded:
            Text("Done — Python environment ready.")
                .font(AppTypography.font(.body))
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text("Setup failed.")
                    .font(AppTypography.font(.cardHeading))
                Text(message)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can retry now, or skip this step — Relay Runner will retry on the first voice session, but voice replies won't work until it succeeds.")
                    .font(AppTypography.font(.caption))
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
                        .font(AppTypography.symbolFont(size: 17, weight: .semibold))
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .font(AppTypography.font(.screenTitle))
                }
                Text("Sign in to your agent")
                    .font(AppTypography.font(.screenTitle))
            }
            if agentSignedIn {
                Text("Signed in — you're ready to go.")
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.green)
            } else {
                Text("Click the button below. A Terminal window will open and prompt you to sign in. This window will update automatically when you're done.")
                    .font(AppTypography.font(.body))
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
        _ = setupReadinessRefresh
        let runtimeReadiness = setupStatus()
        let readiness = currentReadiness
        let voiceReady = readiness.voiceReady
        return VStack(spacing: 16) {
            Spacer(minLength: 4)
            if runtimeReadiness.isPreparing {
                ProgressView()
                    .controlSize(.large)
            } else if runtimeReadiness.needsSetupAction {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(AppTypography.symbolFont(size: 44))
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: readinessIcon(for: readiness.mode))
                    .font(AppTypography.symbolFont(size: 44))
                    .foregroundStyle(readinessColor(for: readiness.mode))
            }
            Text(readyTitle(runtimeReadiness: runtimeReadiness, readiness: readiness))
                .font(AppTypography.font(.appTitle))
            if !runtimeReadiness.isReady {
                Text(runtimeReadiness.statusDetail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !voiceReady {
                Text(readiness.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if showsWorkingDirectoryPicker {
                    workingDirectoryPicker
                }
                Text(readiness.detail)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Two ways to start a voice session:")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    sessionMethodRow(
                        icon: "menubar.rectangle",
                        title: "From the menu bar",
                        detail: "Click the Relay Runner icon, then choose \u{201C}Start Session\u{2026}\u{201D}. Workspace opens to an embedded terminal with the configured agent already listening."
                    )
                    sessionMethodRow(
                        icon: "terminal",
                        title: "From an Agent",
                        detail: "Run Codex or Claude in any terminal and start the relay-bridge skill or command. Install Relay Skills from Settings \u{2192} General if needed."
                    )
                }
                Text("Already running Codex, Claude Code, or a terminal? Restart it to load the Relay Runner skill or command.")
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tap Caps Lock to start and stop recording in either mode.")
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func readyTitle(runtimeReadiness: SetupRuntimeReadiness,
                            readiness: GuidedSetupReadiness) -> String {
        switch runtimeReadiness {
        case .preparing:
            return "Almost ready\u{2026}"
        case .notStarted, .failed:
            return "Setup needs attention."
        case .ready:
            return readiness.title
        }
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
                    .font(AppTypography.font(.cardHeading))
                if !hasConfirmedWorkingDirectory {
                    Text("(required)")
                        .font(AppTypography.font(.caption))
                        .foregroundStyle(.orange)
                }
            }
            Text(Self.workspaceFolderHelpText)
                .font(AppTypography.font(.caption))
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
                SettingsActionButton(
                    title: "Browse\u{2026}",
                    systemImage: "folder"
                ) { pickWorkingDirectory() }
                SettingsActionButton(
                    title: "Use Home Folder",
                    systemImage: "house"
                ) { useHomeWorkingDirectory() }
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
        WorkspaceDirectoryPicker.pick(
            message: GeneralSettingsTab.workspaceFolderPanelMessage,
            onPrepareExternalWindow: { ready in
                onOpenExternalWindow()
                ready()
            },
            chooseDirectory: {
                WorkspaceDirectoryPicker.runAppKitDirectoryPanel(
                    message: GeneralSettingsTab.workspaceFolderPanelMessage
                )
            },
            completion: { path in
                guard let path else { return }
                workingDirectory = path
                hasConfirmedWorkingDirectory = true
            }
        )
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
                .font(AppTypography.symbolFont(size: 17, weight: .semibold))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTypography.font(.cardHeading))
                Text(detail)
                    .font(AppTypography.font(.body))
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

    // MARK: - Settings presentation

    enum ReadyPrimaryActionKind: Equatable {
        case startSession(isEnabled: Bool)
        case retrySetup
        case waiting
        case done
    }

    static func readyPrimaryActionKind(
        setupStatus: SetupRuntimeReadiness,
        voiceReady: Bool,
        hasConfirmedWorkingDirectory: Bool
    ) -> ReadyPrimaryActionKind {
        switch setupStatus {
        case .ready:
            return voiceReady ? .startSession(isEnabled: hasConfirmedWorkingDirectory) : .done
        case .preparing:
            return .waiting
        case .notStarted, .failed:
            return .retrySetup
        }
    }

    static func showsReadyDismissAction(
        setupStatus: SetupRuntimeReadiness,
        voiceReady: Bool
    ) -> Bool {
        setupStatus.isReady && voiceReady
    }

    private func publishPresentation() {
        presentation?.update(detail: OnboardingDetailPresentation(
            title: Self.headerTitle(for: step, provider: selectedAgentProvider),
            subtitle: Self.headerSubtitle(for: step),
            progress: progressLabel
        ))
        presentation?.updateActions(
            primary: primaryFooterAction,
            secondary: secondaryFooterAction
        )
    }

    private var primaryFooterAction: OnboardingFooterAction? {
        switch step {
        case .welcome:
            return footerAction(
                title: "Get Started",
                systemImage: "arrow.right",
                prominence: .primary,
                shortcut: .default
            ) { advance() }
        case .agentChoice:
            return footerAction(
                title: GuidedSetupPlan(provider: selectedAgentProvider).primaryActionTitle,
                systemImage: "checkmark",
                prominence: .primary,
                isEnabled: hasConfirmedWorkingDirectory || !showsWorkingDirectoryPicker,
                shortcut: .default
            ) { beginGuidedSetup() }
        case .microphone, .parentAccessibility, .parentScreenRecording:
            return nil
        case .pythonSetup:
            return pythonPrimaryAction
        case .agentLogin:
            return agentLoginPrimaryAction
        case .ready:
            switch Self.readyPrimaryActionKind(
                setupStatus: setupStatus(),
                voiceReady: currentReadiness.voiceReady,
                hasConfirmedWorkingDirectory: hasConfirmedWorkingDirectory || !showsWorkingDirectoryPicker
            ) {
            case .startSession(let isEnabled):
                return footerAction(
                    title: "Start Session",
                    systemImage: "play.fill",
                    prominence: .primary,
                    isEnabled: isEnabled,
                    shortcut: .default
                ) {
                    persistWorkingDirectoryIfNeeded()
                    onStartSession()
                    onFinish()
                }
            case .retrySetup:
                return footerAction(
                    title: "Retry Setup",
                    systemImage: "arrow.clockwise",
                    prominence: .primary,
                    shortcut: .default
                ) { onRetrySetup() }
            case .waiting:
                return footerAction(
                    title: "Waiting",
                    systemImage: "clock",
                    prominence: .primary,
                    isEnabled: false,
                    shortcut: .default
                ) {}
            case .done:
                return footerAction(
                    title: "Done",
                    systemImage: "checkmark",
                    prominence: .primary,
                    shortcut: .default
                ) { onFinish() }
            }
        }
    }

    private var secondaryFooterAction: OnboardingFooterAction? {
        if step == .ready && Self.showsReadyDismissAction(
            setupStatus: setupStatus(),
            voiceReady: currentReadiness.voiceReady
        ) {
            return footerAction(
                title: "Dismiss",
                systemImage: "xmark",
                prominence: .secondary,
                shortcut: .cancel
            ) {
                persistWorkingDirectoryIfNeeded()
                onFinish()
            }
        }
        if step == .welcome || step == .agentChoice {
            return footerAction(
                title: "Cancel",
                systemImage: "xmark",
                prominence: .secondary,
                shortcut: .cancel
            ) { onHostDismissed() }
        }
        if let kind = step.kind, activePermissionSetupKind == kind {
            return nil
        }
        if step != .ready {
            return footerAction(
                title: "Skip",
                systemImage: "forward",
                prominence: .secondary
            ) {
                cancelPermissionSetup(.onboarding)
                advance()
            }
        }
        return nil
    }

    private var microphonePrimaryAction: OnboardingFooterAction {
        switch permissions.microphone {
        case .granted:
            return footerAction(
                title: "Continue",
                systemImage: "arrow.right",
                prominence: .primary,
                shortcut: .default
            ) { advance() }
        case .notDetermined:
            return footerAction(
                title: "Grant Microphone Access",
                systemImage: "mic.badge.plus",
                prominence: .primary,
                shortcut: .default
            ) {
                startPermissionSetup(.microphone, purpose: permissionExplanation(for: .microphone))
            }
        case .denied:
            return footerAction(
                title: "Ask Again",
                systemImage: "mic.badge.plus",
                prominence: .primary,
                shortcut: .default
            ) {
                startPermissionSetup(.microphone, purpose: permissionExplanation(for: .microphone))
            }
        case .restricted:
            return footerAction(
                title: "Open System Settings",
                systemImage: "gearshape",
                prominence: .primary,
                shortcut: .default
            ) {
                persistResume()
                startPermissionSetup(.microphone, purpose: permissionExplanation(for: .microphone))
            }
        }
    }

    private func permissionPromptAction(for kind: PermissionKind) {
        if permissions.status(for: kind) == .granted {
            advance()
            return
        }
        persistResume()
        startPermissionSetup(kind, purpose: permissionExplanation(for: kind))
    }

    private var pythonPrimaryAction: OnboardingFooterAction {
        switch venvInstaller.status {
        case .succeeded:
            return footerAction(
                title: "Continue",
                systemImage: "arrow.right",
                prominence: .primary,
                shortcut: .default
            ) { advance() }
        case .failed:
            return footerAction(
                title: "Retry",
                systemImage: "arrow.clockwise",
                prominence: .primary,
                shortcut: .default
            ) { venvInstaller.install() }
        case .idle, .running:
            return footerAction(
                title: "Continue",
                systemImage: "arrow.right",
                prominence: .primary,
                isEnabled: false,
                shortcut: .default
            ) { advance() }
        }
    }

    private var agentLoginPrimaryAction: OnboardingFooterAction {
        if agentSignedIn {
            return footerAction(
                title: "Continue",
                systemImage: "arrow.right",
                prominence: .primary,
                shortcut: .default
            ) { advance() }
        }
        return footerAction(
            title: "Sign in",
            systemImage: "terminal",
            prominence: .primary,
            shortcut: .default
        ) {
            persistResume()
            AgentAuth.openLoginInTerminal(for: selectedAgentProvider)
        }
    }

    private func permissionPrimaryAction(for kind: PermissionKind) -> OnboardingFooterAction {
        switch permissions.status(for: kind) {
        case .granted:
            return footerAction(
                title: "Continue",
                systemImage: "arrow.right",
                prominence: .primary,
                shortcut: .default
            ) { advance() }
        case .notDetermined, .denied:
            return footerAction(
                title: "Open \(kind.displayName) Settings",
                systemImage: "gearshape",
                prominence: .primary,
                shortcut: .default
            ) {
                startPermissionSetup(kind, purpose: permissionExplanation(for: kind))
            }
        case .restricted:
            return footerAction(
                title: "Open System Settings",
                systemImage: "gearshape",
                prominence: .primary,
                shortcut: .default
            ) {
                startPermissionSetup(kind, purpose: permissionExplanation(for: kind))
            }
        }
    }

    private func footerAction(
        title: String,
        systemImage: String?,
        prominence: SettingsActionButton.Prominence,
        isEnabled: Bool = true,
        shortcut: OnboardingFooterAction.Shortcut? = nil,
        perform: @escaping () -> Void
    ) -> OnboardingFooterAction {
        OnboardingFooterAction(
            title: title,
            systemImage: systemImage,
            prominence: prominence,
            isEnabled: isEnabled,
            accessibilityLabel: title,
            helpText: title,
            shortcut: shortcut,
            perform: perform
        )
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

        if let next = Self.nextFullFlowStep(after: step) {
            step = next
        } else {
            onFinish()
        }
    }

    private func beginGuidedSetup() {
        Self.persistGuidedSetupSelection(
            provider: selectedAgentProvider,
            model: selectedModel,
            effort: selectedCodexReasoningEffort,
            onSetAgentProvider: onSetAgentProvider,
            onSetModel: onSetModel,
            onSetEffort: onSetCodexReasoningEffort
        )
        persistWorkingDirectoryIfNeeded()
        agentSignedIn = AgentAuth.isAuthenticated(for: selectedAgentProvider)
        venvInstaller.install()
        advance()
    }

    private func persistWorkingDirectoryIfNeeded() {
        guard persistsWorkingDirectorySelection,
              showsWorkingDirectoryPicker,
              hasConfirmedWorkingDirectory else { return }
        onSetWorkingDirectory(workingDirectory)
    }

    private func autoAdvance(for kind: PermissionKind, status: PermissionStatus) {
        guard status == .granted,
              step.kind == kind,
              !autoAdvancedPermissionKinds.contains(kind),
              !shouldDeferPermissionAdvance(kind) else { return }
        autoAdvancedPermissionKinds.insert(kind)
        // Small delay so the user sees the green check before the view flips
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard step.kind == kind else { return }
            advance()
        }
    }

    static func normalizedInitialSelection(
        provider: GeneralConfig.AgentProvider,
        model: String,
        effort: String
    ) -> (model: String, effort: String) {
        let normalizedModel = GeneralConfig.normalizeModel(model, for: provider)
        return (
            normalizedModel,
            GeneralConfig.normalizedOrchestratorEffort(
                effort,
                for: provider,
                model: normalizedModel
            )
        )
    }

    static func persistGuidedSetupSelection(
        provider: GeneralConfig.AgentProvider,
        model: String,
        effort: String,
        onSetAgentProvider: (GeneralConfig.AgentProvider) -> Void,
        onSetModel: (String) -> Void,
        onSetEffort: (String) -> Void
    ) {
        let selection = normalizedInitialSelection(
            provider: provider,
            model: model,
            effort: effort
        )
        onSetAgentProvider(provider)
        onSetModel(selection.model)
        onSetEffort(selection.effort)
    }

    /// The next Settings-hosted step (after `from`) that still needs the
    /// user's attention — provider choice, pythonSetup if the venv hasn't been
    /// bootstrapped, or agentLogin if the configured agent isn't signed in.
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
            if candidate.kind != nil {
                continue
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

    private static func nextFullFlowStep(after step: Step) -> Step? {
        let steps: [Step] = [.welcome, .agentChoice, .pythonSetup, .agentLogin, .ready]
        guard let index = steps.firstIndex(of: step) else {
            return nextStepAfter(
                step,
                requiresAgentChoice: true,
                requiresParentPermissionGuidance: false,
                parentPermissionsReviewed: true,
                permissionStatus: { _ in .granted },
                venvInstalled: false,
                agentSignedIn: false
            )
        }
        let nextIndex = index + 1
        guard steps.indices.contains(nextIndex) else { return nil }
        return steps[nextIndex]
    }

    // MARK: - Text

    static func headerTitle(for step: Step, provider: GeneralConfig.AgentProvider) -> String {
        switch step {
        case .welcome:          return "Welcome to Relay Runner"
        case .agentChoice:      return "Coding Agent"
        case .microphone:       return "Microphone"
        case .parentAccessibility: return "Accessibility"
        case .parentScreenRecording: return "Screen Recording"
        case .pythonSetup:      return "Python Environment"
        case .agentLogin:       return "\(provider.displayName) Account"
        case .ready:            return "Setup Complete"
        }
    }

    static func headerSubtitle(for step: Step) -> String {
        switch step {
        case .welcome:
            return "Guided setup walkthrough"
        case .agentChoice:
            return "Provider, model, effort, and workspace"
        case .microphone, .parentAccessibility, .parentScreenRecording:
            return "Privacy permission setup"
        case .pythonSetup:
            return "Local runtime preparation"
        case .agentLogin:
            return "Agent authentication"
        case .ready:
            return "Final session readiness"
        }
    }

    private var progressLabel: String? {
        // Full Settings flow visits provider choice, python setup, and agent
        // login. Privacy permissions are handled by the intro surface or
        // Status settings, not this progress count.
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
            return [
                .agentChoice,
                .pythonSetup,
                .agentLogin,
            ]
        }
        var steps: [Step] = []
        for s in Step.allCases {
            if s == .agentChoice, requiresAgentChoice {
                steps.append(s)
            }
            if s.kind != nil {
                continue
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
        // Screen Recording is not part of Settings-hosted onboarding; first-run
        // permission setup is owned by the intro surface.
        case .screenRecording: return "Allow Screen Recording"
        }
    }

    private func permissionExplanation(for kind: PermissionKind) -> String {
        OnboardingPermissionTreatment.explanation(for: kind)
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
            return "Relay Runner opens Accessibility automatically and shows a small draggable companion beside System Settings. Drag Relay Runner.app into the list if it is missing, then turn on its switch."
        case .inputMonitoring:
            return "Relay Runner opens Input Monitoring automatically and shows a small draggable companion beside System Settings. Drag Relay Runner.app into the list if it is missing, then turn on its switch. If macOS asks to quit and reopen, approve it — Relay Runner resumes here."
        case .screenRecording:
            return "Relay Runner opens Screen Recording automatically and shows a small draggable companion beside System Settings. Drag Relay Runner.app into the list if it is missing, then turn on its switch. If macOS asks to quit and reopen, Relay Runner resumes here."
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusBadge(for status: PermissionStatus) -> some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(AppTypography.symbolFont(size: 17, weight: .semibold))
        case .denied, .notDetermined:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(AppTypography.font(.screenTitle))
        case .restricted:
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
                .font(AppTypography.symbolFont(size: 17, weight: .semibold))
        }
    }

    static func initialStep(simplified: Bool,
                            resumeStep: OnboardingStepID?,
                            requiresAgentChoice: Bool,
                            requiresParentPermissionGuidance: Bool,
                            parentPermissionsReviewed: Bool,
                            permissionStatus: (PermissionKind) -> PermissionStatus,
                            venvInstalled: Bool,
                            agentSignedIn: Bool,
                            fullFlowInitialStep: Step = .welcome) -> Step {
        if let resumeStep, let step = Step(resumeID: resumeStep), step.kind == nil {
            return step
        }
        guard simplified else {
            return fullFlowInitialStep
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
            if s.kind != nil {
                continue
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

    static func initialSurfaceVisible(for step: Step) -> Bool {
        true
    }

    static func surfaceVisible(for step: Step,
                               activePermissionSetupKind: PermissionKind?) -> Bool {
        guard let kind = step.kind else { return true }
        return activePermissionSetupKind != kind
    }

    private var currentReadiness: GuidedSetupReadiness {
        GuidedSetupReadiness(
            provider: selectedAgentProvider,
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            screenRecording: permissions.screenRecording,
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

    private func syncSurfaceVisibility() {
        onSurfaceVisibilityChanged(Self.surfaceVisible(
            for: step,
            activePermissionSetupKind: activePermissionSetupKind
        ))
    }

    private func startPermissionSetup(_ kind: PermissionKind, purpose: String) {
        activePermissionSetupKind = kind
        syncSurfaceVisibility()
        requestPermissionSetup(kind, .onboarding, purpose)
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

struct OnboardingPermissionPromptView: View {
    let presentation: OnboardingPermissionPromptPresentation
    let action: () -> Void

    var body: some View {
        VStack(spacing: 54) {
            Text(presentation.prompt)
                .font(AppTypography.font(.onboardingHero))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: OnboardingPermissionTreatment.promptMaxWidth)
                .accessibilityAddTraits(.isHeader)

            OnboardingIntroWhiteActionButton(
                title: presentation.buttonTitle,
                accessibilityLabel: presentation.buttonTitle,
                action: action
            )
            .keyboardShortcut(.defaultAction)
            .disabled(!presentation.isButtonEnabled)

            if let supportingCopy = presentation.supportingCopy {
                Text(supportingCopy)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: OnboardingPermissionTreatment.promptMinHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.prompt)
    }
}
