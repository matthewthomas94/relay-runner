import Foundation
import XCTest
@testable import relay_runner

final class MeetingTranscriptProducerTests: XCTestCase {
    func testFixtureSessionCapturesMicrophoneAndSystemAudioWithoutVoicePipeline() async throws {
        let events = MeetingEventRecorder()
        let transcriber = FakeMeetingTranscriber { request in
            MeetingTranscriptionResult(
                text: request.sourceID.rawValue,
                tokens: [],
                processingMilliseconds: 2
            )
        }
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-dual-source",
            transcriber: transcriber,
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(sourceID: .microphone, samples: [.init(repeating: 0.2, count: 10)])
        let system = FakeMeetingAudioCapture(sourceID: .systemAudio, samples: [.init(repeating: 0.3, count: 10)])
        let session = MeetingNoteCaptureSession(
            producer: producer,
            captures: [microphone, system]
        )

        try await session.start(initiallyPaused: false)
        try await eventually {
            await producer.currentMetrics().acceptedChunkCount == 2
        }
        let boundary = try await session.stop()

        let finals = events.revisions.filter(\.isFinal)
        XCTAssertEqual(Set(finals.map(\.sourceID)), Set(MeetingAudioSourceID.allCases))
        XCTAssertEqual(boundary.metrics.acceptedChunkCount, 2)
        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(system.stopCount, 1)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in [
            "MeetingNoteCaptureSession.swift",
            "MeetingTranscriptProducer.swift",
            "FluidAudioMeetingTranscriber.swift",
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent("Sources/relay-runner/Notes/\(name)"),
                encoding: .utf8
            )
            for forbidden in ["FIFOWriter.", "ProcessManager(", "STTEngine(", "writeVoiceOutput("] {
                XCTAssertFalse(source.contains(forbidden), "\(name) must not reference \(forbidden)")
            }
        }
    }

    func testDeniedSystemAudioIsVisibleWhileMicrophoneCaptureContinues() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-denied-system",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "local speech", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [.init(repeating: 0.2, count: 10)]
        )
        let system = FakeMeetingAudioCapture(
            sourceID: .systemAudio,
            samples: [],
            startFailure: .permissionDenied(.systemAudio)
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [microphone, system])

        try await session.start(initiallyPaused: false)
        try await eventually {
            await producer.currentMetrics().acceptedChunkCount == 1
        }
        _ = try await session.stop()

        XCTAssertTrue(events.sourceStates.contains {
            $0.0 == .systemAudio && $0.1 == .denied
        })
        XCTAssertTrue(events.issues.contains {
            $0.code == .permissionDenied && $0.sourceID == .systemAudio
        })
        let finalSources = events.revisions.filter(\.isFinal).map(\.sourceID)
        XCTAssertFalse(finalSources.isEmpty)
        XCTAssertTrue(finalSources.allSatisfy { $0 == .microphone })
    }

    func testBurstCaptureUsesBoundedIngressAndSurfacesDroppedFrames() async throws {
        let events = MeetingEventRecorder()
        let accepted = BlockingMeetingAcceptedAudioSink()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-capture-ingress",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "accepted", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { audio in await accepted.record(audio) },
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(sourceID: .microphone, samples: [])
        let session = MeetingNoteCaptureSession(
            producer: producer,
            captures: [microphone],
            maximumPendingFrames: 2
        )

        try await session.start(initiallyPaused: false)
        microphone.emit([[1, 1]])
        try await eventually {
            await accepted.recordingCount == 1
        }
        let burst = (0..<8).map { _ in [Float](repeating: 2, count: 2) }
        microphone.emit(burst)
        await accepted.release()
        try await eventually(timeout: 2) {
            events.issues.contains { $0.code == .backpressureExceeded }
        }

        let metrics = await producer.currentMetrics()
        XCTAssertEqual(metrics.acceptedChunkCount, 1)
        XCTAssertEqual(metrics.droppedAudioFrameCount, burst.count)
        XCTAssertEqual(metrics.droppedAudioSampleCount, burst.flatMap { $0 }.count)
        XCTAssertEqual(microphone.stopCount, 1)
        await XCTAssertThrowsErrorAsync(try await session.stop()) { error in
            XCTAssertEqual(error as? MeetingProducerError, .backpressureExceeded)
        }
    }

    func testPauseDrainsFrameEmittedWhileAdapterStops() async throws {
        let accepted = MeetingAcceptedAudioRecorder()
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-pause-tail",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "pre-pause tail", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) },
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [],
            stopSamples: [[3, 3, 3, 3]]
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [microphone])

        try await session.start(initiallyPaused: false)
        try await session.pause()

        XCTAssertEqual(accepted.audio.flatMap(\.samples), [3, 3, 3, 3])
        XCTAssertEqual(events.revisions.filter(\.isFinal).map(\.text), ["pre-pause tail"])
        XCTAssertEqual(microphone.stopCount, 1)
        let boundary = try await session.stop()
        XCTAssertEqual(boundary.metrics.acceptedSamplesBySource[.microphone], 4)
        XCTAssertEqual(microphone.stopCount, 1)
    }

    func testPostStartCaptureFailureStillStopsAdapterDuringTeardown() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-post-start-failure",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )
        let system = FakeMeetingAudioCapture(
            sourceID: .systemAudio,
            samples: [],
            eventOnStart: .failed(.unsupportedFormat(.systemAudio, "fixture format changed"))
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [system])

        try await session.start(initiallyPaused: false)
        try await eventually {
            events.sourceStates.contains { $0.0 == .systemAudio && $0.1 == .unavailable }
        }
        _ = try await session.stop()

        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(system.stopCount, 1)
        XCTAssertTrue(events.issues.contains {
            $0.code == .sourceUnavailable && $0.sourceID == .systemAudio
        })
    }

    func testMissingLocalModelFailsBeforeAnyAudioIsAccepted() async {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-model-missing",
            transcriber: FailingMeetingTranscriber(),
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )

        await XCTAssertThrowsErrorAsync(try await producer.start(initiallyPaused: false))

        XCTAssertTrue(events.issues.contains { $0.code == .modelUnavailable })
        XCTAssertTrue(events.states.contains(.failed))
        let metrics = await producer.currentMetrics()
        XCTAssertEqual(metrics.acceptedChunkCount, 0)
    }

    func testRepeatedSentenceInLaterOwnedRangeSurvivesAsDistinctFinalSegment() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-repeat",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(
                    text: "we should ship this sentence",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )

        try await producer.start(initiallyPaused: false)
        try await producer.ingest(.init(repeating: 0.2, count: 16), from: .microphone)
        _ = try await producer.stop()

        let finals = events.revisions.filter { $0.isFinal && $0.sourceID == .microphone }
        XCTAssertEqual(finals.count, 2)
        XCTAssertEqual(finals.map(\.text), [
            "we should ship this sentence",
            "we should ship this sentence",
        ])
        XCTAssertNotEqual(finals[0].segmentID, finals[1].segmentID)
        XCTAssertLessThan(finals[0].startMilliseconds, finals[1].startMilliseconds)
    }

    func testSilenceCreatesFinalBoundaryWithoutEmptyTranscriptSegment() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-silence",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )

        try await producer.start(initiallyPaused: false)
        try await producer.ingest(.init(repeating: 0, count: 10), from: .systemAudio)
        let boundary = try await producer.stop()

        XCTAssertTrue(events.revisions.isEmpty)
        XCTAssertTrue(boundary.finalSegmentRevisionByID.isEmpty)
        XCTAssertEqual(boundary.metrics.acceptedSamplesBySource[.systemAudio], 10)
    }

    func testOwnedTokenRangesRemoveWindowOverlapWithoutSuppressingLaterSpeech() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-overlap",
            transcriber: FakeMeetingTranscriber { request in
                let tokens: [MeetingRecognizedToken]
                if request.windowSequence == 0 {
                    tokens = [
                        .init(text: "first ", startSeconds: 0.1, endSeconds: 0.2, confidence: 1),
                        .init(text: "context", startSeconds: 0.85, endSeconds: 0.95, confidence: 1),
                    ]
                } else {
                    tokens = [
                        .init(text: "context ", startSeconds: 0.05, endSeconds: 0.15, confidence: 1),
                        .init(text: "second", startSeconds: 0.3, endSeconds: 0.4, confidence: 1),
                    ]
                }
                return MeetingTranscriptionResult(
                    text: "unused fallback",
                    tokens: tokens,
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )

        try await producer.start(initiallyPaused: false)
        try await producer.ingest(.init(repeating: 0.4, count: 16), from: .microphone)
        _ = try await producer.stop()

        let finals = events.revisions.filter { $0.isFinal && $0.sourceID == .microphone }
        XCTAssertEqual(finals.map(\.text), ["first", "context second"])
    }

    func testNewerFinalRevisionRejectsDelayedOlderPartial() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-revisions",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )
        let base = MeetingTranscriptionRequest(
            segmentID: "epoch-S0",
            sourceID: .microphone,
            timingEpochID: "epoch",
            windowSequence: 0,
            revision: 2,
            contextStartMilliseconds: 0,
            ownedStartMilliseconds: 0,
            ownedEndMilliseconds: 800,
            isFinal: true,
            samples: .init(repeating: 0.2, count: 10)
        )
        await producer.applyTranscriptionResultForTesting(
            .init(text: "plan Tuesday", tokens: [], processingMilliseconds: 4),
            request: base
        )
        await producer.applyTranscriptionResultForTesting(
            .init(text: "plan Tues", tokens: [], processingMilliseconds: 7),
            request: MeetingTranscriptionRequest(
                segmentID: base.segmentID,
                sourceID: base.sourceID,
                timingEpochID: base.timingEpochID,
                windowSequence: base.windowSequence,
                revision: 1,
                contextStartMilliseconds: 0,
                ownedStartMilliseconds: 0,
                ownedEndMilliseconds: 400,
                isFinal: false,
                samples: .init(repeating: 0.2, count: 4)
            )
        )

        XCTAssertEqual(events.revisions.map(\.text), ["plan Tuesday"])
        XCTAssertEqual(events.revisions.map(\.revision), [2])
        XCTAssertTrue(events.revisions[0].isFinal)
    }

    func testPauseDropsEverySourceAndResumeCreatesNewEpochs() async throws {
        let accepted = MeetingAcceptedAudioRecorder()
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-pause",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.timingEpochID,
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) },
            eventSink: { events.record($0) }
        )

        try await producer.start(initiallyPaused: true)
        await XCTAssertThrowsErrorAsync(try await producer.ingest([9, 9], from: .microphone))
        XCTAssertTrue(accepted.audio.isEmpty)

        try await producer.resume()
        try await producer.ingest([1, 1, 1, 1, 1], from: .microphone)
        try await producer.ingest([2, 2, 2, 2, 2], from: .systemAudio)
        try await producer.pause()
        let acceptedBeforePausedSpeech = accepted.audio.count
        await XCTAssertThrowsErrorAsync(try await producer.ingest([9, 9, 9], from: .systemAudio))
        XCTAssertEqual(accepted.audio.count, acceptedBeforePausedSpeech)

        try await producer.resume()
        try await producer.ingest([3, 3, 3, 3], from: .microphone)
        try await producer.ingest([4, 4, 4, 4], from: .systemAudio)
        let boundary = try await producer.stop()

        for source in MeetingAudioSourceID.allCases {
            XCTAssertEqual(boundary.timingEpochs.filter { $0.sourceID == source }.count, 2)
        }
        XCTAssertEqual(boundary.metrics.droppedAudioSampleCount, 0)
        XCTAssertFalse(accepted.audio.flatMap(\.samples).contains(9))
    }

    func testSourceInterruptionFinalizesTailAndRecoveryStartsNewEpoch() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-route-change",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.timingEpochID,
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )

        try await producer.start(initiallyPaused: false)
        try await producer.ingest([1, 1, 1, 1, 1], from: .microphone)
        try await producer.sourceWasInterrupted(.microphone, message: "fixture route changed")
        await producer.markSourceCapturing(.microphone)
        try await producer.ingest([2, 2, 2, 2, 2], from: .microphone)
        let boundary = try await producer.stop()

        XCTAssertEqual(boundary.timingEpochs.filter { $0.sourceID == .microphone }.count, 2)
        XCTAssertEqual(events.revisions.filter { $0.isFinal }.count, 2)
        XCTAssertTrue(events.issues.contains { $0.code == .sourceInterrupted })
    }

    func testCheckpointReplayDoesNotRepeatCommittedPartialRevision() async throws {
        let accepted = MeetingAcceptedAudioRecorder()
        let originalEvents = MeetingEventRecorder()
        let transcriber = FakeMeetingTranscriber { request in
            MeetingTranscriptionResult(
                text: request.isFinal ? "stable final" : "stable partial",
                tokens: [],
                processingMilliseconds: 1
            )
        }
        let original = MeetingTranscriptProducer(
            sessionID: "fixture-replay",
            transcriber: transcriber,
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) },
            eventSink: { originalEvents.record($0) }
        )
        try await original.start(initiallyPaused: false)
        try await original.ingest(.init(repeating: 0.2, count: 5), from: .microphone)
        await original.waitUntilIdle()
        let checkpoint = await original.checkpoint()
        XCTAssertEqual(originalEvents.revisions.map(\.revision), [1])

        let resumedEvents = MeetingEventRecorder()
        let resumed = MeetingTranscriptProducer(
            sessionID: "fixture-replay",
            transcriber: transcriber,
            configuration: smallConfiguration,
            eventSink: { resumedEvents.record($0) }
        )
        try await resumed.start(initiallyPaused: false, resume: checkpoint)
        try await resumed.replayAcceptedAudio(accepted.audio)
        let boundary = try await resumed.stop()

        XCTAssertEqual(resumedEvents.revisions.map(\.text), ["stable final"])
        XCTAssertEqual(resumedEvents.revisions.map(\.revision), [2])
        XCTAssertEqual(boundary.finalSegmentRevisionByID.values.sorted(), [2])
    }

    func testFailedWindowSurvivesLaterSuccessfulFinalAndReplaysWithoutDuplicate() async throws {
        let accepted = MeetingAcceptedAudioRecorder()
        let original = MeetingTranscriptProducer(
            sessionID: "fixture-failed-window",
            transcriber: FakeMeetingTranscriber { request in
                if request.isFinal && request.windowSequence == 0 {
                    throw FixtureTranscriptionError.failedWindow
                }
                return MeetingTranscriptionResult(
                    text: "window \(request.windowSequence)",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) }
        )
        try await original.start(initiallyPaused: false)
        try await original.ingest((0..<16).map(Float.init), from: .microphone)
        _ = try await original.stop()
        let checkpoint = await original.checkpoint()

        XCTAssertEqual(checkpoint.nextWindowSequenceByEpoch.values.sorted(), [0])
        XCTAssertEqual(checkpoint.completedWindowSequencesByEpoch.values.first, [1])
        XCTAssertEqual(checkpoint.pendingAudio.map(\.chunkID), accepted.audio.map(\.descriptor.chunkID))

        let resumedEvents = MeetingEventRecorder()
        let resumed = MeetingTranscriptProducer(
            sessionID: "fixture-failed-window",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: "replayed window \(request.windowSequence)",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            eventSink: { resumedEvents.record($0) }
        )
        try await resumed.start(initiallyPaused: false, resume: checkpoint)
        try await resumed.replayAcceptedAudio(accepted.audio)
        _ = try await resumed.stop()

        XCTAssertEqual(resumedEvents.revisions.map(\.windowSequence), [0])
        XCTAssertEqual(resumedEvents.revisions.map(\.text), ["replayed window 0"])
        let completedCheckpoint = await resumed.checkpoint()
        XCTAssertTrue(completedCheckpoint.pendingAudio.isEmpty)
        XCTAssertEqual(completedCheckpoint.nextWindowSequenceByEpoch.values.sorted(), [2])
    }

    func testCheckpointReplayTrimsChunkCrossingCommittedWindowBoundary() async throws {
        let accepted = MeetingAcceptedAudioRecorder()
        let original = MeetingTranscriptProducer(
            sessionID: "fixture-crossing-chunk",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.isFinal ? "final" : "partial",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) }
        )
        try await original.start(initiallyPaused: false)
        try await original.ingest((0..<16).map(Float.init), from: .microphone)
        await original.waitUntilIdle()
        let checkpointData = try JSONEncoder().encode(await original.checkpoint())
        let checkpoint = try JSONDecoder().decode(
            MeetingProducerCheckpoint.self,
            from: checkpointData
        )

        XCTAssertEqual(checkpoint.nextWindowSequenceByEpoch.values.sorted(), [1])
        XCTAssertEqual(checkpoint.pendingAudio.count, 1)
        XCTAssertEqual(checkpoint.pendingAudio[0].startSample, 0)
        XCTAssertEqual(checkpoint.pendingAudio[0].endSample, 16)

        let requests = MeetingRequestRecorder()
        let resumed = MeetingTranscriptProducer(
            sessionID: "fixture-crossing-chunk",
            transcriber: FakeMeetingTranscriber { request in
                requests.record(request)
                return MeetingTranscriptionResult(
                    text: "replayed tail",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration
        )
        try await resumed.start(initiallyPaused: false, resume: checkpoint)
        try await resumed.replayAcceptedAudio(accepted.audio)
        _ = try await resumed.stop()

        XCTAssertEqual(requests.requests.count, 1)
        XCTAssertEqual(requests.requests[0].windowSequence, 1)
        XCTAssertEqual(requests.requests[0].revision, 2)
        XCTAssertEqual(requests.requests[0].samples, (8..<16).map(Float.init))
    }

    func testCheckpointReplayPreservesPendingAudioAcrossMultipleEpochs() async throws {
        let accepted = MeetingAcceptedAudioRecorder()
        let original = MeetingTranscriptProducer(
            sessionID: "fixture-multiple-epochs",
            transcriber: FakeMeetingTranscriber { _ in
                throw FixtureTranscriptionError.failedWindow
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) }
        )
        try await original.start(initiallyPaused: false)
        try await original.ingest([1, 1, 1], from: .microphone)
        try await original.pause()
        try await original.resume()
        try await original.ingest([2, 2, 2], from: .microphone)
        try await original.pause()
        let checkpoint = await original.checkpoint()

        XCTAssertEqual(checkpoint.timingEpochs.count, 2)
        XCTAssertEqual(checkpoint.pendingAudio.count, 2)

        let resumedEvents = MeetingEventRecorder()
        let resumed = MeetingTranscriptProducer(
            sessionID: "fixture-multiple-epochs",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.timingEpochID,
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            eventSink: { resumedEvents.record($0) }
        )
        try await resumed.start(initiallyPaused: false, resume: checkpoint)
        try await resumed.replayAcceptedAudio(accepted.audio)
        _ = try await resumed.stop()

        XCTAssertEqual(resumedEvents.revisions.filter(\.isFinal).count, 2)
        XCTAssertEqual(Set(resumedEvents.revisions.map(\.timingEpochID)).count, 2)
        let completedCheckpoint = await resumed.checkpoint()
        XCTAssertTrue(completedCheckpoint.pendingAudio.isEmpty)
    }

    func testSharedMonotonicTimelineAlignsDelayedSystemAudio() async throws {
        let accepted = MeetingAcceptedAudioRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-shared-timeline",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.sourceID.rawValue,
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) }
        )
        try await producer.start(initiallyPaused: false)
        try await producer.ingest(
            [1, 1, 1, 1, 1],
            from: .microphone,
            presentationTimeNanoseconds: 10_000_000_000
        )
        try await producer.ingest(
            [2, 2, 2, 2, 2],
            from: .systemAudio,
            presentationTimeNanoseconds: 12_000_000_000
        )
        _ = try await producer.stop()

        let microphone = try XCTUnwrap(accepted.audio.first {
            $0.descriptor.sourceID == .microphone
        })
        let system = try XCTUnwrap(accepted.audio.first {
            $0.descriptor.sourceID == .systemAudio
        })
        XCTAssertEqual(microphone.descriptor.startMilliseconds, 0)
        XCTAssertEqual(system.descriptor.startMilliseconds, 2_000)
        XCTAssertEqual(system.descriptor.startSample, 20)
    }

    func testSyntheticSixtyMinuteDualSourceFixtureRemainsBounded() async throws {
        let configuration = MeetingTranscriptProducer.Configuration(
            sampleRate: 10,
            windowMilliseconds: 60_000,
            overlapMilliseconds: 1_000,
            firstPartialMilliseconds: 30_000,
            partialIntervalMilliseconds: 30_000,
            maximumQueuedWindows: 16
        )
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-sixty-minutes",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "", tokens: [], processingMilliseconds: 3)
            },
            configuration: configuration
        )
        try await producer.start(initiallyPaused: false)

        var maximumBufferedSamples = 0
        for second in 0..<(60 * 60) {
            try await producer.ingest(.init(repeating: 0.01, count: 10), from: .microphone)
            try await producer.ingest(.init(repeating: 0.02, count: 10), from: .systemAudio)
            if second % 60 == 59 {
                await producer.waitUntilIdle()
                maximumBufferedSamples = max(
                    maximumBufferedSamples,
                    await producer.bufferedSampleCount()
                )
            }
        }
        let boundary = try await producer.stop()

        XCTAssertEqual(boundary.metrics.acceptedSamplesBySource[.microphone], 36_000)
        XCTAssertEqual(boundary.metrics.acceptedSamplesBySource[.systemAudio], 36_000)
        XCTAssertEqual(boundary.metrics.droppedAudioSampleCount, 0)
        XCTAssertEqual(boundary.metrics.transcriptionFailureCount, 0)
        XCTAssertLessThanOrEqual(boundary.metrics.maximumQueuedWindowCount, 16)
        XCTAssertEqual(boundary.metrics.maximumProcessingMilliseconds, 3)
        XCTAssertLessThan(maximumBufferedSamples, configuration.windowSamples * 2)
        XCTAssertLessThan(maximumBufferedSamples * MemoryLayout<Float>.stride, 4_800)
        print(
            "RR-365 synthetic-60m accepted=\(boundary.metrics.acceptedChunkCount) " +
            "max_queue=\(boundary.metrics.maximumQueuedWindowCount) " +
            "max_buffer_bytes=\(maximumBufferedSamples * MemoryLayout<Float>.stride) " +
            "max_processing_ms=\(boundary.metrics.maximumProcessingMilliseconds) " +
            "dropped=\(boundary.metrics.droppedAudioSampleCount)"
        )
    }

    func testBackpressureStopsInsteadOfSilentlyDroppingFinalAudio() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-backpressure",
            transcriber: FakeMeetingTranscriber(delayNanoseconds: 100_000_000) { _ in
                MeetingTranscriptionResult(text: "slow", tokens: [], processingMilliseconds: 100)
            },
            configuration: MeetingTranscriptProducer.Configuration(
                sampleRate: 10,
                windowMilliseconds: 1_000,
                overlapMilliseconds: 100,
                firstPartialMilliseconds: 900,
                partialIntervalMilliseconds: 900,
                maximumQueuedWindows: 1
            ),
            eventSink: { events.record($0) }
        )
        try await producer.start(initiallyPaused: false)
        try await producer.ingest(.init(repeating: 0.2, count: 10), from: .microphone)
        try await producer.ingest(.init(repeating: 0.2, count: 10), from: .microphone)

        await XCTAssertThrowsErrorAsync(
            try await producer.ingest(.init(repeating: 0.2, count: 10), from: .microphone)
        ) { error in
            XCTAssertEqual(error as? MeetingProducerError, .backpressureExceeded)
        }
        XCTAssertTrue(events.issues.contains { $0.code == .backpressureExceeded })
    }

    private var smallConfiguration: MeetingTranscriptProducer.Configuration {
        MeetingTranscriptProducer.Configuration(
            sampleRate: 10,
            windowMilliseconds: 1_000,
            overlapMilliseconds: 200,
            firstPartialMilliseconds: 400,
            partialIntervalMilliseconds: 400,
            maximumQueuedWindows: 32
        )
    }

    private func eventually(
        timeout: TimeInterval = 1,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for asynchronous fixture state")
    }
}

