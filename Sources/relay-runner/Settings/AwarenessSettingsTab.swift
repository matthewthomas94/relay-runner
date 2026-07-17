import SwiftUI

struct AwarenessSettingsTab: View {
    @Binding var config: AwarenessConfig

    var body: some View {
        SettingsStack {
            SettingsSection("Overlay") {
                SettingsControlRow("Particle field") {
                    Toggle("Particle field", isOn: $config.screen_glow)
                }
                SettingsDivider()
                SettingsControlRow("Live transcription") {
                    Toggle("Live transcription", isOn: $config.live_transcription)
                }
                SettingsDivider()
                SettingsControlRow("Message preview") {
                    Toggle("Message preview", isOn: $config.message_preview)
                }
                SettingsDivider()
                SettingsControlRow("Live captions during playback") {
                    Toggle("Live captions during playback", isOn: $config.live_captions)
                }
            }

            SettingsSection("Particle Field") {
                SettingsControlRow("Intensity") {
                    HStack(spacing: 8) {
                        Slider(value: $config.glow_intensity, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(config.glow_intensity * 100))%")
                            .font(AppTypography.monospacedFont(size: 11))
                            .foregroundStyle(SettingsSurfaceColor.secondaryText)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }
}
