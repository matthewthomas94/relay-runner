import Foundation
import XCTest
@testable import relay_runner

final class MeetingNoteCoordinatorTests: XCTestCase {
    func testRecorderPresentationUsesExactOwnedLabelsAndNoStaleListeningState() {
        let recording = snapshot(phase: .recording).notchPresentation
        let paused = snapshot(phase: .paused).notchPresentation

        XCTAssertEqual(recording?.status, .listening)
        XCTAssertEqual(recording?.label, "Taking notes")
        XCTAssertEqual(paused?.status, .paused)
        XCTAssertEqual(paused?.label, "Paused")
        for phase in [
            MeetingNoteCoordinatorPhase.preparing,
            .stopping,
            .interrupted,
            .error,
        ] {
            let presentation = snapshot(phase: phase).notchPresentation
            XCTAssertNotEqual(presentation?.status, .listening)
            XCTAssertNil(presentation?.label)
        }
        XCTAssertNil(snapshot(phase: .saved).notchPresentation)
        XCTAssertEqual(MeetingNoteCheckpointPolicy.default.artifactIntervalSeconds, 15)
        XCTAssertEqual(
            MeetingNoteCheckpointPolicy.default.maximumUnpersistedAcceptedAudioMilliseconds,
            0
        )
        XCTAssertEqual(
            MeetingNoteCheckpointPolicy.default.maximumRecoveryAudioSecondsAtTwoSources,
            2_097
        )
        XCTAssertEqual(
            MeetingNoteCheckpointPolicy.default.maximumRecoveryAudioSecondsAtOneSource,
            4_194
        )
    }

    func testStopDrainsFinalTailPreservesUTF8AndGenuineRepeatedSpeech() async throws {
        let writer = FakeMeetingNoteWriter(syncState: "pending")
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        captures.stopRevisions = [
            revision(id: "microphone-E0-S0", start: 0, text: "Same words — café", final: true),
            revision(id: "microphone-E0-S10", start: 1_000, text: "Same words — café", final: true),
        ]
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)

        let started = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        let saved = try await coordinator.stop()
        let repeated = try await coordinator.stop()

