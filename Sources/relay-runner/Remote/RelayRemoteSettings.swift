import RelayRemoteProtocol

/// The Mac's settings for the phone (RR-532 seam, RR-536).
///
/// The phone's `settings_command` reaches the app over the session-control
/// socket and is answered with one `settings_state` (docs/specs/relay-remote.md,
/// "Settings"). A `set` is validated like the desktop Settings controls and
/// saved through `RelayAppSettings.applying` and `AppState.saveConfig`, the path
/// Relay App's `set_settings` uses, so the Settings window and running sessions
/// react as they do to a change made on the Mac. Only speech speed, model,
/// effort and sizing are accepted; the provider is read-only.
enum RelayRemoteSettings {
    static let unsupported = "Settings cannot be changed from the phone on this Mac yet."

    static func reply(to command: SettingsCommand, host: RelaySessionControlHost) -> SettingsState {
        let current = host.config()
        guard command.action == .set else { return state(current) }
        do {
            guard let patch = try patch(for: command, current: current.general) else { return state(current) }
            let (next, _) = try RelayAppSettings.applying(patch, to: current)
            if next != current { host.saveConfig(next) }
            return state(host.config())
        } catch let error as RelayAppCommandError {
            return state(current, error: error.message)
        } catch {
            return state(current, error: error.localizedDescription)
        }
    }

    private static let acceptedKeys: Set<String> = ["type", "client_id", "action", "speech_speed_percent", "model", "effort", "sizing"]

    /// A refusal, with the unchanged values, when a command names a key the
    /// phone may not use (the provider, or anything else); nil otherwise.
    static func refusal(forKeysIn object: [String: Any], host: RelaySessionControlHost) -> SettingsState? {
        let extra = Set(object.keys).subtracting(acceptedKeys).sorted()
        guard !extra.isEmpty else { return nil }
        return state(host.config(), error: "The phone cannot set \(extra.joined(separator: ", ")). "
            + "Only speech speed, model, effort and sizing can be changed.")
    }

    /// The state the phone sees for `config`.
    static func state(_ config: AppConfig, error: String? = nil) -> SettingsState {
        let general = config.general
        return SettingsState(
            speechSpeedPercent: Int((config.tts.rate * 100).rounded()),
            provider: general.provider.rawValue,
            model: general.model,
            effort: general.orchestrator_effort,
            sizing: general.subagent_sizing_policy.rawValue,
            modelOptions: GeneralConfig.modelOptions(for: general.provider)
                .map { SettingOption(value: $0.value, label: $0.label) },
            effortOptions: GeneralConfig.reasoningEffortOptions(for: general.provider, model: general.model)
                .map { SettingOption(value: $0.value, label: $0.label) },
            sizingOptions: GeneralConfig.SubagentSizingPolicy.allCases
                .map { SettingOption(value: $0.rawValue, label: $0.displayName) },
            error: error
        )
    }

    /// The `set_settings` patch for a command, or nil when it names nothing to
    /// change. Throws, with nothing saved, for a value the desktop would not offer.
    private static func patch(for command: SettingsCommand, current: GeneralConfig) throws -> [String: Any]? {
        var tts: [String: Any] = [:]
        var general: [String: Any] = [:]
        if let percent = command.speechSpeedPercent {
            guard (50...200).contains(percent), percent % 10 == 0 else {
                throw RelayAppCommandError("Speech speed must be 50 to 200 in steps of 10.")
            }
            tts["rate"] = Double(percent) / 100
        }
        var model = current.model
        if let requested = command.model {
            guard GeneralConfig.isModel(requested, validFor: current.provider) else {
                throw RelayAppCommandError("'\(requested)' is not a \(current.provider.displayName) model on this Mac.")
            }
            model = GeneralConfig.normalizeModel(requested, for: current.provider)
            general["model"] = model
        }
        // As the desktop's model picker does: keep the effort when the new model has it, else correct it.
        var effort = GeneralConfig.normalizedOrchestratorEffort(current.orchestrator_effort, for: current.provider, model: model)
        if let requested = command.effort {
            let value = requested.trimmingCharacters(in: .whitespaces).lowercased()
            guard GeneralConfig.isEffort(value, validFor: current.provider, model: model) else {
                throw RelayAppCommandError("'\(requested)' is not an effort \(model) supports.")
            }
            effort = value
        }
        if command.model != nil || command.effort != nil { general["orchestrator_effort"] = effort }
        if let requested = command.sizing {
            guard GeneralConfig.SubagentSizingPolicy(rawValue: requested) != nil else {
                throw RelayAppCommandError("'\(requested)' is not a sub-agent sizing choice.")
            }
            general["subagent_sizing_policy"] = requested
        }
        var patch: [String: Any] = [:]
        if !tts.isEmpty { patch["tts"] = tts }
        if !general.isEmpty { patch["general"] = general }
        return patch.isEmpty ? nil : patch
    }
}
