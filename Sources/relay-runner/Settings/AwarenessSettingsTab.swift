import SwiftUI

struct AwarenessSettingsTab: View {
    @Binding var config: AwarenessConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    SettingsSlider(value: $config.glow_intensity, in: 0.1...1.0, step: 0.05,
                                   label: SessionWheelIntensity.percent(config.glow_intensity))
                        .disabled(!config.screen_glow)
                        .accessibilityLabel("Particle field intensity")
                        .accessibilityValue(Self.particleIntensityAccessibilityValue(config.glow_intensity))
                        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: config.screen_glow)
                }
            }
        }
    }

    static func particleIntensityAccessibilityValue(_ intensity: Double) -> String {
        "\(Int((intensity * 100).rounded())) percent"
    }
}
