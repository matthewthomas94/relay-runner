import Foundation

/// Reads and partially updates `AppConfig` for Relay App's `get_settings` and
/// `set_settings` (RR-459). An update names `section.key` pairs; unknown or
/// app-managed keys, values of the wrong type, and values the Settings
/// controls could not hold for the current provider and model are refused
/// rather than coerced. The result is saved through `AppState.saveConfig`, the
/// path every Settings control saves through. `AppConfig` holds no credentials,
/// so nothing is redacted.
enum RelayAppSettings {
    /// Fields Relay Runner records itself; Save ignores edits to them.
    static let readOnly: Set<String> = ["stt.phonon_migration", "stt.phonon_migration_previous_model"]

    /// Every setting by section: the config structs' stored properties, which are their JSON keys.
    static let fields: [String: [String]] = [
        "stt": names(SttConfig()),
        "tts": names(TtsConfig()),
        "general": names(GeneralConfig()),
        "awareness": names(AwarenessConfig()),
    ]

    private static func names(_ value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }

    static func json(_ config: AppConfig) -> [String: Any] {
        let data = (try? JSONEncoder().encode(config)) ?? Data()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }

    /// The config with `patch` applied, and the `section.key` paths whose value changed.
    static func applying(_ patch: [String: Any], to current: AppConfig) throws -> (config: AppConfig, changed: [String]) {
        guard !patch.isEmpty else {
            throw RelayAppCommandError(#"settings must name at least one setting, for example {"tts": {"rate": 1.2}}."#)
        }
        var requested: [(section: String, key: String, value: Any)] = []
        for (section, value) in patch.sorted(by: { $0.key < $1.key }) {
            guard let known = fields[section] else {
                throw RelayAppCommandError("Unknown settings section '\(section)'. Sections: \(fields.keys.sorted().joined(separator: ", ")).")
            }
            guard let entries = value as? [String: Any], !entries.isEmpty else {
                throw RelayAppCommandError("settings.\(section) must be an object naming the settings to change.")
            }
            for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
                let path = "\(section).\(key)"
                guard known.contains(key) else {
                    throw RelayAppCommandError("Unknown setting '\(path)'. \(section) has: \(known.sorted().joined(separator: ", ")).")
                }
                guard !readOnly.contains(path) else {
                    throw RelayAppCommandError("'\(path)' is recorded by Relay Runner and cannot be set.")
                }
                requested.append((section, key, value))
            }
        }

        // Choosing a provider resets its command, model and efforts first, as the Settings picker does.
        var base = current
        if let raw = (patch["general"] as? [String: Any])?["provider"] {
            guard let name = raw as? String, let provider = GeneralConfig.AgentProvider(rawValue: name) else {
                throw RelayAppCommandError("'general.provider' must be one of: codex, claude.")
            }
            if provider != base.general.provider { base.general.selectProvider(provider) }
        }

        var object = json(base)
        for item in requested {
            var section = object[item.section] as? [String: Any] ?? [:]
            section[item.key] = item.value is NSNull ? nil : item.value
            object[item.section] = section
        }
        var candidate: AppConfig
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            candidate = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch let DecodingError.typeMismatch(type, context) {
            throw RelayAppCommandError("Invalid value for '\(path(context))': expected \(typeName(type)).")
        } catch let DecodingError.keyNotFound(key, context) {
            throw RelayAppCommandError("'\(path(context, key))' cannot be cleared.")
        } catch let DecodingError.valueNotFound(type, context) {
            throw RelayAppCommandError("Invalid value for '\(path(context))': expected \(typeName(type)).")
        } catch let DecodingError.dataCorrupted(context) {
            throw RelayAppCommandError("Invalid value for '\(path(context))'.")
        } catch {
            throw RelayAppCommandError("Invalid settings: \(error.localizedDescription)")
        }

        if requested.contains(where: { $0.section == "general" }) {
            candidate.general.normalize(providerWasExplicit: true, orchestratorEffortWasExplicit: true)
        }
        let effective = json(candidate)
        for item in requested where !(item.value is NSNull) {
            let actual = (effective[item.section] as? [String: Any])?[item.key]
            guard let actual, (actual as AnyObject).isEqual(item.value) else {
                throw RelayAppCommandError(
                    "'\(item.section).\(item.key)' cannot be \(describe(item.value)) with these settings; "
                        + "Relay Runner would use \(describe(actual)). Check get_settings for the provider and model in effect."
                )
            }
        }

        let before = json(current)
        var changed: [String] = []
        for section in fields.keys.sorted() {
            for key in fields[section, default: []].sorted() {
                let old = (before[section] as? [String: Any])?[key]
                let new = (effective[section] as? [String: Any])?[key]
                if !same(old, new) { changed.append("\(section).\(key)") }
            }
        }
        return (candidate, changed)
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }

    private static func path(_ context: DecodingError.Context, _ key: CodingKey? = nil) -> String {
        (context.codingPath + (key.map { [$0] } ?? [])).map(\.stringValue).joined(separator: ".")
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is Bool.Type: return "true or false"
        case is Double.Type, is Int.Type: return "a number"
        case is String.Type: return "a string"
        default: return String(describing: type)
        }
    }

    private static func describe(_ value: Any?) -> String {
        guard let value else { return "nothing" }
        if let string = value as? String { return "'\(string)'" }
        return "\(value)"
    }
}
