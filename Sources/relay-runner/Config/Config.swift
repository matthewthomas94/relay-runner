import Foundation

// MARK: - Top-level config matching config.toml schema

struct AppConfig: Codable, Equatable {
    var stt = SttConfig()
    var tts = TtsConfig()
    var general = GeneralConfig()
    var awareness = AwarenessConfig()
}

struct SttConfig: Codable, Equatable {
    var model: String = "parakeet-tdt-v2"
    var input_device: String = "default"
    var input_mode: String = "caps_lock_toggle"
    var push_to_talk_key: String = ""
    var activation_key: String = "Caps Lock"
    var vad_sensitivity: String = "medium"
}

struct TtsConfig: Codable, Equatable {
    var engine: String = "kokoro"
    var voice: String = "af_bella"
    var rate: Double = 1.0
    var auto_play: Bool = false
    var chime: String = "Tink"
    var show_notification: Bool = true
}

struct GeneralConfig: Codable, Equatable {
    var command: String = "claude"
    var terminal: String = "warp"
    var auto_start: Bool = false
    var working_directory: String = ""

    /// Resolve legacy terminal short names to full app paths.
    static func resolveTerminalPath(_ terminal: String) -> String {
        if terminal.hasPrefix("/") { return terminal }
        switch terminal.lowercased() {
        case "warp":            return "/Applications/Warp.app"
        case "iterm2", "iterm": return "/Applications/iTerm.app"
        case "terminal":        return "/Applications/Utilities/Terminal.app"
        case "kitty":           return "/Applications/kitty.app"
        case "alacritty":       return "/Applications/Alacritty.app"
        default:                return "/Applications/\(terminal).app"
        }
    }

    /// App name for AppleScript addressing, from the bundle's CFBundleName.
    var terminalAppName: String {
        let resolved = Self.resolveTerminalPath(terminal)
        if let bundle = Bundle(path: resolved),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return URL(fileURLWithPath: resolved).deletingPathExtension().lastPathComponent
    }
}

struct AwarenessConfig: Codable, Equatable {
    var screen_glow: Bool = true
    var live_transcription: Bool = true
    var message_preview: Bool = true
    var live_captions: Bool = false
    var glow_intensity: Double = 0.6
}
