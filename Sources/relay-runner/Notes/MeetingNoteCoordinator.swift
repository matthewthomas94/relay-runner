import Foundation
import OSLog

enum MeetingNoteCoordinatorPhase: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    /// Stop has finalized the recording and local transcription is running.
    case transcribing
    case stopping
    case cancelling
    case saved
    case interrupted
    case error

    var ownsForeground: Bool {
        switch self {
        case .preparing, .recording, .paused, .transcribing, .stopping, .cancelling, .interrupted, .error:
            return true
        case .idle, .saved:
            return false
        }
    }
}

struct MeetingNoteProjectBinding: Codable, Equatable, Sendable {
    let repositoryPath: String
    let expectedProjectID: String?
    let provider: String?

    private enum CodingKeys: String, CodingKey {
        case repositoryPath = "repository_path"
        case expectedProjectID = "expected_project_id"
        case provider
    }
}

/// Audio is recorded while the meeting runs and transcribed once after Stop,
/// so nothing is published between the empty note and the completed one.
struct MeetingNoteCheckpointPolicy: Equatable, Sendable {
    /// Local cap on the compressed recording across both sources.
    let recordingBudgetBytes: Int

    /// Only each source's open recorder segment is unreadable, so a hard crash
    /// loses at most this much audio per source.
    var maximumUnfinalizedAudioSecondsPerSource: Int {
        MeetingCompressedAudioRecorder.maxSegmentSeconds
    }

    var maximumRecordingSecondsAtTwoSources: Int {
        recordingBudgetBytes / (MeetingCompressedAudioRecorder.nominalBytesPerSecond * 2)
    }

    var maximumRecordingSecondsAtOneSource: Int {
        recordingBudgetBytes / MeetingCompressedAudioRecorder.nominalBytesPerSecond
    }

    static let `default` = MeetingNoteCheckpointPolicy(
        recordingBudgetBytes: MeetingCompressedAudioRecorder.defaultBudgetBytes
    )
}

struct MeetingNoteCoordinatorSnapshot: Equatable, Sendable {
    let phase: MeetingNoteCoordinatorPhase
    let noteID: String?
    let project: MeetingNoteProjectBinding?
    let liveHypothesisCount: Int
    let durableSegmentCount: Int
    let syncState: String?
    let errorMessage: String?
    var unhealthySourceIDs: Set<MeetingAudioSourceID> = []
    /// Capture ended on its own while recording or paused, not through Stop.
    var captureInterrupted = false

    var captureStatusMessage: String? {
        guard phase == .recording else { return nil }
        if unhealthySourceIDs.contains(.microphone), unhealthySourceIDs.contains(.systemAudio) {
            return "Audio interrupted"
        }
        if unhealthySourceIDs.contains(.systemAudio) {
            return "Computer audio interrupted"
        }
        if unhealthySourceIDs.contains(.microphone) {
            return "Microphone interrupted"
        }
        return nil
    }

    var notchPresentation: (status: NotchSessionStatus, label: String?, pinsLabel: Bool)? {
        switch phase {
        case .recording:
            // Warnings and failures hold their label at rest; the working
            // status would retract them after its brief reveal.
            if let captureStatusMessage { return (.notWorking, captureStatusMessage, false) }
            return (.listening, "Taking notes", false)
        case .paused:
            return (.paused, "Paused", false)
        case .transcribing:
            return (.working, "Transcribing notes", true)
        case .stopping:
            // A failure tears capture down through the same phase as Stop;
            // it must not look like a save the user asked for.
            if captureInterrupted { return (.notWorking, "Recording interrupted", false) }
            // Saving is work, but its label stays up until the note is saved.
            return (.working, "Saving notes", true)
        case .error:
            return (.notWorking, captureInterrupted ? "Recording interrupted" : "Note save failed", false)
        case .cancelling:
            return errorMessage == nil
                ? (.working, "Cancelling note", true)
                : (.notWorking, "Note cancellation failed", false)
        case .preparing, .interrupted:
            return (.working, nil, false)
        case .idle, .saved:
            return nil
        }
    }
}

enum MeetingNoteRecoveryResolution: String, Sendable {
    /// Reopen the retained recording and remain paused. Microphone capture
    /// resumes only through a later explicit resume action, and a later Stop
    /// transcribes audio from before and after the interruption.
    case recoverPaused
    /// Transcribe the retained recording, then publish a completed note.
    case finalize
    /// Delete the retained recording and complete the last canonical transcript.
    case discardIncompleteTail
}

struct MeetingNoteRecoveryOffer: Equatable, Sendable {
    let sessionID: String
    let noteID: String?
    let project: MeetingNoteProjectBinding
    let phase: MeetingNoteCoordinatorPhase
    let updatedAt: String
    let pendingAudioChunkCount: Int
    /// Recognizer the recording started with; nil for journals from before
    /// transcription identities were recorded.
    var transcriptionIdentity: MeetingTranscriptionIdentity? = nil
    /// The unsaved tail cannot be replayed exactly, so Recover paused and
    /// Finalize need an explicit model from `transcriptionModelChoices`.
    var requiresTranscriptionModelChoice = false
    var transcriptionModelChoices: [STTModel] = []
}

enum MeetingNoteCoordinatorError: LocalizedError, Equatable {
    case foregroundBusy
    case recoveryNotFound
    case projectIdentityChanged
    case captureUnavailable
    case captureFailed(String)
    case localSaveFailed(String)
    /// The note writer rejected or missed a checkpoint. The journal and
    /// recording remain on this Mac.
    case publicationFailed(String)
    /// An unsaved tail without a reproducible transcription identity needs an
    /// explicit model before replay. Nothing was changed.
    case transcriptionModelRequired
    /// This build cannot reproduce the recording's recognizer. The journal and
    /// recording remain on this Mac.
    case transcriptionIdentityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .foregroundBusy:
            return "Another foreground transition already owns note capture."
        case .recoveryNotFound:
            return "The interrupted note recovery record is unavailable."
        case .projectIdentityChanged:
            return "The selected project no longer matches the note's original project."
        case .captureUnavailable:
            return "The note capture runtime is unavailable."
        case .captureFailed(let message):
            return message
        case .localSaveFailed(let message), .publicationFailed(let message):
            return "The note could not be saved locally: \(message)"
        case .transcriptionModelRequired:
            return "Choose a transcription model before replaying this interrupted recording."
        case .transcriptionIdentityUnavailable(let model):
            return "This version of Relay Runner cannot reproduce the \(model) transcription this recording started with. "
                + "The recording is kept; choose a model to replay it."
        }
    }
}

enum MeetingNoteProjectScopeResolver {
    static func renewedToken(
        for project: MeetingNoteProjectBinding,
        registry: ProjectRegistryV2Service
    ) throws -> String {
        guard let expectedProjectID = project.expectedProjectID else {
            throw MeetingNoteCoordinatorError.projectIdentityChanged
        }
        let token = try registry.scopeToken(matching: project.repositoryPath)
        guard token.projectID == expectedProjectID,
              ProgramBoardProjectPath.matches(token.repositoryPath, project.repositoryPath),
              registry.validateScopeToken(token).isValid,
              let encoded = token.encodedValue else {
            throw MeetingNoteCoordinatorError.projectIdentityChanged
        }
        return encoded
    }
}

struct MeetingNoteRecoveryJournal: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let sessionID: String
    let project: MeetingNoteProjectBinding
    let createRequest: RelayProjectNoteCreateRequest
    var identity: RelayProjectNoteIdentity?
    var phase: MeetingNoteCoordinatorPhase
    var producerCheckpoint: MeetingProducerCheckpoint?
    var revisions: [MeetingTranscriptSegmentRevision]
    var canonicalSegments: [RelayProjectNoteSegment]
    var pendingUpdate: RelayProjectNoteCheckpointRequest?
    var nextCheckpointSequence: Int
    var syncState: String?
    var captureEndedAt: String?
    var lastError: String?
    var updatedAt: String
    /// Fixed when recording starts. Optional so older journals still decode.
    var transcriptionIdentity: MeetingTranscriptionIdentity? = nil

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case project, identity, phase, revisions
        case createRequest = "create_request"
        case producerCheckpoint = "producer_checkpoint"
        case canonicalSegments = "canonical_segments"
        case pendingUpdate = "pending_update"
        case nextCheckpointSequence = "next_checkpoint_sequence"
        case syncState = "sync_state"
        case captureEndedAt = "capture_ended_at"
        case lastError = "last_error"
        case updatedAt = "updated_at"
        case transcriptionIdentity = "transcription_identity"
    }
}

