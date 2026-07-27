import Foundation

struct CodexModelResolution: Equatable {
    let selectedFamily: String
    let resolvedModel: String
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [String]
    let resolvedEffort: String
}

enum CodexModelResolver {
    enum Error: LocalizedError, Equatable {
        case unavailable(String)
        case invalidCatalogue(String)
        case familyUnavailable(String)
        case unsupportedEffort(model: String, effort: String, supported: [String])

        var errorDescription: String? {
            switch self {
            case .unavailable(let message):
                return message
            case .invalidCatalogue(let message):
                return "Codex model catalogue could not be read: \(message)"
            case .familyUnavailable(let family):
                return "Codex model family '\(family)' is unavailable in the provider catalogue."
            case .unsupportedEffort(let model, let effort, let supported):
                return "Codex model \(model) does not advertise reasoning effort '\(effort)'. Supported efforts: \(supported.joined(separator: ", "))."
            }
        }
    }

    private struct CatalogueModel: Equatable {
        let id: String
        let model: String
        let hidden: Bool
        let defaultReasoningEffort: String
        let supportedReasoningEfforts: [String]
        let inputModalities: [String]

        var launchModel: String { model.isEmpty ? id : model }
        var isTextCompatible: Bool {
            inputModalities.isEmpty || inputModalities.contains("text")
        }
    }

    static func resolve(
        family rawFamily: String,
        effort rawEffort: String = GeneralConfig.defaultReasoningEffort,
        catalogueData: Data
    ) throws -> CodexModelResolution {
        let payload = try JSONSerialization.jsonObject(with: catalogueData)
        guard let models = catalogueModels(from: payload) else {
            throw Error.invalidCatalogue("missing model list")
        }
        let family = GeneralConfig.normalizeCodexFamily(rawFamily)
        let candidates = models
            .filter { !$0.hidden && $0.isTextCompatible && familyAndVersion(for: $0.launchModel)?.family == family }
        guard let resolved = candidates.max(by: {
            versionLess(
                familyAndVersion(for: $0.launchModel)?.version ?? [],
                familyAndVersion(for: $1.launchModel)?.version ?? []
            )
        }) else {
            throw Error.familyUnavailable(family)
        }
        let effort = try resolvedEffort(rawEffort, for: resolved)
        return CodexModelResolution(
            selectedFamily: family,
            resolvedModel: resolved.launchModel,
            defaultReasoningEffort: resolved.defaultReasoningEffort,
            supportedReasoningEfforts: resolved.supportedReasoningEfforts,
            resolvedEffort: effort
        )
    }

    static func resolveViaService(
        family rawFamily: String,
        effort rawEffort: String,
        command: String,
        servicesDir: URL,
        pythonPath: String
    ) throws -> CodexModelResolution {
        let script = servicesDir.appendingPathComponent("codex_model_catalog.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw Error.unavailable("Codex model resolver is missing at \(script.path).")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            script.path,
            "--command", command,
            "--family", GeneralConfig.normalizeCodexFamily(rawFamily),
            "--effort", rawEffort,
        ]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw Error.unavailable("Could not run Codex model resolver with \(pythonPath): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Error.unavailable(message.isEmpty ? "Codex model resolver exited with status \(process.terminationStatus)." : message)
        }
        guard let data = stdout.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidCatalogue("resolver returned invalid JSON")
        }
        return CodexModelResolution(
            selectedFamily: string(object["selectedFamily"], default: GeneralConfig.defaultCodexModelFamily),
            resolvedModel: string(object["resolvedModel"], default: ""),
            defaultReasoningEffort: string(object["defaultReasoningEffort"], default: GeneralConfig.defaultReasoningEffort),
            supportedReasoningEfforts: stringArray(object["supportedReasoningEfforts"]),
            resolvedEffort: string(object["resolvedEffort"], default: GeneralConfig.defaultReasoningEffort)
        )
    }

    private static func catalogueModels(from payload: Any) -> [CatalogueModel]? {
        let rawModels: [Any]?
        if let array = payload as? [Any] {
            rawModels = array
        } else if let dictionary = payload as? [String: Any] {
            rawModels = (dictionary["data"] as? [Any])
                ?? (dictionary["models"] as? [Any])
                ?? (dictionary["items"] as? [Any])
                ?? ((dictionary["result"] as? [String: Any])?["data"] as? [Any])
        } else {
            rawModels = nil
        }
        return rawModels?.compactMap { raw in
            guard let model = raw as? [String: Any] else { return nil }
            let id = string(model["id"], default: string(model["model"], default: ""))
            let launchModel = string(model["model"], default: id)
            guard !id.isEmpty || !launchModel.isEmpty else { return nil }
            let efforts = reasoningEfforts(model["supportedReasoningEfforts"])
            let defaultEffort = string(
                model["defaultReasoningEffort"],
                default: efforts.first ?? GeneralConfig.defaultReasoningEffort
            )
            return CatalogueModel(
                id: id,
                model: launchModel,
                hidden: (model["hidden"] as? Bool) ?? false,
                defaultReasoningEffort: defaultEffort,
                supportedReasoningEfforts: efforts,
                inputModalities: stringArray(model["inputModalities"])
            )
        }
    }

    private static func reasoningEfforts(_ value: Any?) -> [String] {
        guard let rawEfforts = value as? [Any] else { return [] }
        var efforts: [String] = []
        for raw in rawEfforts {
            let effort: String
            if let dictionary = raw as? [String: Any] {
                effort = string(dictionary["reasoningEffort"] ?? dictionary["value"] ?? dictionary["id"], default: "")
            } else {
                effort = string(raw, default: "")
            }
            if !effort.isEmpty && !efforts.contains(effort) {
                efforts.append(effort)
            }
        }
        return efforts
    }

    private static func resolvedEffort(_ rawEffort: String, for model: CatalogueModel) throws -> String {
        let effort = rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if effort.isEmpty || effort == GeneralConfig.defaultReasoningEffort {
            return model.defaultReasoningEffort
        }
        guard model.supportedReasoningEfforts.contains(effort) else {
            throw Error.unsupportedEffort(
                model: model.launchModel,
                effort: effort,
                supported: model.supportedReasoningEfforts
            )
        }
        return effort
    }

    private static func familyAndVersion(for model: String) -> (family: String, version: [Int])? {
        let parts = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "-").map(String.init)
        guard parts.count >= 3,
              parts.first == "gpt",
              let family = parts.last,
              ["sol", "terra", "luna"].contains(family) else { return nil }
        let version = parts[1].split(separator: ".").compactMap { Int($0) }
        return version.isEmpty ? nil : (family, version)
    }

    private static func versionLess(_ left: [Int], _ right: [Int]) -> Bool {
        let count = max(left.count, right.count)
        for index in 0..<count {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs {
                return lhs < rhs
            }
        }
        return false
    }

    private static func string(_ value: Any?, default defaultValue: String) -> String {
        guard let value else { return defaultValue }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func stringArray(_ value: Any?) -> [String] {
        guard let values = value as? [Any] else { return [] }
        return values.map { string($0, default: "") }.filter { !$0.isEmpty }
    }
}
