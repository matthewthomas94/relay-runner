import AppKit
import SwiftUI

/// One-shot wizard that fires the first time Relay Runner sees a new parent
/// terminal/IDE running `claude` (Terminal, Warp, VS Code, Claude.app, …).
///
/// Why this exists: macOS attributes Accessibility + Screen Recording grants
/// to the *responsible* process — typically the parent of `claude`. Granting
/// Relay Runner doesn't help; the user must grant the parent. The MCP server
/// detects the parent and surfaces this wizard so the user knows exactly
/// which app to find in System Settings, without trial-and-error.
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
                title: "Grant \(parent) Accessibility",
                detail: "Lets me click, type, and scroll on your behalf.",
                buttonTitle: "Open Accessibility Settings",
                action: openAccessibility
            )
            stepRow(
                number: 2,
                title: "Grant \(parent) Screen Recording",
                detail: "Lets me see the screen so I can describe what's there and ground my clicks.",
                buttonTitle: "Open Screen Recording Settings",
                action: openScreenRecording
            )
            relaunchHint
            Spacer(minLength: 0)
            footer
        }
        .padding(28)
        .frame(width: 520, height: 480)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First time using Relay Runner via \(parent)")
                .font(.title2).bold()
            Text("macOS attributes Accessibility and Screen Recording to the app that launched `claude` — that's **\(parent)** for this session, not Relay Runner. Toggle \(parent) on in both panes below; you'll only see this prompt once per app.")
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
            VStack(alignment: .leading, spacing: 2) {
                Text("After granting Screen Recording, restart \(parent)")
                    .font(.callout).bold()
                Text("macOS doesn't apply that grant to long-running processes — quit \(parent), reopen it, and start a fresh `claude` session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
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
