import FluidAudio
import Foundation

/// The persisted `[stt] model` identifiers Relay accepts. Ordinary STT and
/// Note Taker both resolve through `resolve(_:operatingSystem:)`, so an
/// unrecognized name is rejected instead of silently falling back to v2.
enum STTModel: String, CaseIterable, Sendable {
    case phonon2 = "phonon-2"
    case parakeetV2 = "parakeet-tdt-v2"
    case parakeetV3 = "parakeet-tdt-v3"

    var asrVersion: AsrModelVersion {
        switch self {
        case .phonon2: return .phonon2
        case .parakeetV2: return .v2
        case .parakeetV3: return .v3
        }
    }

    var displayName: String {
        switch self {
        case .phonon2: return "Phonon 2"
        case .parakeetV2: return "Parakeet v2"
        case .parakeetV3: return "Parakeet v3"
        }
    }

    /// Phonon's compressed encoder uses macOS 15 Core ML ops.
    var minimumMacOSMajorVersion: Int {
        self == .phonon2 ? 15 : 14
    }

    /// Resolves an explicit identifier and OS support. Pure: performs no model
    /// download, cache access or load, so callers can reject before any I/O.
    static func resolve(
        _ name: String,
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws -> STTModel {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let model = STTModel(rawValue: trimmed) else {
            throw STTModelSelectionError.unknownModel(trimmed)
        }
        guard operatingSystem.majorVersion >= model.minimumMacOSMajorVersion else {
            throw STTModelSelectionError.unsupportedOperatingSystem(
                model: model,
                requiredMajorVersion: model.minimumMacOSMajorVersion
            )
        }
        return model
    }
}

enum STTModelSelectionError: LocalizedError, Equatable {
    case unknownModel(String)
    case unsupportedOperatingSystem(model: STTModel, requiredMajorVersion: Int)

    var errorDescription: String? {
        switch self {
        case .unknownModel(let name):
            let choices = STTModel.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unknown speech-to-text model \"\(name)\". Set [stt] model to one of: \(choices)."
        case .unsupportedOperatingSystem(let model, let required):
            return "\(model.displayName) requires macOS \(required) or later. "
                + "Choose parakeet-tdt-v2 or parakeet-tdt-v3 for this Mac."
        }
    }
}
