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
    let onFinish: () -> Void

    @State private var step: Step

    init(permissions: PermissionsManager,
         simplified: Bool,
         setupStatus: @escaping () -> String? = { nil },
         onFinish: @escaping () -> Void) {
        self.permissions = permissions
        self.simplified = simplified
        self.setupStatus = setupStatus
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
    }

    enum Step: Int, CaseIterable {
        case welcome
        case microphone
        case accessibility
        case inputMonitoring
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
        .frame(minWidth: 520, minHeight: 420)
        .onChange(of: permissions.microphone) { _, new in
            autoAdvance(for: .microphone, status: new)
        }
        .onChange(of: permissions.accessibility) { _, new in
            autoAdvance(for: .accessibility, status: new)
        }
        .onChange(of: permissions.inputMonitoring) { _, new in
            autoAdvance(for: .inputMonitoring, status: new)
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
            if kind != .microphone {
                Text(permissionInstruction(for: kind))
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
        }
    }

    private var readyView: some View {
        let status = setupStatus()
        return VStack(spacing: 20) {
            Spacer()
            if status != nil {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: permissions.allGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(permissions.allGranted ? .green : .orange)
            }
            Text(status != nil ? "Almost ready\u{2026}" : "You're all set.")
                .font(.title2).bold()
            VStack(spacing: 6) {
                if let status {
                    Text(status)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Relay Runner is running in your menu bar.")
                }
                if !permissions.allGranted {
                    Text("Some features are disabled until missing permissions are granted — open Relay Runner's menu to fix them later.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Button

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .welcome:
            Button("Get Started") { advance() }
                .keyboardShortcut(.defaultAction)
        case .microphone:
            if permissions.microphone == .granted {
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Grant Microphone Access") {
                    permissions.markAttemptedGrant(.microphone)
                    permissions.requestMicrophone { _ in }
                }.keyboardShortcut(.defaultAction)
            }
        case .accessibility:
            if permissions.accessibility == .granted {
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Open System Settings") {
                    permissions.markAttemptedGrant(.accessibility)
                    permissions.promptAccessibility()
                    permissions.openSettings(for: .accessibility)
                }.keyboardShortcut(.defaultAction)
            }
        case .inputMonitoring:
            if permissions.inputMonitoring == .granted {
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Open System Settings") {
                    permissions.markAttemptedGrant(.inputMonitoring)
                    permissions.promptInputMonitoring()
                    permissions.openSettings(for: .inputMonitoring)
                }.keyboardShortcut(.defaultAction)
            }
        case .ready:
            Button("Done") { onFinish() }
                .keyboardShortcut(.defaultAction)
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

    /// The next step (after `from`) whose permission is still not granted.
    /// Used by the simplified re-prompt flow to skip already-granted items.
    private func nextMissingStep(after from: Step) -> Step? {
        let remaining = Step.allCases.filter {
            $0.rawValue > from.rawValue
        }
        for candidate in remaining {
            if let kind = candidate.kind, permissions.status(for: kind) != .granted {
                return candidate
            }
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
        case .ready:            return "Setup Complete"
        }
    }

    private var progressLabel: String? {
        let count = simplified ? Step.allCases.filter { $0.kind != nil }.count : Step.allCases.count - 2
        guard let index = visibleIndex else { return nil }
        return "\(index) of \(count)"
    }

    private var visibleIndex: Int? {
        switch step {
        case .welcome, .ready: return nil
        case .microphone:      return 1
        case .accessibility:   return 2
        case .inputMonitoring: return 3
        }
    }

    private func permissionTitle(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:      return "Allow microphone access"
        case .accessibility:   return "Allow Accessibility access"
        case .inputMonitoring: return "Allow Input Monitoring"
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
        }
    }

    private func permissionInstruction(for kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return ""
        case .accessibility:
            return "Click the button below. In System Settings, find Relay Runner in the list and switch it on. This window will update automatically when you're done."
        case .inputMonitoring:
            return "Click the button below. In System Settings, find Relay Runner in the list and switch it on. This window will update automatically when you're done."
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
        for s in Step.allCases where s.kind != nil {
            if let kind = s.kind, permissions.status(for: kind) != .granted {
                return s
            }
        }
        return nil
    }
}