        XCTAssertEqual(started.phase, .recording)
        XCTAssertEqual(saved.phase, .saved)
        XCTAssertEqual(saved.noteID, "RR-N1")
        XCTAssertEqual(saved.durableSegmentCount, 2)
        XCTAssertEqual(saved.syncState, "pending")
        XCTAssertEqual(repeated, saved)
        let updates = await writer.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].update.recordingState, .completed)
        XCTAssertEqual(updates[0].update.checkpointReason, .complete)
        XCTAssertEqual(
            updates[0].update.segments.map(\.text),
            ["Same words — café", "Same words — café"]
        )
        XCTAssertNotNil(updates[0].update.captureEndedAt)
        let capture = try XCTUnwrap(captures.latest())
        let stopCount = await capture.stopCount
        let storeIsEmpty = await store.isEmpty
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(storeIsEmpty)
    }

    func testFirstStopRetriesTransientFinalTranscriptionAndClearsRecovery() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = DurableMeetingNoteCaptureFactory(firstCaptureFailureCount: 1)
        let coordinator = makeDurableCoordinator(
            writer: writer,
            store: store,
            captures: captures
        )
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )

        let saved = try await coordinator.stop()
        let updates = await writer.updates
        let storeIsEmpty = await store.isEmpty
        let capture = try XCTUnwrap(captures.firstCapture)
        let transcriber = try XCTUnwrap(captures.firstTranscriber)

        XCTAssertEqual(saved.phase, .saved)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(transcriber.attemptCount, 2)
        XCTAssertEqual(updates.map(\.update.recordingState), [.completed])
        XCTAssertEqual(updates.first?.update.segments.map(\.text), ["recovered tail"])
        XCTAssertTrue(storeIsEmpty)
    }

    func testStopSupersedesCancelledBackgroundCheckpointWithoutSaveFailure() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let policy = MeetingNoteCheckpointPolicy(
            artifactIntervalSeconds: 1,
            maximumUnpersistedAcceptedAudioMilliseconds: 0,
            recoveryAudioBudgetBytes: MeetingNoteRecoveryStore.defaultAudioBudgetBytes
        )
        let coordinator = makeCoordinator(
            writer: writer,
            store: store,
            captures: captures,
            policy: policy,
            automaticCheckpointing: true
        )
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        let capture = try XCTUnwrap(captures.latest())
        await capture.emitRevision(
            revision(id: "microphone-E0-S0", start: 0, text: "durable words", final: true)
        )
        await writer.suspendNextUpdateUntilCancelled()
        await writer.waitForCancellableUpdate()

        let saved = try await coordinator.stop()
        let attempts = await writer.attemptedRequestIDs
        let updates = await writer.updates
        let storeIsEmpty = await store.isEmpty

        XCTAssertEqual(saved.phase, .saved)
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(attempts[0], attempts[1])
        XCTAssertNotEqual(attempts[1], attempts[2])
        XCTAssertEqual(updates.map(\.update.recordingState), [.recording, .completed])
        XCTAssertEqual(updates.last?.update.segments.map(\.text), ["durable words"])
        XCTAssertTrue(storeIsEmpty)
    }

    func testFailedFinalSaveKeepsRecoveryAndRetryUsesSameRequestID() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        captures.stopRevisions = [
            revision(id: "system-E0-S0", start: 0, text: "durable tail", final: true),
        ]
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        await writer.failNextUpdate()

        do {
            _ = try await coordinator.stop()
            XCTFail("expected the local artifact save to block completion")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("saved locally"))
        }

        let failed = await coordinator.snapshot()
        let offers = try await coordinator.recoveryOffers()
        let failedAttempts = await writer.attemptedRequestIDs
        XCTAssertEqual(failed.phase, .error)
        XCTAssertEqual(offers.count, 1)
        XCTAssertEqual(failedAttempts.count, 1)

        let recovered = try await coordinator.resolveRecovery(
            sessionID: try XCTUnwrap(offers.first?.sessionID),
            projectScopeToken: "scope-original",
            resolution: .finalize
        )

        let attempted = await writer.attemptedRequestIDs
        XCTAssertGreaterThanOrEqual(attempted.count, 2)
        XCTAssertEqual(attempted[0], attempted[1])
        XCTAssertEqual(recovered.phase, .saved)
        let storeIsEmpty = await store.isEmpty
        XCTAssertTrue(storeIsEmpty)
    }

    func testStopDrainsFailedPauseCheckpointBeforePublishingCompletion() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        await writer.failNextUpdate()

        await coordinator.setCapsLock(isOn: true)
        let failedPause = await coordinator.snapshot()
        XCTAssertEqual(failedPause.phase, .error)

        let saved = try await coordinator.stop()
        let attempts = await writer.attemptedRequestIDs
        let updates = await writer.updates
        let storeIsEmpty = await store.isEmpty

        XCTAssertEqual(saved.phase, .saved)
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(attempts[0], attempts[1])
        XCTAssertNotEqual(attempts[1], attempts[2])
        XCTAssertEqual(updates.map(\.update.recordingState), [.paused, .completed])
        XCTAssertEqual(updates.map(\.update.checkpointReason), [.pause, .complete])
        XCTAssertNil(updates[0].update.captureEndedAt)
        XCTAssertNotNil(updates[1].update.captureEndedAt)
        XCTAssertTrue(storeIsEmpty)
    }

    func testFailedResumeCheckpointStopsCaptureBeforeDiscardingRecovery() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: true
        )
        let firstCapture = try XCTUnwrap(captures.latest())
        await writer.failNextUpdate()

        await coordinator.setCapsLock(isOn: false)

        let failed = await coordinator.snapshot()
        let offers = try await coordinator.recoveryOffers()
        let firstStopCount = await firstCapture.stopCount
        let firstIsRecording = await firstCapture.isRecording
        XCTAssertEqual(failed.phase, .error)
        XCTAssertEqual(firstStopCount, 1)
        XCTAssertFalse(firstIsRecording)
        XCTAssertEqual(offers.count, 1)

        let recovered = try await coordinator.resolveRecovery(
            sessionID: try XCTUnwrap(offers.first?.sessionID),
            projectScopeToken: "scope-original",
            resolution: .discardIncompleteTail
        )
        XCTAssertEqual(recovered.phase, .saved)
        XCTAssertEqual(captures.count, 1)

        let restarted = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        let secondCapture = try XCTUnwrap(captures.latest())
        let firstStillRecording = await firstCapture.isRecording
        let secondIsRecording = await secondCapture.isRecording
        XCTAssertEqual(restarted.phase, .recording)
        XCTAssertEqual(captures.count, 2)
        XCTAssertFalse(firstStillRecording)
        XCTAssertTrue(secondIsRecording)
    }

    func testStopSerializesCompletionAfterInFlightPauseCheckpoint() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        await writer.suspendNextUpdate()

        let pauseTask = Task { await coordinator.setCapsLock(isOn: true) }
        await writer.waitForSuspendedUpdate()
        let stopTask = Task { try await coordinator.stop() }
        for _ in 0..<200 {
            if await coordinator.snapshot().phase == .stopping { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let attemptsWhilePauseIsSuspended = await writer.attemptedRequestIDs
        let stopping = await coordinator.snapshot()
        XCTAssertEqual(stopping.phase, .stopping)
        XCTAssertEqual(attemptsWhilePauseIsSuspended.count, 1)

        await writer.resumeSuspendedUpdate()
        await pauseTask.value
        let saved = try await stopTask.value
        let updates = await writer.updates
        let storeIsEmpty = await store.isEmpty

        XCTAssertEqual(saved.phase, .saved)
        XCTAssertEqual(updates.map(\.update.recordingState), [.paused, .completed])
        XCTAssertEqual(updates.map(\.update.checkpointReason), [.pause, .complete])
        XCTAssertNotEqual(updates[0].requestID, updates[1].requestID)
        XCTAssertNil(updates[0].update.captureEndedAt)
        XCTAssertNotNil(updates[1].update.captureEndedAt)
        XCTAssertTrue(storeIsEmpty)
    }

    func testPausePublishesCaptureAcknowledgementBeforeDelayedWriterAndReconcilesRapidResume() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let snapshots = MeetingNoteSnapshotRecorder()
        let coordinator = makeCoordinator(
            writer: writer,
            store: store,
            captures: captures,
            snapshotSink: { snapshots.append($0) }
        )
        let started = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        let capture = try XCTUnwrap(captures.latest())
        await capture.suspendNextPause()
        await writer.suspendNextUpdate()

        let pauseTask = Task { await coordinator.setCapsLock(isOn: true) }
        await capture.waitForSuspendedPause()

        let stillRecording = await coordinator.snapshot()
        XCTAssertEqual(stillRecording.phase, .recording)
        XCTAssertFalse(snapshots.snapshots.contains { $0.phase == .paused })

        await capture.resumeSuspendedPause()
        await writer.waitForSuspendedUpdate()

        let paused = await coordinator.snapshot()
        let captureIsRecording = await capture.isRecording
        let committedWhileDelayed = await writer.updates
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(paused.noteID, started.noteID)
        XCTAssertFalse(captureIsRecording)
        XCTAssertTrue(snapshots.snapshots.contains { $0.phase == .paused })
        XCTAssertTrue(committedWhileDelayed.isEmpty)

        await coordinator.setCapsLock(isOn: false)
        await writer.resumeSuspendedUpdate()
        await pauseTask.value

        let resumed = await coordinator.snapshot()
        let updates = await writer.updates
        let pauseCount = await capture.pauseCount
        let resumeCount = await capture.resumeCount
        XCTAssertEqual(resumed.phase, .recording)
        XCTAssertEqual(resumed.noteID, started.noteID)
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(
            updates.map(\.update.checkpointReason),
            [.pause, .resume]
        )
        XCTAssertEqual(
            snapshots.snapshots.map(\.phase),
            [.paused, .recording]
        )
    }

    func testResumePublishesCaptureAcknowledgementBeforeDelayedWriter() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let snapshots = MeetingNoteSnapshotRecorder()
        let coordinator = makeCoordinator(
            writer: writer,
            store: store,
            captures: captures,
            snapshotSink: { snapshots.append($0) }
        )
        let started = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: true
        )
        let capture = try XCTUnwrap(captures.latest())
        await writer.suspendNextUpdate()

        let resumeTask = Task { await coordinator.setCapsLock(isOn: false) }
        await writer.waitForSuspendedUpdate()

        let resumed = await coordinator.snapshot()
        let captureIsRecording = await capture.isRecording
        let committedWhileDelayed = await writer.updates
        XCTAssertEqual(resumed.phase, .recording)
        XCTAssertEqual(resumed.noteID, started.noteID)
        XCTAssertTrue(captureIsRecording)
        XCTAssertTrue(snapshots.snapshots.contains { $0.phase == .recording })
        XCTAssertTrue(committedWhileDelayed.isEmpty)

        await writer.resumeSuspendedUpdate()
        await resumeTask.value
        let updates = await writer.updates
        XCTAssertEqual(updates.map(\.update.checkpointReason), [.resume])
    }

    func testRemoteSyncFailureDoesNotBlockCompletedLocalSave() async throws {
        let writer = FakeMeetingNoteWriter(syncState: "failure")
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )

        let saved = try await coordinator.stop()
        let storeIsEmpty = await store.isEmpty

        XCTAssertEqual(saved.phase, .saved)
        XCTAssertEqual(saved.syncState, "failure")
        XCTAssertTrue(storeIsEmpty)
    }

    func testBenignSameProjectScopeRefreshRenewsOnceAcrossLiveCheckpoints() async throws {
        let writer = ScopeAwareMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let refreshes = ScopeRefreshRecorder()
        let coordinator = makeCoordinator(
            writer: writer,
            store: store,
            captures: captures,
            scopeTokenRefresher: { project in
                refreshes.record(project)
                return "scope-refreshed"
            }
        )
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        let capture = try XCTUnwrap(captures.latest())
        await capture.emitRevision(
            revision(id: "microphone-E0-S0", start: 0, text: "saved once", final: true)
        )
        await writer.invalidateOriginalScope()

        let checkpointed = try await coordinator.checkpointNow()
        XCTAssertEqual(checkpointed.phase, .recording)
        await coordinator.setCapsLock(isOn: true)
        let paused = await coordinator.snapshot()
        XCTAssertEqual(paused.phase, .paused)
        await coordinator.setCapsLock(isOn: false)
        let resumed = await coordinator.snapshot()
        XCTAssertEqual(resumed.phase, .recording)
        let saved = try await coordinator.stop()
        XCTAssertEqual(saved.phase, .saved)

        let attempts = await writer.attemptedRequestIDs
        let tokens = await writer.attemptedScopeTokens
        let updates = await writer.updates
        XCTAssertEqual(refreshes.projects, [project])
        XCTAssertEqual(tokens, [
            "scope-original",
            "scope-refreshed",
            "scope-refreshed",
            "scope-refreshed",
            "scope-refreshed",
        ])
        XCTAssertEqual(attempts[0], attempts[1], "scope retry must preserve the request ID")
        XCTAssertEqual(
            updates.map(\.update.checkpointReason),
            [.checkpoint, .pause, .resume, .complete]
        )
        XCTAssertEqual(
            updates.map(\.update.recordingState),
            [.recording, .paused, .recording, .completed]
        )
        let savedTexts = await writer.savedSegments.map(\.text)
        XCTAssertEqual(savedTexts, ["saved once"])
    }

    func testRecoveryRenewsStaleScopeAndReconcilesLostCommittedResponseExactlyOnce() async throws {
        let writer = ScopeAwareMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let refreshes = ScopeRefreshRecorder()
        let coordinator = makeCoordinator(
            writer: writer,
            store: store,
            captures: captures,
            scopeTokenRefresher: { project in
                refreshes.record(project)
                return "scope-refreshed"
            }
        )
        _ = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        let capture = try XCTUnwrap(captures.latest())
        await capture.emitRevision(
            revision(id: "microphone-E0-S0", start: 0, text: "committed tail", final: true)
        )
        await writer.loseNextCommittedUpdateResponse()

        do {
            _ = try await coordinator.stop()
            XCTFail("expected the committed response to be lost")
        } catch {
            let failed = await coordinator.snapshot()
            XCTAssertEqual(failed.phase, .error)
        }
        let offers = try await coordinator.recoveryOffers()
        let offer = try XCTUnwrap(offers.first)
        await writer.invalidateOriginalScope()

        let recovered = try await coordinator.resolveRecovery(
            sessionID: offer.sessionID,
            projectScopeToken: "scope-original",
            resolution: .finalize
        )

        let attempts = await writer.attemptedRequestIDs
        let tokens = await writer.attemptedScopeTokens
        XCTAssertEqual(recovered.phase, .saved)
        XCTAssertEqual(Set(attempts).count, 1, "recovery must reuse the pending request ID")
        XCTAssertEqual(tokens, ["scope-original", "scope-original", "scope-refreshed"])
        XCTAssertEqual(refreshes.projects, [project])
        let committedUpdateCount = await writer.updates.count
        let recoveredTexts = await writer.savedSegments.map(\.text)
        let storeIsEmpty = await store.isEmpty
        XCTAssertEqual(committedUpdateCount, 1, "the committed checkpoint stays exactly once")
        XCTAssertEqual(recoveredTexts, ["committed tail"])
        XCTAssertTrue(storeIsEmpty)
        XCTAssertEqual(captures.count, 1, "completed recovery must not create a second capture owner")
    }

    @MainActor
    func testNoteToWorkBlocksOnFailedFinalASRAndRecoveryWritesTailExactlyOnce() async throws {
        for pauseBeforeSwitch in [false, true] {
            let writer = FakeMeetingNoteWriter()
            let store = InMemoryMeetingNoteRecoveryStore()
            let captures = DurableMeetingNoteCaptureFactory()
            let coordinator = makeDurableCoordinator(
                writer: writer,
                store: store,
                captures: captures
            )
            let started = try await coordinator.start(
                project: project,
                projectScopeToken: "scope-original",
                initiallyPaused: false
            )
            let originalNoteID = try XCTUnwrap(started.noteID)
            if pauseBeforeSwitch {
                await coordinator.setCapsLock(isOn: true)
                let paused = await coordinator.snapshot()
                XCTAssertEqual(paused.phase, .paused)
            }

            var launchCount = 0
            do {
                _ = try await AppState.finalizeMeetingNoteBeforeWorkSession(
                    coordinator: coordinator
                ) { _ in
                    launchCount += 1
                    return true
                }
                XCTFail("unresolved accepted audio must block the work session")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("pending local transcription"))
            }

            let failed = await coordinator.snapshot()
            let offers = try await coordinator.recoveryOffers()
            let firstCapture = try XCTUnwrap(captures.firstCapture)
            let failedUpdates = await writer.updates
            XCTAssertEqual(failed.phase, .error)
            XCTAssertEqual(failed.noteID, originalNoteID)
            XCTAssertEqual(failed.project, project)
            XCTAssertEqual(offers.count, 1)
            XCTAssertEqual(offers.first?.noteID, originalNoteID)
            XCTAssertEqual(offers.first?.project, project)
            XCTAssertEqual(offers.first?.pendingAudioChunkCount, 1)
            XCTAssertEqual(firstCapture.stopCount, 1)
            XCTAssertFalse(firstCapture.isRunning)
            XCTAssertEqual(launchCount, 0)
            XCTAssertFalse(failedUpdates.contains { $0.update.recordingState == .completed })

            let recovered = try await coordinator.resolveRecovery(
                sessionID: try XCTUnwrap(offers.first?.sessionID),
                projectScopeToken: "scope-original",
                resolution: .finalize
            )
            let repeated = try await coordinator.stop()
            let completed = await writer.updates.filter {
                $0.update.recordingState == .completed
            }
            let repositories = await writer.repositories
            let storeIsEmpty = await store.isEmpty

            XCTAssertEqual(recovered.phase, .saved)
            XCTAssertEqual(recovered.noteID, originalNoteID)
            XCTAssertEqual(recovered.project, project)
            XCTAssertEqual(repeated, recovered)
            XCTAssertEqual(completed.count, 1)
            XCTAssertEqual(completed.first?.update.segments.map(\.text), ["recovered tail"])
            XCTAssertTrue(repositories.allSatisfy { $0 == project.repositoryPath })
            XCTAssertTrue(storeIsEmpty)
        }
    }

    @MainActor
    func testNoteToWorkLaunchesAfterLocalSaveWhenRemoteSyncRemainsPending() async throws {
        for initiallyPaused in [false, true] {
            let writer = FakeMeetingNoteWriter(syncState: "pending")
            let store = InMemoryMeetingNoteRecoveryStore()
            let captures = FakeMeetingNoteCaptureFactory()
            let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
            _ = try await coordinator.start(
                project: project,
                projectScopeToken: "scope-original",
                initiallyPaused: initiallyPaused
            )
            var launchedDestination: String?

            let launched = try await AppState.finalizeMeetingNoteBeforeWorkSession(
                coordinator: coordinator
            ) { saved in
                XCTAssertEqual(saved.phase, .saved)
                XCTAssertEqual(saved.syncState, "pending")
                launchedDestination = "/tmp/destination-project"
                return true
            }

            let repositories = await writer.repositories
            XCTAssertTrue(launched)
            XCTAssertEqual(launchedDestination, "/tmp/destination-project")
            XCTAssertTrue(repositories.allSatisfy { $0 == project.repositoryPath })
        }
    }

    func testRecoveryReplaysExactPendingAudioAndNeverStartsMicrophoneImplicitly() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        captures.replayRevision = revision(
            id: "microphone-E0-S0",
            start: 0,
            text: "recovered tail",
            final: true
        )
        let sessionID = "interrupted-session"
        let descriptor = audioDescriptor(chunkID: "chunk-1")
        let identity = noteIdentity()
        let timestamp = "2026-09-21T00:00:00Z"
        let create = RelayProjectNoteCreateRequest(
            requestID: "note-create-\(sessionID)",
            createdAt: timestamp,
            captureStartedAt: timestamp,
            capturedAt: timestamp,
            recordingState: .recording,
            checkpointReason: .checkpoint,
            segments: [],
            captureEndedAt: nil,
            provider: "codex"
        )
        let checkpoint = producerCheckpoint(
            sessionID: sessionID,
            state: .recording,
            pendingAudio: [descriptor]
        )
        try await store.save(MeetingNoteRecoveryJournal(
            schemaVersion: MeetingNoteRecoveryJournal.schemaVersion,
            sessionID: sessionID,
            project: project,
            createRequest: create,
            identity: identity,
            phase: .interrupted,
            producerCheckpoint: checkpoint,
            revisions: [],
            canonicalSegments: [],
            pendingUpdate: nil,
            nextCheckpointSequence: 1,
            syncState: "local_only",
            captureEndedAt: nil,
            lastError: nil,
            updatedAt: timestamp
        ))
        await store.persistAudio(
            sessionID: sessionID,
            audio: MeetingAcceptedAudio(descriptor: descriptor, samples: [0.1, 0.2])
        )
        await writer.seed(identity: identity, segments: [])
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)

        let recovered = try await coordinator.resolveRecovery(
            sessionID: sessionID,
            projectScopeToken: "scope-original",
            resolution: .recoverPaused
        )
        let capture = try XCTUnwrap(captures.latest())
        let startInitiallyPaused = await capture.startInitiallyPaused
        let startCount = await capture.startCount
        let resumeCount = await capture.resumeCount
        let replayedChunkIDs = await capture.replayedChunkIDs
        let recoveryUpdates = await writer.updates

        XCTAssertEqual(recovered.phase, .paused)
        XCTAssertEqual(startInitiallyPaused, true)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(resumeCount, 0)
        XCTAssertEqual(replayedChunkIDs, ["chunk-1"])
        XCTAssertEqual(recoveryUpdates.last?.update.segments.map(\.text), ["recovered tail"])

        let resumed = try await coordinator.resumeRecoveredCapture()
        let resumedCount = await capture.resumeCount
        XCTAssertEqual(resumed.phase, .recording)
        XCTAssertEqual(resumedCount, 1)
    }

    @MainActor
    func testWorkSessionWaitsForPendingRecoveryThenFinalizesLatePausedResult() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        captures.replayRevision = revision(
            id: "microphone-E0-S0",
            start: 0,
            text: "recovered tail",
            final: true
        )
        let sessionID = "pending-recovery-session"
        let descriptor = audioDescriptor(chunkID: "pending-recovery-chunk")
        let identity = noteIdentity()
        let timestamp = "2026-09-21T00:00:00Z"
        try await store.save(MeetingNoteRecoveryJournal(
            schemaVersion: MeetingNoteRecoveryJournal.schemaVersion,
            sessionID: sessionID,
            project: project,
            createRequest: RelayProjectNoteCreateRequest(
                requestID: "note-create-\(sessionID)",
                createdAt: timestamp,
                captureStartedAt: timestamp,
                capturedAt: timestamp,
                recordingState: .recording,
                checkpointReason: .checkpoint,
                segments: [],
                captureEndedAt: nil,
                provider: "codex"
            ),
            identity: identity,
            phase: .interrupted,
            producerCheckpoint: producerCheckpoint(
                sessionID: sessionID,
                state: .recording,
                pendingAudio: [descriptor]
            ),
            revisions: [],
            canonicalSegments: [],
            pendingUpdate: nil,
            nextCheckpointSequence: 1,
            syncState: "local_only",
            captureEndedAt: nil,
            lastError: nil,
            updatedAt: timestamp
        ))
        await store.persistAudio(
            sessionID: sessionID,
            audio: MeetingAcceptedAudio(descriptor: descriptor, samples: [0.1, 0.2])
        )
        await writer.seed(identity: identity, segments: [])
        await writer.suspendNextUpdate()
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)

        let recoveryTask = Task {
            try await coordinator.resolveRecovery(
                sessionID: sessionID,
                projectScopeToken: "scope-original",
                resolution: .recoverPaused
            )
        }
        await writer.waitForSuspendedUpdate()
        var launchCount = 0
        var launchedPhase: MeetingNoteCoordinatorPhase?
        let workTask = Task { @MainActor in
            try await AppState.finalizeMeetingNoteBeforeWorkSession(
                pendingRecovery: recoveryTask,
                coordinator: coordinator
            ) { snapshot in
                launchCount += 1
                launchedPhase = snapshot.phase
                return true
            }
        }

        await Task.yield()
        let pending = await coordinator.snapshot()
        XCTAssertEqual(pending.phase, .paused)
        XCTAssertEqual(launchCount, 0)

        await writer.resumeSuspendedUpdate()
        let launched = try await workTask.value
        let recovered = try await recoveryTask.value
        let final = await coordinator.snapshot()
        let capture = try XCTUnwrap(captures.latest())
        let startInitiallyPaused = await capture.startInitiallyPaused
        let resumeCount = await capture.resumeCount
        let stopCount = await capture.stopCount
        let updates = await writer.updates
        let storeIsEmpty = await store.isEmpty

        XCTAssertTrue(launched)
        XCTAssertEqual(recovered.phase, .paused)
        XCTAssertEqual(final.phase, .saved)
        XCTAssertEqual(launchCount, 1)
        XCTAssertEqual(launchedPhase, .saved)
        XCTAssertEqual(startInitiallyPaused, true)
        XCTAssertEqual(resumeCount, 0)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(updates.map(\.update.recordingState), [.paused, .completed])
        XCTAssertEqual(updates.last?.update.segments.map(\.text), ["recovered tail"])
        XCTAssertEqual(updates.filter { $0.update.recordingState == .completed }.count, 1)
        XCTAssertTrue(storeIsEmpty)
    }

    func testRecoveryDoesNotRecreateAlreadyFinalizedCanonicalNote() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let sessionID = "already-finalized"
        let timestamp = "2026-09-21T00:00:00Z"
        await writer.setFetchState(.completed)
        try await store.save(MeetingNoteRecoveryJournal(
            schemaVersion: MeetingNoteRecoveryJournal.schemaVersion,
            sessionID: sessionID,
            project: project,
            createRequest: RelayProjectNoteCreateRequest(
                requestID: "create-already-finalized",
                createdAt: timestamp,
                captureStartedAt: timestamp,
                capturedAt: timestamp,
                recordingState: .recording,
                checkpointReason: .checkpoint,
                segments: [],
                captureEndedAt: nil,
                provider: "codex"
            ),
            identity: noteIdentity(),
            phase: .stopping,
            producerCheckpoint: producerCheckpoint(
                sessionID: sessionID,
                state: .stopping
            ),
            revisions: [],
            canonicalSegments: [],
            pendingUpdate: nil,
            nextCheckpointSequence: 2,
            syncState: "local_only",
            captureEndedAt: nil,
            lastError: nil,
            updatedAt: timestamp
        ))
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)

        let result = try await coordinator.resolveRecovery(
            sessionID: sessionID,
            projectScopeToken: "scope-original",
            resolution: .recoverPaused
        )

        let storeIsEmpty = await store.isEmpty
        XCTAssertEqual(result.phase, .saved)
        XCTAssertNil(captures.latest())
        XCTAssertTrue(storeIsEmpty)
    }

    func testCapsLockChangesAreIdempotentAndKeepOneNoteIdentity() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
        let started = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: true
        )
        let duplicate = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: true
        )
        do {
            _ = try await coordinator.start(
                project: MeetingNoteProjectBinding(
                    repositoryPath: "/tmp/changed-project",
                    expectedProjectID: "project-2",
                    provider: "claude"
                ),
                projectScopeToken: "scope-changed",
                initiallyPaused: false
            )
            XCTFail("an active note must reject a changed project")
        } catch let error as MeetingNoteCoordinatorError {
            XCTAssertEqual(error, .foregroundBusy)
        }

        await coordinator.setCapsLock(isOn: true)
        await coordinator.setCapsLock(isOn: false)
        await coordinator.setCapsLock(isOn: false)
        await coordinator.setCapsLock(isOn: true)
        await coordinator.setCapsLock(isOn: true)
        let paused = await coordinator.snapshot()
        let capture = try XCTUnwrap(captures.latest())
        let resumeCount = await capture.resumeCount
        let pauseCount = await capture.pauseCount
        let createCount = await writer.createCount

        XCTAssertEqual(started.noteID, paused.noteID)
        XCTAssertEqual(duplicate.noteID, started.noteID)
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(createCount, 1)
    }

    func testDelayedCaptureStartupFailurePreservesOriginalProjectAndRecoversWithoutRestart() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        captures.startError = FakeMeetingNoteError.injectedCaptureFailure
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)

        do {
            _ = try await coordinator.start(
                project: project,
                projectScopeToken: "scope-original",
                initiallyPaused: false
            )
            XCTFail("expected capture startup to fail")
        } catch {
            XCTAssertEqual(error as? FakeMeetingNoteError, .injectedCaptureFailure)
        }

        let failed = await coordinator.snapshot()
        let offers = try await coordinator.recoveryOffers()
        let firstCapture = try XCTUnwrap(captures.latest())
        let implicitResumeCount = await firstCapture.resumeCount
        XCTAssertEqual(failed.phase, .error)
        XCTAssertEqual(failed.project?.repositoryPath, "/tmp/original-project")
        XCTAssertEqual(offers.first?.project.repositoryPath, "/tmp/original-project")
        XCTAssertEqual(implicitResumeCount, 0)

        captures.startError = nil
        let recovered = try await coordinator.resolveRecovery(
            sessionID: try XCTUnwrap(offers.first?.sessionID),
            projectScopeToken: "scope-original",
            resolution: .discardIncompleteTail
        )
        let createCount = await writer.createCount
        XCTAssertEqual(recovered.phase, .saved)
        XCTAssertEqual(recovered.project?.repositoryPath, "/tmp/original-project")
        XCTAssertEqual(createCount, 1)
    }

    func testInitialJournalDiskFullIsVisibleAndDirectRetryStartsCleanly() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
        await store.failNextSaveWithDiskFull()

        do {
            _ = try await coordinator.start(
                project: project,
                projectScopeToken: "scope-original",
                initiallyPaused: false
            )
            XCTFail("expected the initial recovery journal save to fail")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }

        let failed = await coordinator.snapshot()
        let offers = try await coordinator.recoveryOffers()
        let createCountAfterFailure = await writer.createCount
        XCTAssertEqual(failed.phase, .error)
        XCTAssertEqual(failed.errorMessage, "Local recovery storage is full.")
        XCTAssertEqual(failed.project, project)
        XCTAssertTrue(offers.isEmpty)
        XCTAssertEqual(createCountAfterFailure, 0)
        XCTAssertNil(captures.latest())

        let retried = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        let createCountAfterRetry = await writer.createCount
        XCTAssertEqual(retried.phase, .recording)
        XCTAssertEqual(createCountAfterRetry, 1)
        XCTAssertNotNil(captures.latest())
        let saved = try await coordinator.stop()
        XCTAssertEqual(saved.phase, .saved)
    }

    func testStopReleasesForegroundAfterInitialJournalDiskFull() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = FakeMeetingNoteCaptureFactory()
        let coordinator = makeCoordinator(writer: writer, store: store, captures: captures)
        await store.failNextSaveWithDiskFull()

        do {
            _ = try await coordinator.start(
                project: project,
                projectScopeToken: "scope-original",
                initiallyPaused: false
            )
            XCTFail("expected the initial recovery journal save to fail")
        } catch {}

        let released = try await coordinator.stop()
        XCTAssertEqual(released.phase, .idle)
        XCTAssertFalse(released.phase.ownsForeground)
        XCTAssertNil(released.project)
        XCTAssertNil(captures.latest())

        let restarted = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: true
        )
        XCTAssertEqual(restarted.phase, .paused)
    }

    func testRuntimeCheckpointDiskFullStopsCaptureAndClearsTakingNotes() async throws {
        let writer = FakeMeetingNoteWriter()
        let store = InMemoryMeetingNoteRecoveryStore()
        let captures = RuntimeCheckpointFailureCaptureFactory()
        let updates = MeetingNoteSnapshotRecorder()
        let coordinator = MeetingNoteCoordinator(
            writer: writer,
            recoveryStore: store,
            automaticCheckpointing: false,
            now: { "2026-09-21T00:00:00Z" },
            snapshotSink: { updates.append($0) }
        ) { sessionID, acceptedAudio, durableCheckpoint, events in
            captures.make(
                sessionID: sessionID,
                acceptedAudioSink: acceptedAudio,
                durableCheckpointSink: durableCheckpoint,
                eventSink: events
            )
        }

        let started = try await coordinator.start(
            project: project,
            projectScopeToken: "scope-original",
            initiallyPaused: false
        )
        XCTAssertEqual(started.notchPresentation?.status, .listening)
        XCTAssertEqual(started.notchPresentation?.label, "Taking notes")

        await store.failNextProducerCheckpointWithDiskFull()
        XCTAssertTrue(captures.capture.emit(samples: [0.25, 0.5]))

        let failed = try await waitForRuntimeFailure(
            coordinator: coordinator,
            capture: captures.capture
        )
        let offers = try await coordinator.recoveryOffers()

        XCTAssertEqual(failed.phase, .error)
        XCTAssertEqual(failed.errorMessage, "Local recovery storage is full.")
        XCTAssertNotEqual(failed.notchPresentation?.status, .listening)
        XCTAssertNil(failed.notchPresentation?.label)
        XCTAssertEqual(captures.capture.stopCount, 1)
        XCTAssertFalse(captures.capture.isRunning)
        XCTAssertEqual(offers.count, 1)
        XCTAssertEqual(offers.first?.pendingAudioChunkCount, 1)
        XCTAssertTrue(updates.snapshots.contains { snapshot in
            snapshot.phase == .error && snapshot.notchPresentation?.status != .listening
        })
    }

    func testFileRecoveryStoreEnforcesBudgetAndRemovesOwnedAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-note-store-\(UUID().uuidString)", isDirectory: true)
        let store = MeetingNoteRecoveryStore(root: root, audioBudgetBytes: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = audioDescriptor(chunkID: "first")
        let second = audioDescriptor(chunkID: "second")

        try await store.persistAudio(
            sessionID: "budget",
            audio: MeetingAcceptedAudio(descriptor: first, samples: [1, 2])
        )
        do {
            try await store.persistAudio(
                sessionID: "budget",
                audio: MeetingAcceptedAudio(descriptor: second, samples: [3, 4])
            )
            XCTFail("expected the bounded recovery audio budget")
        } catch let error as MeetingNoteRecoveryStoreError {
            XCTAssertEqual(error, .audioBudgetExceeded(limitBytes: 8))
        }
        try await store.retainAudio(sessionID: "budget", chunkIDs: [])
        do {
            _ = try await store.loadAudio(sessionID: "budget", descriptors: [first])
            XCTFail("owned audio should have been removed")
        } catch let error as MeetingNoteRecoveryStoreError {
            XCTAssertEqual(error, .missingAudio("first"))
        }
    }

    func testArtifactResponseCannotRegressCursorPersistedDuringWriterDelay() async throws {
        let store = InMemoryMeetingNoteRecoveryStore()
        let sessionID = "cursor-race"
        let timestamp = "2026-09-21T00:00:00Z"
        let stale = MeetingNoteRecoveryJournal(
            schemaVersion: MeetingNoteRecoveryJournal.schemaVersion,
            sessionID: sessionID,
            project: project,
            createRequest: RelayProjectNoteCreateRequest(
                requestID: "create-cursor-race",
                createdAt: timestamp,
                captureStartedAt: timestamp,
                capturedAt: timestamp,
                recordingState: .recording,
                checkpointReason: .checkpoint,
                segments: [],
                captureEndedAt: nil,
                provider: "codex"
            ),
            identity: noteIdentity(),
            phase: .recording,
            producerCheckpoint: producerCheckpoint(
                sessionID: sessionID,
                state: .recording,
                acceptedChunkCount: 1
            ),
            revisions: [],
            canonicalSegments: [],
            pendingUpdate: nil,
            nextCheckpointSequence: 1,
            syncState: "local_only",
            captureEndedAt: nil,
            lastError: nil,
            updatedAt: timestamp
        )
        try await store.save(stale)
        try await store.saveProducerCheckpoint(
            sessionID: sessionID,
            checkpoint: producerCheckpoint(
                sessionID: sessionID,
                state: .recording,
                acceptedChunkCount: 2
            )
        )

        try await store.save(stale)

        let restored = await store.load(sessionID: sessionID)
        XCTAssertEqual(restored?.producerCheckpoint?.metrics.acceptedChunkCount, 2)
    }

    private var project: MeetingNoteProjectBinding {
        MeetingNoteProjectBinding(
            repositoryPath: "/tmp/original-project",
            expectedProjectID: "project-1",
            provider: "codex"
        )
    }

    private func snapshot(phase: MeetingNoteCoordinatorPhase) -> MeetingNoteCoordinatorSnapshot {
        MeetingNoteCoordinatorSnapshot(
            phase: phase,
            noteID: "RR-N1",
            project: project,
            liveHypothesisCount: 0,
            durableSegmentCount: 0,
            syncState: "local_only",
            errorMessage: nil
        )
    }

    private func makeCoordinator(
        writer: any MeetingNoteArtifactWriting,
        store: InMemoryMeetingNoteRecoveryStore,
        captures: FakeMeetingNoteCaptureFactory,
        policy: MeetingNoteCheckpointPolicy = .default,
        automaticCheckpointing: Bool = false,
        snapshotSink: @escaping MeetingNoteCoordinator.SnapshotSink = { _ in },
        scopeTokenRefresher: MeetingNoteCoordinator.ScopeTokenRefresher? = nil
    ) -> MeetingNoteCoordinator {
        MeetingNoteCoordinator(
            writer: writer,
            recoveryStore: store,
            policy: policy,
            automaticCheckpointing: automaticCheckpointing,
            now: { "2026-09-21T00:00:00Z" },
            snapshotSink: snapshotSink,
            scopeTokenRefresher: scopeTokenRefresher
        ) { sessionID, acceptedAudio, _, events in
            captures.make(
                sessionID: sessionID,
                acceptedAudioSink: acceptedAudio,
                eventSink: events
            )
        }
    }

    private func makeDurableCoordinator(
        writer: FakeMeetingNoteWriter,
        store: InMemoryMeetingNoteRecoveryStore,
        captures: DurableMeetingNoteCaptureFactory
    ) -> MeetingNoteCoordinator {
        MeetingNoteCoordinator(
            writer: writer,
            recoveryStore: store,
            automaticCheckpointing: false,
            now: { "2026-09-21T00:00:00Z" }
        ) { sessionID, acceptedAudio, durableCheckpoint, events in
            captures.make(
                sessionID: sessionID,
                acceptedAudioSink: acceptedAudio,
                durableCheckpointSink: durableCheckpoint,
                eventSink: events
            )
        }
    }

    private func waitForRuntimeFailure(
        coordinator: MeetingNoteCoordinator,
        capture: ControllableMeetingAudioCapture
    ) async throws -> MeetingNoteCoordinatorSnapshot {
        for _ in 0..<200 {
            let snapshot = await coordinator.snapshot()
            if snapshot.phase == .error, !capture.isRunning {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("runtime checkpoint failure did not reach terminal coordinator state")
        return await coordinator.snapshot()
    }

    private func revision(
        id: String,
        start: Int,
        text: String,
        final: Bool
    ) -> MeetingTranscriptSegmentRevision {
        MeetingTranscriptSegmentRevision(
            segmentID: id,
            sourceID: .microphone,
            timingEpochID: "microphone-E0",
            windowSequence: start / 1_000,
            revision: final ? 2 : 1,
            startMilliseconds: start,
            endMilliseconds: start + 1_000,
            text: text,
            isFinal: final
        )
    }

    private func noteIdentity() -> RelayProjectNoteIdentity {
        RelayProjectNoteIdentity(
            noteID: "RR-N1",
            artifactID: "note-artifact-1",
            projectID: "project-1",
            createdAt: "2026-09-21T00:00:00Z",
            captureStartedAt: "2026-09-21T00:00:00Z"
        )
    }

    private func audioDescriptor(chunkID: String) -> MeetingAcceptedAudioDescriptor {
        MeetingAcceptedAudioDescriptor(
            chunkID: chunkID,
            sourceID: .microphone,
            timingEpochID: "microphone-E0",
            sequence: 0,
            startSample: 0,
            endSample: 2,
            startMilliseconds: 0,
            endMilliseconds: 1,
            sampleRate: 16_000,
            sampleCount: 2
        )
    }

    private func producerCheckpoint(
        sessionID: String,
        state: MeetingProducerState,
        acceptedChunkCount: Int = 0,
        pendingAudio: [MeetingAcceptedAudioDescriptor] = []
    ) -> MeetingProducerCheckpoint {
        var metrics = MeetingProducerMetrics()
        metrics.acceptedChunkCount = acceptedChunkCount
        return MeetingProducerCheckpoint(
            sessionID: sessionID,
            state: state,
            timingEpochs: [],
            timelineOriginNanoseconds: nil,
            timelineSampleBySource: [:],
            nextWindowSequenceByEpoch: [:],
            completedWindowSequencesByEpoch: [:],
            emittedRevisionBySegment: [:],
            finalRevisionBySegment: [:],
            pendingAudio: pendingAudio,
            metrics: metrics
        )
    }
}

private actor FakeMeetingNoteWriter: MeetingNoteArtifactWriting {
    private let syncState: String
    private var identity = RelayProjectNoteIdentity(
        noteID: "RR-N1",
        artifactID: "note-artifact-1",
        projectID: "project-1",
        createdAt: "2026-09-21T00:00:00Z",
        captureStartedAt: "2026-09-21T00:00:00Z"
    )
    private var savedSegments: [RelayProjectNoteSegment] = []
    private var shouldFailNextUpdate = false
    private var shouldSuspendNextUpdate = false
    private var suspendedUpdate: CheckedContinuation<Void, Never>?
    private var suspendedUpdateWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendNextUpdateUntilCancelled = false
    private var cancellableUpdateActive = false
    private var cancellableUpdateWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchState: RelayProjectNoteRecordingState = .paused
    private(set) var createCount = 0
    private(set) var updates: [RelayProjectNoteCheckpointRequest] = []
    private(set) var attemptedRequestIDs: [String] = []
    private(set) var repositories: [String] = []

    init(syncState: String = "local_only") {
        self.syncState = syncState
    }

    func failNextUpdate() {
        shouldFailNextUpdate = true
    }

    func suspendNextUpdate() {
        shouldSuspendNextUpdate = true
    }

    func waitForSuspendedUpdate() async {
        if suspendedUpdate != nil { return }
        await withCheckedContinuation { continuation in
            suspendedUpdateWaiters.append(continuation)
        }
    }

    func suspendNextUpdateUntilCancelled() {
        shouldSuspendNextUpdateUntilCancelled = true
    }

    func waitForCancellableUpdate() async {
        if cancellableUpdateActive { return }
        await withCheckedContinuation { continuation in
            cancellableUpdateWaiters.append(continuation)
        }
    }

    func resumeSuspendedUpdate() {
        let continuation = suspendedUpdate
        suspendedUpdate = nil
        continuation?.resume()
    }

    func seed(identity: RelayProjectNoteIdentity, segments: [RelayProjectNoteSegment]) {
        self.identity = identity
        savedSegments = segments
    }

    func setFetchState(_ state: RelayProjectNoteRecordingState) {
        fetchState = state
    }

    func create(
        _ request: RelayProjectNoteCreateRequest,
        repositoryPath: String,
        projectScopeToken: String?
    ) -> RelayProjectNoteResponse {
        createCount += 1
        repositories.append(repositoryPath)
        return response(
            state: request.recordingState,
            reason: request.checkpointReason,
            segments: request.segments,
            captureEndedAt: request.captureEndedAt
        )
    }

    func update(
        _ request: RelayProjectNoteCheckpointRequest,
        repositoryPath: String,
        projectScopeToken: String?
    ) async throws -> RelayProjectNoteResponse {
        attemptedRequestIDs.append(request.requestID)
        repositories.append(repositoryPath)
        if shouldFailNextUpdate {
            shouldFailNextUpdate = false
            throw FakeMeetingNoteError.injectedSaveFailure
        }
        if shouldSuspendNextUpdateUntilCancelled {
            shouldSuspendNextUpdateUntilCancelled = false
            cancellableUpdateActive = true
            let waiters = cancellableUpdateWaiters
            cancellableUpdateWaiters.removeAll()
            waiters.forEach { $0.resume() }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancellableUpdateActive = false
                throw URLError(.cancelled)
            }
            cancellableUpdateActive = false
        }
        if shouldSuspendNextUpdate {
            shouldSuspendNextUpdate = false
            await withCheckedContinuation { continuation in
                suspendedUpdate = continuation
                let waiters = suspendedUpdateWaiters
                suspendedUpdateWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        updates.append(request)
        savedSegments = request.update.segments
        return response(
            state: request.update.recordingState,
            reason: request.update.checkpointReason,
            segments: savedSegments,
            captureEndedAt: request.update.captureEndedAt
        )
    }

    func fetch(
        _ noteIdentity: String,
        repositoryPath: String,
        projectScopeToken: String?
    ) -> RelayProjectNoteResponse {
        repositories.append(repositoryPath)
        return response(
            state: fetchState,
            reason: .checkpoint,
            segments: savedSegments,
            captureEndedAt: fetchState == .completed ? "2026-09-21T00:01:00Z" : nil
        )
    }

    private func response(
        state: RelayProjectNoteRecordingState,
        reason: RelayProjectNoteCheckpointReason,
        segments: [RelayProjectNoteSegment],
        captureEndedAt: String?
    ) -> RelayProjectNoteResponse {
        RelayProjectNoteResponse(
            note: RelayProjectNoteUpdate(
                identity: identity,
                capturedAt: "2026-09-21T00:00:00Z",
                recordingState: state,
                checkpointReason: reason,
                segments: segments,
                captureEndedAt: captureEndedAt
            ),
            markdownBase64: "",
            materialized: true,
            artifactCommit: "artifact-commit",
            reference: RelayProjectNoteReference(
                path: ".orchestrator/notes/RR-N1.md",
                artifactRef: "refs/heads/relay/artifacts",
                commit: "artifact-commit",
                revision: "blob",
                historyReference: "artifact-commit:.orchestrator/notes/RR-N1.md",
                verified: true,
                catalogCommit: "artifact-commit"
            ),
            idempotent: false,
            sync: RelayProjectNoteSyncState(
                mode: "artifact_ref",
                state: syncState,
                recovery: nil
            )
        )
    }
}

private actor ScopeAwareMeetingNoteWriter: MeetingNoteArtifactWriting {
    private let identity = RelayProjectNoteIdentity(
        noteID: "RR-N1",
        artifactID: "note-artifact-1",
        projectID: "project-1",
        createdAt: "2026-09-21T00:00:00Z",
        captureStartedAt: "2026-09-21T00:00:00Z"
    )
    private var validScopeToken = "scope-original"
    private var shouldLoseNextCommittedResponse = false
    private var committedResponses: [String: RelayProjectNoteResponse] = [:]
    private(set) var updates: [RelayProjectNoteCheckpointRequest] = []
    private(set) var attemptedRequestIDs: [String] = []
    private(set) var attemptedScopeTokens: [String?] = []
    private(set) var savedSegments: [RelayProjectNoteSegment] = []
    private var recordingState: RelayProjectNoteRecordingState = .recording
    private var checkpointReason: RelayProjectNoteCheckpointReason = .checkpoint
    private var captureEndedAt: String?

    func invalidateOriginalScope() {
        validScopeToken = "scope-refreshed"
    }

    func loseNextCommittedUpdateResponse() {
        shouldLoseNextCommittedResponse = true
    }

    func create(
        _ request: RelayProjectNoteCreateRequest,
        repositoryPath: String,
        projectScopeToken: String?
    ) throws -> RelayProjectNoteResponse {
        try validate(projectScopeToken)
        recordingState = request.recordingState
        checkpointReason = request.checkpointReason
        savedSegments = request.segments
        captureEndedAt = request.captureEndedAt
        return response(idempotent: false)
    }

    func update(
        _ request: RelayProjectNoteCheckpointRequest,
        repositoryPath: String,
        projectScopeToken: String?
    ) throws -> RelayProjectNoteResponse {
        attemptedRequestIDs.append(request.requestID)
        attemptedScopeTokens.append(projectScopeToken)
        try validate(projectScopeToken)
        if committedResponses[request.requestID] != nil {
            return response(idempotent: true)
        }
        updates.append(request)
        savedSegments = request.update.segments
        recordingState = request.update.recordingState
        checkpointReason = request.update.checkpointReason
        captureEndedAt = request.update.captureEndedAt
        let committed = response(idempotent: false)
        committedResponses[request.requestID] = committed
        if shouldLoseNextCommittedResponse {
            shouldLoseNextCommittedResponse = false
            throw OrchestratorClientError.timedOut
        }
        return committed
    }

    func fetch(
        _ noteIdentity: String,
        repositoryPath: String,
        projectScopeToken: String?
    ) throws -> RelayProjectNoteResponse {
        try validate(projectScopeToken)
        return response(idempotent: false)
    }

    private func validate(_ token: String?) throws {
        guard token == validScopeToken else {
            throw OrchestratorClientError.badStatus(
                422,
                #"{"error":"confirmed project scope token is stale"}"#
            )
        }
    }

    private func response(idempotent: Bool) -> RelayProjectNoteResponse {
        RelayProjectNoteResponse(
            note: RelayProjectNoteUpdate(
                identity: identity,
                capturedAt: "2026-09-21T00:00:00Z",
                recordingState: recordingState,
                checkpointReason: checkpointReason,
                segments: savedSegments,
                captureEndedAt: captureEndedAt
            ),
            markdownBase64: "",
            materialized: true,
            artifactCommit: "artifact-commit",
            reference: RelayProjectNoteReference(
                path: ".orchestrator/notes/RR-N1.md",
                artifactRef: "refs/heads/relay/artifacts",
                commit: "artifact-commit",
                revision: "blob",
                historyReference: "artifact-commit:.orchestrator/notes/RR-N1.md",
                verified: true,
                catalogCommit: "artifact-commit"
            ),
            idempotent: idempotent,
            sync: RelayProjectNoteSyncState(mode: "artifact_ref", state: "local_only", recovery: nil)
        )
    }
}

private final class ScopeRefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingNoteProjectBinding] = []

    var projects: [MeetingNoteProjectBinding] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ project: MeetingNoteProjectBinding) {
        lock.lock()
        values.append(project)
        lock.unlock()
    }
}

