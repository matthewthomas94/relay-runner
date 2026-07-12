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

    enum SubagentSizingPolicy: String, CaseIterable, Codable, Identifiable {
        case orchestratorDecides = "orchestrator_decides"
        case userDefault = "user_default"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .orchestratorDecides: return "Orchestrator decides"
            case .userDefault: return "Use my defaults"
            }
        }
    }

    static let defaultModel = "default"
    static let defaultReasoningEffort = "default"
    static let defaultCodexReasoningEffort = defaultReasoningEffort
    static let defaultSubagentModel = "balanced"
    static let defaultSubagentEffort = "medium"

    static let codexModelOptions: [ModelOption] = [
        ModelOption(label: "Default", value: defaultModel),
        ModelOption(label: "GPT-5.6 Sol", value: "gpt-5.6-sol"),
        ModelOption(label: "GPT-5.6 Terra", value: "gpt-5.6-terra"),
        ModelOption(label: "GPT-5.6 Luna", value: "gpt-5.6-luna"),
        ModelOption(label: "GPT-5.5", value: "gpt-5.5"),
        ModelOption(label: "GPT-5.4", value: "gpt-5.4"),
        ModelOption(label: "GPT-5.4 Mini", value: "gpt-5.4-mini"),
        ModelOption(label: "GPT-5.3 Codex Spark", value: "gpt-5.3-codex-spark"),
    ]

    static let codexPlanAccessNote = "GPT-5.6 models and Ultra effort depend on your Codex plan."
    static let claudeFableAccessNote = "Fable requires an eligible Claude plan or usage credits and is unavailable with zero data retention."
    static let claudeBestAccessNote = "Best selects Fable when available, otherwise the latest Opus."

    static let claudeModelOptions: [ModelOption] = [
        ModelOption(label: "Default", value: defaultModel),
        ModelOption(label: "Best", value: "best"),
        ModelOption(label: "Fable", value: "fable"),
        ModelOption(label: "Opus", value: "opus"),
        ModelOption(label: "Sonnet", value: "sonnet"),
        ModelOption(label: "Haiku", value: "haiku"),
    ]

    static let defaultReasoningEffortOptions: [ReasoningEffortOption] = [
        ReasoningEffortOption(label: "Default", value: defaultCodexReasoningEffort),
    ]

    static let baseReasoningEffortOptions: [ReasoningEffortOption] = [
        ReasoningEffortOption(label: "Default", value: defaultReasoningEffort),
        ReasoningEffortOption(label: "Low", value: "low"),
        ReasoningEffortOption(label: "Medium", value: "medium"),
        ReasoningEffortOption(label: "High", value: "high"),
        ReasoningEffortOption(label: "Extra High", value: "xhigh"),
    ]

    static let maxReasoningEffortOption = ReasoningEffortOption(label: "Max", value: "max")
    static let ultraReasoningEffortOption = ReasoningEffortOption(label: "Ultra", value: "ultra")

    static let codexReasoningEffortOptions: [ReasoningEffortOption] = baseReasoningEffortOptions

    static let claudeReasoningEffortOptions: [ReasoningEffortOption] = baseReasoningEffortOptions + [
        ReasoningEffortOption(label: "Max", value: "max"),
    ]

    static let subagentModelOptions: [ModelOption] = [
        ModelOption(label: "Fast", value: "fast"),
        ModelOption(label: "Balanced", value: "balanced"),
        ModelOption(label: "Strong", value: "strong"),
    ]

    static let subagentEffortOptions: [ReasoningEffortOption] = [
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
    var orchestrator_effort: String = defaultReasoningEffort
    /// Legacy Codex-only key. Kept for migration and older config readers.
    var codex_reasoning_effort: String = defaultCodexReasoningEffort
    var subagent_sizing_policy: SubagentSizingPolicy = .orchestratorDecides
    var subagent_model: String = defaultSubagentModel
    var subagent_effort: String = defaultSubagentEffort

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
        accessNote(for: model, effort: defaultReasoningEffort, provider: provider) != nil
    }

    static func accessNote(for model: String, effort: String, provider: AgentProvider) -> String? {
        let normalizedModel = model.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedEffort = effort.trimmingCharacters(in: .whitespaces).lowercased()
        switch provider {
        case .codex:
            if ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"].contains(normalizedModel)
                || normalizedEffort == "ultra" {
                return codexPlanAccessNote
            }
        case .claude:
            if normalizedModel == "fable" {
                return claudeFableAccessNote
            }
            if normalizedModel == "best" {
                return claudeBestAccessNote
            }
        }
        return nil
    }

    static func reasoningEffortOptions(for provider: AgentProvider, model: String) -> [ReasoningEffortOption] {
        let normalizedModel = model.trimmingCharacters(in: .whitespaces).lowercased()
        switch provider {
        case .codex:
            switch normalizedModel {
            case "gpt-5.6-sol", "gpt-5.6-terra":
                return baseReasoningEffortOptions + [maxReasoningEffortOption, ultraReasoningEffortOption]
            case "gpt-5.6-luna":
                return baseReasoningEffortOptions + [maxReasoningEffortOption]
            case "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.3-codex-spark":
                return baseReasoningEffortOptions
            default:
                return defaultReasoningEffortOptions
            }
        case .claude:
            switch normalizedModel {
            case "best", "fable", "opus":
                return baseReasoningEffortOptions + [maxReasoningEffortOption]
            case "sonnet":
                return [
                    ReasoningEffortOption(label: "Default", value: defaultReasoningEffort),
                    ReasoningEffortOption(label: "Low", value: "low"),
                    ReasoningEffortOption(label: "Medium", value: "medium"),
                    ReasoningEffortOption(label: "High", value: "high"),
                    maxReasoningEffortOption,
                ]
            default:
                return defaultReasoningEffortOptions
            }
        }
    }

    static func isEffort(_ effort: String, validFor provider: AgentProvider, model: String) -> Bool {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return reasoningEffortOptions(for: provider, model: model).contains { $0.value == normalized }
    }

    static func normalizedCodexReasoningEffort(_ effort: String, model: String = defaultModel) -> String {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isEffort(normalized, validFor: .codex, model: model)
            ? normalized
            : defaultCodexReasoningEffort
    }

    static func normalizedOrchestratorEffort(
        _ effort: String,
        for provider: AgentProvider,
        model: String = defaultModel
    ) -> String {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isEffort(normalized, validFor: provider, model: model)
            ? normalized
            : defaultReasoningEffort
    }

    static func modelEffortMatrix(for provider: AgentProvider) -> [(model: String, efforts: [String])] {
        modelOptions(for: provider).map { option in
            (option.value, reasoningEffortOptions(for: provider, model: option.value).map(\.value))
        }
    }

    static func normalizeModel(_ model: String, for provider: AgentProvider) -> String {
        let normalized = model.trimmingCharacters(in: .whitespaces).lowercased()
        return Self.isModel(normalized, validFor: provider) ? normalized : Self.defaultModel
    }

    static func normalizedSubagentModel(_ model: String) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return subagentModelOptions.contains { $0.value == normalized }
            ? normalized
            : defaultSubagentModel
    }

    static func normalizedSubagentEffort(_ effort: String) -> String {
        let normalized = effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return subagentEffortOptions.contains { $0.value == normalized }
            ? normalized
            : defaultSubagentEffort
    }

    static func normalizedSubagentSizingPolicy(_ policy: String) -> SubagentSizingPolicy {
        SubagentSizingPolicy(rawValue: policy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            ?? .orchestratorDecides
    }

    static func inferProvider(from command: String) -> AgentProvider {
        let name = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        return name.contains("claude") ? .claude : .codex
    }

    var effectiveOrchestratorEffort: String {
        if orchestrator_effort == Self.defaultReasoningEffort {
            let legacy = Self.normalizedCodexReasoningEffort(codex_reasoning_effort, model: model)
            if legacy != Self.defaultCodexReasoningEffort {
                return legacy
            }
        }
        return orchestrator_effort
    }

    mutating func selectProvider(_ newProvider: AgentProvider) {
        provider = newProvider
        if !hasCustomAbsoluteCommand {
            command = newProvider.defaultCommand
        }
        normalizeSelectedModel()
        normalizeOrchestratorEffort(legacyCodexWasExplicit: true)
        normalizeSubagentDefaults()
    }

    mutating func normalize(providerWasExplicit: Bool, orchestratorEffortWasExplicit: Bool = false) {
        if !providerWasExplicit {
            provider = Self.inferProvider(from: command)
        }
        if !hasCustomAbsoluteCommand {
            command = provider.defaultCommand
        }
        normalizeSelectedModel()
        if !orchestratorEffortWasExplicit {
            orchestrator_effort = codex_reasoning_effort
        }
        normalizeOrchestratorEffort(legacyCodexWasExplicit: !orchestratorEffortWasExplicit)
        normalizeSubagentDefaults()
    }

    private var hasCustomAbsoluteCommand: Bool {
        command.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    private mutating func normalizeSelectedModel() {
        model = Self.normalizeModel(model, for: provider)
    }

    private mutating func normalizeOrchestratorEffort(legacyCodexWasExplicit: Bool) {
        if legacyCodexWasExplicit && orchestrator_effort == Self.defaultReasoningEffort {
            orchestrator_effort = codex_reasoning_effort
        }
        orchestrator_effort = Self.normalizedOrchestratorEffort(
            orchestrator_effort,
            for: provider,
            model: model
        )
        codex_reasoning_effort = Self.normalizedCodexReasoningEffort(
            orchestrator_effort,
            model: model
        )
    }

    private mutating func normalizeSubagentDefaults() {
        subagent_model = Self.normalizedSubagentModel(subagent_model)
        subagent_effort = Self.normalizedSubagentEffort(subagent_effort)
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