private final class FakeMeetingTranscriber: MeetingWindowTranscribing, @unchecked Sendable {
    private let delayNanoseconds: UInt64
    private let result: @Sendable (MeetingTranscriptionRequest) throws -> MeetingTranscriptionResult

    init(
        delayNanoseconds: UInt64 = 0,
        result: @escaping @Sendable (MeetingTranscriptionRequest) throws -> MeetingTranscriptionResult
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    func prepare(
        onState: @escaping @Sendable (MeetingLocalModelState) -> Void
    ) async throws {
        onState(.ready(model: "synthetic-fixture"))
    }

    func transcribe(
        _ request: MeetingTranscriptionRequest
    ) async throws -> MeetingTranscriptionResult {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try result(request)
    }
}

private final class FakeMeetingAudioCapture: MeetingAudioCapturing, @unchecked Sendable {
    let sourceID: MeetingAudioSourceID
    private let batches: [[Float]]
    private let stopBatches: [[Float]]
    private let startFailure: MeetingAudioCaptureFailure?
    private let eventOnStart: MeetingAudioCaptureEvent?
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var nextPresentationTime: UInt64 = 1_000_000_000
    private var sampleHandler: (@Sendable (MeetingAudioFrame) -> Void)?
    private var eventHandler: (@Sendable (MeetingAudioCaptureEvent) -> Void)?

