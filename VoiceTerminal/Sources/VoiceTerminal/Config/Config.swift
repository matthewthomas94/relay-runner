import Foundation

// MARK: - Top-level config matching config.toml schema

struct AppConfig: Codable, Equatable {
    var stt = SttConfig()
    var tts = TtsConfig()
    var controls = ControlsConfig()
    var general = GeneralConfig()
    var awareness = AwarenessConfig()
}

struct SttConfig: Codable, Equatable {
    var model: String = "parakeet-tdt-v2"
    var input_device: String = "default"
    var input_mode: String = "always_on"
    var push_to_talk_key: String = ""
    var vad_sensitivity: String = "medium"
}

struct TtsConfig: Codable, Equatable {
    var engine: String = "kokoro"
    var voice: String = "af_bella"
    var rate: Double = 1.0
    var auto_play: Bool = true
    var chime: String = "Tink"
    var show_notification: Bool = true
}

struct ControlsConfig: Codable, Equatable {
    var play_pause_key: String = "F5"
    var skip_key: String = "Shift+F5"
}

struct GeneralConfig: Codable, Equatable {
    var command: String = "claude"
    var terminal: String = "warp"
    var auto_start: Bool = false
}

struct AwarenessConfig: Codable, Equatable {
    var screen_glow: Bool = true
    var live_transcription: Bool = true
    var message_preview: Bool = true
    var live_captions: Bool = false
    var glow_intensity: Double = 0.6
}
