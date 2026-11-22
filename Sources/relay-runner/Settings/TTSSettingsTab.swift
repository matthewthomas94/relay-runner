import SwiftUI

struct TTSSettingsTab: View {
    @Binding var config: TtsConfig

    @State private var chimes: [String] = []

    var body: some View {
        SettingsStack {
            SettingsSection("Playback") {
                SettingsControlRow("Playback Mode") {
                    SettingsSegmentedPicker("Playback Mode", selection: $config.auto_play, options: [
                        (label: "Auto-play", value: true),
                        (label: "Queue", value: false),
                    ])
                }

                SettingsDivider()

                SettingsControlRow("Speech Speed") {
                    SettingsSlider(value: $config.rate, in: 0.5...2.0, step: 0.1,
                                   label: { "\(String(format: "%.1f", $0))x" })
                        .accessibilityLabel("Speech speed")
                        .accessibilityValue(Self.speechSpeedAccessibilityValue(config.rate))
                }
            }

            SettingsSection("Notifications") {
                SettingsControlRow("Notification Chime") {
                    SettingsMenuPicker(
                        "Notification Chime",
                        selection: $config.chime,
                        options: chimes.map { (label: $0, value: $0) }
                    )
                }

                SettingsDivider()

                SettingsControlRow("Show macOS notification on new message") {
                    Toggle("Show macOS notification on new message", isOn: $config.show_notification)
                }
            }
        }
        .onAppear { loadChimes() }
    }

    private func loadChimes() {
        let soundsDir = "/System/Library/Sounds"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: soundsDir) else {
            chimes = ["Tink", "Glass", "Ping", "Pop"]
            return
        }
        chimes = entries
            .filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    static func speechSpeedAccessibilityValue(_ rate: Double) -> String {
        "\(String(format: "%.1f", rate)) times"
    }
}
