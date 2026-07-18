import AppKit
import SwiftUI

/// Legacy compatibility wizard. Current Relay Actions and Relay Vision helpers
/// forward permission-gated work to Relay Runner's app process, so normal setup
/// grants Accessibility and Screen Recording to Relay Runner, not the parent
/// terminal/IDE/app running Codex or Claude.
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
                title: "Grant Relay Runner Accessibility",
                detail: "Toggle on Relay Runner so Relay Actions can click, type, press keys, scroll, and automate UI for Codex and Claude.",
                buttonTitle: "Open Accessibility Settings",
                action: openAccessibility
            )
            stepRow(
                number: 2,
                title: "Grant Relay Runner Screen Recording",
                detail: "Toggle on Relay Runner so Relay Vision can capture screenshots for visual grounding.",
                buttonTitle: "Open Screen Recording Settings",
                action: openScreenRecording
            )
            relayRunnerFallbackGuide
            relaunchHint
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 36)
        .padding(.horizontal, 28)
        .padding(.bottom, 32)
        .frame(width: 560, height: 700)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("First time using Relay Runner via \(detectedParentName)")
                .font(AppTypography.font(.appTitle))
            Text("Relay Runner now owns screen-control permissions for both Codex and Claude. Toggle on Relay Runner in Accessibility and Screen Recording when macOS asks.")
                .font(AppTypography.font(.body))
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
                .font(AppTypography.font(.screenTitle))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AppTypography.font(.cardHeading))
                Text(detail).font(AppTypography.font(.body)).foregroundStyle(.secondary)
                Button(buttonTitle, action: action)
            }
            Spacer(minLength: 0)
        }
    }

    private var relaunchHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("After granting Screen Recording, relaunch Relay Runner if macOS asks")
                    .font(AppTypography.font(.cardHeading))
                    .fixedSize(horizontal: false, vertical: true)
                Text("macOS may require the app receiving Screen Recording to relaunch before capture starts working.")
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("1. Quit and reopen Relay Runner if prompted")
                    Text("2. Start a fresh Codex or Claude session")
                    Text("3. Run /relay-bridge again")
                }
                .font(AppTypography.font(.caption))
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

    private var relayRunnerFallbackGuide: some View {
        let plan = PermissionCompanionFallbackPlan.make(
            permission: .accessibility,
            purpose: "Relay Actions and Relay Vision use Relay Runner's app-hosted permissions.",
            bundleURL: Bundle.main.bundleURL
        )
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text("If Relay Runner is missing")
                    .font(AppTypography.font(.cardHeading))
                Text("Reveal Relay Runner in Finder, then use System Settings' + button in Accessibility or Screen Recording to add Relay Runner.app manually.")
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reveal Relay Runner in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([plan.revealURL])
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .accessibilityLabel(plan.accessibilityLabel)
        .accessibilityHint(plan.instructions)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Got it", action: onAcknowledge)
                .keyboardShortcut(.defaultAction)
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
