import Foundation
import XCTest
@testable import relay_runner

final class MeetingTranscriptProducerTests: XCTestCase {
    func testSystemAudioCallbackGateRejectsOldStreamCallbacksAfterRestart() {
        let gate = MeetingSystemAudioCallbackGate()
        let oldStream = NSObject()
        let newStream = NSObject()
        let oldEvents = MeetingSystemAudioCallbackRecorder()
        let newEvents = MeetingSystemAudioCallbackRecorder()

        gate.activate(
            stream: oldStream,
            sampleHandler: { oldEvents.record($0) },
            eventHandler: { oldEvents.record($0) }
        )
        gate.deliver(
            MeetingAudioFrame(samples: [10], presentationTimeNanoseconds: 10),
            from: oldStream
        )
        gate.deliver(.interrupted("old stream active"), from: oldStream)
        gate.activate(
            stream: newStream,
            sampleHandler: { newEvents.record($0) },
            eventHandler: { newEvents.record($0) }
        )

        gate.deliver(
            MeetingAudioFrame(samples: [11], presentationTimeNanoseconds: 11),
            from: oldStream
        )
        gate.deliver(
            .failed(.unavailable(.systemAudio, "stale stream stopped")),
            from: oldStream
        )
        gate.deactivate(stream: oldStream)
        gate.deliver(
            MeetingAudioFrame(samples: [22], presentationTimeNanoseconds: 22),
            from: newStream
        )
        gate.deliver(
            .failed(.unavailable(.systemAudio, "active stream stopped")),
            from: newStream
        )

        XCTAssertEqual(oldEvents.frames.map(\.samples), [[10]])
        XCTAssertEqual(oldEvents.events, [.interrupted("old stream active")])
        XCTAssertEqual(newEvents.frames.map(\.samples), [[22]])
        XCTAssertEqual(
            newEvents.events,
            [.failed(.unavailable(.systemAudio, "active stream stopped"))]
        )
    }

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

