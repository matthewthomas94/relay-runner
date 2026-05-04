import AppKit
import SwiftUI

/// First-launch onboarding flow. Walks through the three required
/// privacy permissions and auto-advances when each is granted.
struct OnboardingView: View {

    @Bindable var permissions: PermissionsManager
    let simplified: Bool
    /// Optional setup-progress string (e.g. "Loading speech model…"). When
    /// non-nil on the Ready step, shown in place of "all set" so the user
    /// knows the app isn't fully ready yet.
    let setupStatus: () -> String?
    /// Currently-configured working directory at the moment the window
    /// opens. Used to preload the Ready-step path picker so a returning
    /// user sees their last choice.
    let initialWorkingDirectory: String
    /// Persists the user's working-directory pick to AppConfig. Called
    /// from the Ready step's Done button.
    let onSetWorkingDirectory: (String) -> Void
    /// Starts a voice session immediately. Wired to `AppState.newSession`.
    /// Used by the Start Session CTA on the Ready step so the user can
    /// kick off a session without going back to the menu bar.
    let onStartSession: () -> Void
    let onFinish: () -> Void

    @State private var step: Step
    /// Drives the Python venv bootstrap on the pythonSetup step. Held
    /// at view scope so the install can start in the background as
    /// soon as onboarding opens (welcome step) and is usually finished
    /// by the time the user reaches its dedicated step.
    @State private var venvInstaller = VenvInstaller()
    /// Cached "is the Claude Code CLI signed in" state. Polled by a
    /// 1-second timer while on the claudeLogin step so we can auto-
    /// advance the moment the keychain entry appears (i.e., the user
    /// has finished `claude /login` in the Terminal we spawned).
    @State private var claudeSignedIn: Bool = ClaudeAuth.isAuthenticated
    /// Whether we've already invoked the Accessibility prompt this session.
    /// AXIsProcessTrustedWithOptions reliably shows a system dialog on the
    /// first call (with its own "Open System Settings" button), then macOS
    /// suppresses repeats — so the first click delegates navigation to the
    /// dialog, and subsequent clicks fall through to a Settings deep-link.
    /// Input Monitoring doesn't get this treatment because IOHIDRequestAccess
    /// only shows a dialog for .notDetermined status (the AX dialog fires for
    /// .denied too), and we can't tell the cases apart at click time.
    @State private var hasPromptedAccessibility = false
    /// Working directory the user picks on the Ready step. Initialized
    /// from `initialWorkingDirectory` so a returning user sees their
    /// previous choice; an empty string means "use the home folder."
    @State private var workingDirectory: String
    /// True once the user has actively chosen a working directory on
    /// this opening of the onboarding window — by clicking Browse… or
    /// Use Home Folder. The Done button stays disabled until then so we
    /// can guarantee an explicit pick rather than silently inheriting
    /// whatever was already in config.
    @State private var hasConfirmedWorkingDirectory: Bool = false

    init(permissions: PermissionsManager,
         simplified: Bool,
         setupStatus: @escaping () -> String? = { nil },
         initialWorkingDirectory: String = "",
         onSetWorkingDirectory: @escaping (String) -> Void = { _ in },
         onStartSession: @escaping () -> Void = {},
         onFinish: @escaping () -> Void) {
        self.permissions = permissions
        self.simplified = simplified
        self.setupStatus = setupStatus
        self.initialWorkingDirectory = initialWorkingDirectory
        self.onSetWorkingDirectory = onSetWorkingDirectory
        self.onStartSession = onStartSession
        self.onFinish = onFinish
        // Simplified flow (re-prompt after initial onboarding): jump to the
        // first missing permission. Full flow starts at the welcome screen.
        let initial: Step
        if simplified {
            initial = Self.firstMissing(permissions: permissions) ?? .ready
        } else {
            initial = .welcome
        }
        _step = State(initialValue: initial)
        _workingDirectory = State(initialValue: initialWorkingDirectory)
    }

    enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case accessibility
        case inputMonitoring
        case pythonSetup
        case claudeLogin
        case ready

