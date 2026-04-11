import SwiftUI

struct STTSettingsTab: View {
    @Binding var config: SttConfig

    var body: some View {
        Form {
            Picker("STT Model", selection: $config.model) {
                Text("Parakeet v2 (recommended)").tag("parakeet-tdt-v2")
                Text("Parakeet v3 (most accurate, larger)").tag("parakeet-tdt-v3")
            }

            Picker("Input Device", selection: $config.input_device) {
                Text("System Default").tag("default")
            }

            Picker("Input Mode", selection: $config.input_mode) {
                Text("Caps Lock").tag("caps_lock_toggle")
                Text("Always-on").tag("always_on")
                Text("Push-to-talk").tag("push_to_talk")
            }
            .pickerStyle(.segmented)

            if config.input_mode == "push_to_talk" {
                KeyCaptureView(label: "Push-to-talk Key", value: $config.push_to_talk_key)
            }

            Picker("VAD Sensitivity", selection: $config.vad_sensitivity) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
        }
    }
}
