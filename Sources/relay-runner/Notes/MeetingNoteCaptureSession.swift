import Foundation

/// Note-only capture wiring for RR-368's exclusive foreground coordinator.
/// Constructing or starting this actor does not start a provider, messenger,
/// voice bridge, FIFO writer, command gesture, title model, or summary model.
actor MeetingNoteCaptureSession {
    private let producer: MeetingTranscriptProducer
    private let captures: [MeetingAudioCapturing]
    private let maximumPendingFrames: Int
    private var startedCaptures: [ObjectIdentifier: MeetingAudioCapturing] = [:]
    private var captureIngress: MeetingCaptureIngress?
    private var captureIngressTask: Task<Void, Never>?

    init(
        producer: MeetingTranscriptProducer,
        captures: [MeetingAudioCapturing] = [
            MeetingMicrophoneAudioCapture(),
            MeetingSystemAudioCapture(),
        ],
        maximumPendingFrames: Int = 32
    ) {
        precondition(maximumPendingFrames > 0)
        self.producer = producer
        self.captures = captures
        self.maximumPendingFrames = maximumPendingFrames
    }

    func start(
        initiallyPaused: Bool = CapsLockGesture.isCapsLockOn(),
        resume checkpoint: MeetingProducerCheckpoint? = nil
    ) async throws {
        try await producer.start(
            initiallyPaused: initiallyPaused,
            resume: checkpoint,
            timelineOriginNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        guard !initiallyPaused else { return }
        try await startSources()
    }

    func pause() async throws {
        await stopSourcesAndDrainIngress()
        try await producer.pause()
    }

    func resume() async throws {
        try await producer.resume()
        do {
            try await startSources()
        } catch {
            await stopSourcesAndDrainIngress()
            throw error
        }
    }

    func stop() async throws -> MeetingProducerFinalBoundary {
        await stopSourcesAndDrainIngress()
        return try await producer.stop()
    }

    func checkpoint() async -> MeetingProducerCheckpoint {
        await producer.checkpoint()
    }

    private func startSources() async throws {
        guard captureIngress == nil else { return }
        let ingress = MeetingCaptureIngress(maximumPendingItems: maximumPendingFrames)
        captureIngress = ingress
        captureIngressTask = Task { [weak self] in
            await self?.consume(ingress)
        }

        var started = 0
        var lastError: Error?
        for capture in captures {
            guard !ingress.isFinished else { break }
            let sourceID = capture.sourceID
            let captureID = ObjectIdentifier(capture)
            startedCaptures[captureID] = capture
            do {
                _ = try await capture.start(
                    sampleHandler: { frame in
                        ingress.submit(.frame(frame, sourceID))
                    },
                    eventHandler: { event in
                        ingress.submit(.event(event, sourceID))
                    }
                )
                guard !ingress.isFinished, startedCaptures[captureID] != nil else {
                    await capture.stop()
                    continue
                }
                await producer.markSourceCapturing(sourceID)
                started += 1
            } catch let failure as MeetingAudioCaptureFailure {
                lastError = failure
                await stopIfStarted(capture)
                try await producer.sourceBecameUnavailable(
                    failure.sourceID,
                    denied: {
                        if case .permissionDenied = failure { return true }
                        return false
                    }(),
                    message: failure.localizedDescription
                )
            } catch {
                lastError = error
                await stopIfStarted(capture)
                try await producer.sourceBecameUnavailable(
                    sourceID,
                    message: error.localizedDescription
                )
            }
        }
        if started == 0 {
            await stopSourcesAndDrainIngress()
            throw lastError ?? MeetingAudioCaptureFailure.unavailable(
                .microphone,
                "No meeting audio source could start."
            )
        }
    }

    private func stopIfStarted(_ capture: MeetingAudioCapturing) async {
        guard startedCaptures.removeValue(forKey: ObjectIdentifier(capture)) != nil else {
            return
        }
        await capture.stop()
    }

    private func stopStartedCaptures() async {
        let captures = Array(startedCaptures.values)
        startedCaptures.removeAll()
        for capture in captures {
            await capture.stop()
        }
    }

    private func stopSourcesAndDrainIngress() async {
        let ingress = captureIngress
        let ingressTask = captureIngressTask
        ingress?.finish()
        await stopStartedCaptures()
        await ingressTask?.value
        if let ingress, captureIngress === ingress {
            captureIngress = nil
            captureIngressTask = nil
        }
    }

    private func consume(_ ingress: MeetingCaptureIngress) async {
        defer {
            if captureIngress === ingress {
                captureIngress = nil
                captureIngressTask = nil
            }
        }
        var iterator = ingress.stream.makeAsyncIterator()
        while let item = await iterator.next() {
            var dropped = ingress.takeDroppedItems()
            if !dropped.isEmpty {
                dropped.record(item)
                await stopStartedCaptures()
                ingress.finish()
                while let pending = await iterator.next() {
                    dropped.record(pending)
                }
                dropped.merge(ingress.takeDroppedItems())
                await producer.recordCaptureIngressDrops(
                    droppedFrameCount: dropped.frameCount,
                    droppedEventCount: dropped.eventCount,
                    droppedSamplesBySource: dropped.samplesBySource,
                    maximumPendingFrames: maximumPendingFrames
                )
                return
            }

            guard await consume(item) else {
                await stopStartedCaptures()
                ingress.finish()
                while let pending = await iterator.next() {
                    dropped.record(pending)
                }
                dropped.merge(ingress.takeDroppedItems())
                if !dropped.isEmpty {
                    await producer.recordCaptureIngressDrops(
                        droppedFrameCount: dropped.frameCount,
                        droppedEventCount: dropped.eventCount,
                        droppedSamplesBySource: dropped.samplesBySource,
                        maximumPendingFrames: maximumPendingFrames
                    )
                }
                return
            }
        }

        let dropped = ingress.takeDroppedItems()
        if !dropped.isEmpty {
            await producer.recordCaptureIngressDrops(
                droppedFrameCount: dropped.frameCount,
                droppedEventCount: dropped.eventCount,
                droppedSamplesBySource: dropped.samplesBySource,
                maximumPendingFrames: maximumPendingFrames
            )
        }
    }

    private func consume(_ item: MeetingCaptureIngress.Item) async -> Bool {
        do {
            switch item {
            case .frame(let frame, let source):
                try await producer.ingest(
                    frame.samples,
                    from: source,
                    presentationTimeNanoseconds: frame.presentationTimeNanoseconds
                )
            case .event(let event, let source):
                switch event {
                case .interrupted(let message):
                    try await producer.sourceWasInterrupted(source, message: message)
                case .recovered:
                    await producer.markSourceCapturing(source)
                case .failed(let failure):
                    try await producer.sourceBecameUnavailable(
                        source,
                        denied: {
                            if case .permissionDenied = failure { return true }
                            return false
                        }(),
                        message: failure.localizedDescription
                    )
                }
            }
            return true
        } catch let error as MeetingProducerError {
            if case .invalidState(let state) = error,
               state == .paused || state == .stopping || state == .stopped
            {
                return true
            }
            return false
        } catch {
            return false
        }
    }
}

final class MeetingCaptureIngress: @unchecked Sendable {
    enum Item: Sendable {
        case frame(MeetingAudioFrame, MeetingAudioSourceID)
        case event(MeetingAudioCaptureEvent, MeetingAudioSourceID)
    }

    struct DroppedItems {
        var frameCount = 0
        var eventCount = 0
        var samplesBySource: [MeetingAudioSourceID: Int] = [:]

        var isEmpty: Bool { frameCount == 0 && eventCount == 0 }

        mutating func record(_ item: Item) {
            switch item {
            case .frame(let frame, let source):
                frameCount += 1
                samplesBySource[source, default: 0] += frame.samples.count
            case .event:
                eventCount += 1
            }
        }

        mutating func merge(_ other: DroppedItems) {
            frameCount += other.frameCount
            eventCount += other.eventCount
            for (source, samples) in other.samplesBySource {
                samplesBySource[source, default: 0] += samples
            }
        }
    }

    let stream: AsyncStream<Item>

    private let continuation: AsyncStream<Item>.Continuation
    private let lock = NSLock()
    private var droppedItems = DroppedItems()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    init(maximumPendingItems: Int) {
        var capturedContinuation: AsyncStream<Item>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(maximumPendingItems)) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation!
    }

    @discardableResult
    func submit(_ item: Item) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }

        switch continuation.yield(item) {
        case .enqueued:
            return true
        case .terminated:
            return false
        case .dropped(let dropped):
            droppedItems.record(dropped)
            return true
        @unknown default:
            return false
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else {
            return
        }
        finished = true
        continuation.finish()
    }

    func takeDroppedItems() -> DroppedItems {
        lock.lock()
        defer { lock.unlock() }
        let result = droppedItems
        droppedItems = DroppedItems()
        return result
    }
}
