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
        case .localSaveFailed(let message):
            return "The note could not be saved locally: \(message)"
        }
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

    func append(_ event: MeetingProducerEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
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
    typealias CaptureFactory = @Sendable (
        _ sessionID: String,
        _ acceptedAudioSink: @escaping MeetingTranscriptProducer.AcceptedAudioSink,
        _ durableCheckpointSink: @escaping MeetingTranscriptProducer.DurableCheckpointSink,
        _ eventSink: @escaping MeetingTranscriptProducer.EventSink
    ) -> any MeetingNoteCaptureControlling

    private struct Runtime {
        let capture: any MeetingNoteCaptureControlling
        let events: MeetingNoteEventBuffer
        let scopeToken: String?
    }

    private let writer: any MeetingNoteArtifactWriting
    private let recoveryStore: any MeetingNoteRecoveryStoring
    private let captureFactory: CaptureFactory
    private let policy: MeetingNoteCheckpointPolicy
    private let now: @Sendable () -> String
    private let automaticCheckpointing: Bool

    private var journal: MeetingNoteRecoveryJournal?
    private var runtime: Runtime?
    private var phase: MeetingNoteCoordinatorPhase = .idle
    private var desiredPaused = false
    private var pauseReconciliationRunning = false
    private var checkpointTask: Task<Void, Never>?
    private var stopTask: Task<MeetingNoteCoordinatorSnapshot, Error>?
    private var activeScopeToken: String?

    init(
        writer: any MeetingNoteArtifactWriting,
        recoveryStore: any MeetingNoteRecoveryStoring,
        policy: MeetingNoteCheckpointPolicy = .default,
        automaticCheckpointing: Bool = true,
        now: @escaping @Sendable () -> String = {
            Date().ISO8601Format(.iso8601)
        },
        captureFactory: @escaping CaptureFactory
    ) {
        self.writer = writer
        self.recoveryStore = recoveryStore
        self.policy = policy
        self.automaticCheckpointing = automaticCheckpointing
        self.now = now
        self.captureFactory = captureFactory
    }

    static func live(modelName: String) -> MeetingNoteCoordinator {
        let store = MeetingNoteRecoveryStore()
        return MeetingNoteCoordinator(
            writer: OrchestratorMeetingNoteWriter(),
            recoveryStore: store
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
        guard phase == .idle || phase == .saved else {
            if journal?.project == project { return snapshot() }
            throw MeetingNoteCoordinatorError.foregroundBusy
        }

        checkpointTask?.cancel()
        stopTask = nil
        activeScopeToken = projectScopeToken
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
        try await recoveryStore.save(journal)

        do {
            let created = try await writer.create(
                create,
                repositoryPath: project.repositoryPath,
                projectScopeToken: projectScopeToken
            )
            try validateIdentity(created.note.identity, project: project)
            journal.identity = created.note.identity
            journal.canonicalSegments = created.note.segments
            journal.syncState = created.sync.state
            journal.updatedAt = now()
            self.journal = journal
            try await recoveryStore.save(journal)

            let events = MeetingNoteEventBuffer()
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
                capture: capture,
                events: events,
                scopeToken: projectScopeToken
            )
            try await capture.start(initiallyPaused: initiallyPaused, resume: nil)
            journal.producerCheckpoint = await capture.checkpoint()
            applyBufferedEvents(to: &journal)
            phase = initiallyPaused ? .paused : .recording
            journal.phase = phase
            journal.updatedAt = now()
            self.journal = journal
            try await recoveryStore.save(journal)
            startCheckpointLoopIfNeeded()
            return snapshot()
        } catch {
            try? await markInterrupted(error)
            throw error
        }
    }

    func setCapsLock(isOn: Bool) async {
        guard phase == .recording || phase == .paused || pauseReconciliationRunning else {
            return
        }
        desiredPaused = isOn
        guard !pauseReconciliationRunning else { return }
        pauseReconciliationRunning = true
        defer { pauseReconciliationRunning = false }

        while (phase == .recording && desiredPaused) || (phase == .paused && !desiredPaused) {
            do {
                if phase == .recording {
                    try await pauseCapture()
                } else {
                    try await resumeCapture()
                }
            } catch {
                try? await markInterrupted(error)
                return
            }
        }
    }

    /// Explicit API used after the user chooses recovery. Recovery itself is
    /// always paused and never starts a microphone.
    func resumeRecoveredCapture() async throws -> MeetingNoteCoordinatorSnapshot {
        guard phase == .paused else { throw MeetingNoteCoordinatorError.captureUnavailable }
        desiredPaused = false
        try await resumeCapture()
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

        checkpointTask?.cancel()
        activeScopeToken = projectScopeToken
        runtime = nil
        phase = .interrupted
        journal.phase = .interrupted
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)

        do {
            var canonicalAlreadyCompleted = false
            if journal.identity == nil {
                let created = try await writer.create(
                    journal.createRequest,
                    repositoryPath: journal.project.repositoryPath,
                    projectScopeToken: projectScopeToken
                )
                try validateIdentity(created.note.identity, project: journal.project)
                journal.identity = created.note.identity
                journal.canonicalSegments = created.note.segments
                journal.syncState = created.sync.state
                journal.updatedAt = now()
                self.journal = journal
                try await recoveryStore.save(journal)
            }

            if let pending = journal.pendingUpdate {
                let retried = try await writer.update(
                    pending,
                    repositoryPath: journal.project.repositoryPath,
                    projectScopeToken: projectScopeToken
                )
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
                let canonical = try await writer.fetch(
                    identity.artifactID,
                    repositoryPath: journal.project.repositoryPath,
                    projectScopeToken: projectScopeToken
                )
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
                return snapshot()
            }

            let events = MeetingNoteEventBuffer()
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
                capture: capture,
                events: events,
                scopeToken: projectScopeToken
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
            applyBufferedEvents(to: &journal)
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

    private func pauseCapture() async throws {
        guard let runtime else { throw MeetingNoteCoordinatorError.captureUnavailable }
        try await runtime.capture.pause()
        phase = .paused
        journal?.phase = .paused
        _ = try await publishCheckpoint(
            reason: .pause,
            recordingState: .paused,
            captureEndedAt: nil,
            force: true
        )
    }

    private func resumeCapture() async throws {
        guard let runtime else { throw MeetingNoteCoordinatorError.captureUnavailable }
        try await runtime.capture.resume()
        phase = .recording
        journal?.phase = .recording
        _ = try await publishCheckpoint(
            reason: .resume,
            recordingState: .recording,
            captureEndedAt: nil,
            force: true
        )
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
            _ = try await runtime.capture.stop()
            let endedAt = now()
            journal.producerCheckpoint = await runtime.capture.checkpoint()
            applyBufferedEvents(to: &journal)
            journal.captureEndedAt = endedAt
            journal.updatedAt = endedAt
            self.journal = journal
            try await recoveryStore.save(journal)
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
        guard var journal, let identity = journal.identity else {
            throw MeetingNoteCoordinatorError.localSaveFailed("note identity is unavailable")
        }
        if let runtime {
            journal.producerCheckpoint = await runtime.capture.checkpoint()
            applyBufferedEvents(to: &journal)
        }
        journal.phase = phase
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)

        let finalSegments = segmentsOverride ?? durableSegments(in: journal)
        if !force,
           finalSegments == journal.canonicalSegments,
           journal.pendingUpdate == nil {
            try await retainPendingAudio(journal)
            return snapshot()
        }

        let request: RelayProjectNoteCheckpointRequest
        if let pending = journal.pendingUpdate {
            request = pending
        } else {
            let update = RelayProjectNoteUpdate(
                identity: identity,
                capturedAt: now(),
                recordingState: recordingState,
                checkpointReason: reason,
                segments: finalSegments,
                captureEndedAt: captureEndedAt
            )
            request = RelayProjectNoteCheckpointRequest(
                requestID: "note-\(journal.sessionID)-checkpoint-\(journal.nextCheckpointSequence)",
                update: update,
                provider: journal.project.provider
            )
            journal.pendingUpdate = request
            journal.updatedAt = now()
            self.journal = journal
            try await recoveryStore.save(journal)
        }

        do {
            let response = try await writer.update(
                request,
                repositoryPath: journal.project.repositoryPath,
                projectScopeToken: runtime?.scopeToken ?? activeScopeToken
            )
            try validateIdentity(response.note.identity, project: journal.project)
            journal.canonicalSegments = response.note.segments
            journal.syncState = response.sync.state
            journal.pendingUpdate = nil
            journal.nextCheckpointSequence += 1
            journal.captureEndedAt = response.note.captureEndedAt
            journal.lastError = nil
            journal.updatedAt = now()
            self.journal = journal
            try await recoveryStore.save(journal)
            try await retainPendingAudio(journal)
            return snapshot()
        } catch {
            journal.lastError = safeMessage(error)
            journal.updatedAt = now()
            self.journal = journal
            try? await recoveryStore.save(journal)
            throw MeetingNoteCoordinatorError.localSaveFailed(safeMessage(error))
        }
    }

    private func applyBufferedEvents(to journal: inout MeetingNoteRecoveryJournal) {
        guard let runtime else { return }
        var revisions = Dictionary(
            uniqueKeysWithValues: journal.revisions.map { ($0.segmentID, $0) }
        )
        for event in runtime.events.drain() {
            guard case .revision(let revision) = event else { continue }
            if let current = revisions[revision.segmentID] {
                if current.isFinal || revision.revision <= current.revision { continue }
            }
            revisions[revision.segmentID] = revision
        }
        journal.revisions = revisions.values.sorted(by: Self.revisionOrder)
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
        checkpointTask?.cancel()
        checkpointTask = nil
        phase = .error
        guard var journal else { return }
        journal.phase = .error
        journal.lastError = safeMessage(error)
        journal.updatedAt = now()
        self.journal = journal
        try await recoveryStore.save(journal)
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
        return String(describing: type(of: error))
    }
}