    var startCount: Int { lock.withTestLock { starts } }
    var stopCount: Int { lock.withTestLock { stops } }

    init(
        sourceID: MeetingAudioSourceID,
        samples: [[Float]],
        stopSamples: [[Float]] = [],
        startFailure: MeetingAudioCaptureFailure? = nil,
        eventOnStart: MeetingAudioCaptureEvent? = nil
    ) {
        self.sourceID = sourceID
        self.batches = samples
        self.stopBatches = stopSamples
        self.startFailure = startFailure
        self.eventOnStart = eventOnStart
    }

    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        lock.withTestLock {
            starts += 1
            self.sampleHandler = sampleHandler
            self.eventHandler = eventHandler
        }
        if let startFailure { throw startFailure }
        emit(batches)
        if let eventOnStart { eventHandler(eventOnStart) }
        return MeetingCaptureSourceInfo(
            sourceID: sourceID,
            routeID: "fixture-\(sourceID.rawValue)",
            sampleRate: 10,
            channelCount: 1
        )
    }

    func stop() async {
        emit(stopBatches)
        lock.withTestLock {
            stops += 1
            sampleHandler = nil
            eventHandler = nil
        }
    }

    func emit(_ batches: [[Float]]) {
        for batch in batches {
            let callback: ((@Sendable (MeetingAudioFrame) -> Void)?, UInt64) = lock.withTestLock {
                let presentationTime = nextPresentationTime
                nextPresentationTime += UInt64(batch.count) * 100_000_000
                return (sampleHandler, presentationTime)
            }
            callback.0?(MeetingAudioFrame(
                samples: batch,
                presentationTimeNanoseconds: callback.1
            ))
        }
    }
}

