import SwiftUI

struct STTSettingsTab: View {
    @Binding var config: SttConfig

    var body: some View {
        SettingsStack {
            SettingsSection("Recognition") {
                SettingsControlRow("STT Model") {
                    Picker("STT Model", selection: $config.model) {
                        Text("Parakeet v2 (recommended)").tag("parakeet-tdt-v2")
                        Text("Parakeet v3 (most accurate, larger)").tag("parakeet-tdt-v3")
                    }
                }

                SettingsDivider()

                SettingsControlRow(
                    "Input Device",
                    description: "Uses the current macOS input device until real device selection is available."
                ) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Self.inputDeviceDisplayName(config.input_device))
                            .font(AppTypography.font(.body))
                            .foregroundStyle(SettingsSurfaceColor.primaryText)
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
                    }

                    if config.input_mode == "caps_lock_toggle" {
                        SettingsControlRow("Activation Key") {
                            KeyCaptureView(label: "Activation Key", showsLabel: false, value: $config.activation_key)
                        }
                    }
                }
            }

            SettingsSection("Voice Activity") {
                SettingsControlRow("VAD Sensitivity") {
                    Picker("VAD Sensitivity", selection: $config.vad_sensitivity) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                }
            }
        }
    }

    static func inputDeviceDisplayName(_ device: String) -> String {
        let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "default" ? "System Default" : trimmed
    }

    static func inputDeviceAccessibilityValue(_ device: String) -> String {
        "\(inputDeviceDisplayName(device)), read-only"
    }
}
