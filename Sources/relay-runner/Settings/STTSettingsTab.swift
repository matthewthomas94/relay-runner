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

                SettingsControlRow("Input Device") {
                    Picker("Input Device", selection: $config.input_device) {
                        Text("System Default").tag("default")
                    }
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
}
