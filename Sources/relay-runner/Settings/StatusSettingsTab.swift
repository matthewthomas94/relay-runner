import SwiftUI

/// Flat list of every component the app depends on, with a live status
/// indicator and an action button where one makes sense. Designed to be the
/// single place a user (or support request) can look to answer "what's
/// wrong with my install?" without digging through logs.
struct StatusSettingsTab: View {
    @Bindable var appState: AppState

    @State private var venvPresent: Bool = false
    @State private var bridgeAlive: Bool = false
    /// Nudged every 1s so we re-read state that isn't observable on its own
    /// (venv files on disk, bridge process). Cheap — both checks are one
    /// stat + one pgrep. Faster cadence keeps the tab feeling live when
    /// the user is actively flipping toggles in System Settings.
    @State private var refreshTrigger = UUID()

    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if !appState.permissions.resetSinceLastRun.isEmpty {
                Section {
                    staleGrantBanner
                }
            }
            Section("Privacy Permissions") {
                permissionRow(.microphone)
                permissionRow(.accessibility)
                permissionRow(.inputMonitoring)
            }

            Section("Runtime") {
                pythonEnvRow
                sttModelRow
                voiceBridgeRow
            }

            Section {
                Button("Re-run Setup Walkthrough\u{2026}") {
                    appState.onboarding.showAlways()
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onReceive(refreshTimer) { _ in refresh() }
    }

    // MARK: - Stale-grant banner

    /// One-time notice shown when permissions that were granted on a
    /// previous run appear denied now. Dismissable; also clears
    /// automatically when the user re-grants.
    @ViewBuilder
    private var staleGrantBanner: some View {
        let names = appState.permissions.resetSinceLastRun
            .map { $0.displayName }
            .sorted()
            .joined(separator: ", ")
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions were reset")
                    .font(.subheadline).bold()
                Text("\(names) showed as granted on a previous run but appear denied now. macOS sometimes resets permissions after an OS update or app reinstall — re-grant below to continue using the affected features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Dismiss") {
                for kind in appState.permissions.resetSinceLastRun {
                    appState.permissions.acknowledgeReset(kind)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Rows

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = appState.permissions.status(for: kind)
        let restricted = appState.permissions.likelyRestricted.contains(kind)
        return statusRow(
            label: kind.displayName,
            state: permissionState(status: status, restricted: restricted),
            detail: permissionDetail(kind: kind, status: status, restricted: restricted),
            action: permissionAction(kind: kind, status: status)
        )
    }

    private var pythonEnvRow: some View {
        statusRow(
            label: "Python environment",
            state: venvPresent ? .ok : .warning,
            detail: venvPresent
                ? "Installed in Application Support"
                : "Not yet installed — will be created on first session",
            action: nil
        )
    }

    private var sttModelRow: some View {
        let msg = appState.sttEngine?.statusMessage ?? ""
        let state: RowState
        let detail: String
        if let translation = appState.sttEngineErrorTranslation {
            state = .error
            detail = translation.headline
        } else if msg.isEmpty {
            state = .idle
            detail = "Not started"
        } else if msg == "Listening" {
            state = .ok
            detail = "Loaded and listening"
        } else {
            state = .loading
            detail = msg
        }
        return statusRow(
            label: "Speech-to-Text model",
            state: state,
            detail: detail,
            action: appState.sttEngineError == nil ? nil :
                RowAction(title: "Retry Setup") { appState.retrySTTSetup() }
        )
    }

    private var voiceBridgeRow: some View {
        statusRow(
            label: "Voice bridge",
            state: bridgeAlive ? .ok : .idle,
            detail: bridgeAlive
                ? "Running — voice session active"
                : "Not running — start a session to launch",
            action: nil
        )
    }

    // MARK: - Row builder

    private enum RowState {
        case ok, warning, error, loading, idle, locked
    }

    private struct RowAction {
        let title: String
        let perform: () -> Void
    }

    private func statusRow(label: String,
                           state: RowState,
                           detail: String,
                           action: RowAction?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            stateIcon(state)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action {
                Button(action.title) { action.perform() }
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: RowState) -> some View {
        switch state {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .loading:
            ProgressView().controlSize(.small)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .locked:
            Image(systemName: "lock.fill").foregroundStyle(.orange)
        }
    }

    // MARK: - Permission helpers

    private func permissionState(status: PermissionStatus, restricted: Bool) -> RowState {
        if restricted { return .locked }
        switch status {
        case .granted:       return .ok
        case .denied:        return .warning
        case .restricted:    return .locked
        case .notDetermined: return .idle
        }
    }

    private func permissionDetail(kind: PermissionKind,
                                  status: PermissionStatus,
                                  restricted: Bool) -> String {
        if restricted {
            return "Blocked by a device policy — contact your IT admin."
        }
        switch status {
        case .granted:       return "Granted"
        case .denied:        return "Denied — open System Settings to allow."
        case .notDetermined: return "Not yet requested."
        case .restricted:    return "Restricted by system policy."
        }
    }

    private func permissionAction(kind: PermissionKind,
                                  status: PermissionStatus) -> RowAction? {
        guard status != .granted else { return nil }
        return RowAction(title: "Open Settings") {
            switch kind {
            case .accessibility:   appState.permissions.promptAccessibility()
            case .inputMonitoring: appState.permissions.promptInputMonitoring()
            case .screenRecording: appState.permissions.promptScreenRecording()
            case .microphone:      break
            }
            appState.permissions.openSettings(for: kind)
        }
    }

    // MARK: - Refresh

    private func refresh() {
        refreshTrigger = UUID()
        venvPresent = Self.venvExists()
        bridgeAlive = appState.processManager.bridgeAlive()
    }

    private static func venvExists() -> Bool {
        // Defer to VenvInstaller.alreadyInstalled — it's the single source
        // of truth for "is the install fully done", and checks both the
        // venv interpreter AND the Kokoro speech-model files. If either is
        // missing, the relay-bridge bash side will run the install, so the
        // Settings row should reflect that the install isn't really done.
        VenvInstaller.alreadyInstalled
    }
}
