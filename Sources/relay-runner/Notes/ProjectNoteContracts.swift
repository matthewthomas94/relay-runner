import Foundation

/// Immutable identity allocated by the project artifact writer. Recorder state
/// may change, but these fields must be sent back unchanged on every checkpoint.
struct RelayProjectNoteIdentity: Codable, Equatable, Sendable {
    let noteID: String
    let artifactID: String
    let projectID: String
    let createdAt: String
    let captureStartedAt: String

    private enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case artifactID = "artifact_id"
        case projectID = "project_id"
        case createdAt = "created_at"
        case captureStartedAt = "capture_started_at"
    }
}

struct RelayProjectNoteSegment: Codable, Equatable, Sendable {
    let segmentID: String
    let capturedAt: String
    let text: String
    let startMilliseconds: Int?
    let endMilliseconds: Int?
    let speaker: String?

    init(
        segmentID: String,
        capturedAt: String,
        text: String,
        startMilliseconds: Int? = nil,
        endMilliseconds: Int? = nil,
        speaker: String? = nil
    ) {
        self.segmentID = segmentID
        self.capturedAt = capturedAt
        self.text = text
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case capturedAt = "captured_at"
        case text
        case startMilliseconds = "start_ms"
        case endMilliseconds = "end_ms"
        case speaker
    }
}

enum RelayProjectNoteRecordingState: String, Codable, Sendable {
    case recording
    case paused
    case completed
}

/// Storage accepts only meaningful checkpoints. RR-368 owns recorder timing
/// and must not submit one update for every partial speech callback.
enum RelayProjectNoteCheckpointReason: String, Codable, Sendable {
    case checkpoint
    case pause
    case resume
    case complete
    case manual
}

struct RelayProjectNoteUpdate: Codable, Equatable, Sendable {
    let identity: RelayProjectNoteIdentity
    let capturedAt: String
    let recordingState: RelayProjectNoteRecordingState
    let checkpointReason: RelayProjectNoteCheckpointReason
    let segments: [RelayProjectNoteSegment]
    let captureEndedAt: String?

    private enum CodingKeys: String, CodingKey {
        case identity, segments
        case capturedAt = "captured_at"
        case recordingState = "recording_state"
        case checkpointReason = "checkpoint_reason"
        case captureEndedAt = "capture_ended_at"
    }
}

struct RelayProjectNoteCreateRequest: Codable, Equatable, Sendable {
    let requestID: String
    let createdAt: String
    let captureStartedAt: String
    let capturedAt: String
    let recordingState: RelayProjectNoteRecordingState
    let checkpointReason: RelayProjectNoteCheckpointReason
    let segments: [RelayProjectNoteSegment]
    let captureEndedAt: String?
    let provider: String?

    private enum CodingKeys: String, CodingKey {
        case segments, provider
        case requestID = "request_id"
        case createdAt = "created_at"
        case captureStartedAt = "capture_started_at"
        case capturedAt = "captured_at"
        case recordingState = "recording_state"
        case checkpointReason = "checkpoint_reason"
        case captureEndedAt = "capture_ended_at"
    }
}

struct RelayProjectNoteCheckpointRequest: Codable, Equatable, Sendable {
    let requestID: String
    let update: RelayProjectNoteUpdate
    let provider: String?

    private enum CodingKeys: String, CodingKey {
        case update, provider
        case requestID = "request_id"
    }
}

struct RelayProjectNoteSyncState: Codable, Equatable, Sendable {
    let mode: String
    let state: String
    let recovery: String?
}

struct RelayProjectNoteResponse: Codable, Equatable, Sendable {
    let note: RelayProjectNoteUpdate
    let markdownBase64: String
    let materialized: Bool
    let artifactCommit: String
    let idempotent: Bool
    let sync: RelayProjectNoteSyncState

    var markdown: String? {
        guard let data = Data(base64Encoded: markdownBase64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private enum CodingKeys: String, CodingKey {
        case note, materialized, idempotent, sync
        case markdownBase64 = "markdown_base64"
        case artifactCommit = "artifact_commit"
    }
}

struct RelayProjectNoteCard: Codable, Equatable, Identifiable, Sendable {
    let noteID: String
    let artifactID: String
    let projectID: String
    let createdAt: String
    let updatedAt: String
    let recordingState: RelayProjectNoteRecordingState
    let segmentCount: Int
    let materialized: Bool
    let archivedAt: String?

    var id: String { artifactID }

    private enum CodingKeys: String, CodingKey {
        case materialized
        case noteID = "note_id"
        case artifactID = "artifact_id"
        case projectID = "project_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case recordingState = "recording_state"
        case segmentCount = "segment_count"
        case archivedAt = "archived_at"
    }
}

struct RelayProjectNoteListResponse: Codable, Equatable, Sendable {
    let notes: [RelayProjectNoteCard]
    let artifactCommit: String
    let sync: RelayProjectNoteSyncState

    private enum CodingKeys: String, CodingKey {
        case notes, sync
        case artifactCommit = "artifact_commit"
    }
}
