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

    struct ReasoningEffortOption: Identifiable, Equatable {
        let label: String
        let value: String

        var id: String { value }
    }

    static let defaultModel = "default"
    static let defaultCodexReasoningEffort = "default"

    static let codexModelOptions: [ModelOption] = [
        ModelOption(label: "Default", value: defaultModel),
        ModelOption(label: "GPT-5.5", value: "gpt-5.5"),
        ModelOption(label: "GPT-5.4", value: "gpt-5.4"),
        ModelOption(label: "GPT-5.4-Mini", value: "gpt-5.4-mini"),
        ModelOption(label: "GPT-5.3-Codex-Spark", value: "gpt-5.3-codex-spark"),
    ]

    static let claudeModelOptions: [ModelOption] = [
        ModelOption(label: "Default", value: defaultModel),
        ModelOption(label: "Opus", value: "opus"),
        ModelOption(label: "Sonnet", value: "sonnet"),
        ModelOption(label: "Haiku", value: "haiku"),
    ]

    static let codexReasoningEffortOptions: [ReasoningEffortOption] = [
        ReasoningEffortOption(label: "Default", value: defaultCodexReasoningEffort),
        ReasoningEffortOption(label: "Low", value: "low"),
        ReasoningEffortOption(label: "Medium", value: "medium"),
        ReasoningEffortOption(label: "High", value: "high"),
        ReasoningEffortOption(label: "Extra High", value: "xhigh"),
    ]

    var provider: AgentProvider = .codex
    var command: String = "codex"
    var terminal: String = "warp"
    var auto_start: Bool = false
    var working_directory: String = ""
    var bypass_permissions: Bool = true
    var model: String = defaultModel
    var codex_reasoning_effort: String = defaultCodexReasoningEffort

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

    static func normalizedCodexReasoningEffort(_ effort: String) -> String {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return codexReasoningEffortOptions.contains { $0.value == normalized }
            ? normalized
            : defaultCodexReasoningEffort
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
        normalizeCodexReasoningEffort()
    }

    mutating func normalize(providerWasExplicit: Bool) {
        if !providerWasExplicit {
            provider = Self.inferProvider(from: command)
        }
        if !hasCustomAbsoluteCommand {
            command = provider.defaultCommand
        }
        normalizeSelectedModel()
        normalizeCodexReasoningEffort()
    }

    private var hasCustomAbsoluteCommand: Bool {
        command.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    private mutating func normalizeSelectedModel() {
        let normalized = model.trimmingCharacters(in: .whitespaces).lowercased()
        model = Self.isModel(normalized, validFor: provider) ? normalized : Self.defaultModel
    }

    private mutating func normalizeCodexReasoningEffort() {
        codex_reasoning_effort = Self.normalizedCodexReasoningEffort(codex_reasoning_effort)
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