private final class MeetingEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingProducerEvent] = []

    func record(_ event: MeetingProducerEvent) {
        lock.withTestLock { values.append(event) }
    }

    var revisions: [MeetingTranscriptSegmentRevision] {
        lock.withTestLock {
            values.compactMap {
                if case .revision(let revision) = $0 { return revision }
                return nil
            }
        }
    }

    var issues: [MeetingCaptureIssue] {
        lock.withTestLock {
            values.compactMap {
                if case .issue(let issue) = $0 { return issue }
                return nil
            }
        }
    }

    var states: [MeetingProducerState] {
        lock.withTestLock {
            values.compactMap {
                if case .state(let state) = $0 { return state }
                return nil
            }
        }
    }

    var sourceStates: [(MeetingAudioSourceID, MeetingCaptureSourceState)] {
        lock.withTestLock {
            values.compactMap {
                if case .source(let source, let state) = $0 { return (source, state) }
                return nil
            }
        }
    }
}

private final class MeetingAcceptedAudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingAcceptedAudio] = []

    func record(_ audio: MeetingAcceptedAudio) async throws {
        lock.withTestLock { values.append(audio) }
    }

    var audio: [MeetingAcceptedAudio] { lock.withTestLock { values } }
}

private actor BlockingMeetingAcceptedAudioSink {
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    var recordingCount: Int { count }

    func record(_ audio: MeetingAcceptedAudio) async {
        count += 1
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class MeetingRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingTranscriptionRequest] = []

    func record(_ request: MeetingTranscriptionRequest) {
        lock.withTestLock { values.append(request) }
    }

    var requests: [MeetingTranscriptionRequest] { lock.withTestLock { values } }
}

private enum FixtureTranscriptionError: Error {
    case failedWindow
}

private struct FailingMeetingTranscriber: MeetingWindowTranscribing {
    struct MissingModel: LocalizedError {
        var errorDescription: String? { "Synthetic model is corrupt." }
    }

    func prepare(
        onState: @escaping @Sendable (MeetingLocalModelState) -> Void
    ) async throws {
        throw MissingModel()
    }

    func transcribe(
        _ request: MeetingTranscriptionRequest
    ) async throws -> MeetingTranscriptionResult {
        throw MissingModel()
    }
}

private extension NSLock {
    func withTestLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
