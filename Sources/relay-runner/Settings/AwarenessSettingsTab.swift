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
                SettingsControlRow("Live captions during playback") {
                    Toggle("Live captions during playback", isOn: $config.live_captions)
                }
            }

            SettingsSection("Particle Field") {
                SettingsControlRow("Intensity") {
                    HStack(spacing: 8) {
                        Slider(value: $config.glow_intensity, in: 0.1...1.0, step: 0.05)
                            .disabled(!config.screen_glow)
                            .accessibilityLabel("Particle field intensity")
                            .accessibilityValue(Self.particleIntensityAccessibilityValue(config.glow_intensity))
                        Text("\(Int(config.glow_intensity * 100))%")
                            .font(AppTypography.monospacedFont(size: 11))
                            .foregroundStyle(config.screen_glow ? SettingsSurfaceColor.secondaryText : SettingsSurfaceColor.disabledText)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    static func particleIntensityAccessibilityValue(_ intensity: Double) -> String {
        "\(Int((intensity * 100).rounded())) percent"
    }
}
