import Foundation

protocol MeetingNoteCaptureControlling: Sendable {
    func start(
        initiallyPaused: Bool,
        resume checkpoint: MeetingProducerCheckpoint?
    ) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws -> MeetingProducerFinalBoundary
    func quiesceCaptureSources() async
    func stopCaptureSourcesForInterruption() async
    func checkpoint() async -> MeetingProducerCheckpoint
    func replayAcceptedAudio(_ chunks: [MeetingAcceptedAudio]) async throws
}

/// Note-only capture wiring for RR-368's exclusive foreground coordinator.
/// Constructing or starting this actor does not start a provider, messenger,
/// voice bridge, FIFO writer, command gesture, title model, or summary model.
actor MeetingNoteCaptureSession {
    private struct SourceStartup {
        let generation: UInt64
        let ingress: MeetingCaptureIngress
        var bufferedFrames: [MeetingAudioFrame] = []
        var blockedDuringStart = false
    }

    private let producer: MeetingTranscriptProducer
    private let captures: [MeetingAudioCapturing]
    private let maximumPendingFrames: Int
    private var startedCaptures: [ObjectIdentifier: MeetingAudioCapturing] = [:]
    private var captureIngress: MeetingCaptureIngress?
    private var captureIngressTask: Task<Void, Never>?
    private var sourceCaptureGenerations: [MeetingAudioSourceID: UInt64] = [:]
    private var sourceStartups: [MeetingAudioSourceID: SourceStartup] = [:]
    private var blockedSources: Set<MeetingAudioSourceID> = []
    private var captureQuiescing = false
    private var sourceStartInProgress = false
    private var sourceStartWaiters: [CheckedContinuation<Void, Never>] = []

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
        captureQuiescing = true
        await stopSourcesAndDrainIngress()
        return try await producer.stop()
    }

    func quiesceCaptureSources() async {
        captureQuiescing = true
        await stopSourcesAndDrainIngress()
    }

    func stopCaptureSourcesForInterruption() async {
        captureQuiescing = true
        await stopSourcesAndDrainIngress()
    }

    func checkpoint() async -> MeetingProducerCheckpoint {
        await producer.checkpoint()
    }

    func replayAcceptedAudio(_ chunks: [MeetingAcceptedAudio]) async throws {
        try await producer.replayAcceptedAudio(chunks)
    }

    private func startSources() async throws {
        guard !captureQuiescing else { return }
        guard captureIngress == nil else { return }
        await waitForSourceStart()
        guard !captureQuiescing else { return }
        guard captureIngress == nil else { return }
        sourceStartInProgress = true
        defer { finishSourceStart() }

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
            let generation = sourceCaptureGenerations[sourceID, default: 0] &+ 1
            sourceCaptureGenerations[sourceID] = generation
            sourceStartups[sourceID] = SourceStartup(
                generation: generation,
                ingress: ingress
            )
            startedCaptures[captureID] = capture
            do {
                _ = try await capture.start(
                    sampleHandler: { frame in
                        ingress.submit(.frame(frame, sourceID, generation))
                    },
                    eventHandler: { event in
                        ingress.submit(.event(event, sourceID, generation))
                    }
                )
                guard !ingress.isFinished, startedCaptures[captureID] != nil else {
                    discardStartup(for: sourceID, generation: generation)
                    await stopAfterCompletedStart(capture)
                    continue
                }
                let startBarrier = MeetingCaptureStartBarrier()
                guard ingress.submit(.started(sourceID, generation, startBarrier)) else {
                    discardStartup(for: sourceID, generation: generation)
                    await stopAfterCompletedStart(capture)
                    continue
                }
                await startBarrier.wait()
                started += 1
            } catch let failure as MeetingAudioCaptureFailure {
                lastError = failure
                ingress.submit(.startFailed(failure, sourceID, generation))
                await stopAfterCompletedStart(capture)
            } catch {
                lastError = error
                ingress.submit(.startFailed(
                    .startFailed(sourceID, error.localizedDescription),
                    sourceID,
                    generation
                ))
                await stopAfterCompletedStart(capture)
            }
        }
        if started == 0 {
            await stopSourcesAndDrainIngress(waitForSourceStart: false)
            throw lastError ?? MeetingAudioCaptureFailure.unavailable(
                .microphone,
                "No meeting audio source could start."
            )
        }
    }

    private func stopAfterCompletedStart(_ capture: MeetingAudioCapturing) async {
        startedCaptures.removeValue(forKey: ObjectIdentifier(capture))
        await capture.stop()
    }

    private func stopStartedCaptures() async {
        let captures = Array(startedCaptures.values)
        startedCaptures.removeAll()
        for capture in captures {
            await capture.stop()
        }
    }

    private func stopSourcesAndDrainIngress(waitForSourceStart: Bool = true) async {
        let ingress = captureIngress
        let ingressTask = captureIngressTask
        ingress?.finish()
        if waitForSourceStart {
            await self.waitForSourceStart()
        }
        await stopStartedCaptures()
        await ingressTask?.value
        if let ingress {
            sourceStartups = sourceStartups.filter { $0.value.ingress !== ingress }
        }
        if let ingress, captureIngress === ingress {
            captureIngress = nil
            captureIngressTask = nil
        }
    }

    private func waitForSourceStart() async {
        while sourceStartInProgress {
            await withCheckedContinuation { continuation in
                sourceStartWaiters.append(continuation)
            }
        }
    }

    private func finishSourceStart() {
        sourceStartInProgress = false
        let waiters = sourceStartWaiters
        sourceStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func captureIngressIsClosedForTesting() -> Bool {
        captureIngress?.isFinished ?? true
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
            case .frame(let frame, let source, let generation):
                guard sourceCaptureGenerations[source] == generation else { return true }
                if var startup = sourceStartups[source], startup.generation == generation {
                    guard !startup.blockedDuringStart else { return true }
                    guard startup.bufferedFrames.count < maximumPendingFrames else {
                        await producer.recordCaptureIngressDrops(
                            droppedFrameCount: 1,
                            droppedEventCount: 0,
                            droppedSamplesBySource: [source: frame.samples.count],
                            maximumPendingFrames: maximumPendingFrames
                        )
                        return false
                    }
                    startup.bufferedFrames.append(frame)
                    sourceStartups[source] = startup
                    return true
                }
                guard !blockedSources.contains(source) else { return true }
                try await producer.ingest(
                    frame.samples,
                    from: source,
                    presentationTimeNanoseconds: frame.presentationTimeNanoseconds
                )
            case .event(let event, let source, let generation):
                guard sourceCaptureGenerations[source] == generation else { return true }
                switch event {
                case .interrupted(let message):
                    blockedSources.insert(source)
                    blockStartup(for: source, generation: generation)
                    try await producer.sourceWasInterrupted(source, message: message)
                case .recovered:
                    blockedSources.remove(source)
                    unblockStartup(for: source, generation: generation)
                    if sourceStartups[source] == nil {
                        await producer.markSourceCapturing(source)
                    }
                case .failed(let failure):
                    blockedSources.insert(source)
                    blockStartup(for: source, generation: generation)
                    try await report(failure, from: source)
                case .restartRequested:
                    await restartSystemSource(source, generation: generation)
                }
            case .started(let source, let generation, let startBarrier):
                defer { startBarrier.complete() }
                guard sourceCaptureGenerations[source] == generation,
                      let startup = sourceStartups[source],
                      startup.generation == generation
                else { return true }
                sourceStartups.removeValue(forKey: source)
                guard !startup.blockedDuringStart else { return true }
                blockedSources.remove(source)
                await producer.markSourceCapturing(source)
                for frame in startup.bufferedFrames {
                    try await producer.ingest(
                        frame.samples,
                        from: source,
                        presentationTimeNanoseconds: frame.presentationTimeNanoseconds
                    )
                }
            case .startFailed(let failure, let source, let generation):
                guard sourceCaptureGenerations[source] == generation else { return true }
                discardStartup(for: source, generation: generation)
                blockedSources.insert(source)
                try await report(failure, from: source)
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

    private func blockStartup(for source: MeetingAudioSourceID, generation: UInt64) {
        guard var startup = sourceStartups[source], startup.generation == generation else {
            return
        }
        startup.bufferedFrames.removeAll()
        startup.blockedDuringStart = true
        sourceStartups[source] = startup
    }

    private func unblockStartup(for source: MeetingAudioSourceID, generation: UInt64) {
        guard var startup = sourceStartups[source], startup.generation == generation else {
            return
        }
        startup.blockedDuringStart = false
        sourceStartups[source] = startup
    }

    private func discardStartup(for source: MeetingAudioSourceID, generation: UInt64) {
        guard sourceStartups[source]?.generation == generation else { return }
        sourceStartups.removeValue(forKey: source)
    }

    private func report(
        _ failure: MeetingAudioCaptureFailure,
        from source: MeetingAudioSourceID
    ) async throws {
        let issueCode: MeetingCaptureIssueCode
        switch failure {
        case .permissionDenied:
            issueCode = .permissionDenied
        case .unsupportedFormat:
            issueCode = .formatChanged
        case .unavailable, .startFailed:
            issueCode = .sourceUnavailable
        }
        try await producer.sourceBecameUnavailable(
            source,
            issueCode: issueCode,
            message: failure.localizedDescription
        )
    }

    private func restartSystemSource(_ source: MeetingAudioSourceID, generation: UInt64) async {
        guard source == .systemAudio,
              sourceCaptureGenerations[source] == generation,
              !sourceStartInProgress,
              !captureQuiescing,
              let ingress = captureIngress,
              !ingress.isFinished,
              let capture = captures.first(where: { $0.sourceID == source }),
              startedCaptures[ObjectIdentifier(capture)] != nil else { return }

        sourceStartInProgress = true
        defer { finishSourceStart() }
        blockedSources.insert(source)
        let nextGeneration = generation &+ 1
        sourceCaptureGenerations[source] = nextGeneration
        await capture.stop()
        guard !captureQuiescing, !ingress.isFinished else { return }

        do {
            _ = try await capture.start(
                sampleHandler: { frame in
                    ingress.submit(.frame(frame, source, nextGeneration))
                },
                eventHandler: { event in
                    ingress.submit(.event(event, source, nextGeneration))
                }
            )
            guard !captureQuiescing, !ingress.isFinished else {
                await capture.stop()
                return
            }
            blockedSources.remove(source)
            await producer.markSourceCapturing(source)
        } catch let failure as MeetingAudioCaptureFailure {
            try? await report(failure, from: source)
        } catch {
            try? await report(.startFailed(source, error.localizedDescription), from: source)
        }
    }
}

extension MeetingNoteCaptureSession: MeetingNoteCaptureControlling {}

final class MeetingCaptureIngress: @unchecked Sendable {
    enum Item: Sendable {
        case frame(MeetingAudioFrame, MeetingAudioSourceID, UInt64)
        case event(MeetingAudioCaptureEvent, MeetingAudioSourceID, UInt64)
        case started(MeetingAudioSourceID, UInt64, MeetingCaptureStartBarrier)
        case startFailed(MeetingAudioCaptureFailure, MeetingAudioSourceID, UInt64)
    }

    struct DroppedItems {
        var frameCount = 0
        var eventCount = 0
        var samplesBySource: [MeetingAudioSourceID: Int] = [:]

        var isEmpty: Bool { frameCount == 0 && eventCount == 0 }

        mutating func record(_ item: Item) {
            switch item {
            case .frame(let frame, let source, _):
                frameCount += 1
                samplesBySource[source, default: 0] += frame.samples.count
            case .event, .startFailed:
                eventCount += 1
            case .started(_, _, let startBarrier):
                eventCount += 1
                startBarrier.complete()
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

final class MeetingCaptureStartBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func complete() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }
}
