import SwiftUI

struct TTSSettingsTab: View {
    @Binding var config: TtsConfig

    private let voices = [
        "af_bella", "af_sarah", "af_nicole", "af_sky", "af_heart",
        "am_adam", "am_michael",
        "bf_emma", "bf_isabella",
        "bm_george", "bm_lewis",
    ]

    /// Sample sentence for the preview button. A pangram covers most phonemes
    /// so the user gets a realistic sense of each voice's character.
    private let previewText = "The quick brown fox jumps over the lazy dog."

    @State private var chimes: [String] = []
    @State private var isPreviewing = false
    @State private var previewError: String?

    var body: some View {
        SettingsStack {
            SettingsSection("Voice") {
                SettingsControlRow("Voice") {
                    HStack(spacing: 8) {
                        Picker("Voice", selection: $config.voice) {
                            ForEach(voices, id: \.self) { voice in
                                Text(formatVoiceName(voice)).tag(voice)
                            }
                        }
                        Button(action: previewSelectedVoice) {
                            if isPreviewing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "play.circle.fill")
                                    .font(AppTypography.symbolFont(size: 17, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isPreviewing)
                        .accessibilityLabel(isPreviewing ? "Previewing voice" : "Preview voice")
                        .help("Preview this voice")
                    }
                }

                if let previewError {
                    SettingsDivider()
                    SettingsRow {
                        Text(previewError)
                            .font(AppTypography.font(.settingsDescription))
                            .foregroundStyle(SettingsSurfaceColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

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

    private func formatVoiceName(_ voice: String) -> String {
        let parts = voice.split(separator: "_")
        guard parts.count == 2 else { return voice }
        let prefix = parts[0]
        let accent = prefix.first == "a" ? "American" : "British"
        let gender = prefix.last == "f" ? "Female" : "Male"
        let name = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        return "\(name) (\(accent) \(gender))"
    }

    private func previewSelectedVoice() {
        let voice = config.voice
        let text = previewText
        isPreviewing = true
        previewError = nil
        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error>
            do {
                try ProcessManager().previewVoice(name: voice, text: text)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                isPreviewing = false
                if case .failure(let err) = result {
                    previewError = err.localizedDescription
                }
            }
        }
    }
}
