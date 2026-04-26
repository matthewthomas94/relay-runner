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
        Form {
            HStack {
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
                            .font(.title3)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isPreviewing)
                .help("Preview this voice")
            }
            if let previewError {
                Text(previewError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