private enum FakeMeetingNoteError: Error, Equatable {
    case injectedSaveFailure
    case injectedCaptureFailure
    case injectedTranscriptionFailure
}

private final class FakeMeetingNoteCaptureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var captures: [FakeMeetingNoteCapture] = []
    var stopRevisions: [MeetingTranscriptSegmentRevision] = []
    var replayRevision: MeetingTranscriptSegmentRevision?
    var startError: Error?

    func make(
        sessionID: String,
        acceptedAudioSink: @escaping MeetingTranscriptProducer.AcceptedAudioSink,
        eventSink: @escaping MeetingTranscriptProducer.EventSink
    ) -> FakeMeetingNoteCapture {
        lock.lock()
        let stopRevisions = self.stopRevisions
        let replayRevision = self.replayRevision
        let startError = self.startError
        let capture = FakeMeetingNoteCapture(
            sessionID: sessionID,
            eventSink: eventSink,
            stopRevisions: stopRevisions,
            replayRevision: replayRevision,
            startError: startError
        )
        captures.append(capture)
        lock.unlock()
        return capture
    }

    func latest() -> FakeMeetingNoteCapture? {
        lock.lock()
        defer { lock.unlock() }
        return captures.last
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return captures.count
    }
}

private actor FakeMeetingNoteCapture: MeetingNoteCaptureControlling {
    let sessionID: String
    private let eventSink: MeetingTranscriptProducer.EventSink
    private let stopRevisions: [MeetingTranscriptSegmentRevision]
    private let replayRevision: MeetingTranscriptSegmentRevision?
    private let startError: Error?
    private(set) var startCount = 0
    private(set) var startInitiallyPaused: Bool?
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var replayedChunkIDs: [String] = []
    private var shouldSuspendNextPause = false
    private var suspendedPause: CheckedContinuation<Void, Never>?
    private var suspendedPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var state: MeetingProducerState = .idle
    private var checkpointValue: MeetingProducerCheckpoint?

    var isRecording: Bool { state == .recording }

    func emitRevision(_ revision: MeetingTranscriptSegmentRevision) {
        eventSink(.revision(revision))
    }

    init(
        sessionID: String,
        eventSink: @escaping MeetingTranscriptProducer.EventSink,
        stopRevisions: [MeetingTranscriptSegmentRevision],
        replayRevision: MeetingTranscriptSegmentRevision?,
        startError: Error?
    ) {
        self.sessionID = sessionID
        self.eventSink = eventSink
        self.stopRevisions = stopRevisions
        self.replayRevision = replayRevision
        self.startError = startError
    }

    func start(
        initiallyPaused: Bool,
        resume checkpoint: MeetingProducerCheckpoint?
    ) throws {
        startCount += 1
        if let startError { throw startError }
        startInitiallyPaused = initiallyPaused
        state = initiallyPaused ? .paused : .recording
        checkpointValue = checkpoint
    }

    func suspendNextPause() {
        shouldSuspendNextPause = true
    }

    func waitForSuspendedPause() async {
        if suspendedPause != nil { return }
        await withCheckedContinuation { continuation in
            suspendedPauseWaiters.append(continuation)
        }
    }

    func resumeSuspendedPause() {
        let continuation = suspendedPause
        suspendedPause = nil
        continuation?.resume()
    }

    func pause() async {
        guard state == .recording else { return }
        if shouldSuspendNextPause {
            shouldSuspendNextPause = false
            await withCheckedContinuation { continuation in
                suspendedPause = continuation
                let waiters = suspendedPauseWaiters
                suspendedPauseWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        pauseCount += 1
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        resumeCount += 1
        state = .recording
    }

    func stop() -> MeetingProducerFinalBoundary {
        stopCount += 1
        for revision in stopRevisions { eventSink(.revision(revision)) }
        state = .stopped
        return MeetingProducerFinalBoundary(
            sessionID: sessionID,
            timingEpochs: [],
            finalSegmentRevisionByID: Dictionary(
                uniqueKeysWithValues: stopRevisions.map { ($0.segmentID, $0.revision) }
            ),
            metrics: MeetingProducerMetrics()
        )
    }

    func stopCaptureSourcesForInterruption() {
        switch state {
        case .preparing, .recording, .paused, .failed:
            stopCount += 1
            state = .stopped
        case .idle, .stopping, .stopped:
            return
        }
    }

    func checkpoint() -> MeetingProducerCheckpoint {
        let pending = checkpointValue?.pendingAudio ?? []
        return MeetingProducerCheckpoint(
            sessionID: sessionID,
            state: state,
            timingEpochs: checkpointValue?.timingEpochs ?? [],
            timelineOriginNanoseconds: checkpointValue?.timelineOriginNanoseconds,
            timelineSampleBySource: checkpointValue?.timelineSampleBySource ?? [:],
            nextWindowSequenceByEpoch: checkpointValue?.nextWindowSequenceByEpoch ?? [:],
            completedWindowSequencesByEpoch: checkpointValue?.completedWindowSequencesByEpoch ?? [:],
            emittedRevisionBySegment: checkpointValue?.emittedRevisionBySegment ?? [:],
            finalRevisionBySegment: checkpointValue?.finalRevisionBySegment ?? [:],
            pendingAudio: pending,
            metrics: MeetingProducerMetrics()
        )
    }

    func replayAcceptedAudio(_ chunks: [MeetingAcceptedAudio]) {
        replayedChunkIDs = chunks.map(\.descriptor.chunkID)
        if let replayRevision { eventSink(.revision(replayRevision)) }
        checkpointValue = MeetingProducerCheckpoint(
            sessionID: sessionID,
            state: state,
            timingEpochs: [],
            timelineOriginNanoseconds: nil,
            timelineSampleBySource: [:],
            nextWindowSequenceByEpoch: [:],
            completedWindowSequencesByEpoch: [:],
            emittedRevisionBySegment: [:],
            finalRevisionBySegment: [:],
            pendingAudio: [],
            metrics: MeetingProducerMetrics()
        )
    }
}

private final class DurableMeetingNoteCaptureFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let firstCaptureFailureCount: Int?
    private var makeCount = 0
    private var captures: [DurableSyntheticAudioCapture] = []
    private var transcribers: [DurableFinalWindowTranscriber] = []

    init(firstCaptureFailureCount: Int? = nil) {
        self.firstCaptureFailureCount = firstCaptureFailureCount
    }

    var firstCapture: DurableSyntheticAudioCapture? {
        lock.lock()
        defer { lock.unlock() }
        return captures.first
    }

    var firstTranscriber: DurableFinalWindowTranscriber? {
        lock.lock()
        defer { lock.unlock() }
        return transcribers.first
    }

    func make(
        sessionID: String,
        acceptedAudioSink: @escaping MeetingTranscriptProducer.AcceptedAudioSink,
        durableCheckpointSink: @escaping MeetingTranscriptProducer.DurableCheckpointSink,
        eventSink: @escaping MeetingTranscriptProducer.EventSink
    ) -> MeetingNoteCaptureSession {
        lock.lock()
        makeCount += 1
        let failureCount = makeCount == 1 ? firstCaptureFailureCount : 0
        let capture = DurableSyntheticAudioCapture(samples: [0.25, 0.5])
        let transcriber = DurableFinalWindowTranscriber(failureCount: failureCount)
        captures.append(capture)
        transcribers.append(transcriber)
        lock.unlock()

        let producer = MeetingTranscriptProducer(
            sessionID: sessionID,
            transcriber: transcriber,
            configuration: MeetingTranscriptProducer.Configuration(
                sampleRate: 10,
                windowMilliseconds: 1_000,
                overlapMilliseconds: 200,
                firstPartialMilliseconds: 400,
                partialIntervalMilliseconds: 400,
                maximumQueuedWindows: 4
            ),
            acceptedAudioSink: acceptedAudioSink,
            durableCheckpointSink: durableCheckpointSink,
            eventSink: eventSink
        )
        return MeetingNoteCaptureSession(producer: producer, captures: [capture])
    }
}

private final class RuntimeCheckpointFailureCaptureFactory: @unchecked Sendable {
    let capture = ControllableMeetingAudioCapture()

    func make(
        sessionID: String,
        acceptedAudioSink: @escaping MeetingTranscriptProducer.AcceptedAudioSink,
        durableCheckpointSink: @escaping MeetingTranscriptProducer.DurableCheckpointSink,
        eventSink: @escaping MeetingTranscriptProducer.EventSink
    ) -> MeetingNoteCaptureSession {
        let producer = MeetingTranscriptProducer(
            sessionID: sessionID,
            transcriber: DurableFinalWindowTranscriber(failureCount: 0),
            configuration: MeetingTranscriptProducer.Configuration(
                sampleRate: 10,
                windowMilliseconds: 1_000,
                overlapMilliseconds: 200,
                firstPartialMilliseconds: 400,
                partialIntervalMilliseconds: 400,
                maximumQueuedWindows: 4
            ),
            acceptedAudioSink: acceptedAudioSink,
            durableCheckpointSink: durableCheckpointSink,
            eventSink: eventSink
        )
        return MeetingNoteCaptureSession(producer: producer, captures: [capture])
    }
}

private final class MeetingNoteSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingNoteCoordinatorSnapshot] = []

    var snapshots: [MeetingNoteCoordinatorSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(_ snapshot: MeetingNoteCoordinatorSnapshot) {
        lock.lock()
        values.append(snapshot)
        lock.unlock()
    }
}

