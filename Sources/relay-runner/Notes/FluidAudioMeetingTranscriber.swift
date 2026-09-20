import FluidAudio
import Foundation

/// A note-only local recognizer. It intentionally has no FIFO, provider,
/// messenger, title, summary, or voice-command dependency.
actor FluidAudioMeetingTranscriber: MeetingWindowTranscribing {
    private let modelName: String
    private let modelVersion: AsrModelVersion
    private var manager: AsrManager?

    init(modelName: String) {
        self.modelName = modelName
        self.modelVersion = modelName.contains("v3") ? .v3 : .v2
    }

    func prepare(
        onState: @escaping @Sendable (MeetingLocalModelState) -> Void
    ) async throws {
        if manager != nil {
            onState(.ready(model: modelName))
            return
        }
        onState(.checking)
        let models = try await AsrModels.downloadAndLoad(version: modelVersion) { progress in
            switch progress.phase {
            case .listing:
                onState(.checking)
            case .downloading(let completed, let total):
                onState(.downloading(completed: completed, total: total))
            case .compiling(let name):
                onState(.compiling(name))
            }
        }
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
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
        let source: AudioSource = request.sourceID == .microphone ? .microphone : .system
        let result = try await manager.transcribe(samples, source: source)
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
}
