import Foundation

enum MeetingAudioSourceID: String, Codable, CaseIterable, Sendable {
    case microphone
    case systemAudio = "system_audio"
}

enum MeetingLocalModelState: Equatable, Sendable {
    case notLoaded
    case checking
    case downloading(completed: Int, total: Int)
    case compiling(String)
    case ready(model: String)
    case failed(String)
}

enum MeetingProducerState: String, Codable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case stopped
    case failed
}

enum MeetingCaptureSourceState: String, Codable, Sendable {
    case inactive
    case starting
    case capturing
    case paused
    case unavailable
    case denied
    case interrupted
    case stopped
}

struct MeetingTimingEpoch: Codable, Equatable, Sendable {
    let epochID: String
    let sourceID: MeetingAudioSourceID
    let sequence: Int
    let startSample: Int
    let startMilliseconds: Int
    let sampleRate: Int

    private enum CodingKeys: String, CodingKey {
        case epochID = "epoch_id"
        case sourceID = "source_id"
        case sequence
        case startSample = "start_sample"
        case startMilliseconds = "start_ms"
        case sampleRate = "sample_rate"
    }
}

struct MeetingAcceptedAudioDescriptor: Codable, Equatable, Sendable {
    let chunkID: String
    let sourceID: MeetingAudioSourceID
    let timingEpochID: String
    let sequence: Int
    let startSample: Int
    let endSample: Int
    let startMilliseconds: Int
    let endMilliseconds: Int
    let sampleRate: Int
    let sampleCount: Int

    private enum CodingKeys: String, CodingKey {
        case chunkID = "chunk_id"
        case sourceID = "source_id"
        case timingEpochID = "timing_epoch_id"
        case sequence
        case startSample = "start_sample"
        case endSample = "end_sample"
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case sampleRate = "sample_rate"
        case sampleCount = "sample_count"
    }
}

/// Samples from every capture adapter use the same host-monotonic timebase.
/// The timestamp identifies the beginning of the first sample in the frame.
struct MeetingAudioFrame: Sendable {
    let samples: [Float]
    let presentationTimeNanoseconds: UInt64
    let captureFrameCount: Int

    init(
        samples: [Float],
        presentationTimeNanoseconds: UInt64,
        captureFrameCount: Int = 1
    ) {
        self.samples = samples
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.captureFrameCount = captureFrameCount
    }
}

/// RR-368 persists accepted chunks before this ticket retains them in its
/// bounded ASR window. Audio is deliberately absent from logs and note Markdown.
struct MeetingAcceptedAudio: Sendable {
    let descriptor: MeetingAcceptedAudioDescriptor
    let samples: [Float]
}

struct MeetingRecognizedToken: Equatable, Sendable {
    let text: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let confidence: Float
}

struct MeetingRecognizedWord: Codable, Equatable, Sendable {
    let text: String
    let startMilliseconds: Double
}

struct MeetingTranscriptionRequest: Equatable, Sendable {
    let segmentID: String
    let sourceID: MeetingAudioSourceID
    let timingEpochID: String
    let windowSequence: Int
    let revision: Int
    let contextStartMilliseconds: Int
    let ownedStartMilliseconds: Int
    let ownedEndMilliseconds: Int
    let ownedEndSample: Int
    let isFinal: Bool
    let samples: [Float]
}

struct MeetingTranscriptionResult: Equatable, Sendable {
    let text: String
    let tokens: [MeetingRecognizedToken]
    let processingMilliseconds: Int
}

struct MeetingTranscriptSegmentRevision: Codable, Equatable, Sendable {
    let segmentID: String
    let sourceID: MeetingAudioSourceID
    let timingEpochID: String
    let windowSequence: Int
    let revision: Int
    let startMilliseconds: Int
    let endMilliseconds: Int
    let text: String
    let isFinal: Bool
    var recognizedWords: [MeetingRecognizedWord]? = nil

    private enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case sourceID = "source_id"
        case timingEpochID = "timing_epoch_id"
        case windowSequence = "window_sequence"
        case revision
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case text
        case isFinal = "is_final"
        case recognizedWords = "recognized_words"
    }

    func projectNoteSegment(capturedAt: String) -> RelayProjectNoteSegment {
        RelayProjectNoteSegment(
            segmentID: segmentID,
            capturedAt: capturedAt,
            text: text,
            startMilliseconds: startMilliseconds,
            endMilliseconds: endMilliseconds,
            speaker: sourceID.rawValue
        )
    }
}

enum MeetingCaptureIssueCode: String, Codable, Sendable {
    case modelUnavailable = "model_unavailable"
    case permissionDenied = "permission_denied"
    case sourceUnavailable = "source_unavailable"
    case sourceInterrupted = "source_interrupted"
    case formatChanged = "format_changed"
    case transcriptionFailed = "transcription_failed"
    case backpressureExceeded = "backpressure_exceeded"
    case checkpointFailed = "checkpoint_failed"
}