protocol MeetingNoteArtifactWriting: Sendable {
    func create(
        _ request: RelayProjectNoteCreateRequest,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws -> RelayProjectNoteResponse
    func update(
        _ request: RelayProjectNoteCheckpointRequest,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws -> RelayProjectNoteResponse
    func fetch(
        _ identity: String,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws -> RelayProjectNoteResponse
    func cancel(
        _ identity: RelayProjectNoteIdentity,
        requestID: String,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws
}

struct OrchestratorMeetingNoteWriter: MeetingNoteArtifactWriting {
    func cancel(
        _ identity: RelayProjectNoteIdentity,
        requestID: String,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws {
        try await OrchestratorClient.cancelProjectNote(
            identity, requestID: requestID,
            repoPath: repositoryPath, projectScopeToken: projectScopeToken
        )
    }

    func create(
        _ request: RelayProjectNoteCreateRequest,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws -> RelayProjectNoteResponse {
        try await OrchestratorClient.createProjectNote(
            request,
            repoPath: repositoryPath,
            projectScopeToken: projectScopeToken
        )
    }

    func update(
        _ request: RelayProjectNoteCheckpointRequest,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws -> RelayProjectNoteResponse {
        try await OrchestratorClient.updateProjectNote(
            request,
            repoPath: repositoryPath,
            projectScopeToken: projectScopeToken
        )
    }

    func fetch(
        _ identity: String,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws -> RelayProjectNoteResponse {
        try await OrchestratorClient.fetchProjectNote(
            identity,
            repoPath: repositoryPath,
            projectScopeToken: projectScopeToken
        )
    }
}

/// Lock-backed because producer events are synchronous and may originate off
/// the coordinator actor. Draining after producer barriers preserves emission
/// order without spawning an unbounded Task for every partial revision.
final class MeetingNoteEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeetingProducerEvent] = []
    private var latestIssue: MeetingCaptureIssue?
    private var sourceStates: [MeetingAudioSourceID: MeetingCaptureSourceState] = [:]
    private let terminalFailureSink: @Sendable (MeetingCaptureIssue?) -> Void
    private let sourceStateSink: @Sendable () -> Void

    init(
        terminalFailureSink: @escaping @Sendable (MeetingCaptureIssue?) -> Void = { _ in },
        sourceStateSink: @escaping @Sendable () -> Void = {}
    ) {
        self.terminalFailureSink = terminalFailureSink
        self.sourceStateSink = sourceStateSink
    }

    func append(_ event: MeetingProducerEvent) {
        var terminalIssue: MeetingCaptureIssue?
        var producerFailed = false
        var sourceChanged = false
        lock.lock()
        if case .source(let source, let state) = event {
            // Capture reports the same state for every chunk. Keep transitions
            // without retaining those duplicates for the entire recording.
            guard sourceStates[source] != state else {
                lock.unlock()
                return
            }
            sourceStates[source] = state
            sourceChanged = true
        }
        events.append(event)
        if case .issue(let issue) = event {
            latestIssue = issue
        } else if case .state(.failed) = event {
            terminalIssue = latestIssue
            producerFailed = true
        }
        lock.unlock()
        if sourceChanged { sourceStateSink() }
        if producerFailed {
            terminalFailureSink(terminalIssue)
        }
    }

    func unhealthySources() -> Set<MeetingAudioSourceID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(sourceStates.compactMap { source, state in
            switch state {
            case .unavailable, .denied, .interrupted: source
            default: nil
            }
        })
    }

    func drain() -> [MeetingProducerEvent] {
        lock.lock()
        defer { lock.unlock() }
        let drained = events
        events.removeAll(keepingCapacity: true)
        return drained
    }
}

actor MeetingNoteCoordinator {
    typealias SnapshotSink = @Sendable (MeetingNoteCoordinatorSnapshot) -> Void
    typealias ScopeTokenRefresher = @MainActor @Sendable (
        MeetingNoteProjectBinding
    ) async throws -> String
    typealias CaptureFactory = @Sendable (
        _ sessionID: String,
        _ acceptedAudioSink: @escaping MeetingTranscriptProducer.AcceptedAudioSink,
        _ durableCheckpointSink: @escaping MeetingTranscriptProducer.DurableCheckpointSink,
        _ eventSink: @escaping MeetingTranscriptProducer.EventSink
    ) -> any MeetingNoteCaptureControlling
    /// Builds the post-stop transcriber for a journal's recorded identity, or
    /// throws when this build cannot reproduce it.
    typealias RecordingTranscriberFactory = @Sendable (
        MeetingTranscriptionIdentity
    ) throws -> any MeetingRecordingTranscribing

    private struct Runtime {
        let id: UUID
        let capture: any MeetingNoteCaptureControlling
        let events: MeetingNoteEventBuffer
        let recorder: MeetingCompressedAudioRecorder
    }

    private let writer: any MeetingNoteArtifactWriting
    private let recoveryStore: any MeetingNoteRecoveryStoring
    private let recordingTranscriber: any MeetingRecordingTranscribing
    /// Identity recorded for new sessions. When set, a journal without one
    /// predates identities and its unsaved tail needs an explicit choice.
    private let transcriptionIdentity: MeetingTranscriptionIdentity?
    private let recordingTranscriberFactory: RecordingTranscriberFactory?
    private let captureFactory: CaptureFactory
    private let policy: MeetingNoteCheckpointPolicy
    private let now: @Sendable () -> String
    private let snapshotSink: SnapshotSink
    private let scopeTokenRefresher: ScopeTokenRefresher?

    private var journal: MeetingNoteRecoveryJournal?
    private var runtime: Runtime?
    private var phase: MeetingNoteCoordinatorPhase = .idle
    private var desiredPaused = false
    private var pauseReconciliationRunning = false
    private var stopTask: Task<MeetingNoteCoordinatorSnapshot, Error>?
    private var cancelTask: Task<MeetingNoteCoordinatorSnapshot, Error>?
    private var captureStatePersistenceTail: Task<Void, Error>?
    private var captureStatePersistenceGeneration = 0
    private var checkpointPublicationActive = false
    private var checkpointPublicationWaiters: [CheckedContinuation<Void, Never>] = []
    private var interruptionTeardownActive = false
    private var interruptionTeardownWaiters: [CheckedContinuation<Void, Never>] = []
    private var captureInterrupted = false
    private var activeScopeToken: String?
    private var hasPersistedRecoveryJournal = false

    /// Interruption causes are logged as codes and counts only, never
    /// transcript text, audio, paths, or capability tokens.
    private static let logger = Logger(subsystem: "com.relayrunner.app", category: "notes")

    init(
        writer: any MeetingNoteArtifactWriting,
        recoveryStore: any MeetingNoteRecoveryStoring,
        policy: MeetingNoteCheckpointPolicy = .default,
        now: @escaping @Sendable () -> String = {
            Date().ISO8601Format(.iso8601)
        },
        snapshotSink: @escaping SnapshotSink = { _ in },
        scopeTokenRefresher: ScopeTokenRefresher? = nil,
        recordingTranscriber: any MeetingRecordingTranscribing,
        transcriptionIdentity: MeetingTranscriptionIdentity? = nil,
        recordingTranscriberFactory: RecordingTranscriberFactory? = nil,
        captureFactory: @escaping CaptureFactory
    ) {
        self.writer = writer
        self.recoveryStore = recoveryStore
        self.recordingTranscriber = recordingTranscriber
        self.transcriptionIdentity = transcriptionIdentity
        self.recordingTranscriberFactory = recordingTranscriberFactory
        self.policy = policy
        self.now = now
        self.snapshotSink = snapshotSink
        self.scopeTokenRefresher = scopeTokenRefresher
        self.captureFactory = captureFactory
    }

    static func live(
        modelName: String,
        snapshotSink: @escaping SnapshotSink = { _ in },
        scopeTokenRefresher: ScopeTokenRefresher? = nil
    ) -> MeetingNoteCoordinator {
        let store = MeetingNoteRecoveryStore()
        return MeetingNoteCoordinator(
            writer: OrchestratorMeetingNoteWriter(),
            recoveryStore: store,
            snapshotSink: snapshotSink,
            scopeTokenRefresher: scopeTokenRefresher,
            recordingTranscriber: MeetingRecordingTranscriber(
                transcriber: FluidAudioMeetingTranscriber(modelName: modelName)
            ),
            transcriptionIdentity: (try? STTModel.resolve(modelName)).map {
                MeetingTranscriptionIdentity.current(for: $0)
            },
            recordingTranscriberFactory: { identity in
                MeetingRecordingTranscriber(
                    transcriber: FluidAudioMeetingTranscriber(
                        modelName: try identity.reproducibleModel().rawValue
                    )
                )
            }
        ) { sessionID, acceptedAudioSink, durableCheckpointSink, eventSink in
            // Recording loads no model; the transcriber runs only after Stop.
            let producer = MeetingTranscriptProducer(
                sessionID: sessionID,
                transcriber: FluidAudioMeetingTranscriber(modelName: modelName),
                transcribesLive: false,
                acceptedAudioSink: acceptedAudioSink,
                durableCheckpointSink: durableCheckpointSink,
                eventSink: eventSink
            )
            // Hand the recorder roughly 100 ms per source instead of every
            // hardware callback. Hold about 30 s of two-source batches so a
            // stall delays recording instead of dropping audio and ending it.
            return MeetingNoteCaptureSession(
                producer: producer,
                maximumPendingFrames: 600,
                minimumBatchSamples: 1_600
            )
        }
    }

    func checkpointPolicy() -> MeetingNoteCheckpointPolicy { policy }

    func snapshot() -> MeetingNoteCoordinatorSnapshot {
        snapshot(from: journal)
    }

    func start(
        project: MeetingNoteProjectBinding,
        projectScopeToken: String?,
        initiallyPaused: Bool
    ) async throws -> MeetingNoteCoordinatorSnapshot {
        if phase == .error, runtime == nil, !hasPersistedRecoveryJournal {
            releaseUndurableStartFailure()
        }
        guard phase == .idle || phase == .saved else {
            if journal?.project == project { return snapshot() }
            throw MeetingNoteCoordinatorError.foregroundBusy
        }

        stopTask = nil
        captureStatePersistenceTail = nil
        captureInterrupted = false
        activeScopeToken = projectScopeToken
        hasPersistedRecoveryJournal = false
        phase = .preparing
        desiredPaused = initiallyPaused
        let timestamp = now()
        let sessionID = UUID().uuidString.lowercased()
        let create = RelayProjectNoteCreateRequest(
            requestID: "note-create-\(sessionID)",
            createdAt: timestamp,
            captureStartedAt: timestamp,
            capturedAt: timestamp,
            recordingState: initiallyPaused ? .paused : .recording,
            checkpointReason: .checkpoint,
            segments: [],
            captureEndedAt: nil,
            provider: project.provider
        )
        var journal = MeetingNoteRecoveryJournal(
            schemaVersion: MeetingNoteRecoveryJournal.schemaVersion,
            sessionID: sessionID,
            project: project,
            createRequest: create,
            identity: nil,
            phase: .preparing,
            producerCheckpoint: nil,
            revisions: [],
            canonicalSegments: [],
            pendingUpdate: nil,
            nextCheckpointSequence: 1,
            syncState: nil,
            captureEndedAt: nil,
            lastError: nil,
            updatedAt: timestamp,
            transcriptionIdentity: transcriptionIdentity
        )
        self.journal = journal

        do {
            try await recoveryStore.save(journal)
            hasPersistedRecoveryJournal = true
            let created = try await withScopeRenewal(for: project) { scopeToken in
                try await self.writer.create(
                    create,
                    repositoryPath: project.repositoryPath,
                    projectScopeToken: scopeToken
                )
            }
            try validateIdentity(created.note.identity, project: project)
            journal.identity = created.note.identity
            journal.canonicalSegments = created.note.segments
            journal.syncState = created.sync.state
            journal.updatedAt = now()
            self.journal = journal
            try await recoveryStore.save(journal)

            let capture = try await makeRuntime(sessionID: sessionID).capture
            try await capture.start(initiallyPaused: initiallyPaused, resume: nil)
            journal.producerCheckpoint = await capture.checkpoint()
            if let issue = applyBufferedEvents(to: &journal) {
                throw captureFailure(issue)
            }
            phase = initiallyPaused ? .paused : .recording
            journal.phase = phase
            journal.updatedAt = now()
            self.journal = journal
            try await recoveryStore.save(journal)
            return snapshot()
        } catch {
            if !hasPersistedRecoveryJournal,
               let _ = try? await recoveryStore.load(sessionID: sessionID) {
                hasPersistedRecoveryJournal = true
            }
            if hasPersistedRecoveryJournal {
                try? await markInterrupted(error)
            } else {
                markUndurableStartFailed(error, journal: journal)
            }
            throw error
        }
    }

    func togglePause() async {
        guard phase == .recording || phase == .paused else { return }
        desiredPaused.toggle()
        await reconcileDesiredPause()
    }

    func setPaused(_ isPaused: Bool) async {
        guard phase == .recording || phase == .paused || pauseReconciliationRunning else {
            return
        }
        desiredPaused = isPaused
        await reconcileDesiredPause()
    }

    private func reconcileDesiredPause() async {
        let sessionID = journal?.sessionID
        if !pauseReconciliationRunning {
            pauseReconciliationRunning = true
            do {
                while (phase == .recording && desiredPaused)
                    || (phase == .paused && !desiredPaused) {
                    if phase == .recording {
                        guard try await pauseCapture() else { break }
                        enqueueCaptureStateCheckpoint(reason: .pause, recordingState: .paused)
                    } else {
                        guard try await resumeCapture() else { break }
                        enqueueCaptureStateCheckpoint(reason: .resume, recordingState: .recording)
                    }
                }
            } catch {
                pauseReconciliationRunning = false
                if journal?.sessionID == sessionID, phase != .cancelling {
                    try? await markInterrupted(error)
                }
                return
            }
            pauseReconciliationRunning = false
        }

        if let captureStatePersistenceTail {
            let generation = captureStatePersistenceGeneration
            do {
                try await captureStatePersistenceTail.value
                clearCaptureStatePersistenceTail(ifGeneration: generation)
            } catch {
                clearCaptureStatePersistenceTail(ifGeneration: generation)
                if journal?.sessionID == sessionID, phase != .cancelling {
                    try? await markInterrupted(error)
                }
            }
        }
    }

    private func enqueueCaptureStateCheckpoint(
        reason: RelayProjectNoteCheckpointReason,
        recordingState: RelayProjectNoteRecordingState
    ) {
        let predecessor = captureStatePersistenceTail
        captureStatePersistenceGeneration &+= 1
        captureStatePersistenceTail = Task {
            if let predecessor {
                try await predecessor.value
            }
            _ = try await publishCheckpoint(
                reason: reason,
                recordingState: recordingState,
                captureEndedAt: nil,
                force: true
            )
        }
    }

    private func clearCaptureStatePersistenceTail(ifGeneration generation: Int) {
        if captureStatePersistenceGeneration == generation {
            captureStatePersistenceTail = nil
        }
    }

    /// Explicit API used after the user chooses recovery. Recovery itself is
    /// always paused and never starts a microphone.
    func resumeRecoveredCapture() async throws -> MeetingNoteCoordinatorSnapshot {
        guard phase == .paused else { throw MeetingNoteCoordinatorError.captureUnavailable }
        desiredPaused = false
        guard try await resumeCapture() else {
            throw MeetingNoteCoordinatorError.captureUnavailable
        }
        _ = try await publishCheckpoint(
            reason: .resume,
            recordingState: .recording,
            captureEndedAt: nil,
            force: true
        )
        return snapshot()
    }

    func stop() async throws -> MeetingNoteCoordinatorSnapshot {
        guard phase != .cancelling else { throw MeetingNoteCoordinatorError.foregroundBusy }
        if interruptionTeardownActive {
            // A failure is already stopping capture. Let it finish so Stop
            // finalizes from the recovery journal instead of racing it.
            await withCheckedContinuation { continuation in
                interruptionTeardownWaiters.append(continuation)
            }
        }
        if phase == .saved { return snapshot() }
        if phase == .error, runtime == nil, !hasPersistedRecoveryJournal {
            releaseUndurableStartFailure()
            return snapshot()
        }
        if phase == .error,
           runtime == nil,
           hasPersistedRecoveryJournal,
           let sessionID = journal?.sessionID {
            return try await resolveRecovery(
                sessionID: sessionID,
                projectScopeToken: activeScopeToken,
                resolution: .finalize
            )
        }
        if let stopTask { return try await stopTask.value }
        let task = Task { try await self.performStop() }
        stopTask = task
        do {
            let result = try await task.value
            stopTask = nil
            return result
        } catch {
            stopTask = nil
            throw error
        }
    }

    /// Cancel owns teardown separately from Stop: no final transcript or completed
    /// note is ever published. Repeated requests join the same deletion.
    func cancel() async throws -> MeetingNoteCoordinatorSnapshot {
        if let cancelTask { return try await cancelTask.value }
        guard stopTask == nil,
              phase == .recording || phase == .paused || phase == .cancelling,
              journal?.identity != nil else { throw MeetingNoteCoordinatorError.captureUnavailable }
        phase = .cancelling
        journal?.phase = .cancelling
        journal?.lastError = nil
        snapshotSink(snapshot())
        let task = Task { try await self.performCancel() }
        cancelTask = task
        defer { cancelTask = nil }
        do {
            return try await task.value
        } catch {
            // Keep cancellation intent for retry/relaunch; Stop must never turn
            // a failed cancellation into a transcription request.
            journal?.phase = .cancelling
            journal?.lastError = safeMessage(error)
            if let journal { try? await recoveryStore.save(journal) }
            snapshotSink(snapshot())
            throw error
        }
    }

    private func performCancel() async throws -> MeetingNoteCoordinatorSnapshot {
        if let runtime {
            await runtime.capture.quiesceCaptureSources()
            // Close file handles even if the recording itself cannot finalize;
            // its contents will be discarded, not sent to the transcriber.
            try? await runtime.recorder.close()
            self.runtime = nil
        }
        // Remember the discard choice even while an older checkpoint is waiting
        // on the daemon, so a relaunch cannot offer to transcribe this recording.
        if let journal { try await recoveryStore.save(journal) }
        if let captureStatePersistenceTail {
            let generation = captureStatePersistenceGeneration
            _ = try? await captureStatePersistenceTail.value
            clearCaptureStatePersistenceTail(ifGeneration: generation)
        }
        // A pause/resume checkpoint must finish before deleting its draft.
        await acquireCheckpointPublication()
        defer { releaseCheckpointPublication() }
        guard var journal, let identity = journal.identity else {
            throw MeetingNoteCoordinatorError.captureUnavailable
        }
        journal.phase = .cancelling
        journal.pendingUpdate = nil
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)
        try await withScopeRenewal(for: journal.project) { scopeToken in
            try await self.writer.cancel(
                identity, requestID: "note-\(journal.sessionID)-cancel",
                repositoryPath: journal.project.repositoryPath, projectScopeToken: scopeToken
            )
        }
        try await recoveryStore.removeSession(sessionID: journal.sessionID)
        self.journal = nil
        activeScopeToken = nil
        hasPersistedRecoveryJournal = false
        captureInterrupted = false
        phase = .idle
        return snapshot()
    }

    /// Reads journals and recording manifests only; no model, microphone, or
    /// capture starts until the user picks a resolution.
    func recoveryOffers() async throws -> [MeetingNoteRecoveryOffer] {
        var offers: [MeetingNoteRecoveryOffer] = []
        for journal in try await recoveryStore.loadAll() {
            let recorded = (try? await recoveryStore.loadRecording(
                sessionID: journal.sessionID
            ))?.segments.count ?? 0
            let pending = (journal.producerCheckpoint?.pendingAudio.count ?? 0) + recorded
            let requiresChoice = requiresTranscriptionModelChoice(
                journal,
                pendingAudioChunkCount: pending
            )
            offers.append(MeetingNoteRecoveryOffer(
                sessionID: journal.sessionID,
                noteID: journal.identity?.noteID,
                project: journal.project,
                phase: journal.phase,
                updatedAt: journal.updatedAt,
                pendingAudioChunkCount: pending,
                transcriptionIdentity: journal.transcriptionIdentity,
                requiresTranscriptionModelChoice: requiresChoice,
                transcriptionModelChoices: requiresChoice
                    ? STTModel.allCases.filter { (try? STTModel.resolve($0.rawValue)) != nil }
                    : []
            ))
        }
        return offers
    }

    /// Only an unsaved tail is ever replayed; saved text is never re-transcribed.
    private func requiresTranscriptionModelChoice(
        _ journal: MeetingNoteRecoveryJournal,
        pendingAudioChunkCount: Int
    ) -> Bool {
        guard journal.phase != .cancelling, pendingAudioChunkCount > 0 else { return false }
        guard let identity = journal.transcriptionIdentity else {
            return transcriptionIdentity != nil
        }
        guard recordingTranscriberFactory != nil else { return false }
        return (try? identity.reproducibleModel()) == nil
    }

    /// `transcriptionModel` is used only when the offer requires a choice;
    /// otherwise the recording's own identity stays fixed.
    func resolveRecovery(
        sessionID: String,
        projectScopeToken: String?,
        resolution: MeetingNoteRecoveryResolution,
        transcriptionModel: STTModel? = nil
    ) async throws -> MeetingNoteCoordinatorSnapshot {
        guard phase == .idle || phase == .saved || phase == .interrupted || phase == .error,
              var journal = try await recoveryStore.load(sessionID: sessionID)
        else { throw MeetingNoteCoordinatorError.recoveryNotFound }

        guard runtime == nil else { throw MeetingNoteCoordinatorError.foregroundBusy }
        if journal.phase == .cancelling {
            self.journal = journal
            activeScopeToken = projectScopeToken
            hasPersistedRecoveryJournal = true
            phase = .cancelling
            return try await cancel()
        }
        if resolution != .discardIncompleteTail {
            let recorded = (try? await recoveryStore.loadRecording(sessionID: sessionID))?
                .segments.count ?? 0
            let pending = (journal.producerCheckpoint?.pendingAudio.count ?? 0) + recorded
            if requiresTranscriptionModelChoice(journal, pendingAudioChunkCount: pending) {
                guard let transcriptionModel else {
                    throw MeetingNoteCoordinatorError.transcriptionModelRequired
                }
                journal.transcriptionIdentity = MeetingTranscriptionIdentity.current(
                    for: try STTModel.resolve(transcriptionModel.rawValue)
                )
            }
        }
        captureInterrupted = false
        activeScopeToken = projectScopeToken
        hasPersistedRecoveryJournal = true
        phase = .interrupted
        journal.phase = .interrupted
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)

        do {
            var canonicalAlreadyCompleted = false
            if journal.identity == nil {
                let created = try await withScopeRenewal(for: journal.project) { scopeToken in
                    try await self.writer.create(
                        journal.createRequest,
                        repositoryPath: journal.project.repositoryPath,
                        projectScopeToken: scopeToken
                    )
                }
                try validateIdentity(created.note.identity, project: journal.project)
                journal.identity = created.note.identity
                journal.canonicalSegments = created.note.segments
                journal.syncState = created.sync.state
                journal.updatedAt = now()
                self.journal = journal
                try await recoveryStore.save(journal)
            }

            if let pending = journal.pendingUpdate {
                let retried = try await withScopeRenewal(for: journal.project) { scopeToken in
                    try await self.writer.update(
                        pending,
                        repositoryPath: journal.project.repositoryPath,
                        projectScopeToken: scopeToken
                    )
                }
                journal.canonicalSegments = retried.note.segments
                journal.syncState = retried.sync.state
                journal.captureEndedAt = retried.note.captureEndedAt
                canonicalAlreadyCompleted = retried.note.recordingState == .completed
                journal.pendingUpdate = nil
                journal.nextCheckpointSequence += 1
                journal.updatedAt = now()
                self.journal = journal
                try await recoveryStore.save(journal)
            }

            if let identity = journal.identity {
                let canonical = try await withScopeRenewal(for: journal.project) { scopeToken in
                    try await self.writer.fetch(
                        identity.artifactID,
                        repositoryPath: journal.project.repositoryPath,
                        projectScopeToken: scopeToken
                    )
                }
                try validateIdentity(canonical.note.identity, project: journal.project)
                journal.canonicalSegments = canonical.note.segments
                journal.syncState = canonical.sync.state
                journal.captureEndedAt = canonical.note.captureEndedAt
                canonicalAlreadyCompleted = canonicalAlreadyCompleted
                    || canonical.note.recordingState == .completed
                self.journal = journal
                try await recoveryStore.save(journal)
            }

            if canonicalAlreadyCompleted {
                phase = .saved
                journal.phase = .saved
                journal.captureEndedAt = journal.captureEndedAt ?? now()
                self.journal = journal
                runtime = nil
                activeScopeToken = nil
                try await recoveryStore.removeSession(sessionID: sessionID)
                hasPersistedRecoveryJournal = false
                return snapshot()
            }

            if resolution == .discardIncompleteTail {
                journal.revisions.removeAll()
                journal.producerCheckpoint = nil
                self.journal = journal
                try await recoveryStore.removeRecording(sessionID: sessionID)
                _ = try await publishCheckpoint(
                    reason: .complete,
                    recordingState: .completed,
                    captureEndedAt: now(),
                    force: true,
                    segmentsOverride: journal.canonicalSegments
                )
                phase = .saved
                self.journal?.phase = .saved
                runtime = nil
                activeScopeToken = nil
                try await recoveryStore.removeSession(sessionID: sessionID)
                hasPersistedRecoveryJournal = false
                return snapshot()
            }

            if resolution == .finalize {
                return try await transcribeAndComplete(
                    journal,
                    captureEndedAt: journal.captureEndedAt ?? now()
                )
            }

            // Record-only capture checkpoints only when an epoch opens, so a
            // crash leaves the timeline cursor behind the recorded audio. New
            // epochs must start after everything already on disk.
            var checkpoint = journal.producerCheckpoint
            if var timeline = checkpoint?.timelineSampleBySource {
                for segment in try await recoveryStore.loadRecording(sessionID: sessionID).segments {
                    let end = segment.startSample + segment.sampleCount
                    timeline[segment.sourceID] = max(timeline[segment.sourceID] ?? 0, end)
                }
                checkpoint?.timelineSampleBySource = timeline
            }
            let capture = try await makeRuntime(sessionID: sessionID).capture
            try await capture.start(initiallyPaused: true, resume: checkpoint)
            journal.producerCheckpoint = await capture.checkpoint()
            if let issue = applyBufferedEvents(to: &journal) {
                throw captureFailure(issue)
            }
            phase = .paused
            journal.phase = .paused
            journal.updatedAt = now()
            self.journal = journal
            try await recoveryStore.save(journal)
            _ = try await publishCheckpoint(
                reason: .pause,
                recordingState: .paused,
                captureEndedAt: nil,
                force: true
            )
            desiredPaused = true
            return snapshot()
        } catch {
            try? await markInterrupted(error)
            throw error
        }
    }

    private func pauseCapture() async throws -> Bool {
        guard let runtime else { throw MeetingNoteCoordinatorError.captureUnavailable }
        try await runtime.capture.pause()
        try await runtime.recorder.finishAll()
        guard self.runtime?.id == runtime.id, phase == .recording else { return false }
        phase = .paused
        journal?.phase = .paused
        // Capture acknowledgement owns the visible state; persistence is queued separately.
        snapshotSink(snapshot())
        return true
    }

    private func resumeCapture() async throws -> Bool {
        guard let runtime else { throw MeetingNoteCoordinatorError.captureUnavailable }
        try await runtime.capture.resume()
        guard self.runtime?.id == runtime.id, phase == .paused else { return false }
        phase = .recording
        journal?.phase = .recording
        // Capture acknowledgement owns the visible state; persistence is queued separately.
        snapshotSink(snapshot())
        return true
    }

    private func performStop() async throws -> MeetingNoteCoordinatorSnapshot {
        guard let runtime, var journal else {
            throw MeetingNoteCoordinatorError.captureUnavailable
        }
        phase = .stopping
        journal.phase = .stopping
        journal.updatedAt = now()
        self.journal = journal

        do {
            // Close both ingress paths before any queued writer or journal I/O
            // can delay Stop. Accepted callbacks still drain before finalization.
            await runtime.capture.quiesceCaptureSources()
            try await recoveryStore.save(journal)
            if let captureStatePersistenceTail {
                let generation = captureStatePersistenceGeneration
                do {
                    try await captureStatePersistenceTail.value
                    clearCaptureStatePersistenceTail(ifGeneration: generation)
                } catch {
                    clearCaptureStatePersistenceTail(ifGeneration: generation)
                    throw error
                }
                guard let current = self.journal,
                      current.sessionID == journal.sessionID else {
                    throw MeetingNoteCoordinatorError.localSaveFailed(
                        "note recovery session changed"
                    )
                }
                journal = current
            }
            _ = try await runtime.capture.stop()
            let endedAt = now()
            journal.producerCheckpoint = await runtime.capture.checkpoint()
            if let issue = applyBufferedEvents(to: &journal) {
                throw captureFailure(issue)
            }
            journal.captureEndedAt = endedAt
            journal.updatedAt = endedAt
            self.journal = journal
            try await runtime.recorder.close()
            return try await transcribeAndComplete(journal, captureEndedAt: endedAt)
        } catch {
            try? await markInterrupted(error)
            if error as? MeetingProducerError == .backpressureExceeded,
               self.runtime == nil,
               phase == .error {
                return try await resolveRecovery(
                    sessionID: journal.sessionID,
                    projectScopeToken: activeScopeToken,
                    resolution: .finalize
                )
            }
            throw error
        }
    }

    /// Stop's second half: the recording is final, so transcribe it once,
    /// publish the completed note, and only then delete the local audio.
    private func transcribeAndComplete(
        _ journal: MeetingNoteRecoveryJournal,
        captureEndedAt: String
    ) async throws -> MeetingNoteCoordinatorSnapshot {
        var journal = journal
        let recordingTranscriber = try recordingTranscriber(for: journal)
        phase = .transcribing
        journal.phase = .transcribing
        journal.captureEndedAt = captureEndedAt
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)
        snapshotSink(snapshot())

        let checkpoint = journal.producerCheckpoint
        let legacyAudio: [MeetingAcceptedAudio]
        if let checkpoint, !checkpoint.pendingAudio.isEmpty {
            legacyAudio = try await recoveryStore.loadAudio(
                sessionID: journal.sessionID,
                descriptors: checkpoint.pendingAudio
            )
        } else {
            legacyAudio = []
        }
        let reader = MeetingNoteRecordingReader(
            checkpoint: checkpoint,
            legacyAudio: legacyAudio,
            recording: try await recoveryStore.loadRecording(sessionID: journal.sessionID)
        )
        let collector = MeetingNoteRevisionCollector()
        _ = try await recordingTranscriber.transcribe(reader, sessionID: journal.sessionID) { event in
            if case .revision(let revision) = event { collector.append(revision) }
        }

        var revisions = Dictionary(
            uniqueKeysWithValues: journal.revisions.map { ($0.segmentID, $0) }
        )
        for revision in (checkpoint?.durableRevisions ?? []) + collector.values.map(reader.restore) {
            if let current = revisions[revision.segmentID], current.isFinal { continue }
            revisions[revision.segmentID] = revision
        }
        journal.revisions = revisions.values.sorted(by: Self.revisionOrder)
        phase = .stopping
        journal.phase = .stopping
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)
        snapshotSink(snapshot())

        _ = try await publishCheckpoint(
            reason: .complete,
            recordingState: .completed,
            captureEndedAt: captureEndedAt,
            force: true
        )
        phase = .saved
        self.journal?.phase = .saved
        runtime = nil
        activeScopeToken = nil
        try await recoveryStore.removeRecording(sessionID: journal.sessionID)
        try await recoveryStore.removeSession(sessionID: journal.sessionID)
        hasPersistedRecoveryJournal = false
        return snapshot()
    }

    private func recordingTranscriber(
        for journal: MeetingNoteRecoveryJournal
    ) throws -> any MeetingRecordingTranscribing {
        guard let factory = recordingTranscriberFactory,
              let identity = journal.transcriptionIdentity else {
            return recordingTranscriber
        }
        return try factory(identity)
    }

    @discardableResult
    private func publishCheckpoint(
        reason: RelayProjectNoteCheckpointReason,
        recordingState: RelayProjectNoteRecordingState,
        captureEndedAt: String?,
        force: Bool,
        segmentsOverride: [RelayProjectNoteSegment]? = nil
    ) async throws -> MeetingNoteCoordinatorSnapshot {
        await acquireCheckpointPublication()
        defer { releaseCheckpointPublication() }
        try Task.checkCancellation()

        guard var journal, let identity = journal.identity else {
            throw MeetingNoteCoordinatorError.localSaveFailed("note identity is unavailable")
        }
        if let runtime {
            journal.producerCheckpoint = await runtime.capture.checkpoint()
            if let issue = applyBufferedEvents(to: &journal) {
                throw captureFailure(issue)
            }
        }
        journal.phase = phase
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)
        if let runtime {
            await runtime.capture.releasePersistedRevisions(Dictionary(
                journal.revisions.filter(\.isFinal).map { ($0.segmentID, $0.revision) },
                uniquingKeysWith: max
            ))
        }

        var finalSegments = segmentsOverride ?? durableSegments(in: journal)
        if let pending = journal.pendingUpdate {
            let satisfiesRequestedBoundary = checkpointMatchesBoundary(
                pending,
                matches: identity,
                reason: reason,
                recordingState: recordingState,
                segments: finalSegments,
                captureEndedAt: captureEndedAt
            )
            _ = try await submitCheckpoint(pending, sessionID: journal.sessionID)
            if satisfiesRequestedBoundary { return snapshot() }
            guard let current = self.journal, current.identity == identity else {
                throw MeetingNoteCoordinatorError.localSaveFailed("note identity is unavailable")
            }
            journal = current
            finalSegments = segmentsOverride ?? durableSegments(in: journal)
        }

        if !force, finalSegments == journal.canonicalSegments {
            return snapshot()
        }

        let update = RelayProjectNoteUpdate(
            identity: identity,
            capturedAt: now(),
            recordingState: recordingState,
            checkpointReason: reason,
            segments: finalSegments,
            captureEndedAt: captureEndedAt
        )
        let request = RelayProjectNoteCheckpointRequest(
            requestID: "note-\(journal.sessionID)-checkpoint-\(journal.nextCheckpointSequence)",
            update: update,
            provider: journal.project.provider
        )
        journal.pendingUpdate = request
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)
        return try await submitCheckpoint(request, sessionID: journal.sessionID)
    }

    private func submitCheckpoint(
        _ request: RelayProjectNoteCheckpointRequest,
        sessionID: String
    ) async throws -> MeetingNoteCoordinatorSnapshot {
        guard let publicationJournal = journal,
              publicationJournal.sessionID == sessionID else {
            throw MeetingNoteCoordinatorError.localSaveFailed("note recovery session changed")
        }
        do {
            let response = try await withScopeRenewal(for: publicationJournal.project) { scopeToken in
                try await self.writer.update(
                    request,
                    repositoryPath: publicationJournal.project.repositoryPath,
                    projectScopeToken: scopeToken
                )
            }
            guard var current = journal, current.sessionID == sessionID else {
                throw MeetingNoteCoordinatorError.localSaveFailed("note recovery session changed")
            }
            try validateIdentity(response.note.identity, project: current.project)
            current.canonicalSegments = response.note.segments
            current.syncState = response.sync.state
            if current.pendingUpdate?.requestID == request.requestID {
                current.pendingUpdate = nil
                current.nextCheckpointSequence += 1
            }
            if let captureEndedAt = response.note.captureEndedAt {
                current.captureEndedAt = captureEndedAt
            }
            current.lastError = nil
            current.updatedAt = now()
            self.journal = current
            try await recoveryStore.save(current)
            return snapshot()
        } catch {
            if Self.isCancellation(error) {
                throw error
            }
            if var current = journal, current.sessionID == sessionID {
                current.lastError = safeMessage(error)
                current.updatedAt = now()
                self.journal = current
                try? await recoveryStore.save(current)
            }
            throw MeetingNoteCoordinatorError.publicationFailed(safeMessage(error))
        }
    }

    private func checkpointMatchesBoundary(
        _ request: RelayProjectNoteCheckpointRequest,
        matches identity: RelayProjectNoteIdentity,
        reason: RelayProjectNoteCheckpointReason,
        recordingState: RelayProjectNoteRecordingState,
        segments: [RelayProjectNoteSegment],
        captureEndedAt: String?
    ) -> Bool {
        let captureBoundaryMatches = request.update.captureEndedAt == captureEndedAt
            || (recordingState == .completed
                && request.update.captureEndedAt != nil
                && captureEndedAt != nil)
        return request.update.identity == identity
            && request.update.checkpointReason == reason
            && request.update.recordingState == recordingState
            && request.update.segments == segments
            && captureBoundaryMatches
    }

    /// A registry availability refresh may rotate only the scope proof while
    /// the note's immutable project binding remains unchanged. Retry exactly
    /// once, and only for the daemon's explicit stale-scope response.
    private func withScopeRenewal<Value: Sendable>(
        for project: MeetingNoteProjectBinding,
        operation: (String?) async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation(activeScopeToken)
        } catch let error as OrchestratorClientError where error.isStaleProjectScope {
            guard let scopeTokenRefresher else { throw error }
            let refreshed = try await scopeTokenRefresher(project)
            activeScopeToken = refreshed
            return try await operation(refreshed)
        }
    }

    private func acquireCheckpointPublication() async {
        if !checkpointPublicationActive {
            checkpointPublicationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            checkpointPublicationWaiters.append(continuation)
        }
    }

    private func releaseCheckpointPublication() {
        guard !checkpointPublicationWaiters.isEmpty else {
            checkpointPublicationActive = false
            return
        }
        checkpointPublicationWaiters.removeFirst().resume()
    }

    private func applyBufferedEvents(
        to journal: inout MeetingNoteRecoveryJournal
    ) -> MeetingCaptureIssue? {
        guard let runtime else { return nil }
        var revisions = Dictionary(
            uniqueKeysWithValues: journal.revisions.map { ($0.segmentID, $0) }
        )
        for revision in journal.producerCheckpoint?.durableRevisions ?? [] {
            if let current = revisions[revision.segmentID],
               (current.isFinal || revision.revision <= current.revision) { continue }
            revisions[revision.segmentID] = revision
        }
        var latestIssue: MeetingCaptureIssue?
        var producerFailed = false
        for event in runtime.events.drain() {
            switch event {
            case .revision(let revision):
                if let current = revisions[revision.segmentID] {
                    if current.isFinal || revision.revision <= current.revision { continue }
                }
                revisions[revision.segmentID] = revision
            case .issue(let issue):
                latestIssue = issue
            case .state(.failed):
                producerFailed = true
            default:
                continue
            }
        }
        journal.revisions = revisions.values.sorted(by: Self.revisionOrder)
        return producerFailed ? latestIssue : nil
    }

    private func durableSegments(in journal: MeetingNoteRecoveryJournal) -> [RelayProjectNoteSegment] {
        let capturedAt = now()
        return journal.revisions
            .filter(\.isFinal)
            .sorted(by: Self.revisionOrder)
            .map { $0.projectNoteSegment(capturedAt: capturedAt) }
    }

    private static func revisionOrder(
        _ left: MeetingTranscriptSegmentRevision,
        _ right: MeetingTranscriptSegmentRevision
    ) -> Bool {
        if left.startMilliseconds != right.startMilliseconds {
            return left.startMilliseconds < right.startMilliseconds
        }
        if left.sourceID != right.sourceID {
            return left.sourceID.rawValue < right.sourceID.rawValue
        }
        return left.segmentID < right.segmentID
    }

    private func validateIdentity(
        _ identity: RelayProjectNoteIdentity,
        project: MeetingNoteProjectBinding
    ) throws {
        if let expected = project.expectedProjectID,
           expected != identity.projectID {
            throw MeetingNoteCoordinatorError.projectIdentityChanged
        }
        if let current = journal?.identity,
           current != identity {
            throw MeetingNoteCoordinatorError.projectIdentityChanged
        }
    }

    private func markInterrupted(_ error: Error) async throws {
        guard phase != .cancelling else { return }
        if interruptionTeardownActive {
            await withCheckedContinuation { continuation in
                interruptionTeardownWaiters.append(continuation)
            }
            return
        }
        interruptionTeardownActive = true
        defer {
            interruptionTeardownActive = false
            let waiters = interruptionTeardownWaiters
            interruptionTeardownWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        if phase == .recording || phase == .paused {
            captureInterrupted = true
        }
        Self.logger.error(
            "Note capture interrupted: \(Self.diagnosticCode(for: error), privacy: .public) phase=\(self.phase.rawValue, privacy: .public)"
        )
        phase = .stopping
        snapshotSink(snapshot())

        if let activeRuntime = runtime {
            let checkpoint = await activeRuntime.capture.checkpoint()
            switch checkpoint.state {
            case .preparing, .recording, .paused:
                _ = try? await activeRuntime.capture.stop()
            case .failed:
                await activeRuntime.capture.stopCaptureSourcesForInterruption()
            case .idle, .stopping, .stopped:
                break
            }
            // Finalize the open segments so the retained recording stays readable.
            try? await activeRuntime.recorder.close()

            if self.runtime?.id == activeRuntime.id {
                if var current = journal {
                    current.producerCheckpoint = await activeRuntime.capture.checkpoint()
                    _ = applyBufferedEvents(to: &current)
                    self.journal = current
                }
                runtime = nil
            }
        }

        guard var journal else {
            phase = .error
            snapshotSink(snapshot())
            return
        }
        journal.phase = .error
        journal.lastError = safeMessage(error)
        journal.updatedAt = now()
        self.journal = journal
        defer {
            phase = .error
            snapshotSink(snapshot())
        }
        try await recoveryStore.save(journal)
    }

    private func handleTerminalProducerFailure(
        sessionID: String,
        runtimeID: UUID,
        issue: MeetingCaptureIssue?
    ) async {
        guard phase == .preparing || phase == .recording || phase == .paused,
              let runtime,
              runtime.id == runtimeID,
              var journal,
              journal.sessionID == sessionID else { return }

        let checkpoint = await runtime.capture.checkpoint()
        guard phase == .preparing || phase == .recording || phase == .paused,
              self.runtime?.id == runtimeID,
              self.journal?.sessionID == sessionID else { return }
        journal.producerCheckpoint = checkpoint
        let bufferedIssue = applyBufferedEvents(to: &journal)
        self.journal = journal
        let metrics = checkpoint.metrics
        Self.logger.error("""
            Note producer failed: \((bufferedIssue ?? issue)?.code.rawValue ?? "unknown", privacy: .public) \
            accepted_chunks=\(metrics.acceptedChunkCount, privacy: .public) \
            dropped_frames=\(metrics.droppedAudioFrameCount, privacy: .public) \
            max_queued_windows=\(metrics.maximumQueuedWindowCount, privacy: .public) \
            max_processing_ms=\(metrics.maximumProcessingMilliseconds, privacy: .public) \
            transcription_failures=\(metrics.transcriptionFailureCount, privacy: .public)
            """)
        let failure = captureFailure(bufferedIssue ?? issue)
        try? await markInterrupted(failure)
    }

    /// Accepted audio goes only to the session's compressed recorder; producer
    /// checkpoints carry the recording's timing epochs.
    private func makeRuntime(sessionID: String) async throws -> Runtime {
        let recorder = try MeetingCompressedAudioRecorder(
            directory: try await recoveryStore.recordingDirectory(sessionID: sessionID),
            budgetBytes: policy.recordingBudgetBytes
        )
        let runtimeID = UUID()
        let events = makeEventBuffer(sessionID: sessionID, runtimeID: runtimeID)
        let store = recoveryStore
        let capture = captureFactory(
            sessionID,
            { audio in try await recorder.append(audio) },
            { checkpoint in
                try await store.saveProducerCheckpoint(
                    sessionID: sessionID,
                    checkpoint: checkpoint
                )
            },
            { events.append($0) }
        )
        let created = Runtime(id: runtimeID, capture: capture, events: events, recorder: recorder)
        runtime = created
        return created
    }

    private func makeEventBuffer(sessionID: String, runtimeID: UUID) -> MeetingNoteEventBuffer {
        MeetingNoteEventBuffer(
            terminalFailureSink: { [weak self] issue in
                Task {
                    await self?.handleTerminalProducerFailure(
                        sessionID: sessionID,
                        runtimeID: runtimeID,
                        issue: issue
                    )
                }
            },
            sourceStateSink: { [weak self] in
                Task { await self?.publishSourceState(sessionID: sessionID, runtimeID: runtimeID) }
            }
        )
    }

    private func publishSourceState(sessionID: String, runtimeID: UUID) {
        guard let runtime, runtime.id == runtimeID,
              journal?.sessionID == sessionID,
              phase == .recording else { return }
        snapshotSink(snapshot())
    }

    private func captureFailure(_ issue: MeetingCaptureIssue?) -> MeetingNoteCoordinatorError {
        guard let issue else {
            return .captureFailed("Meeting capture stopped unexpectedly. Recovery is available.")
        }
        switch issue.code {
        case .checkpointFailed:
            let lowercased = issue.message.lowercased()
            if lowercased.contains("space")
                || lowercased.contains("volume")
                || lowercased.contains("disk full") {
                return .captureFailed("Local recovery storage is full.")
            }
            return .captureFailed(
                "Meeting audio could not be checkpointed. Recovery is available."
            )
        case .backpressureExceeded:
            return .captureFailed(
                "Meeting capture stopped because local transcription could not keep up. Recovery is available."
            )
        case .modelUnavailable:
            return .captureFailed("The local transcription model became unavailable.")
        case .permissionDenied:
            return .captureFailed("Meeting capture lost audio permission.")
        case .sourceUnavailable, .sourceInterrupted, .formatChanged:
            return .captureFailed("Meeting capture lost its audio source.")
        case .transcriptionFailed:
            return .captureFailed("Local meeting transcription failed. Recovery is available.")
        }
    }

    private func markUndurableStartFailed(
        _ error: Error,
        journal: MeetingNoteRecoveryJournal
    ) {
        runtime = nil
        activeScopeToken = nil
        phase = .error
        var failed = journal
        failed.phase = .error
        failed.lastError = safeMessage(error)
        failed.updatedAt = now()
        self.journal = failed
    }

    private func releaseUndurableStartFailure() {
        stopTask = nil
        runtime = nil
        activeScopeToken = nil
        desiredPaused = false
        captureInterrupted = false
        phase = .idle
        journal = nil
    }

    private func snapshot(from journal: MeetingNoteRecoveryJournal?) -> MeetingNoteCoordinatorSnapshot {
        let live = journal?.revisions.filter { !$0.isFinal }.count ?? 0
        return MeetingNoteCoordinatorSnapshot(
            phase: phase,
            noteID: journal?.identity?.noteID,
            project: journal?.project,
            liveHypothesisCount: live,
            durableSegmentCount: journal?.canonicalSegments.count ?? 0,
            syncState: journal?.syncState,
            errorMessage: journal?.lastError,
            unhealthySourceIDs: runtime?.events.unhealthySources() ?? [],
            captureInterrupted: captureInterrupted
        )
    }

    private func safeMessage(_ error: Error) -> String {
        if let coordinatorError = error as? MeetingNoteCoordinatorError {
            return coordinatorError.localizedDescription
        }
        if let storeError = error as? MeetingNoteRecoveryStoreError {
            return storeError.localizedDescription
        }
        if let recordingError = error as? MeetingCompressedAudioError {
            return recordingError.localizedDescription
        }
        // Underlying transcriber messages are not passed through.
        if let transcriptionError = error as? MeetingRecordingTranscriptionError {
            switch transcriptionError {
            case .modelUnavailable: return "The local transcription model is unavailable."
            case .invalidRecording: return "The meeting recording could not be read."
            case .transcriptionFailed: return "Local transcription failed for the recording."
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return "Local recovery storage is full."
        }
        return String(describing: type(of: error))
    }

    /// A stable, content-free label for logs.
    private static func diagnosticCode(for error: Error) -> String {
        switch error {
        case let error as MeetingNoteCoordinatorError:
            switch error {
            case .foregroundBusy: return "foreground_busy"
            case .recoveryNotFound: return "recovery_not_found"
            case .projectIdentityChanged: return "project_identity_changed"
            case .captureUnavailable: return "capture_unavailable"
            case .captureFailed: return "capture_failed"
            case .localSaveFailed: return "local_save_failed"
            case .publicationFailed: return "publication_failed"
            case .transcriptionModelRequired: return "transcription_model_required"
            case .transcriptionIdentityUnavailable: return "transcription_identity_unavailable"
            }
        case let error as MeetingNoteRecoveryStoreError:
            switch error {
            case .missingAudio: return "recovery_audio_missing"
            case .invalidAudio: return "recovery_audio_invalid"
            }
        case let error as MeetingCompressedAudioError:
            switch error {
            case .budgetExceeded: return "recording_budget_exceeded"
            case .invalidAudio: return "recording_audio_invalid"
            case .recorderClosed: return "recording_closed"
            case .invalidManifest: return "recording_manifest_invalid"
            case .missingSegment: return "recording_segment_missing"
            }
        case let error as MeetingRecordingTranscriptionError:
            switch error {
            case .modelUnavailable: return "transcription_model_unavailable"
            case .invalidRecording: return "recording_invalid"
            case .transcriptionFailed: return "transcription_failed"
            }
        case let error as MeetingProducerError:
            switch error {
            case .backpressureExceeded: return "backpressure_exceeded"
            default: return "producer_error"
            }
        default:
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
                return "disk_full"
            }
            return "\(nsError.domain)#\(nsError.code)"
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.cancelled.rawValue
    }
}

/// Replays a session's audio for the post-Stop batch: Float32 chunks retained by
/// journals from before compressed recording first, then the recording.
private struct MeetingNoteRecordingReader: MeetingRecordedAudioReading {
    let timingEpochs: [MeetingTimingEpoch]
    let totalMilliseconds: Int
    private let legacyChunksBySource: [MeetingAudioSourceID: [MeetingAcceptedAudio]]
    private let recording: MeetingCompressedAudioRecording
    /// Legacy windows the live producer already completed. Their epochs are
    /// rebased past them so the batch reproduces the live segment IDs.
    private let windowOffsetByEpoch: [String: Int]
    private let ownedSamples = MeetingTranscriptProducer.Configuration.default.ownedSamples

    init(
        checkpoint: MeetingProducerCheckpoint?,
        legacyAudio: [MeetingAcceptedAudio],
        recording: MeetingCompressedAudioRecording
    ) {
        let legacyEpochIDs = Set(legacyAudio.map(\.descriptor.timingEpochID))
        var offsets: [String: Int] = [:]
        for epochID in legacyEpochIDs {
            offsets[epochID] = checkpoint?.nextWindowSequenceByEpoch[epochID] ?? 0
        }
        let owned = ownedSamples
        timingEpochs = (checkpoint?.timingEpochs ?? []).map { epoch in
            guard let offset = offsets[epoch.epochID], offset > 0 else { return epoch }
            let startSample = epoch.startSample + offset * owned
            return MeetingTimingEpoch(
                epochID: epoch.epochID,
                sourceID: epoch.sourceID,
                sequence: epoch.sequence,
                startSample: startSample,
                startMilliseconds: startSample * 1_000 / epoch.sampleRate,
                sampleRate: epoch.sampleRate
            )
        }
        windowOffsetByEpoch = offsets
        let sequenceByEpoch = Dictionary(
            (checkpoint?.timingEpochs ?? []).map { ($0.epochID, $0.sequence) },
            uniquingKeysWith: { first, _ in first }
        )
        legacyChunksBySource = Dictionary(grouping: legacyAudio, by: \.descriptor.sourceID)
            .mapValues { chunks in
                chunks.sorted {
                    let left = sequenceByEpoch[$0.descriptor.timingEpochID] ?? 0
                    let right = sequenceByEpoch[$1.descriptor.timingEpochID] ?? 0
                    if left != right { return left < right }
                    return $0.descriptor.sequence < $1.descriptor.sequence
                }
            }
        self.recording = recording
        totalMilliseconds = legacyAudio.reduce(0) {
            $0 + $1.descriptor.sampleCount * 1_000 / $1.descriptor.sampleRate
        } + recording.segments.reduce(0) {
            $0 + $1.sampleCount * 1_000 / MeetingCompressedAudioRecorder.sampleRate
        }
    }

    func chunks(
        for source: MeetingAudioSourceID
    ) -> AsyncThrowingStream<MeetingAcceptedAudio, Error> {
        let cursor = MeetingNoteRecordingCursor(
            legacy: legacyChunksBySource[source] ?? [],
            recorded: recording.chunks(for: source).makeAsyncIterator()
        )
        // The unfolding form pulls one decoded chunk at a time.
        return AsyncThrowingStream { try await cursor.next() }
    }

    /// Maps a rebased epoch's revision back to the live producer's segment ID
    /// and window sequence.
    func restore(_ revision: MeetingTranscriptSegmentRevision) -> MeetingTranscriptSegmentRevision {
        guard let offset = windowOffsetByEpoch[revision.timingEpochID], offset > 0 else {
            return revision
        }
        let prefix = "\(revision.timingEpochID)-S"
        guard revision.segmentID.hasPrefix(prefix),
              let ownedStart = Int(revision.segmentID.dropFirst(prefix.count)) else {
            return revision
        }
        return MeetingTranscriptSegmentRevision(
            segmentID: prefix + String(ownedStart + offset * ownedSamples),
            sourceID: revision.sourceID,
            timingEpochID: revision.timingEpochID,
            windowSequence: revision.windowSequence + offset,
            revision: revision.revision,
            startMilliseconds: revision.startMilliseconds,
            endMilliseconds: revision.endMilliseconds,
            text: revision.text,
            isFinal: revision.isFinal,
            recognizedWords: revision.recognizedWords
        )
    }
}

/// Only the unfolding stream calls `next`, one call at a time.
private final class MeetingNoteRecordingCursor: @unchecked Sendable {
    private var legacy: IndexingIterator<[MeetingAcceptedAudio]>
    private var recorded: MeetingCompressedAudioRecording.Chunks.Iterator

    init(
        legacy: [MeetingAcceptedAudio],
        recorded: MeetingCompressedAudioRecording.Chunks.Iterator
    ) {
        self.legacy = legacy.makeIterator()
        self.recorded = recorded
    }

    func next() async throws -> MeetingAcceptedAudio? {
        if let chunk = legacy.next() { return chunk }
        return try await recorded.next()
    }
}

/// Lock-backed because the batch transcriber delivers events synchronously.
private final class MeetingNoteRevisionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [MeetingTranscriptSegmentRevision] = []

    func append(_ revision: MeetingTranscriptSegmentRevision) {
        lock.lock()
        revisions.append(revision)
        lock.unlock()
    }

    var values: [MeetingTranscriptSegmentRevision] {
        lock.lock()
        defer { lock.unlock() }
        return revisions
    }
}