    func testStopQuiescenceRejectsLateCallbacksFromBothSources() async throws {
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-stop-quiescence",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "fixture", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration
        )
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [[Float](repeating: 0.2, count: 10)],
            stopSamples: [[Float](repeating: 0.4, count: 10)]
        )
        let system = FakeMeetingAudioCapture(
            sourceID: .systemAudio,
            samples: [[Float](repeating: 0.3, count: 10)],
            stopSamples: [[Float](repeating: 0.5, count: 10)]
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [microphone, system])
        try await session.start(initiallyPaused: false)
        try await eventually { await producer.currentMetrics().acceptedChunkCount == 2 }

        await session.quiesceCaptureSources()
        let ingressClosed = await session.captureIngressIsClosedForTesting()
        XCTAssertTrue(ingressClosed)
        microphone.emit([[Float](repeating: 0.6, count: 10)])
        system.emit([[Float](repeating: 0.7, count: 10)])
        let boundary = try await session.stop()

        XCTAssertEqual(boundary.metrics.acceptedChunkCount, 2)
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(system.stopCount, 1)
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

    func testUnsupportedSystemAudioFormatAtStartupEmitsTypedIssue() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-system-format-startup",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(sourceID: .microphone, samples: [])
        let system = FakeMeetingAudioCapture(
            sourceID: .systemAudio,
            samples: [],
            startFailure: .unsupportedFormat(.systemAudio, "fixture Float32 mismatch")
        )
        let session = MeetingNoteCaptureSession(
            producer: producer,
            captures: [microphone, system]
        )

        try await session.start(initiallyPaused: false)
        try await eventually {
            events.issues.contains {
                $0.code == .formatChanged && $0.sourceID == .systemAudio
            }
        }

        XCTAssertEqual(
            events.sourceStates.last { $0.0 == .systemAudio }?.1,
            .unavailable
        )
        XCTAssertFalse(events.issues.contains {
            $0.code == .sourceUnavailable && $0.sourceID == .systemAudio
        })
        _ = try await session.stop()
        XCTAssertEqual(system.stopCount, 1)
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

    func testIngressOverloadStopsAdapterThatAcquiresResourcesAfterTeardown() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-overload-during-start",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )
        let setupGate = MeetingStartReturnGate()
        let microphone = DelayedOverloadMeetingAudioCapture(setupGate: setupGate)
        let session = MeetingNoteCaptureSession(
            producer: producer,
            captures: [microphone],
            maximumPendingFrames: 1
        )

        let startTask = Task { () -> Bool in
            do {
                try await session.start(initiallyPaused: false)
                return true
            } catch {
                return false
            }
        }
        try await eventually {
            microphone.stopCount == 1
        }
        XCTAssertFalse(microphone.isRunning)

        await setupGate.open()
        let startSucceeded = await startTask.value
        XCTAssertFalse(startSucceeded)
        XCTAssertEqual(microphone.stopCount, 2)
        XCTAssertFalse(microphone.isRunning)
        XCTAssertTrue(events.issues.contains { $0.code == .backpressureExceeded })

        await XCTAssertThrowsErrorAsync(try await session.stop()) { error in
            XCTAssertEqual(error as? MeetingProducerError, .backpressureExceeded)
        }
        XCTAssertEqual(microphone.stopCount, 2)
        XCTAssertFalse(microphone.isRunning)
    }

    func testPauseClosesIngressBeforeDelayedAdaptersAndDrainsAcceptedTail() async throws {
        let accepted = BlockingMeetingAcceptedAudioSink(blockAtRecordingCount: 2)
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-pause-tail",
            transcriber: FakeMeetingTranscriber { request in
                let samples = request.samples.map { String(Int($0)) }.joined()
                return MeetingTranscriptionResult(
                    text: "\(request.sourceID.rawValue):\(samples)",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { await accepted.record($0) },
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [],
            stopSamples: [[9, 9]],
            stopDelayNanoseconds: 50_000_000
        )
        let system = FakeMeetingAudioCapture(
            sourceID: .systemAudio,
            samples: [],
            stopSamples: [[8, 8]],
            stopDelayNanoseconds: 50_000_000
        )
        let session = MeetingNoteCaptureSession(
            producer: producer,
            captures: [microphone, system],
            maximumPendingFrames: 4
        )

        try await session.start(initiallyPaused: false)
        microphone.emit([[1, 1]])
        system.emit([[2, 2]])
        microphone.emit([[3, 3]])
        try await eventually {
            await accepted.recordingCount == 2
        }

        let blockedCheckpoint = await session.checkpoint()
        let blockedAudio = await accepted.audio
        XCTAssertEqual(blockedCheckpoint.pendingAudio, [blockedAudio[0].descriptor])
        XCTAssertEqual(blockedAudio[0].samples, [1, 1])

        let pauseTask = Task { try await session.pause() }
        try await eventually {
            microphone.stopBeginCount + system.stopBeginCount > 0
        }
        await accepted.release()
        try await pauseTask.value

        let persisted = await accepted.audio
        XCTAssertEqual(persisted.map(\.descriptor.sourceID), [
            .microphone,
            .systemAudio,
            .microphone,
        ])
        XCTAssertEqual(persisted.map(\.samples), [[1, 1], [2, 2], [3, 3]])
        XCTAssertEqual(events.revisions.filter(\.isFinal).map(\.text).sorted(), [
            "microphone:1133",
            "system_audio:22",
        ])
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(system.stopCount, 1)
        let boundary = try await session.stop()
        XCTAssertEqual(boundary.metrics.acceptedSamplesBySource[.microphone], 4)
        XCTAssertEqual(boundary.metrics.acceptedSamplesBySource[.systemAudio], 2)
        XCTAssertEqual(boundary.metrics.acceptedChunkCount, 3)
        XCTAssertEqual(boundary.metrics.droppedAudioSampleCount, 0)
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(system.stopCount, 1)
    }

    func testStopDrainsInCapacityBurstThroughSlowSinkWithoutReordering() async throws {
        let accepted = BlockingMeetingAcceptedAudioSink(blockAtRecordingCount: 2)
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-stop-tail",
            transcriber: FakeMeetingTranscriber { request in
                let samples = request.samples.map { String(Int($0)) }.joined()
                return MeetingTranscriptionResult(
                    text: "\(request.sourceID.rawValue):\(samples)",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { await accepted.record($0) },
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [],
            stopSamples: [[9]],
            stopDelayNanoseconds: 50_000_000
        )
        let system = FakeMeetingAudioCapture(
            sourceID: .systemAudio,
            samples: [],
            stopSamples: [[8]],
            stopDelayNanoseconds: 50_000_000
        )
        let session = MeetingNoteCaptureSession(
            producer: producer,
            captures: [microphone, system],
            maximumPendingFrames: 4
        )

        try await session.start(initiallyPaused: false)
        system.emit([[4]])
        microphone.emit([[5]])
        system.emit([[6]])
        try await eventually {
            await accepted.recordingCount == 2
        }

        let stopTask = Task { try await session.stop() }
        try await eventually {
            microphone.stopBeginCount + system.stopBeginCount > 0
        }
        await accepted.release()
        let boundary = try await stopTask.value

        let persisted = await accepted.audio
        XCTAssertEqual(persisted.map(\.descriptor.sourceID), [
            .systemAudio,
            .microphone,
            .systemAudio,
        ])
        XCTAssertEqual(persisted.map(\.samples), [[4], [5], [6]])
        XCTAssertEqual(events.revisions.filter(\.isFinal).map(\.text).sorted(), [
            "microphone:5",
            "system_audio:46",
        ])
        XCTAssertEqual(boundary.metrics.acceptedChunkCount, 3)
        XCTAssertEqual(boundary.metrics.droppedAudioSampleCount, 0)
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(system.stopCount, 1)
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
            $0.code == .formatChanged && $0.sourceID == .systemAudio
        })
    }

    func testFailedEventConsumedBeforeStartReturnsRemainsUnavailable() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-failure-during-start",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )
        let startReturnGate = MeetingStartReturnGate()
        let system = FakeMeetingAudioCapture(
            sourceID: .systemAudio,
            samples: [],
            eventOnStart: .failed(.unsupportedFormat(.systemAudio, "fixture format changed")),
            startReturnGate: startReturnGate
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [system])

        let startTask = Task { try await session.start(initiallyPaused: false) }
        try await eventually {
            events.sourceStates.last { $0.0 == .systemAudio }?.1 == .unavailable
        }
        await startReturnGate.open()
        try await startTask.value

        XCTAssertEqual(
            events.sourceStates.last { $0.0 == .systemAudio }?.1,
            .unavailable
        )
        _ = try await session.stop()
        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(system.stopCount, 1)
    }

    func testFramesAfterFailureStayGatedUntilExplicitRecovery() async throws {
        let events = MeetingEventRecorder()
        let accepted = MeetingAcceptedAudioRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-post-failure-gate",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.samples.map { String(Int($0)) }.joined(),
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) },
            eventSink: { events.record($0) }
        )
        let startReturnGate = MeetingStartReturnGate()
        let system = FakeMeetingAudioCapture(
            sourceID: .systemAudio,
            samples: [],
            eventOnStart: .failed(.unsupportedFormat(.systemAudio, "fixture format changed")),
            startReturnGate: startReturnGate
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [system])

        let startTask = Task { try await session.start(initiallyPaused: false) }
        try await eventually {
            events.sourceStates.last { $0.0 == .systemAudio }?.1 == .unavailable
        }
        system.emit([[9, 9]])
        await startReturnGate.open()
        try await startTask.value
        XCTAssertEqual(
            events.sourceStates.last { $0.0 == .systemAudio }?.1,
            .unavailable
        )

        system.emitEvent(.recovered(MeetingCaptureSourceInfo(
            sourceID: .systemAudio,
            routeID: "fixture-system-recovered",
            sampleRate: 10,
            channelCount: 1
        )))
        try await eventually {
            events.sourceStates.last { $0.0 == .systemAudio }?.1 == .capturing
        }
        system.emit([[3, 3, 3]])
        try await eventually {
            accepted.audio.count == 1
        }

        let checkpoint = await session.checkpoint()
        XCTAssertEqual(accepted.audio.map(\.samples), [[3, 3, 3]])
        XCTAssertEqual(checkpoint.metrics.acceptedSamplesBySource[.systemAudio], 3)
        XCTAssertFalse(checkpoint.pendingAudio.contains { $0.sampleCount == 2 })

        _ = try await session.stop()
        XCTAssertEqual(events.revisions.filter(\.isFinal).map(\.text), ["333"])
        XCTAssertFalse(events.revisions.contains { $0.text.contains("9") })
    }

    func testFramesAfterInterruptionStayGatedUntilExplicitRecovery() async throws {
        let events = MeetingEventRecorder()
        let accepted = MeetingAcceptedAudioRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-post-interruption-gate",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.samples.map { String(Int($0)) }.joined(),
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) },
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(sourceID: .microphone, samples: [])
        let session = MeetingNoteCaptureSession(producer: producer, captures: [microphone])

        try await session.start(initiallyPaused: false)
        microphone.emit([[1]])
        try await eventually {
            accepted.audio.count == 1
        }
        microphone.emitEvent(.interrupted("fixture route rebuild"))
        try await eventually {
            events.sourceStates.last { $0.0 == .microphone }?.1 == .interrupted
        }
        microphone.emit([[2, 2]])
        microphone.emitEvent(.recovered(MeetingCaptureSourceInfo(
            sourceID: .microphone,
            routeID: "fixture-microphone-recovered",
            sampleRate: 10,
            channelCount: 1
        )))
        try await eventually {
            events.sourceStates.last { $0.0 == .microphone }?.1 == .capturing
        }
        microphone.emit([[3, 3, 3]])
        try await eventually {
            accepted.audio.count == 2
        }

        let checkpoint = await session.checkpoint()
        XCTAssertEqual(accepted.audio.map(\.samples), [[1], [3, 3, 3]])
        XCTAssertEqual(checkpoint.metrics.acceptedSamplesBySource[.microphone], 4)
        XCTAssertFalse(checkpoint.pendingAudio.contains { $0.sampleCount == 2 })

        let boundary = try await session.stop()
        XCTAssertEqual(boundary.metrics.acceptedChunkCount, 2)
        XCTAssertEqual(events.revisions.filter(\.isFinal).map(\.text), ["1", "333"])
        XCTAssertFalse(events.revisions.contains { $0.text.contains("2") })
    }

    func testMicrophoneConversionRecoveryFailureEmitsTypedIssue() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-microphone-format-recovery",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )
        let microphone = FakeMeetingAudioCapture(sourceID: .microphone, samples: [])
        let session = MeetingNoteCaptureSession(producer: producer, captures: [microphone])
        let failure = MeetingMicrophoneAudioCapture.captureFailure(
            from: .converterUnavailable(sampleRate: 48_000, channelCount: 2)
        )

        XCTAssertEqual(
            failure,
            .unsupportedFormat(
                .microphone,
                "The microphone format cannot be converted to 16 kHz mono (48000.0 Hz, 2 channels)."
            )
        )
        try await session.start(initiallyPaused: false)
        microphone.emitEvent(.interrupted("fixture conversion-failure rebuild"))
        try await eventually {
            events.sourceStates.last { $0.0 == .microphone }?.1 == .interrupted
        }
        microphone.emitEvent(.failed(failure))
        try await eventually {
            events.issues.contains {
                $0.code == .formatChanged && $0.sourceID == .microphone
            }
        }

        XCTAssertEqual(
            events.sourceStates.last { $0.0 == .microphone }?.1,
            .unavailable
        )
        XCTAssertFalse(events.issues.contains {
            $0.code == .sourceUnavailable && $0.sourceID == .microphone
        })
        _ = try await session.stop()
    }

    func testFreshSuccessfulRestartRetainsFramesEmittedBeforeStartReturns() async throws {
        let events = MeetingEventRecorder()
        let accepted = MeetingAcceptedAudioRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-fresh-restart-frame",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.samples.map { String(Int($0)) }.joined(),
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) },
            eventSink: { events.record($0) }
        )
        let secondStartGate = MeetingStartReturnGate()
        let system = FakeMeetingAudioCapture(sourceID: .systemAudio, samples: [])
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [],
            samplesByStart: [2: [[22]]],
            startReturnGate: secondStartGate,
            gatedStart: 2
        )
        let session = MeetingNoteCaptureSession(
            producer: producer,
            captures: [system, microphone]
        )

        try await session.start(initiallyPaused: false)
        microphone.emit([[11]])
        try await eventually {
            accepted.audio.contains { $0.samples == [11] }
        }
        microphone.emitEvent(.failed(.unavailable(.microphone, "fixture source failure")))
        try await eventually {
            events.sourceStates.last { $0.0 == .microphone }?.1 == .unavailable
        }
        try await session.pause()

        let resumeTask = Task { try await session.resume() }
        try await eventually {
            microphone.startCount == 2
        }
        system.emit([[77]])
        try await eventually {
            accepted.audio.contains { $0.samples == [77] }
        }
        await secondStartGate.open()
        try await resumeTask.value
        try await eventually {
            accepted.audio.contains { $0.samples == [22] }
        }

        let checkpoint = await session.checkpoint()
        XCTAssertEqual(
            accepted.audio
                .filter { $0.descriptor.sourceID == .microphone }
                .map(\.samples),
            [[11], [22]]
        )
        XCTAssertEqual(
            events.sourceStates.last { $0.0 == .microphone }?.1,
            .capturing
        )
        XCTAssertEqual(checkpoint.metrics.acceptedSamplesBySource[.microphone], 2)
        XCTAssertEqual(checkpoint.metrics.droppedAudioSampleCount, 0)

        let boundary = try await session.stop()
        XCTAssertEqual(boundary.metrics.droppedAudioSampleCount, 0)
        XCTAssertTrue(events.revisions.contains { $0.isFinal && $0.text == "22" })
    }

    func testCaptureIngressCloseIsAtomicWithConcurrentSubmissions() async {
        let submissionCount = 64
        let ingress = MeetingCaptureIngress(maximumPendingItems: submissionCount)
        let queue = DispatchQueue(
            label: "MeetingTranscriptProducerTests.capture-boundary",
            attributes: .concurrent
        )
        let gate = DispatchSemaphore(value: 0)
        let completion = DispatchGroup()
        let acceptedLock = NSLock()
        var acceptedCount = 0

        for index in 0..<submissionCount {
            completion.enter()
            queue.async {
                gate.wait()
                let accepted = ingress.submit(.frame(
                    MeetingAudioFrame(
                        samples: [Float(index)],
                        presentationTimeNanoseconds: UInt64(index)
                    ),
                    .microphone,
                    0
                ))
                if accepted {
                    acceptedLock.withTestLock { acceptedCount += 1 }
                }
                completion.leave()
            }
        }
        completion.enter()
        queue.async {
            gate.wait()
            ingress.finish()
            completion.leave()
        }

        for _ in 0...submissionCount { gate.signal() }
        XCTAssertEqual(completion.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(ingress.submit(.frame(
            MeetingAudioFrame(samples: [999], presentationTimeNanoseconds: 999),
            .microphone,
            0
        )))

        var drainedCount = 0
        for await _ in ingress.stream { drainedCount += 1 }
        XCTAssertEqual(drainedCount, acceptedLock.withTestLock { acceptedCount })
    }

    func testPauseWaitsForAndStopsAdapterThatFinishesStarting() async throws {
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-delayed-start-teardown",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration
        )
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [],
            startDelayNanoseconds: 100_000_000
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [microphone])

        let startTask = Task { try await session.start(initiallyPaused: false) }
        try await eventually {
            microphone.startCount == 1
        }
        try await session.pause()
        await XCTAssertThrowsErrorAsync(try await startTask.value)

        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertFalse(microphone.isRunning)
        _ = try await session.stop()
    }

    func testPauseWaitsForAndStopsAdapterThatAcquiresResourcesThenFails() async throws {
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-delayed-start-failure-pause",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration
        )
        let startSetupGate = MeetingStartReturnGate()
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [],
            startFailure: .unavailable(.microphone, "fixture late startup failure"),
            startSetupGate: startSetupGate
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [microphone])

        let startTask = Task { try await session.start(initiallyPaused: false) }
        try await eventually {
            microphone.startCount == 1
        }
        let pauseTask = Task { try await session.pause() }
        try await eventually {
            await session.captureIngressIsClosedForTesting()
        }
        XCTAssertEqual(microphone.stopCount, 0)

        await startSetupGate.open()
        try await pauseTask.value
        await XCTAssertThrowsErrorAsync(try await startTask.value)

        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertFalse(microphone.isRunning)
        _ = try await session.stop()
    }

    func testStopWaitsForAndStopsAdapterThatAcquiresResourcesThenFails() async throws {
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-delayed-start-failure-stop",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(text: "unused", tokens: [], processingMilliseconds: 1)
            },
            configuration: smallConfiguration
        )
        let startSetupGate = MeetingStartReturnGate()
        let microphone = FakeMeetingAudioCapture(
            sourceID: .microphone,
            samples: [],
            startFailure: .unavailable(.microphone, "fixture late startup failure"),
            startSetupGate: startSetupGate
        )
        let session = MeetingNoteCaptureSession(producer: producer, captures: [microphone])

        let startTask = Task { try await session.start(initiallyPaused: false) }
        try await eventually {
            microphone.startCount == 1
        }
        let stopTask = Task { try await session.stop() }
        try await eventually {
            await session.captureIngressIsClosedForTesting()
        }
        XCTAssertEqual(microphone.stopCount, 0)

        await startSetupGate.open()
        _ = try await stopTask.value
        await XCTAssertThrowsErrorAsync(try await startTask.value)

        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertFalse(microphone.isRunning)
    }

    func testRapidRestartAfterDelayedTypedFailurePreservesNewOwnerAndContent() async throws {
        try await assertRapidRestartOwnership(after: .typedFailure)
    }

    func testRapidRestartAfterDelayedOrdinaryFailurePreservesNewOwnerAndContent() async throws {
        try await assertRapidRestartOwnership(after: .ordinaryFailure)
    }

    func testRapidRestartAfterDelayedSuccessPreservesNewOwnerAndContent() async throws {
        try await assertRapidRestartOwnership(after: .success)
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

    func testBoundaryOnsetRetainsFinalWordAndGenuineRepeatedSentenceBySource() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-boundary-final-word",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: "unused fallback",
                    tokens: [
                        .init(text: "amber ", startSeconds: 0.10, endSeconds: 0.20, confidence: 1),
                        .init(text: "telescope ", startSeconds: 0.30, endSeconds: 0.45, confidence: 1),
                        .init(text: "at ", startSeconds: 0.60, endSeconds: 0.70, confidence: 1),
                        .init(text: "sunset", startSeconds: 0.75, endSeconds: 0.85, confidence: 1),
                    ],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            eventSink: { events.record($0) }
        )

        try await producer.start(initiallyPaused: false)
        try await producer.ingest(.init(repeating: 0.4, count: 16), from: .microphone)
        try await producer.ingest(.init(repeating: 0.5, count: 16), from: .systemAudio)
        _ = try await producer.stop()

        for source in MeetingAudioSourceID.allCases {
            let finals = events.revisions.filter { $0.isFinal && $0.sourceID == source }
            XCTAssertEqual(finals.map(\.text), [
                "amber telescope at sunset",
                "amber telescope at sunset",
            ])
            XCTAssertEqual(finals.map(\.startMilliseconds), [0, 800])
            XCTAssertEqual(finals.map(\.endMilliseconds), [800, 1_600])
            XCTAssertNotEqual(finals[0].segmentID, finals[1].segmentID)
        }
    }

    func testSubwordSuffixesAndPunctuationFollowWordOnsetAcrossSources() async throws {
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-subword-boundary",
            transcriber: FakeMeetingTranscriber { request in
                let tokens: [MeetingRecognizedToken]
                if request.windowSequence == 0 {
                    tokens = [
                        .init(text: " Repeat", startSeconds: 0.10, endSeconds: 0.20, confidence: 1),
                        .init(text: " this", startSeconds: 0.30, endSeconds: 0.40, confidence: 1),
                        .init(text: " sent", startSeconds: 0.75, endSeconds: 0.80, confidence: 1),
                        .init(text: "ence", startSeconds: 0.82, endSeconds: 0.85, confidence: 1),
                        .init(text: ".", startSeconds: 0.86, endSeconds: 0.87, confidence: 1),
                        .init(text: " Repeat", startSeconds: 0.90, endSeconds: 0.95, confidence: 1),
                    ]
                } else {
                    tokens = [
                        .init(text: " Repeat", startSeconds: 0.00, endSeconds: 0.10, confidence: 1),
                        .init(text: " this", startSeconds: 0.20, endSeconds: 0.30, confidence: 1),
                        .init(text: " sentence", startSeconds: 0.40, endSeconds: 0.50, confidence: 1),
                        .init(text: ".", startSeconds: 0.51, endSeconds: 0.52, confidence: 1),
                        .init(text: " amber", startSeconds: 0.55, endSeconds: 0.60, confidence: 1),
                        .init(text: " telescope", startSeconds: 0.62, endSeconds: 0.65, confidence: 1),
                        .init(text: " at", startSeconds: 0.66, endSeconds: 0.69, confidence: 1),
                        .init(text: " sun", startSeconds: 0.70, endSeconds: 0.73, confidence: 1),
                        .init(text: "set", startSeconds: 0.75, endSeconds: 0.77, confidence: 1),
                        .init(text: ".", startSeconds: 0.78, endSeconds: 0.79, confidence: 1),
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
        for source in MeetingAudioSourceID.allCases {
            try await producer.ingest(.init(repeating: 0.4, count: 16), from: source)
        }
        _ = try await producer.stop()

        for source in MeetingAudioSourceID.allCases {
            let finals = events.revisions.filter { $0.isFinal && $0.sourceID == source }
            XCTAssertEqual(finals.map(\.text), [
                "Repeat this sentence.",
                "Repeat this sentence. amber telescope at sunset.",
            ])
            XCTAssertEqual(finals.map(\.startMilliseconds), [0, 800])
            XCTAssertEqual(finals.map(\.endMilliseconds), [800, 1_600])
        }
    }

    func testStopRetriesTransientFinalWindowBeforeLeavingAcceptedAudioPending() async throws {
        let accepted = MeetingAcceptedAudioRecorder()
        let events = MeetingEventRecorder()
        let attempts = MeetingRequestRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-stop-retry",
            transcriber: FakeMeetingTranscriber { request in
                attempts.record(request)
                if attempts.requests.count == 1 {
                    throw FixtureTranscriptionError.failedWindow
                }
                return MeetingTranscriptionResult(
                    text: "complete tail",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) },
            eventSink: { events.record($0) }
        )

        try await producer.start(initiallyPaused: false)
        try await producer.ingest([0.2, 0.4], from: .microphone)
        let boundary = try await producer.stop()
        let checkpoint = await producer.checkpoint()

        XCTAssertEqual(attempts.requests.count, 2)
        XCTAssertEqual(attempts.requests[0], attempts.requests[1])
        XCTAssertEqual(events.revisions.filter(\.isFinal).map(\.text), ["complete tail"])
        XCTAssertEqual(boundary.metrics.transcriptionFailureCount, 1)
        XCTAssertTrue(checkpoint.pendingAudio.isEmpty)
        XCTAssertEqual(accepted.audio.count, 1)
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

    func testAcceptedIngestPersistsReplayCursorBeforeReturning() async throws {
        let audio = MeetingAcceptedAudioRecorder()
        let checkpoints = MeetingProducerCheckpointRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-durable-ingest-cursor",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(
                    text: "durable",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await audio.record($0) },
            durableCheckpointSink: { await checkpoints.record($0) }
        )
        try await producer.start(initiallyPaused: false)

        try await producer.ingest([1, 2, 3], from: .microphone)

        let persisted = await checkpoints.values
        XCTAssertEqual(audio.audio.count, 1)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].metrics.acceptedChunkCount, 1)
        XCTAssertEqual(persisted[0].pendingAudio.map(\.chunkID), audio.audio.map(\.descriptor.chunkID))
    }

    func testFinalWindowCheckpointCarriesTextBeforeCoordinatorDrainsEvents() async throws {
        let checkpoints = MeetingProducerCheckpointRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-crash-before-event-drain",
            transcriber: FakeMeetingTranscriber { request in
                let phrases = [
                    "Repeat this sentence",
                    "Repeat this sentence",
                    "quiet harbor sunset",
                ]
                return MeetingTranscriptionResult(
                    text: phrases[min(request.windowSequence, phrases.count - 1)],
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            durableCheckpointSink: { await checkpoints.record($0) }
        )
        try await producer.start(initiallyPaused: false)
        for _ in 0..<3 {
            try await producer.ingest(.init(repeating: 0.25, count: 8), from: .microphone)
        }
        _ = try await producer.stop()

        // No event sink was drained. The checkpoint alone must carry every
        // completed window whose replay cursor is now beyond its audio.
        let values = await checkpoints.values
        let persisted = try XCTUnwrap(values.last)
        XCTAssertTrue(persisted.pendingAudio.isEmpty)
        XCTAssertEqual(persisted.nextWindowSequenceByEpoch.values.first, 3)
        XCTAssertEqual(
            persisted.durableRevisions?.map(\.text),
            ["Repeat this sentence", "Repeat this sentence", "quiet harbor sunset"]
        )
        XCTAssertEqual(persisted.durableRevisions?.map(\.startMilliseconds), [0, 800, 1_600])
        XCTAssertEqual(Set(persisted.durableRevisions?.map(\.segmentID) ?? []).count, 3)
    }

    func testFailedRevisionCheckpointLeavesAcceptedAudioReplayable() async throws {
        let checkpoints = MeetingProducerCheckpointRecorder()
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-revision-write-failure",
            transcriber: FakeMeetingTranscriber { _ in
                MeetingTranscriptionResult(
                    text: "Repeat this sentence",
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            durableCheckpointSink: { checkpoint in
                if checkpoint.metrics.processedWindowCount > 0 {
                    throw FixtureTranscriptionError.failedWindow
                }
                await checkpoints.record(checkpoint)
            },
            eventSink: { events.record($0) }
        )
        try await producer.start(initiallyPaused: false)
        try await producer.ingest(.init(repeating: 0.25, count: 10), from: .microphone)
        await producer.waitUntilIdle()

        let persisted = await checkpoints.values
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].pendingAudio.count, 1)
        XCTAssertEqual(persisted[0].nextWindowSequenceByEpoch.values.first, 0)
        XCTAssertTrue(persisted[0].durableRevisions?.isEmpty == true)
        XCTAssertTrue(events.revisions.isEmpty)
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

    private func assertRapidRestartOwnership(
        after delayedOutcome: DelayedMeetingStartOutcome
    ) async throws {
        let startGate = MeetingStartReturnGate()
        let accepted = MeetingAcceptedAudioRecorder()
        let events = MeetingEventRecorder()
        let producer = MeetingTranscriptProducer(
            sessionID: "fixture-rapid-restart-\(delayedOutcome)",
            transcriber: FakeMeetingTranscriber { request in
                MeetingTranscriptionResult(
                    text: request.samples.map { String(Int($0)) }.joined(separator: " "),
                    tokens: [],
                    processingMilliseconds: 1
                )
            },
            configuration: smallConfiguration,
            acceptedAudioSink: { try await accepted.record($0) },
            eventSink: { events.record($0) }
        )
        let microphone = AttemptOwnedMeetingAudioCapture(
            delayedOutcome: delayedOutcome,
            firstStartGate: startGate
        )
        let session = MeetingNoteCaptureSession(
            producer: producer,
            captures: [microphone]
        )

        let firstStart = Task { () -> Bool in
            do {
                try await session.start(initiallyPaused: false)
                return true
            } catch {
                return false
            }
        }
        try await eventually {
            microphone.startCount == 1
        }

        let pauseTask = Task { try await session.pause() }
        try await eventually {
            await session.captureIngressIsClosedForTesting()
        }
        XCTAssertEqual(microphone.liveAttempts, [])

        await startGate.open()
        try await pauseTask.value
        let firstStartSucceeded = await firstStart.value
        XCTAssertFalse(firstStartSucceeded)
        XCTAssertEqual(microphone.liveAttempts, [])

        try await session.resume()
        try await eventually {
            accepted.audio.map(\.samples) == [[22]]
        }
        XCTAssertEqual(microphone.liveAttempts, [2])
        XCTAssertEqual(
            events.sourceStates.last { $0.0 == .microphone }?.1,
            .capturing
        )

        microphone.emit([33], from: 2)
        try await eventually {
            accepted.audio.map(\.samples) == [[22], [33]]
        }
        let checkpoint = await session.checkpoint()
        XCTAssertEqual(checkpoint.metrics.acceptedSamplesBySource[.microphone], 2)
        XCTAssertEqual(checkpoint.metrics.droppedAudioSampleCount, 0)

        let boundary = try await session.stop()
        XCTAssertEqual(microphone.liveAttempts, [])
        XCTAssertEqual(accepted.audio.map(\.samples), [[22], [33]])
        XCTAssertFalse(accepted.audio.contains { $0.samples.contains(91) })
        XCTAssertEqual(boundary.metrics.droppedAudioSampleCount, 0)
        XCTAssertTrue(events.revisions.contains {
            $0.isFinal && $0.sourceID == .microphone && $0.text == "22 33"
        })
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

private enum DelayedMeetingStartOutcome {
    case success
    case typedFailure
    case ordinaryFailure
}

private enum DelayedMeetingStartError: Error {
    case failed
}

private final class AttemptOwnedMeetingAudioCapture: MeetingAudioCapturing, @unchecked Sendable {
    let sourceID = MeetingAudioSourceID.microphone

    private let delayedOutcome: DelayedMeetingStartOutcome
    private let firstStartGate: MeetingStartReturnGate
    private let lock = NSLock()
    private var starts = 0
    private var resources: Set<Int> = []
    private var handlers: [Int: @Sendable (MeetingAudioFrame) -> Void] = [:]
    private var nextPresentationTime: UInt64 = 1_000_000_000

    init(
        delayedOutcome: DelayedMeetingStartOutcome,
        firstStartGate: MeetingStartReturnGate
    ) {
        self.delayedOutcome = delayedOutcome
        self.firstStartGate = firstStartGate
    }

    var startCount: Int { lock.withTestLock { starts } }
    var liveAttempts: [Int] { lock.withTestLock { resources.sorted() } }

    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        let attempt = lock.withTestLock {
            starts += 1
            return starts
        }
        if attempt == 1 {
            await firstStartGate.wait()
        }
        lock.withTestLock {
            resources.insert(attempt)
            handlers[attempt] = sampleHandler
        }

        if attempt == 1 {
            emit([91], from: attempt)
            switch delayedOutcome {
            case .success:
                break
            case .typedFailure:
                throw MeetingAudioCaptureFailure.startFailed(
                    .microphone,
                    "fixture delayed typed failure"
                )
            case .ordinaryFailure:
                throw DelayedMeetingStartError.failed
            }
        } else {
            emit([22], from: attempt)
        }

        return MeetingCaptureSourceInfo(
            sourceID: sourceID,
            routeID: "fixture-attempt-\(attempt)",
            sampleRate: 10,
            channelCount: 1
        )
    }

    func stop() async {
        lock.withTestLock {
            resources.removeAll()
            handlers.removeAll()
        }
    }

    func emit(_ samples: [Float], from attempt: Int) {
        let callback: ((@Sendable (MeetingAudioFrame) -> Void)?, UInt64) = lock.withTestLock {
            let presentationTime = nextPresentationTime
            nextPresentationTime += UInt64(samples.count) * 100_000_000
            return (handlers[attempt], presentationTime)
        }
        callback.0?(MeetingAudioFrame(
            samples: samples,
            presentationTimeNanoseconds: callback.1
        ))
    }
}

private final class DelayedOverloadMeetingAudioCapture: MeetingAudioCapturing,
    @unchecked Sendable
{
    let sourceID = MeetingAudioSourceID.microphone

    private let setupGate: MeetingStartReturnGate
    private let lock = NSLock()
    private var running = false
    private var stops = 0

    init(setupGate: MeetingStartReturnGate) {
        self.setupGate = setupGate
    }

    var isRunning: Bool { lock.withTestLock { running } }
    var stopCount: Int { lock.withTestLock { stops } }

    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        for value: Float in [11, 22] {
            sampleHandler(MeetingAudioFrame(
                samples: [value],
                presentationTimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ))
        }
        await setupGate.wait()
        lock.withTestLock { running = true }
        return MeetingCaptureSourceInfo(
            sourceID: sourceID,
            routeID: "fixture-delayed-overload",
            sampleRate: 10,
            channelCount: 1
        )
    }

    func stop() async {
        lock.withTestLock {
            stops += 1
            running = false
        }
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
    private let batchesByStart: [Int: [[Float]]]
    private let stopBatches: [[Float]]
    private let stopDelayNanoseconds: UInt64
    private let startDelayNanoseconds: UInt64
    private let startFailure: MeetingAudioCaptureFailure?
    private let eventOnStart: MeetingAudioCaptureEvent?
    private let startSetupGate: MeetingStartReturnGate?
    private let startReturnGate: MeetingStartReturnGate?
    private let gatedStart: Int?
    private let lock = NSLock()
    private var starts = 0
    private var stopBegins = 0
    private var stops = 0
    private var nextPresentationTime: UInt64 = 1_000_000_000
    private var sampleHandler: (@Sendable (MeetingAudioFrame) -> Void)?
    private var eventHandler: (@Sendable (MeetingAudioCaptureEvent) -> Void)?

    var startCount: Int { lock.withTestLock { starts } }
    var stopBeginCount: Int { lock.withTestLock { stopBegins } }
    var stopCount: Int { lock.withTestLock { stops } }
    var isRunning: Bool { lock.withTestLock { sampleHandler != nil } }

    init(
        sourceID: MeetingAudioSourceID,
        samples: [[Float]],
        samplesByStart: [Int: [[Float]]] = [:],
        stopSamples: [[Float]] = [],
        stopDelayNanoseconds: UInt64 = 0,
        startDelayNanoseconds: UInt64 = 0,
        startFailure: MeetingAudioCaptureFailure? = nil,
        eventOnStart: MeetingAudioCaptureEvent? = nil,
        startSetupGate: MeetingStartReturnGate? = nil,
        startReturnGate: MeetingStartReturnGate? = nil,
        gatedStart: Int? = nil
    ) {
        self.sourceID = sourceID
        self.batches = samples
        self.batchesByStart = samplesByStart
        self.stopBatches = stopSamples
        self.stopDelayNanoseconds = stopDelayNanoseconds
        self.startDelayNanoseconds = startDelayNanoseconds
        self.startFailure = startFailure
        self.eventOnStart = eventOnStart
        self.startSetupGate = startSetupGate
        self.startReturnGate = startReturnGate
        self.gatedStart = gatedStart
    }

    func start(
        sampleHandler: @escaping @Sendable (MeetingAudioFrame) -> Void,
        eventHandler: @escaping @Sendable (MeetingAudioCaptureEvent) -> Void
    ) async throws -> MeetingCaptureSourceInfo {
        let startNumber = lock.withTestLock {
            starts += 1
            return starts
        }
        if startDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        if let startSetupGate {
            await startSetupGate.wait()
        }
        lock.withTestLock {
            self.sampleHandler = sampleHandler
            self.eventHandler = eventHandler
        }
        if let startFailure { throw startFailure }
        emit(batchesByStart[startNumber] ?? batches)
        if let eventOnStart { eventHandler(eventOnStart) }
        if let startReturnGate, gatedStart == nil || gatedStart == startNumber {
            await startReturnGate.wait()
        }
        return MeetingCaptureSourceInfo(
            sourceID: sourceID,
            routeID: "fixture-\(sourceID.rawValue)",
            sampleRate: 10,
            channelCount: 1
        )
    }

    func stop() async {
        lock.withTestLock { stopBegins += 1 }
        if stopDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: stopDelayNanoseconds)
        }
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

    func emitEvent(_ event: MeetingAudioCaptureEvent) {
        lock.withTestLock { eventHandler }?(event)
    }
}

