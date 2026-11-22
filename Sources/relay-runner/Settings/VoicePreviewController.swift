import Foundation

enum VoicePreviewFailure: LocalizedError {
    case busy

    var errorDescription: String? {
        switch self {
        case .busy: return "Finish response playback or voice recording before previewing a voice."
        }
    }
}

/// Where relay-speech holds `voice-audio.lock` while a reply plays.
enum SettingsAudioLease {
    static let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("relay-runner", isDirectory: true)
}
