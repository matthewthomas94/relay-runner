import FluidAudio
import Foundation

/// A note-only local recognizer. It intentionally has no FIFO, provider,
/// messenger, title, summary, or voice-command dependency.
actor FluidAudioMeetingTranscriber: MeetingWindowTranscribing {
    typealias ManagerLoader = @Sendable (
        _ model: STTModel,
        _ progress: @escaping @Sendable (STTPreparationPhase) -> Void
    ) async throws -> AsrManager

    private let modelName: String
    private let loadManager: ManagerLoader
    private var manager: AsrManager?
    /// Bumped by `release()` so a preparation it superseded cannot publish
    /// readiness or install its manager.
    private var generation = 0

    init(
        modelName: String,
        loadManager: @escaping ManagerLoader = { model, progress in
            try await STTModelPreparation.shared.prepareManager(for: model, progress: progress)
        }
    ) {
        self.modelName = modelName
        self.loadManager = loadManager
    }

    func prepare(
        onState: @escaping @Sendable (MeetingLocalModelState) -> Void
    ) async throws {
        if manager != nil {
            onState(.ready(model: modelName))
            return
        }
        let model = try STTModel.resolve(modelName)
        let started = generation
        onState(.checking)
        let prepared = try await loadManager(model) { phase in
            switch phase {
            case .checking:
                onState(.checking)
            case .downloading(let completed, let total, _):
                onState(.downloading(completed: completed, total: total))
            case .compiling(let name):
                onState(.compiling(name))
            case .verifying:
                onState(.verifying)
            }
        }
        guard generation == started, manager == nil, !Task.isCancelled else {
            await prepared.cleanup()
            throw CancellationError()
        }
        manager = prepared
        onState(.ready(model: modelName))
    }

    func transcribe(
        _ request: MeetingTranscriptionRequest
    ) async throws -> MeetingTranscriptionResult {
        guard let manager else { throw ASRError.notInitialized }
        var samples = request.samples
        if samples.count < 16_000 {
            samples.append(contentsOf: repeatElement(0, count: 16_000 - samples.count))
        }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        let tokens = (result.tokenTimings ?? []).map {
            MeetingRecognizedToken(
                text: $0.token,
                startSeconds: $0.startTime,
                endSeconds: $0.endTime,
                confidence: $0.confidence
            )
        }
        return MeetingTranscriptionResult(
            text: result.text,
            tokens: tokens,
            processingMilliseconds: Int((result.processingTime * 1_000).rounded())
        )
    }

    func release() async {
        generation += 1
        guard let manager else { return }
        self.manager = nil
        await manager.cleanup()
    }
}
