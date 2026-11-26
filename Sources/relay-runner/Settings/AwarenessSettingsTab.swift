import SwiftUI

struct AwarenessSettingsTab: View {
    @Binding var config: AwarenessConfig
    @Binding var stt: SttConfig
    @Binding var tts: TtsConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsStack {
            if stt.input_mode == "push_to_talk" || stt.input_mode == "caps_lock_toggle" {
                SettingsSection("Activation") {
                    if stt.input_mode == "push_to_talk" {
                        SettingsControlRow("Push-to-talk Key") {
                            KeyCaptureView(label: "Push-to-talk Key", showsLabel: false, value: $stt.push_to_talk_key)
                        }
                        .transition(.relayReplacing(.element))
                    }

                    if stt.input_mode == "caps_lock_toggle" {
                        SettingsControlRow(
                            "Record With",
                            description: Self.activationDescription(holdsToTalk: stt.holdsToTalk)
                        ) {
                            SettingsSegmentedPicker("Record With", selection: activationMode, options: Self.activationOptions)
                                .notchHint("Choose record keys")
                        }
                        .transition(.relayReplacing(.element))
                    }
                }
                .transition(.relayElement)
            }

            SettingsSection("Playback") {
                SettingsControlRow("Playback Mode") {
                    SettingsSegmentedPicker("Playback Mode", selection: $tts.auto_play, options: [
                        (label: "Auto-play", value: true),
                        (label: "Queue", value: false),
                    ])
                }
            }

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
                                   label: SessionWheelIntensity.percent)
                        .disabled(!config.screen_glow)
                        .accessibilityLabel("Particle field intensity")
                        .accessibilityValue(Self.particleIntensityAccessibilityValue(config.glow_intensity))
                        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: config.screen_glow)
                }
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: stt.input_mode)
    }

    static let activationOptions: [(label: String, value: String)] = [
        (label: "Hold ⌃ + ⌥", value: SttConfig.ActivationMode.hold),
        (label: "Caps Lock", value: SttConfig.ActivationMode.capsLock),
    ]

    static func activationDescription(holdsToTalk: Bool) -> String {
        holdsToTalk
            ? "Hold Control and Option to record. Release to send."
            : "Press Caps Lock to open the mic. Press it again to send."
    }

    /// Choosing Caps Lock also clears a custom activation key saved by an
    /// earlier version, so the switch always means the key it names.
    private var activationMode: Binding<String> {
        Binding(
            get: { stt.holdsToTalk ? SttConfig.ActivationMode.hold : SttConfig.ActivationMode.capsLock },
            set: { mode in
                stt.activation_mode = mode
                if mode == SttConfig.ActivationMode.capsLock { stt.activation_key = "Caps Lock" }
            }
        )
    }

    static func particleIntensityAccessibilityValue(_ intensity: Double) -> String {
        "\(Int((intensity * 100).rounded())) percent"
    }
}
