import Foundation

/// Everything that determines how a note's recorded audio becomes text. A
/// recovery journal stores it when recording starts, so the pending tail is
/// transcribed by the recognizer that recording began with, even after a
/// settings change or relaunch.
struct MeetingTranscriptionIdentity: Codable, Equatable, Sendable {
    static let fluidAudioBackend = "fluidaudio-tdt"

    let backend: String
    /// `STTModel` raw value.
    let model: String
    let runtimeRevision: String
    /// Immutable model revision; nil for the legacy unpinned Parakeet cache.
    let modelRevision: String?
    let decoding: String

    private enum CodingKeys: String, CodingKey {
        case backend, model, decoding
        case runtimeRevision = "runtime_revision"
        case modelRevision = "model_revision"
    }

    /// The identity this build uses for `model`.
    static func current(
        for model: STTModel,
        configuration: MeetingTranscriptProducer.Configuration = .default
    ) -> MeetingTranscriptionIdentity {
        MeetingTranscriptionIdentity(
            backend: fluidAudioBackend,
            model: model.rawValue,
            runtimeRevision: STTModelPreparation.runtime,
            modelRevision: model == .phonon2 ? STTModelPreparation.phononRevision : nil,
            // Fresh TDT decoder state per window, short windows zero-padded
            // to one second, words owned by onset.
            decoding: "tdt-greedy;fresh-state-per-window;min-pad-ms=1000;"
                + "window-ms=\(configuration.windowMilliseconds);"
                + "overlap-ms=\(configuration.overlapMilliseconds);ownership=onset"
        )
    }

    /// The model this build can replay the identity with exactly, or an error
    /// when the runtime, model revision, decoding or OS support differs.
    func reproducibleModel(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws -> STTModel {
        let model = try STTModel.resolve(self.model, operatingSystem: operatingSystem)
        guard self == Self.current(for: model) else {
            throw MeetingNoteCoordinatorError.transcriptionIdentityUnavailable(model.displayName)
        }
        return model
    }
}