        var kind: PermissionKind? {
            switch self {
            case .microphone:      return .microphone
            case .accessibility:   return .accessibility
            case .inputMonitoring: return .inputMonitoring
            default:               return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 640)
        .onAppear {
            // Kick the Python bootstrap off as soon as the window opens
            // so it has a head start while the user grants permissions.
            // install() short-circuits to .succeeded if the venv is
            // already healthy, or no-ops if a previous onAppear already
            // started it — safe to call unconditionally.
            venvInstaller.install()
        }
        .onChange(of: permissions.microphone) { _, new in
            autoAdvance(for: .microphone, status: new)
        }
        .onChange(of: permissions.accessibility) { _, new in
            autoAdvance(for: .accessibility, status: new)
        }
        // No auto-advance for inputMonitoring. IOHIDCheckAccess can return
        // kIOHIDAccessTypeGranted from leftover TCC state (especially on
        // ad-hoc-signed reinstalls) and can transition spuriously after
        // the user opens System Settings — both of which would race the
        // user past this step before they've actually granted. The
        // primary button below shows Continue once the API reads granted,
        // so the user advances on an explicit click instead.
        .onChange(of: venvInstaller.status) { _, new in
            // Auto-advance off pythonSetup as soon as the bootstrap
            // succeeds so the user doesn't have to click through.
            if step == .pythonSetup, case .succeeded = new {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { advance() }
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            // Poll only while we're on the claudeLogin step — the
            // keychain check is cheap, but there's no reason to
            // run it forever. When the entry appears, mirror the
            // permission auto-advance pattern.
            guard step == .claudeLogin else { return }
            let now = ClaudeAuth.isAuthenticated
            guard now != claudeSignedIn else { return }
            claudeSignedIn = now
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
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:          welcomeView
        case .microphone:       permissionView(for: .microphone)
        case .accessibility:    permissionView(for: .accessibility)
        case .inputMonitoring:  permissionView(for: .inputMonitoring)
        case .pythonSetup:      pythonSetupView
        case .claudeLogin:      claudeLoginView
        case .ready:            readyView
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .ready {
                Button("Skip") { advance() }
                    .buttonStyle(.link)
            }
            Spacer()
            primaryButton
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Step bodies

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Let's get Relay Runner set up.")
                .font(.title3)
            Text("Relay Runner needs a few macOS privacy permissions so it can hear you and detect your trigger key. We'll walk through each one — it takes about a minute.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var claudeLoginView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if claudeSignedIn {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                Text("Sign in to Claude")
                    .font(.title3).bold()
            }
            Text("Relay Runner uses Claude Code for the conversation. Sign in to your Anthropic account so voice sessions can connect to Claude — without this, every session would fail with an authentication error the moment you started speaking.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if claudeSignedIn {
                Text("Signed in — you're ready to go.")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text("Click the button below. A Terminal window will open and prompt you to sign in to Anthropic. This window will update automatically when you're done.")
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
        let allGranted = permissions.allGranted
        return VStack(spacing: 16) {
            Spacer(minLength: 4)
            if isLoading {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: allGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(allGranted ? .green : .orange)
            }
            Text(isLoading ? "Almost ready\u{2026}" : "You're all set.")
                .font(.title2).bold()
            if isLoading, let status {
                Text(status)
                    .foregroundStyle(.secondary)
            } else if !allGranted {
                Text("Some features are disabled until missing permissions are granted — open Relay Runner's menu to fix them later.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                workingDirectoryPicker
                Text("Two ways to start a voice session:")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 8) {
                    sessionMethodRow(
                        icon: "menubar.rectangle",
                        title: "From the menu bar",
                        detail: "Click the Relay Runner icon, then choose \u{201C}Start Session\u{2026}\u{201D}. A terminal opens with Claude Code already listening."
                    )
                    sessionMethodRow(
                        icon: "terminal",
                        title: "From Claude Code",
                        detail: "Run \u{2018}claude\u{2019} in any terminal and type /relay-bridge. Install the slash command from Settings \u{2192} General if needed."
                    )
                }
                Text("Already running Claude Code or a terminal? Restart it to load /relay-bridge.")
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

    /// Path picker on the Ready step. The user must actively click
    /// Browse… or Use Home Folder before the Done button enables —
    /// the requirement is that every session start has a deliberate
    /// directory choice, not silently inherit whatever was last in
    /// config. An empty `workingDirectory` string maps to "home" and
    /// is what `ProcessManager` already treats as the default.
    private var workingDirectoryPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Where should Claude run from?")
                    .font(.callout).bold()
                if !hasConfirmedWorkingDirectory {
                    Text("(required)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text("New voice sessions start in this folder. You can change it later in Settings.")
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
                Button("Choose Folder\u{2026}") { pickWorkingDirectory() }
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
        panel.message = "Choose where Claude should run from"
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
        case .microphone:
            switch permissions.microphone {
            case .granted:
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            case .notDetermined:
                // First-ever ask: AVCaptureDevice.requestAccess shows the
                // standard system prompt.
                Button("Grant Microphone Access") {
                    permissions.requestMicrophone { _ in }
                }.keyboardShortcut(.defaultAction)
            case .denied, .restricted:
                // Once macOS has heard a "No" (or a previous Allow that's
                // since been revoked), requestAccess is a no-op — the
                // system won't re-prompt. The only way back is to flip
                // the toggle in System Settings.
                Button("Open System Settings") {
                    permissions.openSettings(for: .microphone)
                }.keyboardShortcut(.defaultAction)
            }
        case .accessibility:
            if permissions.accessibility == .granted {
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Open System Settings") {
                    if !hasPromptedAccessibility {
                        // First click: AXIsProcessTrustedWithOptions shows
                        // its own system dialog with an "Open System Settings"
                        // button. Letting that handle the navigation avoids
                        // the focus race we'd get by also opening Settings
                        // ourselves at the same instant.
                        hasPromptedAccessibility = true
                        permissions.promptAccessibility()
                    } else {
                        // Subsequent clicks: macOS suppresses the AX dialog
                        // after the first call per launch, so the button
                        // would otherwise do nothing visible. Deep-link to
                        // Settings as the fallback.
                        permissions.openSettings(for: .accessibility)
                    }
                }.keyboardShortcut(.defaultAction)
            }
        case .inputMonitoring:
            // Continue is only the primary action when the API reads
            // granted. We removed auto-advance for this step (see body
            // above) because IOHIDCheckAccess can lie, so the user
            // explicitly clicking Continue is what advances. When not
            // granted, the primary button opens System Settings;
            // IOHIDRequestAccess is also called so Relay Runner appears
            // in the Input Monitoring list on a fresh install.
            if permissions.inputMonitoring == .granted {
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Open System Settings") {
                    permissions.promptInputMonitoring()
                    permissions.openSettings(for: .inputMonitoring)
                }.keyboardShortcut(.defaultAction)
            }
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
        case .claudeLogin:
            if claudeSignedIn {
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Sign in to Claude") {
                    ClaudeAuth.openLoginInTerminal()
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
            let pickerVisible = setupStatus() == nil && permissions.allGranted
            if pickerVisible {
                HStack(spacing: 8) {
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
            // missing permission has been addressed (granted or skipped).
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

    private func autoAdvance(for kind: PermissionKind, status: PermissionStatus) {
        guard status == .granted, step.kind == kind else { return }
        // Small delay so the user sees the green check before the view flips
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { advance() }
    }

    /// The next step (after `from`) that still needs the user's attention —
    /// a permission not yet granted, pythonSetup if the venv hasn't been
    /// bootstrapped, or claudeLogin if the Claude CLI isn't signed in.
    /// Used by the simplified re-prompt flow to skip already-done items.
    private func nextMissingStep(after from: Step) -> Step? {
        let remaining = Step.allCases.filter {
            $0.rawValue > from.rawValue
        }
        for candidate in remaining {
            if let kind = candidate.kind, permissions.status(for: kind) != .granted {
                return candidate
            }
            if candidate == .pythonSetup, !VenvInstaller.alreadyInstalled {
                return candidate
            }
            if candidate == .claudeLogin, !ClaudeAuth.isAuthenticated {
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
        case .microphone:       return "Microphone"
        case .accessibility:    return "Accessibility"
        case .inputMonitoring:  return "Input Monitoring"
        case .pythonSetup:      return "Python Environment"
        case .claudeLogin:      return "Claude Account"
        case .ready:            return "Setup Complete"
        }
    }

    private var progressLabel: String? {
        guard let index = visibleIndex else { return nil }
        // Full flow always visits 3 permissions + pythonSetup + claudeLogin
        // (the last two briefly auto-advance when their state is already
        // ready, but they still get slots in the count). Simplified flow
        // only counts steps that actually need attention.
        let count: Int
        if simplified {
            count = simplifiedTotalSteps
        } else {
            count = 5
        }
        return "\(index) of \(count)"
    }

    /// Number of steps the simplified re-prompt flow will visit — the
    /// permissions still missing plus pythonSetup if the venv isn't
    /// healthy plus claudeLogin if the CLI isn't signed in. Used so
    /// the "X of N" label reflects actual remaining work, not the full
    /// onboarding length.
    private var simplifiedTotalSteps: Int {
        var count = 0
        for s in Step.allCases {
            if let kind = s.kind, permissions.status(for: kind) != .granted {
                count += 1
            }
            if s == .pythonSetup, !VenvInstaller.alreadyInstalled {
                count += 1
            }
            if s == .claudeLogin, !ClaudeAuth.isAuthenticated {
                count += 1
            }
        }
        return count
    }

    private var visibleIndex: Int? {
        switch step {
        case .welcome, .ready: return nil
        case .microphone:      return 1
        case .accessibility:   return 2
        case .inputMonitoring: return 3
        case .pythonSetup:     return 4
        case .claudeLogin:     return 5
        }
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
            return "On macOS, capturing global keyboard events requires a second permission called Input Monitoring, separate from Accessibility. Same purpose — letting the app notice your trigger key across every app."
        case .screenRecording:
            return "Optional. Required only when you ask Claude to take a screenshot or walk through an app for UAT. Voice transcription and speech don't need it."
        }
    }

    private func permissionInstruction(for kind: PermissionKind, status: PermissionStatus) -> String {
        switch kind {
        case .microphone:
            // Only reached for .denied / .restricted — the .notDetermined
            // path uses the system prompt and skips the instruction box.
            return "Click the button below. In System Settings, find Relay Runner under Microphone and switch it on. This window will update automatically when you're done."
        case .accessibility:
            return "Click the button below. In System Settings, find Relay Runner in the list and switch it on. This window will update automatically when you're done."
        case .inputMonitoring:
            return "Click the button below. In System Settings, find Relay Runner in the list and switch it on. This window will update automatically when you're done."
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

    private static func firstMissing(permissions: PermissionsManager) -> Step? {
        for s in Step.allCases {
            if let kind = s.kind, permissions.status(for: kind) != .granted {
                return s
            }
            if s == .pythonSetup, !VenvInstaller.alreadyInstalled {
                return s
            }
            if s == .claudeLogin, !ClaudeAuth.isAuthenticated {
                return s
            }
        }
        return nil
    }
}
