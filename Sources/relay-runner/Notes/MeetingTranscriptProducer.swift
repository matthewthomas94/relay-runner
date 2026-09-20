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
        resume checkpoint: MeetingProducerCheckpoint? = nil
    ) async throws {
        guard state == .idle else { throw MeetingProducerError.invalidState(state) }
        state = .preparing
        emit(.state(.preparing))

        if let checkpoint {
            guard checkpoint.sessionID == sessionID else {
                try failCheckpoint("checkpoint session does not match the active note")
                return
            }
            timingEpochs = checkpoint.timingEpochs
            emittedRevisionBySegment = checkpoint.emittedRevisionBySegment
            metrics = checkpoint.metrics
            for source in MeetingAudioSourceID.allCases {
                var buffer = sourceBuffers[source] ?? SourceBuffer()
                buffer.timelineSamples = (metrics.acceptedSamplesBySource[source] ?? 0)
                buffer.bufferStartTimelineSamples = buffer.timelineSamples
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
        var replayedSources: Set<MeetingAudioSourceID> = []
        for chunk in chunks.sorted(by: {
            if $0.descriptor.startMilliseconds != $1.descriptor.startMilliseconds {
                return $0.descriptor.startMilliseconds < $1.descriptor.startMilliseconds
            }
            return $0.descriptor.sequence < $1.descriptor.sequence
        }) {
            replayedSources.insert(chunk.descriptor.sourceID)
            try appendAcceptedAudio(chunk)
        }
        for source in replayedSources {
            try submitAvailableWindows(for: source, allowPartial: false)
            try flushTail(for: source)
        }
        await waitUntilIdle()
        for source in replayedSources {
            var buffer = sourceBuffers[source] ?? SourceBuffer()
            buffer.epoch = nil
            sourceBuffers[source] = buffer
        }
    }

    func ingest(_ samples: [Float], from source: MeetingAudioSourceID) async throws {
        guard state == .recording else { throw MeetingProducerError.invalidState(state) }
        if let terminalError { throw terminalError }
        guard !samples.isEmpty else { return }

        var buffer = sourceBuffers[source] ?? SourceBuffer()
        let epoch = ensureEpoch(for: source, buffer: &buffer)
        let startSample = buffer.timelineSamples
        let endSample = startSample + samples.count
        let descriptor = MeetingAcceptedAudioDescriptor(
            chunkID: "\(epoch.epochID)-A\(buffer.acceptedChunkSequence)",
            sourceID: source,
            timingEpochID: epoch.epochID,
            sequence: buffer.acceptedChunkSequence,
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
        let cursors = Dictionary(uniqueKeysWithValues: timingEpochs.map { epoch in
            let source = sourceBuffers[epoch.sourceID] ?? SourceBuffer()
            let next = windowSequence(
                forTimelineSample: source.bufferStartTimelineSamples,
                epoch: epoch
            )
            return (epoch.epochID, next)
        })
        return MeetingProducerCheckpoint(
            sessionID: sessionID,
            state: state,
            timingEpochs: timingEpochs,
            nextWindowSequenceByEpoch: cursors,
            emittedRevisionBySegment: emittedRevisionBySegment,
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
            startMilliseconds: milliseconds(forSample: buffer.timelineSamples),
            sampleRate: configuration.sampleRate
        )
        buffer.nextEpochSequence += 1
        buffer.epoch = epoch
        buffer.bufferStartTimelineSamples = buffer.timelineSamples
        buffer.lastPartialSampleCount = 0
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
            buffer.bufferStartTimelineSamples = samples(forMilliseconds: descriptor.startMilliseconds)
            buffer.timelineSamples = buffer.bufferStartTimelineSamples
            buffer.samples.removeAll(keepingCapacity: true)
            buffer.lastPartialSampleCount = 0
        }
        buffer.samples.append(contentsOf: accepted.samples)
        buffer.timelineSamples = max(
            buffer.timelineSamples,
            samples(forMilliseconds: descriptor.endMilliseconds)
        )
        buffer.acceptedChunkSequence = max(
            buffer.acceptedChunkSequence,
            descriptor.sequence + 1
        )
        buffer.pendingAudio.append(descriptor)
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
            try enqueue(
                request(
                    source: source,
                    epoch: epoch,
                    buffer: &buffer,
                    samples: context,
                    ownedStartSample: ownedStartSample,
                    ownedEndSample: ownedEndSample,
                    isFinal: true
                )
            )
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
        try enqueue(request(
            source: source,
            epoch: epoch,
            buffer: &buffer,
            samples: buffer.samples,
            ownedStartSample: start,
            ownedEndSample: end,
            isFinal: true
        ))
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
                discardCheckpointedAudio(through: request.ownedEndMilliseconds, source: request.sourceID)
            }
            return
        }

        emittedRevisionBySegment[request.segmentID] = request.revision
        if request.isFinal {
            finalRevisionBySegment[request.segmentID] = request.revision
            discardCheckpointedAudio(through: request.ownedEndMilliseconds, source: request.sourceID)
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

    private func discardCheckpointedAudio(
        through endMilliseconds: Int,
        source: MeetingAudioSourceID
    ) {
        guard var buffer = sourceBuffers[source] else { return }
        buffer.pendingAudio.removeAll { $0.endMilliseconds <= endMilliseconds }
        sourceBuffers[source] = buffer
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
        let relativeStart = max(0, ownedStartSample - samples(forMilliseconds: epoch.startMilliseconds))
        return "\(epoch.epochID)-S\(relativeStart)"
    }

    private func windowSequence(
        forTimelineSample sample: Int,
        epoch: MeetingTimingEpoch
    ) -> Int {
        let epochStart = samples(forMilliseconds: epoch.startMilliseconds)
        return max(0, sample - epochStart) / configuration.ownedSamples
    }

    private func milliseconds(forSample sample: Int) -> Int {
        sample * 1_000 / configuration.sampleRate
    }

    private func samples(forMilliseconds milliseconds: Int) -> Int {
        milliseconds * configuration.sampleRate / 1_000
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