private final class ControllableMeetingAudioCapture: MeetingAudioCapturing, @unchecked Sendable {
    let sourceID = MeetingAudioSourceID.microphone
    private let lock = NSLock()
    private var sampleHandler: (@Sendable (MeetingAudioFrame) -> Void)?
    private var stops = 0

    var stopCount: Int {
        withLock { stops }
    }

    var isRunning: Bool {
        withLock { sampleHandler != nil }
    }

    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        withLock { self.sampleHandler = sampleHandler }
        return MeetingCaptureSourceInfo(
            sourceID: sourceID,
            routeID: "controllable-checkpoint-failure",
            sampleRate: 10,
            channelCount: 1
        )
    }

    func stop() async {
        withLock {
            stops += 1
            sampleHandler = nil
        }
    }

    func emit(samples: [Float]) -> Bool {
        guard let handler = withLock({ sampleHandler }) else { return false }
        handler(MeetingAudioFrame(
            samples: samples,
            presentationTimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
        return true
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class DurableFinalWindowTranscriber: MeetingWindowTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int?
    private var attempts = 0

    init(failureCount: Int?) {
        remainingFailures = failureCount
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func prepare(
        onState: @escaping @Sendable (MeetingLocalModelState) -> Void
    ) async throws {
        onState(.ready(model: "synthetic-durability-fixture"))
    }

    func transcribe(
        _ request: MeetingTranscriptionRequest
    ) async throws -> MeetingTranscriptionResult {
        if recordAttemptShouldFail() {
            throw FakeMeetingNoteError.injectedTranscriptionFailure
        }
        return MeetingTranscriptionResult(
            text: "recovered tail",
            tokens: [],
            processingMilliseconds: 1
        )
    }

    private func recordAttemptShouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        if let remainingFailures {
            let shouldFail = remainingFailures > 0
            self.remainingFailures = max(0, remainingFailures - 1)
            return shouldFail
        } else {
            return true
        }
    }
}

private final class DurableSyntheticAudioCapture: MeetingAudioCapturing, @unchecked Sendable {
    let sourceID = MeetingAudioSourceID.microphone
    private let samples: [Float]
    private let lock = NSLock()
    private var sampleHandler: (@Sendable (MeetingAudioFrame) -> Void)?
    private var stops = 0

    var stopCount: Int {
        withLock { stops }
    }

    var isRunning: Bool {
        withLock { sampleHandler != nil }
    }

    init(samples: [Float]) {
        self.samples = samples
    }

    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        withLock { self.sampleHandler = sampleHandler }
        sampleHandler(MeetingAudioFrame(
            samples: samples,
            presentationTimeNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
        return MeetingCaptureSourceInfo(
            sourceID: sourceID,
            routeID: "synthetic-durability",
            sampleRate: 10,
            channelCount: 1
        )
    }

    func stop() async {
        withLock {
            stops += 1
            sampleHandler = nil
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private actor InMemoryMeetingNoteRecoveryStore: MeetingNoteRecoveryStoring {
    private var journals: [String: MeetingNoteRecoveryJournal] = [:]
    private var audio: [String: [String: MeetingAcceptedAudio]] = [:]
    private var failNextSave = false
    private var failNextProducerCheckpoint = false

    var isEmpty: Bool { journals.isEmpty && audio.values.allSatisfy(\.isEmpty) }

    func failNextSaveWithDiskFull() {
        failNextSave = true
    }

    func failNextProducerCheckpointWithDiskFull() {
        failNextProducerCheckpoint = true
    }

    func save(_ journal: MeetingNoteRecoveryJournal) throws {
        if failNextSave {
            failNextSave = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        var value = journal
        if let current = journals[journal.sessionID]?.producerCheckpoint,
           current.metrics.acceptedChunkCount
            > (journal.producerCheckpoint?.metrics.acceptedChunkCount ?? -1) {
            value.producerCheckpoint = current
        }
        journals[journal.sessionID] = value
    }

    func load(sessionID: String) -> MeetingNoteRecoveryJournal? {
        journals[sessionID]
    }

    func loadAll() -> [MeetingNoteRecoveryJournal] {
        journals.values.sorted { $0.updatedAt < $1.updatedAt }
    }

    func persistAudio(sessionID: String, audio: MeetingAcceptedAudio) {
        self.audio[sessionID, default: [:]][audio.descriptor.chunkID] = audio
    }

    func saveProducerCheckpoint(
        sessionID: String,
        checkpoint: MeetingProducerCheckpoint
    ) throws {
        if failNextProducerCheckpoint {
            failNextProducerCheckpoint = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        guard var journal = journals[sessionID] else {
            throw MeetingNoteRecoveryStoreError.invalidAudio(sessionID)
        }
        journal.producerCheckpoint = checkpoint
        journals[sessionID] = journal
    }

    func loadAudio(
        sessionID: String,
        descriptors: [MeetingAcceptedAudioDescriptor]
    ) throws -> [MeetingAcceptedAudio] {
        try descriptors.map { descriptor in
            guard let value = audio[sessionID]?[descriptor.chunkID] else {
                throw MeetingNoteRecoveryStoreError.missingAudio(descriptor.chunkID)
            }
            return value
        }
    }

    func retainAudio(sessionID: String, chunkIDs: Set<String>) {
        audio[sessionID] = audio[sessionID]?.filter { chunkIDs.contains($0.key) }
    }

    func retainCheckpointAudio(sessionID: String) {
        let retained = Set(journals[sessionID]?.producerCheckpoint?.pendingAudio.map(\.chunkID) ?? [])
        retainAudio(sessionID: sessionID, chunkIDs: retained)
    }

    func removeSession(sessionID: String) {
        journals.removeValue(forKey: sessionID)
        audio.removeValue(forKey: sessionID)
    }
}