struct MeetingCaptureIssue: Codable, Equatable, Sendable {
    let code: MeetingCaptureIssueCode
    let sourceID: MeetingAudioSourceID?
    let message: String
    let recoverable: Bool

    private enum CodingKeys: String, CodingKey {
        case code, message, recoverable
        case sourceID = "source_id"
    }
}

struct MeetingProducerMetrics: Codable, Equatable, Sendable {
    var acceptedSamplesBySource: [MeetingAudioSourceID: Int] = [:]
    var acceptedChunkCount = 0
    var processedWindowCount = 0
    var queuedWindowCount = 0
    var maximumQueuedWindowCount = 0
    var droppedAudioFrameCount = 0
    var droppedAudioSampleCount = 0
    var skippedPartialRevisionCount = 0
    var transcriptionFailureCount = 0
    var latestProcessingMilliseconds = 0
    var maximumProcessingMilliseconds = 0
}

/// Stable restart cursor. RR-368 owns the durable audio referenced by
/// `pendingAudio`; the producer owns deterministic IDs and revision cursors.
struct MeetingProducerCheckpoint: Codable, Equatable, Sendable {
    let sessionID: String
    let state: MeetingProducerState
    let timingEpochs: [MeetingTimingEpoch]
    let timelineOriginNanoseconds: UInt64?
    let timelineSampleBySource: [MeetingAudioSourceID: Int]
    let nextWindowSequenceByEpoch: [String: Int]
    let completedWindowSequencesByEpoch: [String: [Int]]
    let emittedRevisionBySegment: [String: Int]
    let finalRevisionBySegment: [String: Int]
    /// Exact ends of completed final tails that extend beyond their owned window.
    /// Optional for recovery journals written before this cursor existed.
    var completedTailEndSampleByEpoch: [String: [Int: Int]]? = nil
    /// Text that must survive a crash after final-window completion but before
    /// the coordinator has published the corresponding segment.
    var durableRevisions: [MeetingTranscriptSegmentRevision]?
    let pendingAudio: [MeetingAcceptedAudioDescriptor]
    let metrics: MeetingProducerMetrics

    private enum CodingKeys: String, CodingKey {
        case state, metrics
        case sessionID = "session_id"
        case timingEpochs = "timing_epochs"
        case timelineOriginNanoseconds = "timeline_origin_nanoseconds"
        case timelineSampleBySource = "timeline_sample_by_source"
        case nextWindowSequenceByEpoch = "next_window_sequence_by_epoch"
        case completedWindowSequencesByEpoch = "completed_window_sequences_by_epoch"
        case emittedRevisionBySegment = "emitted_revision_by_segment"
        case finalRevisionBySegment = "final_revision_by_segment"
        case completedTailEndSampleByEpoch = "completed_tail_end_sample_by_epoch"
        case durableRevisions = "durable_revisions"
        case pendingAudio = "pending_audio"
    }
}

struct MeetingProducerFinalBoundary: Codable, Equatable, Sendable {
    let sessionID: String
    let timingEpochs: [MeetingTimingEpoch]
    let finalSegmentRevisionByID: [String: Int]
    let metrics: MeetingProducerMetrics

    private enum CodingKeys: String, CodingKey {
        case metrics
        case sessionID = "session_id"
        case timingEpochs = "timing_epochs"
        case finalSegmentRevisionByID = "final_segment_revision_by_id"
    }
}

enum MeetingProducerEvent: Equatable, Sendable {
    case state(MeetingProducerState)
    case model(MeetingLocalModelState)
    case source(MeetingAudioSourceID, MeetingCaptureSourceState)
    case epoch(MeetingTimingEpoch)
    case revision(MeetingTranscriptSegmentRevision)
    case issue(MeetingCaptureIssue)
    case finalBoundary(MeetingProducerFinalBoundary)
}

protocol MeetingWindowTranscribing: Sendable {
    func prepare(onState: @escaping @Sendable (MeetingLocalModelState) -> Void) async throws
    func transcribe(_ request: MeetingTranscriptionRequest) async throws -> MeetingTranscriptionResult
}

enum MeetingProducerError: LocalizedError, Equatable {
    case invalidState(MeetingProducerState)
    case sourceUnavailable(MeetingAudioSourceID)
    case backpressureExceeded
    case checkpointFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidState(let state):
            return "Meeting capture cannot perform that operation while \(state.rawValue)."
        case .sourceUnavailable(let source):
            return "The \(source.rawValue) capture source is unavailable."
        case .backpressureExceeded:
            return "Local transcription cannot keep up with accepted meeting audio. Capture stopped before silently dropping speech."
        case .checkpointFailed(let message):
            return "Meeting audio could not be checkpointed: \(message)"
        }
    }
}
