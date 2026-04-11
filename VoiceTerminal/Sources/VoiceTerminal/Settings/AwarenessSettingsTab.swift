import SwiftUI

struct AwarenessSettingsTab: View {
    @Binding var config: AwarenessConfig

    var body: some View {
        Form {
            Section("Overlay") {
                Toggle("Screen edge glow", isOn: $config.screen_glow)
                Toggle("Live transcription", isOn: $config.live_transcription)
                Toggle("Message preview", isOn: $config.message_preview)
                Toggle("Live captions during playback", isOn: $config.live_captions)
            }

            Section("Glow") {
                HStack {
                    Text("Intensity")
                    Slider(value: $config.glow_intensity, in: 0.1...1.0, step: 0.05)
                    Text("\(Int(config.glow_intensity * 100))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}
