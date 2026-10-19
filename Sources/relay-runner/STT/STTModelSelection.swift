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

/// OS-aware default and one-time Phonon migration policy. Mirrored by
/// `services/config.py` (`PHONON_DEFAULT_ACTIVE`, `default_stt_model`,
/// `stt_migration_target`); keep both in step.
enum STTModelPolicy {
    /// RR-416 activation point (mirrors `PHONON_DEFAULT_ACTIVE`). When true,
    /// fresh macOS 15+ installs use Phonon and implicit v2 users migrate once;
    /// when false, Parakeet v2 stays the default and Phonon is only a choice.
    static let phononDefaultActive = true

    /// Pre-Parakeet Whisper identifiers and their persisted replacements.
    static let legacyWhisperAliases: [String: STTModel] = [
        "tiny.en": .parakeetV2, "base.en": .parakeetV2,
        "small.en": .parakeetV2, "medium.en": .parakeetV2,
        "large": .parakeetV3, "large-v3": .parakeetV3,
    ]

    static func isSupported(_ model: STTModel, operatingSystem: OperatingSystemVersion) -> Bool {
        operatingSystem.majorVersion >= model.minimumMacOSMajorVersion
    }

    /// Model a fresh install persists: Phonon on macOS 15+ once active,
    /// otherwise Parakeet v2 (always on macOS 14).
    static func defaultModel(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        phononDefaultActive: Bool = phononDefaultActive
    ) -> STTModel {
        phononDefaultActive && isSupported(.phonon2, operatingSystem: operatingSystem)
            ? .phonon2 : .parakeetV2
    }

    /// Phonon when `stt` is still eligible for the one-time migration: active
    /// policy, supported OS, implicit v2 and no recorded migration decision.
    /// Explicit v3, explicit choices and rollbacks are never re-overridden.
    static func migrationTarget(
        for stt: SttConfig,
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        phononDefaultActive: Bool = phononDefaultActive
    ) -> STTModel? {
        guard phononDefaultActive,
              stt.phonon_migration == SttConfig.PhononMigration.pending,
              stt.model == STTModel.parakeetV2.rawValue,
              isSupported(.phonon2, operatingSystem: operatingSystem)
        else { return nil }
        return .phonon2
    }

    /// An eligible implicit v2 user with no Parakeet v2 cache is set up like a
    /// fresh install: Phonon is adopted before the engine starts, so Parakeet
    /// is never downloaded only to be replaced by the migration.
    static func adoptsPhononWithoutParakeet(
        for stt: SttConfig,
        parakeetV2Cached: Bool,
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        phononDefaultActive: Bool = phononDefaultActive
    ) -> Bool {
        !parakeetV2Cached && migrationTarget(
            for: stt, operatingSystem: operatingSystem, phononDefaultActive: phononDefaultActive
        ) != nil
    }
}
