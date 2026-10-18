import FluidAudio
import Foundation

// Minimal stand-ins for app types the copied production note sources name but
// the soak never exercises (config persistence, preparation UI, note storage).

struct SttConfig {
    enum PhononMigration { static let pending = "" }
    var model = ""
    var phonon_migration = ""
}

enum STTPreparationPhase: Equatable, Sendable {
    case checking
    case downloading(completed: Int, total: Int, fraction: Double)
    case compiling(String)
    case verifying
}

struct RelayProjectNoteSegment: Codable, Equatable, Sendable {
    let segmentID: String
    let capturedAt: String
    let text: String
    let startMilliseconds: Int?
    let endMilliseconds: Int?
    let speaker: String?
}

final class STTModelPreparation: Sendable {
    static let shared = STTModelPreparation()

    func prepareManager(
        for model: STTModel,
        progress: @escaping @Sendable (STTPreparationPhase) -> Void
    ) async throws -> AsrManager {
        fatalError("the soak injects its own offline loader")
    }
}
