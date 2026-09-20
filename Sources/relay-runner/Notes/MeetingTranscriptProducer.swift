import Foundation

actor MeetingTranscriptProducer {
    struct Configuration: Equatable, Sendable {
        let sampleRate: Int
        let windowMilliseconds: Int
        let overlapMilliseconds: Int
        let firstPartialMilliseconds: Int
        let partialIntervalMilliseconds: Int
        let maximumQueuedWindows: Int

        static let `default` = Configuration(
            sampleRate: 16_000,
            windowMilliseconds: 6_000,
            overlapMilliseconds: 1_000,
            firstPartialMilliseconds: 2_000,
            partialIntervalMilliseconds: 2_000,
            maximumQueuedWindows: 8
        )

        var windowSamples: Int { sampleRate * windowMilliseconds / 1_000 }
        var overlapSamples: Int { sampleRate * overlapMilliseconds / 1_000 }
        var ownedSamples: Int { windowSamples - overlapSamples }
        var firstPartialSamples: Int { sampleRate * firstPartialMilliseconds / 1_000 }
        var partialIntervalSamples: Int { sampleRate * partialIntervalMilliseconds / 1_000 }
    }

    typealias AcceptedAudioSink = @Sendable (MeetingAcceptedAudio) async throws -> Void
    typealias EventSink = @Sendable (MeetingProducerEvent) -> Void

    private struct SourceBuffer: Sendable {
        var epoch: MeetingTimingEpoch?
        var nextEpochSequence = 0
        var timelineSamples = 0
        var bufferStartTimelineSamples = 0
        var samples: [Float] = []
        var nextRevisionBySegment: [String: Int] = [:]
        var lastPartialSampleCount = 0
        var acceptedChunkSequence = 0
        var pendingAudio: [MeetingAcceptedAudioDescriptor] = []
    }

    private let sessionID: String
    private let transcriber: MeetingWindowTranscribing
    private let configuration: Configuration
    private let acceptedAudioSink: AcceptedAudioSink
    private let eventSink: EventSink

    private var state: MeetingProducerState = .idle
    private var sourceBuffers: [MeetingAudioSourceID: SourceBuffer] = [:]
    private var sourceStates: [MeetingAudioSourceID: MeetingCaptureSourceState] = [:]
    private var timingEpochs: [MeetingTimingEpoch] = []
    private var timelineOriginNanoseconds: UInt64?
    private var nextWindowSequenceByEpoch: [String: Int] = [:]
    private var completedWindowSequencesByEpoch: [String: Set<Int>] = [:]
    private var emittedRevisionBySegment: [String: Int] = [:]
    private var finalRevisionBySegment: [String: Int] = [:]
    private var queuedJobs: [MeetingTranscriptionRequest] = []
    private var drainTask: Task<Void, Never>?
    private var metrics = MeetingProducerMetrics()
    private var terminalError: MeetingProducerError?

    init(
        sessionID: String,
        transcriber: MeetingWindowTranscribing,
        configuration: Configuration = .default,
        acceptedAudioSink: @escaping AcceptedAudioSink = { _ in },
        eventSink: @escaping EventSink = { _ in }
    ) {
        precondition(configuration.sampleRate > 0)
        precondition(configuration.windowSamples > configuration.overlapSamples)
        precondition(configuration.firstPartialSamples > 0)
        precondition(configuration.maximumQueuedWindows > 0)
        self.sessionID = sessionID
        self.transcriber = transcriber
        self.configuration = configuration
        self.acceptedAudioSink = acceptedAudioSink
        self.eventSink = eventSink
        for source in MeetingAudioSourceID.allCases {
            sourceBuffers[source] = SourceBuffer()
            sourceStates[source] = .inactive
        }
    }

    func start(
        initiallyPaused: Bool = CapsLockGesture.isCapsLockOn(),
        resume checkpoint: MeetingProducerCheckpoint? = nil,
        timelineOriginNanoseconds: UInt64? = nil
    ) async throws {
        guard state == .idle else { throw MeetingProducerError.invalidState(state) }
        state = .preparing
        emit(.state(.preparing))
        self.timelineOriginNanoseconds = timelineOriginNanoseconds

        if let checkpoint {
            guard checkpoint.sessionID == sessionID else {
                try failCheckpoint("checkpoint session does not match the active note")
                return
            }
            timingEpochs = checkpoint.timingEpochs
            self.timelineOriginNanoseconds = checkpoint.timelineOriginNanoseconds
            nextWindowSequenceByEpoch = checkpoint.nextWindowSequenceByEpoch
            completedWindowSequencesByEpoch = checkpoint.completedWindowSequencesByEpoch.mapValues(Set.init)
            emittedRevisionBySegment = checkpoint.emittedRevisionBySegment
            finalRevisionBySegment = checkpoint.finalRevisionBySegment
            metrics = checkpoint.metrics
            for source in MeetingAudioSourceID.allCases {
                var buffer = sourceBuffers[source] ?? SourceBuffer()
                buffer.timelineSamples = checkpoint.timelineSampleBySource[source] ?? 0
                buffer.bufferStartTimelineSamples = buffer.timelineSamples
                buffer.pendingAudio = checkpoint.pendingAudio.filter { $0.sourceID == source }
                let epochIDs = Set(
                    timingEpochs.filter { $0.sourceID == source }.map(\.epochID)
                )
                buffer.nextRevisionBySegment = checkpoint.emittedRevisionBySegment.filter {
                    segmentID, _ in
                    epochIDs.contains { segmentID.hasPrefix("\($0)-S") }
                }
                buffer.nextEpochSequence = (
                    timingEpochs.filter { $0.sourceID == source }.map(\.sequence).max() ?? -1
                ) + 1
                sourceBuffers[source] = buffer
            }
        }

        do {
            try await transcriber.prepare { [eventSink] modelState in
                eventSink(.model(modelState))
            }
        } catch {
            emit(.model(.failed(error.localizedDescription)))
            emitIssue(
                code: .modelUnavailable,
                message: "The local transcription model is unavailable: \(error.localizedDescription)",
                recoverable: true
            )
            state = .failed
            emit(.state(.failed))
            throw error
        }

        state = initiallyPaused ? .paused : .recording
        for source in MeetingAudioSourceID.allCases {
            sourceStates[source] = initiallyPaused ? .paused : .starting
            emit(.source(source, sourceStates[source] ?? .inactive))
        }
        emit(.state(state))
    }

    /// Replays RR-368-owned audio without checkpointing it a second time.
    /// Stable epoch/range-derived segment IDs make already emitted revisions
    /// idempotent when the durable checkpoint is restored first.
    func replayAcceptedAudio(_ chunks: [MeetingAcceptedAudio]) async throws {
        guard state == .recording || state == .paused else {
            throw MeetingProducerError.invalidState(state)
        }
        let expectedDescriptors = sourceBuffers.values.flatMap(\.pendingAudio)
        let expected = Dictionary(
            expectedDescriptors.map { ($0.chunkID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let supplied = Dictionary(
            chunks.map { ($0.descriptor.chunkID, $0.descriptor) },
            uniquingKeysWith: { first, _ in first }
        )
        guard expected == supplied,
              expectedDescriptors.count == expected.count,
              chunks.count == supplied.count
        else {
            try failCheckpoint("replay audio does not match the pending checkpoint descriptors")
            return
        }

        let epochSequence = Dictionary(uniqueKeysWithValues: timingEpochs.map {
            ($0.epochID, $0.sequence)
        })
        let grouped = Dictionary(grouping: chunks) {
            "\($0.descriptor.sourceID.rawValue)|\($0.descriptor.timingEpochID)"
        }
        let orderedGroups = grouped.values.sorted { left, right in
            guard let lhs = left.first?.descriptor, let rhs = right.first?.descriptor else {
                return left.count < right.count
            }
            if lhs.sourceID != rhs.sourceID {
                return lhs.sourceID.rawValue < rhs.sourceID.rawValue
            }
            return (epochSequence[lhs.timingEpochID] ?? 0) <
                (epochSequence[rhs.timingEpochID] ?? 0)
        }
        for group in orderedGroups {
            for chunk in group.sorted(by: { $0.descriptor.sequence < $1.descriptor.sequence }) {
                try appendAcceptedAudio(chunk)
            }
            guard let source = group.first?.descriptor.sourceID else { continue }
            try submitAvailableWindows(for: source, allowPartial: false)
            try flushTail(for: source)
            await waitUntilIdle()
            var buffer = sourceBuffers[source] ?? SourceBuffer()
            buffer.epoch = nil
            sourceBuffers[source] = buffer
        }
    }

    func ingest(
        _ samples: [Float],
        from source: MeetingAudioSourceID,
        presentationTimeNanoseconds: UInt64? = nil
    ) async throws {
        guard state == .recording else { throw MeetingProducerError.invalidState(state) }
        if let terminalError { throw terminalError }
        guard !samples.isEmpty else { return }

        var buffer = sourceBuffers[source] ?? SourceBuffer()
        if buffer.epoch == nil, let presentationTimeNanoseconds {
            buffer.timelineSamples = max(
                buffer.timelineSamples,
                timelineSample(for: presentationTimeNanoseconds)
            )
        }
        let epoch = ensureEpoch(for: source, buffer: &buffer)
        let startSample = buffer.timelineSamples
        let endSample = startSample + samples.count
        let descriptor = MeetingAcceptedAudioDescriptor(
            chunkID: "\(epoch.epochID)-A\(buffer.acceptedChunkSequence)",
            sourceID: source,
            timingEpochID: epoch.epochID,
            sequence: buffer.acceptedChunkSequence,
            startSample: startSample,
            endSample: endSample,
            startMilliseconds: milliseconds(forSample: startSample),
            endMilliseconds: milliseconds(forSample: endSample),
            sampleRate: configuration.sampleRate,
            sampleCount: samples.count
        )

        do {
            try await acceptedAudioSink(MeetingAcceptedAudio(descriptor: descriptor, samples: samples))
        } catch {
            metrics.droppedAudioSampleCount += samples.count
            let producerError = MeetingProducerError.checkpointFailed(error.localizedDescription)
            terminalError = producerError
            state = .failed
            emitIssue(
                code: .checkpointFailed,
                sourceID: source,
                message: producerError.localizedDescription,
                recoverable: true
            )
            emit(.state(.failed))
            throw producerError
        }

        buffer.acceptedChunkSequence += 1
        buffer.timelineSamples = endSample
        buffer.samples.append(contentsOf: samples)
        buffer.pendingAudio.append(descriptor)
        metrics.acceptedSamplesBySource[source, default: 0] += samples.count
        metrics.acceptedChunkCount += 1
        sourceBuffers[source] = buffer
        sourceStates[source] = .capturing
        emit(.source(source, .capturing))

        try submitAvailableWindows(for: source)
        await Task.yield()
    }

    /// The state gate changes before this method suspends, so capture owners can
    /// stop their callbacks afterward without retaining speech from the paused interval.
    func pause() async throws {
        guard state == .recording else {
            if state == .paused { return }
            throw MeetingProducerError.invalidState(state)
        }
        state = .paused
        emit(.state(.paused))
        for source in MeetingAudioSourceID.allCases {
            try flushTail(for: source)
            sourceStates[source] = .paused
            emit(.source(source, .paused))
        }
        await waitUntilIdle()
        endEpochsForModeBoundary()
    }

    func resume() throws {
        guard state == .paused else {
            if state == .recording { return }
            throw MeetingProducerError.invalidState(state)
        }
        state = .recording
        for source in MeetingAudioSourceID.allCases {
            sourceStates[source] = .starting
            emit(.source(source, .starting))
        }
        emit(.state(.recording))
    }

    func stop() async throws -> MeetingProducerFinalBoundary {
        guard state == .recording || state == .paused || state == .failed else {
            throw MeetingProducerError.invalidState(state)
        }
        state = .stopping
        emit(.state(.stopping))
        for source in MeetingAudioSourceID.allCases {
            try flushTail(for: source)
        }
        await waitUntilIdle()

        if let terminalError { throw terminalError }
        state = .stopped
        for source in MeetingAudioSourceID.allCases {
            sourceStates[source] = .stopped
            emit(.source(source, .stopped))
        }
        let boundary = MeetingProducerFinalBoundary(
            sessionID: sessionID,
            timingEpochs: timingEpochs,
            finalSegmentRevisionByID: finalRevisionBySegment,
            metrics: metrics
        )
        emit(.finalBoundary(boundary))
        emit(.state(.stopped))
        return boundary
    }

    func sourceBecameUnavailable(
        _ source: MeetingAudioSourceID,
        denied: Bool = false,
        message: String
    ) async throws {
        if state == .recording {
            try flushTail(for: source)
            await waitUntilIdle()
        }
        var buffer = sourceBuffers[source] ?? SourceBuffer()
        buffer.epoch = nil
        sourceBuffers[source] = buffer
        sourceStates[source] = denied ? .denied : .unavailable
        emit(.source(source, sourceStates[source] ?? .unavailable))
        emitIssue(
            code: denied ? .permissionDenied : .sourceUnavailable,
            sourceID: source,
            message: message,
            recoverable: true
        )
    }

    func sourceWasInterrupted(_ source: MeetingAudioSourceID, message: String) async throws {
        if state == .recording {
            try flushTail(for: source)
            await waitUntilIdle()
        }
        var buffer = sourceBuffers[source] ?? SourceBuffer()
        buffer.epoch = nil
        sourceBuffers[source] = buffer
        sourceStates[source] = .interrupted
        emit(.source(source, .interrupted))
        emitIssue(
            code: .sourceInterrupted,
            sourceID: source,
            message: message,
            recoverable: true
        )
    }

    func markSourceCapturing(_ source: MeetingAudioSourceID) {
        guard state == .recording else { return }
        sourceStates[source] = .capturing
        emit(.source(source, .capturing))
    }

    func checkpoint() -> MeetingProducerCheckpoint {
        let pending = MeetingAudioSourceID.allCases.flatMap {
            sourceBuffers[$0]?.pendingAudio ?? []
        }.sorted { $0.chunkID < $1.chunkID }
        return MeetingProducerCheckpoint(
            sessionID: sessionID,
            state: state,
            timingEpochs: timingEpochs,
            timelineOriginNanoseconds: timelineOriginNanoseconds,
            timelineSampleBySource: Dictionary(uniqueKeysWithValues: MeetingAudioSourceID.allCases.map {
                ($0, sourceBuffers[$0]?.timelineSamples ?? 0)
            }),
            nextWindowSequenceByEpoch: nextWindowSequenceByEpoch,
            completedWindowSequencesByEpoch: completedWindowSequencesByEpoch.mapValues {
                $0.sorted()
            },
            emittedRevisionBySegment: emittedRevisionBySegment,
            finalRevisionBySegment: finalRevisionBySegment,
            pendingAudio: pending,
            metrics: metrics
        )
    }

    func currentMetrics() -> MeetingProducerMetrics {
        var value = metrics
        value.queuedWindowCount = queuedJobs.count + (drainTask == nil ? 0 : 1)
        return value
    }

    func bufferedSampleCount() -> Int {
        sourceBuffers.values.reduce(0) { $0 + $1.samples.count }
    }

    func waitUntilIdle() async {
        while let task = drainTask {
            await task.value
        }
    }

    /// Test seam for a delayed result that arrives after a newer revision.
    func applyTranscriptionResultForTesting(
        _ result: MeetingTranscriptionResult,
        request: MeetingTranscriptionRequest
    ) {
        apply(result, for: request)
    }

    private func ensureEpoch(
        for source: MeetingAudioSourceID,
        buffer: inout SourceBuffer
    ) -> MeetingTimingEpoch {
        if let epoch = buffer.epoch { return epoch }
        let epoch = MeetingTimingEpoch(
            epochID: "\(sessionID)-\(source.rawValue)-E\(buffer.nextEpochSequence)",
            sourceID: source,
            sequence: buffer.nextEpochSequence,
            startSample: buffer.timelineSamples,
            startMilliseconds: milliseconds(forSample: buffer.timelineSamples),
            sampleRate: configuration.sampleRate
        )
        buffer.nextEpochSequence += 1
        buffer.epoch = epoch
        buffer.bufferStartTimelineSamples = buffer.timelineSamples
        buffer.lastPartialSampleCount = 0
        nextWindowSequenceByEpoch[epoch.epochID] = 0
        completedWindowSequencesByEpoch[epoch.epochID] = []
        timingEpochs.append(epoch)
        emit(.epoch(epoch))
        return epoch
    }

    private func appendAcceptedAudio(_ accepted: MeetingAcceptedAudio) throws {
        let descriptor = accepted.descriptor
        guard descriptor.sampleRate == configuration.sampleRate,
              descriptor.sampleCount == accepted.samples.count,
              let epoch = timingEpochs.first(where: { $0.epochID == descriptor.timingEpochID })
        else {
            throw MeetingProducerError.checkpointFailed("replay audio does not match its timing epoch")
        }
        var buffer = sourceBuffers[descriptor.sourceID] ?? SourceBuffer()
        if buffer.epoch?.epochID != epoch.epochID {
            buffer.epoch = epoch
            let replayStart = epoch.startSample +
                (nextWindowSequenceByEpoch[epoch.epochID] ?? 0) * configuration.ownedSamples
            buffer.bufferStartTimelineSamples = replayStart
            buffer.samples.removeAll(keepingCapacity: true)
            buffer.lastPartialSampleCount = 0
        }

        guard descriptor.endSample - descriptor.startSample == descriptor.sampleCount else {
            throw MeetingProducerError.checkpointFailed(
                "replay audio sample offsets do not match the retained sample count"
            )
        }
        let bufferedEnd = buffer.bufferStartTimelineSamples + buffer.samples.count
        guard descriptor.startSample <= bufferedEnd else {
            throw MeetingProducerError.checkpointFailed(
                "replay audio has a gap before the next pending window"
            )
        }
        let acceptedStart = max(descriptor.startSample, bufferedEnd)
        if descriptor.endSample > acceptedStart {
            let skippedSamples = acceptedStart - descriptor.startSample
            buffer.samples.append(contentsOf: accepted.samples.dropFirst(skippedSamples))
        }
        buffer.timelineSamples = max(
            buffer.timelineSamples,
            descriptor.endSample
        )
        buffer.acceptedChunkSequence = max(
            buffer.acceptedChunkSequence,
            descriptor.sequence + 1
        )
        sourceBuffers[descriptor.sourceID] = buffer
    }

    private func submitAvailableWindows(
        for source: MeetingAudioSourceID,
        allowPartial: Bool = true
    ) throws {
        guard var buffer = sourceBuffers[source], let epoch = buffer.epoch else { return }

        while buffer.samples.count >= configuration.windowSamples {
            let context = Array(buffer.samples.prefix(configuration.windowSamples))
            let ownedStartSample = buffer.bufferStartTimelineSamples
            let ownedEndSample = ownedStartSample + configuration.ownedSamples
            let sequence = windowSequence(forTimelineSample: ownedStartSample, epoch: epoch)
            if !isCompletedFinalWindow(epochID: epoch.epochID, sequence: sequence) {
                try enqueue(request(
                    source: source,
                    epoch: epoch,
                    buffer: &buffer,
                    samples: context,
                    ownedStartSample: ownedStartSample,
                    ownedEndSample: ownedEndSample,
                    isFinal: true
                ))
            }
            buffer.samples.removeFirst(configuration.ownedSamples)
            buffer.bufferStartTimelineSamples = ownedEndSample
            buffer.lastPartialSampleCount = 0
        }

        if allowPartial,
           buffer.samples.count >= configuration.firstPartialSamples,
           buffer.samples.count - buffer.lastPartialSampleCount >= configuration.partialIntervalSamples
        {
            let ownedStartSample = buffer.bufferStartTimelineSamples
            let ownedEndSample = ownedStartSample + buffer.samples.count
            let partial = request(
                source: source,
                epoch: epoch,
                buffer: &buffer,
                samples: buffer.samples,
                ownedStartSample: ownedStartSample,
                ownedEndSample: ownedEndSample,
                isFinal: false
            )
            buffer.lastPartialSampleCount = buffer.samples.count
            try enqueue(partial)
        }
        sourceBuffers[source] = buffer
    }

    private func flushTail(for source: MeetingAudioSourceID) throws {
        guard var buffer = sourceBuffers[source],
              let epoch = buffer.epoch,
              !buffer.samples.isEmpty
        else { return }
        let start = buffer.bufferStartTimelineSamples
        let end = start + buffer.samples.count
        let sequence = windowSequence(forTimelineSample: start, epoch: epoch)
        if !isCompletedFinalWindow(epochID: epoch.epochID, sequence: sequence) {
            try enqueue(request(
                source: source,
                epoch: epoch,
                buffer: &buffer,
                samples: buffer.samples,
                ownedStartSample: start,
                ownedEndSample: end,
                isFinal: true
            ))
        }
        buffer.samples.removeAll(keepingCapacity: true)
        buffer.bufferStartTimelineSamples = end
        buffer.lastPartialSampleCount = 0
        sourceBuffers[source] = buffer
    }

    private func request(
        source: MeetingAudioSourceID,
        epoch: MeetingTimingEpoch,
        buffer: inout SourceBuffer,
        samples: [Float],
        ownedStartSample: Int,
        ownedEndSample: Int,
        isFinal: Bool
    ) -> MeetingTranscriptionRequest {
        let segmentID = segmentID(epoch: epoch, ownedStartSample: ownedStartSample)
        let revision = (buffer.nextRevisionBySegment[segmentID] ?? 0) + 1
        buffer.nextRevisionBySegment[segmentID] = revision
        return MeetingTranscriptionRequest(
            segmentID: segmentID,
            sourceID: source,
            timingEpochID: epoch.epochID,
            windowSequence: windowSequence(forTimelineSample: ownedStartSample, epoch: epoch),
            revision: revision,
            contextStartMilliseconds: milliseconds(forSample: buffer.bufferStartTimelineSamples),
            ownedStartMilliseconds: milliseconds(forSample: ownedStartSample),
            ownedEndMilliseconds: milliseconds(forSample: ownedEndSample),
            isFinal: isFinal,
            samples: samples
        )
    }

    private func enqueue(_ request: MeetingTranscriptionRequest) throws {
        if queuedJobs.count >= configuration.maximumQueuedWindows {
            if !request.isFinal {
                metrics.skippedPartialRevisionCount += 1
                emitIssue(
                    code: .backpressureExceeded,
                    sourceID: request.sourceID,
                    message: "A provisional transcript refresh was skipped while local transcription caught up; accepted audio is retained for its final window.",
                    recoverable: true
                )
                return
            }
            let producerError = MeetingProducerError.backpressureExceeded
            terminalError = producerError
            state = .failed
            emitIssue(
                code: .backpressureExceeded,
                sourceID: request.sourceID,
                message: producerError.localizedDescription,
                recoverable: true
            )
            emit(.state(.failed))
            throw producerError
        }
        queuedJobs.append(request)
        metrics.queuedWindowCount = queuedJobs.count
        metrics.maximumQueuedWindowCount = max(
            metrics.maximumQueuedWindowCount,
            queuedJobs.count
        )
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drainJobs()
        }
    }

    private func drainJobs() async {
        while !queuedJobs.isEmpty {
            let request = queuedJobs.removeFirst()
            metrics.queuedWindowCount = queuedJobs.count
            do {
                let result = try await transcriber.transcribe(request)
                apply(result, for: request)
            } catch {
                metrics.transcriptionFailureCount += 1
                emitIssue(
                    code: .transcriptionFailed,
                    sourceID: request.sourceID,
                    message: "Local transcription failed for a retained audio window: \(error.localizedDescription)",
                    recoverable: true
                )
            }
        }
        drainTask = nil
    }

    private func apply(
        _ result: MeetingTranscriptionResult,
        for request: MeetingTranscriptionRequest
    ) {
        if request.isFinal,
           isCompletedFinalWindow(
               epochID: request.timingEpochID,
               sequence: request.windowSequence
           )
        {
            return
        }
        guard request.revision > (emittedRevisionBySegment[request.segmentID] ?? 0) else {
            return
        }
        if finalRevisionBySegment[request.segmentID] != nil, !request.isFinal {
            return
        }

        metrics.processedWindowCount += 1
        metrics.latestProcessingMilliseconds = result.processingMilliseconds
        metrics.maximumProcessingMilliseconds = max(
            metrics.maximumProcessingMilliseconds,
            result.processingMilliseconds
        )
        let text = ownedText(from: result, request: request)
        guard !text.isEmpty else {
            if request.isFinal {
                completeFinalWindow(request)
            }
            return
        }

        emittedRevisionBySegment[request.segmentID] = request.revision
        if request.isFinal {
            finalRevisionBySegment[request.segmentID] = request.revision
            completeFinalWindow(request)
        }
        emit(.revision(MeetingTranscriptSegmentRevision(
            segmentID: request.segmentID,
            sourceID: request.sourceID,
            timingEpochID: request.timingEpochID,
            windowSequence: request.windowSequence,
            revision: request.revision,
            startMilliseconds: request.ownedStartMilliseconds,
            endMilliseconds: request.ownedEndMilliseconds,
            text: text,
            isFinal: request.isFinal
        )))
    }

    private func ownedText(
        from result: MeetingTranscriptionResult,
        request: MeetingTranscriptionRequest
    ) -> String {
        guard !result.tokens.isEmpty else { return clean(result.text) }
        let localOwnedStart = Double(
            request.ownedStartMilliseconds - request.contextStartMilliseconds
        ) / 1_000
        let localOwnedEnd = Double(
            request.ownedEndMilliseconds - request.contextStartMilliseconds
        ) / 1_000
        let tokens = result.tokens.filter { token in
            let midpoint = (token.startSeconds + token.endSeconds) / 2
            return midpoint >= localOwnedStart && midpoint < localOwnedEnd
        }
        return clean(tokens.map(\.text).joined())
    }

    private func completeFinalWindow(_ request: MeetingTranscriptionRequest) {
        var completed = completedWindowSequencesByEpoch[request.timingEpochID] ?? []
        completed.insert(request.windowSequence)
        var next = nextWindowSequenceByEpoch[request.timingEpochID] ?? 0
        while completed.remove(next) != nil {
            next += 1
        }
        completedWindowSequencesByEpoch[request.timingEpochID] = completed
        nextWindowSequenceByEpoch[request.timingEpochID] = next

        guard let epoch = timingEpochs.first(where: {
            $0.epochID == request.timingEpochID
        }), var buffer = sourceBuffers[request.sourceID]
        else { return }
        let committedThroughSample = epoch.startSample +
            next * configuration.ownedSamples
        buffer.pendingAudio.removeAll {
            $0.timingEpochID == epoch.epochID && $0.endSample <= committedThroughSample
        }
        sourceBuffers[request.sourceID] = buffer
    }

    private func isCompletedFinalWindow(epochID: String, sequence: Int) -> Bool {
        sequence < (nextWindowSequenceByEpoch[epochID] ?? 0) ||
            (completedWindowSequencesByEpoch[epochID]?.contains(sequence) ?? false)
    }

    private func endEpochsForModeBoundary() {
        for source in MeetingAudioSourceID.allCases {
            var buffer = sourceBuffers[source] ?? SourceBuffer()
            buffer.epoch = nil
            buffer.samples.removeAll(keepingCapacity: true)
            buffer.lastPartialSampleCount = 0
            sourceBuffers[source] = buffer
        }
    }

    private func segmentID(epoch: MeetingTimingEpoch, ownedStartSample: Int) -> String {
        let relativeStart = max(0, ownedStartSample - epoch.startSample)
        return "\(epoch.epochID)-S\(relativeStart)"
    }

    private func windowSequence(
        forTimelineSample sample: Int,
        epoch: MeetingTimingEpoch
    ) -> Int {
        return max(0, sample - epoch.startSample) / configuration.ownedSamples
    }

    private func milliseconds(forSample sample: Int) -> Int {
        sample * 1_000 / configuration.sampleRate
    }

    private func timelineSample(for presentationTimeNanoseconds: UInt64) -> Int {
        guard let origin = timelineOriginNanoseconds else {
            timelineOriginNanoseconds = presentationTimeNanoseconds
            return 0
        }
        guard presentationTimeNanoseconds >= origin else { return 0 }
        let elapsed = presentationTimeNanoseconds - origin
        return Int(elapsed * UInt64(configuration.sampleRate) / 1_000_000_000)
    }

    private func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func emit(_ event: MeetingProducerEvent) {
        eventSink(event)
    }

    private func emitIssue(
        code: MeetingCaptureIssueCode,
        sourceID: MeetingAudioSourceID? = nil,
        message: String,
        recoverable: Bool
    ) {
        emit(.issue(MeetingCaptureIssue(
            code: code,
            sourceID: sourceID,
            message: message,
            recoverable: recoverable
        )))
    }

    private func failCheckpoint(_ message: String) throws {
        let error = MeetingProducerError.checkpointFailed(message)
        terminalError = error
        state = .failed
        emitIssue(
            code: .checkpointFailed,
            message: error.localizedDescription,
            recoverable: true
        )
        emit(.state(.failed))
        throw error
    }
}
