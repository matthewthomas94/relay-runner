import SwiftUI

struct STTSettingsTab: View {
    @Binding var config: SttConfig

    var body: some View {
        SettingsStack {
            SettingsSection("Recognition") {
                SettingsRow {
                    Picker("STT Model", selection: $config.model) {
                        Text("Parakeet v2 (recommended)").tag("parakeet-tdt-v2")
                        Text("Parakeet v3 (most accurate, larger)").tag("parakeet-tdt-v3")
                    }
                }

                SettingsDivider()

                SettingsRow {
                    Picker("Input Device", selection: $config.input_device) {
                        Text("System Default").tag("default")
                    }
                }
            }

            if config.input_mode == "push_to_talk" || config.input_mode == "caps_lock_toggle" {
                SettingsSection("Activation") {
                    if config.input_mode == "push_to_talk" {
                        SettingsRow {
                            KeyCaptureView(label: "Push-to-talk Key", value: $config.push_to_talk_key)
                        }
                    }

                    if config.input_mode == "caps_lock_toggle" {
                        SettingsRow {
                            KeyCaptureView(label: "Activation Key", value: $config.activation_key)
                        }
                    }
                }
            }

            SettingsSection("Voice Activity") {
                SettingsRow {
                    Picker("VAD Sensitivity", selection: $config.vad_sensitivity) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                }
            }
        }
    }
}
