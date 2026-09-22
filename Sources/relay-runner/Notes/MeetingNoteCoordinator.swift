import Foundation

enum MeetingNoteCoordinatorPhase: String, Codable, Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
    case saved
    case interrupted
    case error

    var ownsForeground: Bool {
        switch self {
        case .preparing, .recording, .paused, .stopping, .interrupted, .error:
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

struct MeetingNoteCheckpointPolicy: Equatable, Sendable {
    /// Target cadence for publishing final transcript revisions while speech continues.
    /// Writer latency or outage may extend canonical publication, while the
    /// zero-unpersisted-audio contract keeps that tail locally replayable.
    let artifactIntervalSeconds: Int
    /// Accepted audio is written before the producer acknowledges its ingest call.
    let maximumUnpersistedAcceptedAudioMilliseconds: Int
    let recoveryAudioBudgetBytes: Int

    var maximumRecoveryAudioSecondsAtTwoSources: Int {
        recoveryAudioBudgetBytes / (16_000 * MemoryLayout<Float>.size * 2)
    }

    var maximumRecoveryAudioSecondsAtOneSource: Int {
        recoveryAudioBudgetBytes / (16_000 * MemoryLayout<Float>.size)
    }

    static let `default` = MeetingNoteCheckpointPolicy(
        artifactIntervalSeconds: 15,
        maximumUnpersistedAcceptedAudioMilliseconds: 0,
        recoveryAudioBudgetBytes: MeetingNoteRecoveryStore.defaultAudioBudgetBytes
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

    var notchPresentation: (status: NotchSessionStatus, label: String?)? {
        switch phase {
        case .recording:
            return (.listening, "Taking notes")
        case .paused:
            return (.paused, "Paused")
        case .preparing, .stopping, .interrupted, .error:
            return (.working, nil)
        case .idle, .saved:
            return nil
        }
    }
}

enum MeetingNoteRecoveryResolution: String, Sendable {
    /// Replay the incomplete accepted tail and remain paused. Microphone capture
    /// resumes only through a later explicit resume action.
    case recoverPaused
    /// Replay the incomplete accepted tail, then publish a completed note.
    case finalize
    /// Complete the last canonical transcript without replaying incomplete audio.
    case discardIncompleteTail
}

struct MeetingNoteRecoveryOffer: Equatable, Sendable {
    let sessionID: String
    let noteID: String?
    let project: MeetingNoteProjectBinding
    let phase: MeetingNoteCoordinatorPhase
    let updatedAt: String
    let pendingAudioChunkCount: Int
}

enum MeetingNoteCoordinatorError: LocalizedError, Equatable {
    case foregroundBusy
    case recoveryNotFound
    case projectIdentityChanged
    case captureUnavailable
    case captureFailed(String)
    case localSaveFailed(String)

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
        case .localSaveFailed(let message):
            return "The note could not be saved locally: \(message)"
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
}

struct OrchestratorMeetingNoteWriter: MeetingNoteArtifactWriting {
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
    private let terminalFailureSink: @Sendable (MeetingCaptureIssue?) -> Void

    init(
        terminalFailureSink: @escaping @Sendable (MeetingCaptureIssue?) -> Void = { _ in }
    ) {
        self.terminalFailureSink = terminalFailureSink
    }

    func append(_ event: MeetingProducerEvent) {
        var terminalIssue: MeetingCaptureIssue?
        var producerFailed = false
        lock.lock()
        events.append(event)
        if case .issue(let issue) = event {
            latestIssue = issue
        } else if case .state(.failed) = event {
            terminalIssue = latestIssue
            producerFailed = true
        }
        lock.unlock()
        if producerFailed {
            terminalFailureSink(terminalIssue)
        }
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

    private struct Runtime {
        let id: UUID
        let capture: any MeetingNoteCaptureControlling
        let events: MeetingNoteEventBuffer
    }

    private let writer: any MeetingNoteArtifactWriting
    private let recoveryStore: any MeetingNoteRecoveryStoring
    private let captureFactory: CaptureFactory
    private let policy: MeetingNoteCheckpointPolicy
    private let now: @Sendable () -> String
    private let automaticCheckpointing: Bool
    private let snapshotSink: SnapshotSink
    private let scopeTokenRefresher: ScopeTokenRefresher?

    private var journal: MeetingNoteRecoveryJournal?
    private var runtime: Runtime?
    private var phase: MeetingNoteCoordinatorPhase = .idle
    private var desiredPaused = false
    private var pauseReconciliationRunning = false
    private var checkpointTask: Task<Void, Never>?
    private var stopTask: Task<MeetingNoteCoordinatorSnapshot, Error>?
    private var captureStatePersistenceTail: Task<Void, Error>?
    private var captureStatePersistenceGeneration = 0
    private var checkpointPublicationActive = false
    private var checkpointPublicationWaiters: [CheckedContinuation<Void, Never>] = []
    private var interruptionTeardownActive = false
    private var interruptionTeardownWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeScopeToken: String?
    private var hasPersistedRecoveryJournal = false

    init(
        writer: any MeetingNoteArtifactWriting,
        recoveryStore: any MeetingNoteRecoveryStoring,
        policy: MeetingNoteCheckpointPolicy = .default,
        automaticCheckpointing: Bool = true,
        now: @escaping @Sendable () -> String = {
            Date().ISO8601Format(.iso8601)
        },
        snapshotSink: @escaping SnapshotSink = { _ in },
        scopeTokenRefresher: ScopeTokenRefresher? = nil,
        captureFactory: @escaping CaptureFactory
    ) {
        self.writer = writer
        self.recoveryStore = recoveryStore
        self.policy = policy
        self.automaticCheckpointing = automaticCheckpointing
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
            scopeTokenRefresher: scopeTokenRefresher
        ) { sessionID, acceptedAudioSink, durableCheckpointSink, eventSink in
            let producer = MeetingTranscriptProducer(
                sessionID: sessionID,
                transcriber: FluidAudioMeetingTranscriber(modelName: modelName),
                acceptedAudioSink: acceptedAudioSink,
                durableCheckpointSink: durableCheckpointSink,
                eventSink: eventSink
            )
            return MeetingNoteCaptureSession(producer: producer)
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

        checkpointTask?.cancel()
        stopTask = nil
        captureStatePersistenceTail = nil
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
            updatedAt: timestamp
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

            let runtimeID = UUID()
            let events = MeetingNoteEventBuffer { [weak self] issue in
                Task {
                    await self?.handleTerminalProducerFailure(
                        sessionID: sessionID,
                        runtimeID: runtimeID,
                        issue: issue
                    )
                }
            }
            let store = recoveryStore
            let capture = captureFactory(
                sessionID,
                { audio in
                    try await store.persistAudio(sessionID: sessionID, audio: audio)
                },
                { checkpoint in
                    try await store.saveProducerCheckpoint(
                        sessionID: sessionID,
                        checkpoint: checkpoint
                    )
                },
                { events.append($0) }
            )
            runtime = Runtime(
                id: runtimeID,
                capture: capture,
                events: events
            )
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
            startCheckpointLoopIfNeeded()
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

    func setCapsLock(isOn: Bool) async {
        guard phase == .recording || phase == .paused || pauseReconciliationRunning else {
            return
        }
        desiredPaused = isOn
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
                try? await markInterrupted(error)
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
                try? await markInterrupted(error)
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

    func checkpointNow() async throws -> MeetingNoteCoordinatorSnapshot {
        guard phase == .recording || phase == .paused else {
            return snapshot()
        }
        _ = try await publishCheckpoint(
            reason: .checkpoint,
            recordingState: phase == .paused ? .paused : .recording,
            captureEndedAt: nil,
            force: false
        )
        return snapshot()
    }

    func stop() async throws -> MeetingNoteCoordinatorSnapshot {
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

    func recoveryOffers() async throws -> [MeetingNoteRecoveryOffer] {
        try await recoveryStore.loadAll().map { journal in
            MeetingNoteRecoveryOffer(
                sessionID: journal.sessionID,
                noteID: journal.identity?.noteID,
                project: journal.project,
                phase: journal.phase,
                updatedAt: journal.updatedAt,
                pendingAudioChunkCount: journal.producerCheckpoint?.pendingAudio.count ?? 0
            )
        }
    }

    func resolveRecovery(
        sessionID: String,
        projectScopeToken: String?,
        resolution: MeetingNoteRecoveryResolution
    ) async throws -> MeetingNoteCoordinatorSnapshot {
        guard phase == .idle || phase == .saved || phase == .interrupted || phase == .error,
              var journal = try await recoveryStore.load(sessionID: sessionID)
        else { throw MeetingNoteCoordinatorError.recoveryNotFound }

        guard runtime == nil else { throw MeetingNoteCoordinatorError.foregroundBusy }
        checkpointTask?.cancel()
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

            let runtimeID = UUID()
            let events = MeetingNoteEventBuffer { [weak self] issue in
                Task {
                    await self?.handleTerminalProducerFailure(
                        sessionID: sessionID,
                        runtimeID: runtimeID,
                        issue: issue
                    )
                }
            }
            let store = recoveryStore
            let capture = captureFactory(
                sessionID,
                { audio in
                    try await store.persistAudio(sessionID: sessionID, audio: audio)
                },
                { checkpoint in
                    try await store.saveProducerCheckpoint(
                        sessionID: sessionID,
                        checkpoint: checkpoint
                    )
                },
                { events.append($0) }
            )
            runtime = Runtime(
                id: runtimeID,
                capture: capture,
                events: events
            )
            try await capture.start(
                initiallyPaused: true,
                resume: journal.producerCheckpoint
            )
            if let checkpoint = journal.producerCheckpoint,
               !checkpoint.pendingAudio.isEmpty {
                let audio = try await recoveryStore.loadAudio(
                    sessionID: sessionID,
                    descriptors: checkpoint.pendingAudio
                )
                try await capture.replayAcceptedAudio(audio)
            }
            journal.producerCheckpoint = await capture.checkpoint()
            if let issue = applyBufferedEvents(to: &journal) {
                throw captureFailure(issue)
            }
            phase = .paused
            journal.phase = .paused
            journal.updatedAt = now()
            self.journal = journal
            try await recoveryStore.save(journal)

            if resolution == .finalize {
                return try await stop()
            }
            _ = try await publishCheckpoint(
                reason: .pause,
                recordingState: .paused,
                captureEndedAt: nil,
                force: true
            )
            desiredPaused = true
            startCheckpointLoopIfNeeded()
            return snapshot()
        } catch {
            try? await markInterrupted(error)
            throw error
        }
    }

    private func pauseCapture() async throws -> Bool {
        guard let runtime else { throw MeetingNoteCoordinatorError.captureUnavailable }
        try await runtime.capture.pause()
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
        checkpointTask?.cancel()
        checkpointTask = nil
        phase = .stopping
        journal.phase = .stopping
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)

        do {
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
            try await recoveryStore.save(journal)
            try await retainPendingAudio(journal)
            guard journal.producerCheckpoint?.pendingAudio.isEmpty == true else {
                throw MeetingNoteCoordinatorError.localSaveFailed(
                    "accepted audio remains pending local transcription"
                )
            }
            _ = try await publishCheckpoint(
                reason: .complete,
                recordingState: .completed,
                captureEndedAt: endedAt,
                force: true
            )
            phase = .saved
            self.journal?.phase = .saved
            self.runtime = nil
            activeScopeToken = nil
            try await recoveryStore.removeSession(sessionID: journal.sessionID)
            hasPersistedRecoveryJournal = false
            return snapshot()
        } catch {
            try? await markInterrupted(error)
            throw error
        }
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
            try await retainPendingAudio(journal)
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
            try await retainPendingAudio(current)
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
            throw MeetingNoteCoordinatorError.localSaveFailed(safeMessage(error))
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

    private func retainPendingAudio(_ journal: MeetingNoteRecoveryJournal) async throws {
        try await recoveryStore.retainCheckpointAudio(sessionID: journal.sessionID)
    }

    private func markInterrupted(_ error: Error) async throws {
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

        checkpointTask?.cancel()
        checkpointTask = nil
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
        try await retainPendingAudio(journal)
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
        let failure = captureFailure(bufferedIssue ?? issue)
        try? await markInterrupted(failure)
        if let journal = self.journal {
            try? await retainPendingAudio(journal)
        }
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
        checkpointTask?.cancel()
        checkpointTask = nil
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
        checkpointTask?.cancel()
        checkpointTask = nil
        stopTask = nil
        runtime = nil
        activeScopeToken = nil
        desiredPaused = false
        phase = .idle
        journal = nil
    }

    private func startCheckpointLoopIfNeeded() {
        guard automaticCheckpointing,
              policy.artifactIntervalSeconds > 0,
              checkpointTask == nil else { return }
        let interval = UInt64(policy.artifactIntervalSeconds) * 1_000_000_000
        checkpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                do {
                    _ = try await self.checkpointNow()
                } catch {
                    if Task.isCancelled { return }
                    if Self.isCancellation(error) { continue }
                    try? await self.markInterrupted(error)
                    return
                }
            }
        }
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
            errorMessage: journal?.lastError
        )
    }

    private func safeMessage(_ error: Error) -> String {
        if let coordinatorError = error as? MeetingNoteCoordinatorError {
            return coordinatorError.localizedDescription
        }
        if let storeError = error as? MeetingNoteRecoveryStoreError {
            return storeError.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return "Local recovery storage is full."
        }
        return String(describing: type(of: error))
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.cancelled.rawValue
    }
}
