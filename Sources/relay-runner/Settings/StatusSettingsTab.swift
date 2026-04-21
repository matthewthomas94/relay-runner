import SwiftUI

/// Flat list of every component the app depends on, with a live status
/// indicator and an action button where one makes sense. Designed to be the
/// single place a user (or support request) can look to answer "what's
/// wrong with my install?" without digging through logs.
struct StatusSettingsTab: View {
    @Bindable var appState: AppState

    @State private var venvPresent: Bool = false
    @State private var bridgeAlive: Bool = false
    /// Nudged every 2s so we re-read state that isn't observable on its own
    /// (venv files on disk, bridge process). Cheap — both checks are one
    /// stat + one pgrep.
    @State private var refreshTrigger = UUID()

    private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
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
                ? "Installed at services/.venv"
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
            appState.permissions.markAttemptedGrant(kind)
            switch kind {
            case .accessibility:   appState.permissions.promptAccessibility()
            case .inputMonitoring: appState.permissions.promptInputMonitoring()
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
        // The canonical venv python path ProcessManager also uses. Cheap
        // filesystem check — no need to shell out for a proper import test
        // here; the Python env row is an "is it roughly installed" hint,
        // and the STT-model row below surfaces the real failure if deps
        // are missing.
        let fm = FileManager.default
        let candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/SharedSupport/services/.venv/bin/python3").path,
            FileManager.default.currentDirectoryPath + "/services/.venv/bin/python3",
        ]
        return candidates.contains { fm.isExecutableFile(atPath: $0) }
    }
}
