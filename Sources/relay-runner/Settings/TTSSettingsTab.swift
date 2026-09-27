import SwiftUI

struct TTSSettingsTab: View {
    @Binding var config: TtsConfig
    @Bindable var appState: AppState

    private let voices = [
        "af_bella", "af_sarah", "af_nicole", "af_sky", "af_heart",
        "am_adam", "am_michael",
        "bf_emma", "bf_isabella",
        "bm_george", "bm_lewis",
    ]

    @State private var chimes: [String] = []
    @State private var preview = VoicePreviewController()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsStack {
            SettingsSection("Standard Voices") {
                SettingsControlRow("Mode") {
                    Text(config.custom_voice_id == nil ? "Standard" : "Custom")
                        .relayTextSwap(config.custom_voice_id == nil, alignment: .trailing)
                    if config.custom_voice_id != nil {
                        SettingsActionButton(title: "Use Standard", systemImage: nil) {
                            preview.invalidate()
                            config.custom_voice_id = nil
                        }
                        .transition(.relayElement)
                    }
                }
                SettingsDivider()
                SettingsControlRow(config.custom_voice_id == nil ? "Voice" : "Base Voice") {
                    HStack(spacing: 8) {
                        Picker("Voice", selection: $config.voice) {
                            ForEach(voices, id: \.self) { voice in
                                Text(formatVoiceName(voice)).tag(voice)
                            }
                        }
                        SettingsActionButton(
                            title: "Preview",
                            systemImage: preview.isBusy ? "stop.fill" : "play.fill",
                            prominence: .icon,
                            isEnabled: preview.isBusy || !appState.settingsAudioBusy,
                            accessibilityLabel: preview.isBusy ? "Stop preview" : "Preview standard voice",
                            helpText: "Preview this voice",
                            action: previewSelectedVoice
                        )
                    }
                }

                if preview.isBusy || preview.error != nil {
                    VStack(spacing: 0) {
                        SettingsDivider()
                        SettingsRow {
                            SettingsInlineStatus(
                                text: previewStatusText,
                                semanticColor: preview.error == nil ? .neutralAccent : .error,
                                reservedWidth: 170
                            )
                            Text(preview.error ?? preview.status)
                                .font(AppTypography.font(.settingsDescription))
                                .foregroundStyle(preview.error == nil ? SettingsSurfaceColor.secondaryText : SettingsSurfaceColor.error)
                                .fixedSize(horizontal: false, vertical: true)
                                .relayTextSwap(preview.error ?? preview.status)
                        }
                    }
                    .transition(.relayElement)
                }
            }

            CustomVoiceSettingsSection(config: $config, appState: appState, preview: preview)

            SettingsSection("Playback") {
                SettingsControlRow("Playback Mode") {
                    Picker("Playback Mode", selection: $config.auto_play) {
                        Text("Auto-play").tag(true)
                        Text("Queue").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                SettingsDivider()

                SettingsControlRow("Speech Speed") {
                    HStack(spacing: 8) {
                        Slider(value: $config.rate, in: 0.5...2.0, step: 0.1)
                            .accessibilityLabel("Speech speed")
                            .accessibilityValue(Self.speechSpeedAccessibilityValue(config.rate))
                        Text("\(String(format: "%.1f", config.rate))x")
                            .font(AppTypography.monospacedFont(size: 11))
                            .foregroundStyle(SettingsSurfaceColor.secondaryText)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            SettingsSection("Notifications") {
                SettingsControlRow("Notification Chime") {
                    Picker("Notification Chime", selection: $config.chime) {
                        ForEach(chimes, id: \.self) { chime in
                            Text(chime).tag(chime)
                        }
                    }
                }

                SettingsDivider()

                SettingsControlRow("Show macOS notification on new message") {
                    Toggle("Show macOS notification on new message", isOn: $config.show_notification)
                }
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: config.custom_voice_id)
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: preview.isBusy || preview.error != nil)
        .onAppear { loadChimes() }
        .onDisappear { preview.stop() }
        .onChange(of: config.voice) { _, _ in preview.invalidate() }
        .onChange(of: config.rate) { _, _ in preview.invalidate() }
        .onChange(of: appState.settingsAudioBusy) { _, busy in if busy { preview.stop() } }
        .onChange(of: appState.sttEngine.map(ObjectIdentifier.init)) { _, _ in preview.stop() }
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

    private func formatVoiceName(_ voice: String) -> String {
        let parts = voice.split(separator: "_")
        guard parts.count == 2 else { return voice }
        let prefix = parts[0]
        let accent = prefix.first == "a" ? "American" : "British"
        let gender = prefix.last == "f" ? "Female" : "Male"
        let name = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        return "\(name) (\(accent) \(gender))"
    }

    private var previewStatusText: String {
        if preview.error != nil {
            return "Preview failed"
        }
        return "Previewing"
    }

    static func speechSpeedAccessibilityValue(_ rate: Double) -> String {
        "\(String(format: "%.1f", rate)) times"
    }

    private func previewSelectedVoice() {
        if preview.isBusy { preview.stop(); return }
        preview.preview(voice: config.voice, rate: config.rate, key: "standard", appState: appState)
    }
}
