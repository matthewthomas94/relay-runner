import SwiftUI

struct TTSSettingsTab: View {
    @Binding var config: TtsConfig

    private let voices = [
        "af_bella", "af_sarah", "af_nicole", "af_sky", "af_heart",
        "am_adam", "am_michael",
        "bf_emma", "bf_isabella",
        "bm_george", "bm_lewis",
    ]

    @State private var chimes: [String] = []

    var body: some View {
        Form {
            Picker("Voice", selection: $config.voice) {
                ForEach(voices, id: \.self) { voice in
                    Text(formatVoiceName(voice)).tag(voice)
                }
            }

            Picker("Playback Mode", selection: $config.auto_play) {
                Text("Auto-play").tag(true)
                Text("Queue").tag(false)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Speech Speed: \(String(format: "%.1f", config.rate))x")
                Slider(value: $config.rate, in: 0.5...2.0, step: 0.1)
            }

            Picker("Notification Chime", selection: $config.chime) {
                ForEach(chimes, id: \.self) { chime in
                    Text(chime).tag(chime)
                }
            }

            Toggle("Show macOS notification on new message", isOn: $config.show_notification)
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
}
