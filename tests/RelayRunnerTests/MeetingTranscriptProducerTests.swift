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
    private let result: @Sendable (MeetingTranscriptionRequest) -> MeetingTranscriptionResult

    init(
        delayNanoseconds: UInt64 = 0,
        result: @escaping @Sendable (MeetingTranscriptionRequest) -> MeetingTranscriptionResult
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
        return result(request)
    }
}

private final class FakeMeetingAudioCapture: MeetingAudioCapturing, @unchecked Sendable {
    let sourceID: MeetingAudioSourceID
    private let batches: [[Float]]
    private let startFailure: MeetingAudioCaptureFailure?
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withTestLock { starts } }
    var stopCount: Int { lock.withTestLock { stops } }

    init(
        sourceID: MeetingAudioSourceID,
        samples: [[Float]],
        startFailure: MeetingAudioCaptureFailure? = nil
    ) {
        self.sourceID = sourceID
        self.batches = samples
        self.startFailure = startFailure
    }

    func start(
        sampleHandler: @escaping @Sendable ([Float]) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        lock.withTestLock { starts += 1 }
        if let startFailure { throw startFailure }
        for batch in batches { sampleHandler(batch) }
        return MeetingCaptureSourceInfo(
            sourceID: sourceID,
            routeID: "fixture-\(sourceID.rawValue)",
            sampleRate: 10,
            channelCount: 1
        )
    }

    func stop() async {
        lock.withTestLock { stops += 1 }
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
