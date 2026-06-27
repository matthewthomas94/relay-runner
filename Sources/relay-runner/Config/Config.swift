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
    var voice: String = "bm_lewis"
    var rate: Double = 1.1
    var auto_play: Bool = false
    var chime: String = "Tink"
    var show_notification: Bool = true
}

struct GeneralConfig: Codable, Equatable {
    enum AgentProvider: String, CaseIterable, Codable, Identifiable {
        case codex
        case claude

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .codex: return "Codex"
            case .claude: return "Claude"
            }
        }

        var defaultCommand: String { rawValue }
    }

    struct ModelOption: Identifiable, Equatable {
        let label: String
        let value: String

        var id: String { value }
    }

    static let defaultModel = "default"

    static let codexModelOptions: [ModelOption] = [
        ModelOption(label: "Default", value: defaultModel),
        ModelOption(label: "GPT-5.6 Sol Preview", value: "gpt-5.6-sol"),
        ModelOption(label: "GPT-5.6 Terra Preview", value: "gpt-5.6-terra"),
        ModelOption(label: "GPT-5.6 Luna Preview", value: "gpt-5.6-luna"),
        ModelOption(label: "GPT-5.5", value: "gpt-5.5"),
        ModelOption(label: "GPT-5.4", value: "gpt-5.4"),
        ModelOption(label: "GPT-5.4-Mini", value: "gpt-5.4-mini"),
        ModelOption(label: "GPT-5.3-Codex-Spark", value: "gpt-5.3-codex-spark"),
    ]

    static let limitedPreviewAccessNote = "Limited preview access: requires an approved Codex workspace."

    static let claudeModelOptions: [ModelOption] = [
        ModelOption(label: "Default", value: defaultModel),
        ModelOption(label: "Opus", value: "opus"),
        ModelOption(label: "Sonnet", value: "sonnet"),
        ModelOption(label: "Haiku", value: "haiku"),
    ]

    var provider: AgentProvider = .codex
    var command: String = "codex"
    var terminal: String = "warp"
    var auto_start: Bool = false
    var working_directory: String = ""
    var bypass_permissions: Bool = true
    var model: String = defaultModel

    static func modelOptions(for provider: AgentProvider) -> [ModelOption] {
        switch provider {
        case .codex: return codexModelOptions
        case .claude: return claudeModelOptions
        }
    }

    static func isModel(_ model: String, validFor provider: AgentProvider) -> Bool {
        let normalized = model.trimmingCharacters(in: .whitespaces).lowercased()
        return modelOptions(for: provider).contains { $0.value == normalized }
    }

    static func requiresLimitedPreviewAccess(_ model: String, for provider: AgentProvider) -> Bool {
        guard provider == .codex else { return false }
        switch model.trimmingCharacters(in: .whitespaces).lowercased() {
        case "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna":
            return true
        default:
            return false
        }
    }

    static func inferProvider(from command: String) -> AgentProvider {
        let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        return name.contains("claude") ? .claude : .codex
    }

    mutating func selectProvider(_ newProvider: AgentProvider) {
        provider = newProvider
        if !hasCustomAbsoluteCommand {
            command = newProvider.defaultCommand
        }
        normalizeSelectedModel()
    }

    mutating func normalize(providerWasExplicit: Bool) {
        if !providerWasExplicit {
            provider = Self.inferProvider(from: command)
        }
        if !hasCustomAbsoluteCommand {
            command = provider.defaultCommand
        }
        normalizeSelectedModel()
    }

    private var hasCustomAbsoluteCommand: Bool {
        command.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    private mutating func normalizeSelectedModel() {
        let normalized = model.trimmingCharacters(in: .whitespaces).lowercased()
        model = Self.isModel(normalized, validFor: provider) ? normalized : Self.defaultModel
    }

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