private actor MeetingStartReturnGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
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

private final class MeetingSystemAudioCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFrames: [MeetingAudioFrame] = []
    private var recordedEvents: [MeetingAudioCaptureEvent] = []

    func record(_ frame: MeetingAudioFrame) {
        lock.withTestLock { recordedFrames.append(frame) }
    }

    func record(_ event: MeetingAudioCaptureEvent) {
        lock.withTestLock { recordedEvents.append(event) }
    }

    var frames: [MeetingAudioFrame] { lock.withTestLock { recordedFrames } }
    var events: [MeetingAudioCaptureEvent] { lock.withTestLock { recordedEvents } }
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
    private let blockAtRecordingCount: Int
    private var values: [MeetingAcceptedAudio] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(blockAtRecordingCount: Int = 1) {
        self.blockAtRecordingCount = blockAtRecordingCount
    }

    var recordingCount: Int { values.count }
    var audio: [MeetingAcceptedAudio] { values }

    func record(_ audio: MeetingAcceptedAudio) async {
        values.append(audio)
        guard !released, values.count == blockAtRecordingCount else { return }
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

private actor MeetingProducerCheckpointRecorder {
    private(set) var values: [MeetingProducerCheckpoint] = []

    func record(_ checkpoint: MeetingProducerCheckpoint) {
        values.append(checkpoint)
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
