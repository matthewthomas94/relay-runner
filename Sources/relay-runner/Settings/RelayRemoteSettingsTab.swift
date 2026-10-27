import AppKit
import SwiftUI

/// Copy for the Remote Login row, resolved from the banner probe.
struct RelayRemoteLoginPresentation: Equatable {
    let title: String
    let description: String
    let showsSettingsLink: Bool

    static func resolve(_ state: RelayRemoteController.RemoteLoginState) -> Self {
        switch state {
        case .checking:
            return Self(title: "Checking Remote Login…", description: "Looking for the Mac's SSH server.", showsSettingsLink: false)
        case .available:
            return Self(
                title: "Remote Login is on",
                description: "Paired devices connect with their own key. Relay Remote uses key authentication only.",
                showsSettingsLink: false
            )
        case .unavailable:
            return Self(
                title: "Remote Login is off",
                description: "Turn on Remote Login in System Settings › General › Sharing, allowing only your user. Relay Remote uses key authentication only and never your password.",
                showsSettingsLink: true
            )
        }
    }
}

struct RelayRemoteSettingsTab: View {
    @Bindable var controller: RelayRemoteController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsStack {
            SettingsSection("Remote Login") {
                RelaySwap(controller.remoteLogin, style: .text, alignment: .leading) { state in
                    remoteLoginRow(RelayRemoteLoginPresentation.resolve(state))
                }
            }

            SettingsSection("Pair a Device") {
                RelaySwap(controller.phase, alignment: .topLeading) { phase in
                    pairingContent(phase)
                }
                if let errorMessage = controller.errorMessage {
                    Text(errorMessage)
                        .font(AppTypography.font(.settingsDescription))
                        .foregroundStyle(SettingsSurfaceColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, SettingsLayout.rowVerticalPadding)
                        .transition(.relayText)
                }
            }

            SettingsSection("Paired Devices") {
                if controller.devices.isEmpty {
                    SettingsRow {
                        Text("No paired devices")
                            .font(AppTypography.font(.settingsDescription))
                            .foregroundStyle(SettingsSurfaceColor.secondaryText)
                    }
                    .transition(.relayElement)
                }
                ForEach(controller.devices) { device in
                    deviceRow(device)
                        .transition(.relayElement)
                }
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: controller.devices)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: controller.errorMessage)
        .task { await controller.refresh() }
    }

    private func remoteLoginRow(_ presentation: RelayRemoteLoginPresentation) -> some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRowLabel(presentation.title, description: presentation.description)
                if presentation.showsSettingsLink {
                    HStack(spacing: 8) {
                        SettingsActionButton(title: "Open Sharing Settings", systemImage: "arrow.up.forward.app") {
                            NSWorkspace.shared.open(RemoteLoginProbe.systemSettingsURL)
                        }
                        SettingsActionButton(title: "Check Again", systemImage: "arrow.clockwise") {
                            Task { await controller.refresh() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pairingContent(_ phase: RelayRemoteController.Phase) -> some View {
        switch phase {
        case .idle:
            SettingsControlRow("Pair an iPhone", description: "Shows a one-time code to scan with Relay Remote. It expires after ten minutes.") {
                SettingsActionButton(
                    title: "Pair a Device",
                    systemImage: "qrcode",
                    prominence: .primary,
                    isEnabled: controller.remoteLogin == .available
                ) {
                    controller.beginPairing()
                }
            }
        case .starting:
            SettingsRow {
                SettingsRowLabel("Preparing a pairing code…")
            }
        case .showingCode(let code):
            pairingCodeCard(code)
        case .confirming(let request):
            confirmationCard(request)
        case .finished(let outcome):
            SettingsControlRow(Self.outcomeTitle(outcome)) {
                SettingsActionButton(title: "Done", systemImage: "checkmark") {
                    controller.dismissOutcome()
                }
            }
        }
    }

    private func pairingCodeCard(_ code: RelayRemoteController.PairingCode) -> some View {
        SettingsRow {
            HStack(alignment: .top, spacing: 18) {
                Image(decorative: code.image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 168, height: 168)
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Pairing code")

                VStack(alignment: .leading, spacing: 10) {
                    SettingsRowLabel(
                        "Scan with Relay Remote",
                        description: "Open Relay Remote on your iPhone and scan this code. It works once and only on this screen."
                    )
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.countdown(until: code.expiresAt, now: context.date))
                            .font(AppTypography.monospacedFont(size: 11))
                            .foregroundStyle(SettingsSurfaceColor.secondaryText)
                            .monospacedDigit()
                    }
                    SettingsActionButton(title: "Cancel", systemImage: "xmark") {
                        controller.cancelPairing()
                    }
                }
            }
        }
    }

    /// The confirmation sheet: nothing is trusted until the user allows it here.
    private func confirmationCard(_ request: RelayRemotePairingRequest) -> some View {
        SettingsRow {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRowLabel(
                    "Allow \u{201C}\(request.deviceName)\u{201D}?",
                    description: "Check that this fingerprint matches the one Relay Remote shows on the iPhone."
                )
                Text(request.fingerprint)
                    .font(AppTypography.monospacedFont(size: 11))
                    .foregroundStyle(SettingsSurfaceColor.primaryText)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(SettingsSurfaceColor.rowFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Toggle("Only from my home network and Tailscale", isOn: $controller.restrictToNetwork)
                    .font(AppTypography.font(.settingsDescription))
                HStack(spacing: 8) {
                    SettingsActionButton(title: "Deny", systemImage: "xmark") {
                        controller.decide(allow: false)
                    }
                    SettingsActionButton(title: "Allow", systemImage: "checkmark", prominence: .primary) {
                        controller.decide(allow: true)
                    }
                }
            }
        }
    }

    private func deviceRow(_ device: RelayRemoteController.Device) -> some View {
        SettingsControlRow(
            device.name,
            description: device.restrictedToNetwork
                ? "\(device.fingerprint) · home network and Tailscale only"
                : device.fingerprint
        ) {
            SettingsActionButton(title: "Unpair", systemImage: "minus.circle") {
                controller.unpair(device)
            }
        }
    }

    static func outcomeTitle(_ outcome: RelayRemotePairingOutcome) -> String {
        switch outcome {
        case .paired(let name): return "\(name) is paired"
        case .denied: return "Pairing declined"
        case .expired: return "The pairing code expired"
        case .cancelled: return "Pairing cancelled"
        case .failed(let message): return "Pairing failed. \(message)"
        }
    }

    static func countdown(until expiry: Date, now: Date) -> String {
        let remaining = max(0, Int(expiry.timeIntervalSince(now).rounded(.up)))
        return String(format: "Expires in %d:%02d", remaining / 60, remaining % 60)
    }
}
