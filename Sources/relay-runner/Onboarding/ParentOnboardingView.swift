import AppKit
import SwiftUI

/// One-shot wizard that fires the first time Relay Runner sees a new parent
/// terminal/IDE/app running Codex or Claude (Terminal, Warp, VS Code, Codex.app, …).
///
/// Why this exists: macOS attributes Accessibility + Screen Recording grants
/// to the *responsible* process — typically the app that launched the agent
/// session. Granting Relay Runner doesn't help for those parent-agent grants;
/// the user must grant the parent app. The MCP server detects the parent and
/// surfaces this wizard so the user knows exactly which app to find in System
/// Settings, without trial-and-error.
///
/// Re-fires automatically if the per-action `PermissionPreflight` later
/// reports a still-missing permission for the same parent (revocation case).
struct ParentOnboardingView: View {

    /// Display name of the parent app (e.g. "Terminal", "Visual Studio Code").
    let parent: String
    /// Called when the user clicks "Got it" — closes the window and marks
    /// this parent as onboarded.
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            stepRow(
                number: 1,
                title: "Grant parent app Accessibility",
                detail: "Toggle on \(targetList) so Relay Actions can click, type, and scroll.",
                buttonTitle: "Open Accessibility Settings",
                action: openAccessibility
            )
            stepRow(
                number: 2,
                title: "Grant parent app Screen Recording",
                detail: "Toggle on \(targetList) so Relay Vision can see the screen and ground clicks.",
                buttonTitle: "Open Screen Recording Settings",
                action: openScreenRecording
            )
            relaunchHint
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 560, height: 600)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First time using Relay Runner via \(detectedParentName)")
                .font(.title2).bold()
            Text("Relay Runner has its own app permissions for microphone and menu-bar behavior. Screen control is different: macOS attributes Accessibility and Screen Recording to the parent terminal, IDE, or native app that launched Codex or Claude. Toggle on the detected parent when it appears: \(targetList).")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepRow(number: Int,
                         title: String,
                         detail: String,
                         buttonTitle: String,
                         action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                Button(buttonTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var relaunchHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("After granting, restart the parent app and re-run /relay-bridge")
                    .font(.callout).bold()
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS doesn't apply Screen Recording to processes already running. Quit and reopen the parent app you granted before starting a new session:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Quit and reopen the granted parent app")
                    Text("2. Start a fresh Codex or Claude session")
                    Text("3. Run /relay-bridge again")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    private var detectedParentName: String {
        ParentPermissionGuidance.displayName(for: parent)
    }

    private var targetList: String {
        ParentPermissionGuidance.targetList(detectedParent: parent)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Got it", action: onAcknowledge)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    // MARK: - Actions

    private func openAccessibility() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openScreenRecording() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
