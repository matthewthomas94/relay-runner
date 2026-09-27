import SwiftUI

struct STTSettingsTab: View {
    @Binding var config: SttConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsStack {
            SettingsSection("Recognition") {
                SettingsControlRow("STT Model") {
                    SettingsMenuPicker("STT Model", selection: $config.model, options: [
                        (label: "Parakeet v2 (recommended)", value: "parakeet-tdt-v2"),
                        (label: "Parakeet v3 (most accurate, larger)", value: "parakeet-tdt-v3"),
                    ])
                }

                SettingsDivider()

                SettingsControlRow(
                    "Input Device",
                    description: "Uses the current macOS input device until real device selection is available."
                ) {
                    VStack(alignment: .trailing, spacing: 2) {
                        RelaySwap(Self.inputDeviceDisplayName(config.input_device), style: .text, alignment: .trailing) { deviceName in
                            Text(deviceName)
                                .font(AppTypography.font(.body))
                                .foregroundStyle(SettingsSurfaceColor.primaryText)
                        }
                        Text("Read-only")
                            .font(AppTypography.font(.settingsDescription))
                            .foregroundStyle(SettingsSurfaceColor.mutedText)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Input Device")
                    .accessibilityValue(Self.inputDeviceAccessibilityValue(config.input_device))
                }
            }

            if config.input_mode == "push_to_talk" || config.input_mode == "caps_lock_toggle" {
                SettingsSection("Activation") {
                    if config.input_mode == "push_to_talk" {
                        SettingsControlRow("Push-to-talk Key") {
                            KeyCaptureView(label: "Push-to-talk Key", showsLabel: false, value: $config.push_to_talk_key)
                        }
                        .transition(.relayReplacing(.element))
                    }

                    if config.input_mode == "caps_lock_toggle" {
                        SettingsControlRow("Activation Key") {
                            KeyCaptureView(label: "Activation Key", showsLabel: false, value: $config.activation_key)
                        }
                        .transition(.relayReplacing(.element))
                    }
                }
                .transition(.relayElement)
            }

            SettingsSection("Voice Activity") {
                SettingsControlRow("VAD Sensitivity") {
                    SettingsMenuPicker("VAD Sensitivity", selection: $config.vad_sensitivity, options: [
                        (label: "Low", value: "low"),
                        (label: "Medium", value: "medium"),
                        (label: "High", value: "high"),
                    ])
                }
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: config.input_mode)
    }

    static func inputDeviceDisplayName(_ device: String) -> String {
        let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "default" ? "System Default" : trimmed
    }

    static func inputDeviceAccessibilityValue(_ device: String) -> String {
        "\(inputDeviceDisplayName(device)), read-only"
    }
}
