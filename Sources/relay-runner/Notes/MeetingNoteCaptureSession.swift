import Foundation

/// Note-only capture wiring for RR-368's exclusive foreground coordinator.
/// Constructing or starting this actor does not start a provider, messenger,
/// voice bridge, FIFO writer, command gesture, title model, or summary model.
actor MeetingNoteCaptureSession {
    private let producer: MeetingTranscriptProducer
    private let captures: [MeetingAudioCapturing]
    private var activeSources: Set<MeetingAudioSourceID> = []

    init(
        producer: MeetingTranscriptProducer,
        captures: [MeetingAudioCapturing] = [
            MeetingMicrophoneAudioCapture(),
            MeetingSystemAudioCapture(),
        ]
    ) {
        self.producer = producer
        self.captures = captures
    }

    func start(
        initiallyPaused: Bool = CapsLockGesture.isCapsLockOn(),
        resume checkpoint: MeetingProducerCheckpoint? = nil
    ) async throws {
        try await producer.start(initiallyPaused: initiallyPaused, resume: checkpoint)
        guard !initiallyPaused else { return }
        try await startSources()
    }

    func pause() async throws {
        do {
            try await producer.pause()
        } catch {
            await stopSources()
            throw error
        }
        await stopSources()
    }

    func resume() async throws {
        try await producer.resume()
        do {
            try await startSources()
        } catch {
            await stopSources()
            throw error
        }
    }

    func stop() async throws -> MeetingProducerFinalBoundary {
        await stopSources()
        return try await producer.stop()
    }

    func checkpoint() async -> MeetingProducerCheckpoint {
        await producer.checkpoint()
    }

    private func startSources() async throws {
        var started = 0
        var lastError: Error?
        for capture in captures {
            do {
                _ = try await capture.start(
                    sampleHandler: { [weak self] samples in
                        Task { await self?.accept(samples, from: capture.sourceID) }
                    },
                    eventHandler: { [weak self] event in
                        Task { await self?.handle(event, from: capture.sourceID) }
                    }
                )
                activeSources.insert(capture.sourceID)
                await producer.markSourceCapturing(capture.sourceID)
                started += 1
            } catch let failure as MeetingAudioCaptureFailure {
                lastError = failure
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
                try await producer.sourceBecameUnavailable(
                    capture.sourceID,
                    message: error.localizedDescription
                )
            }
        }
        if started == 0 {
            throw lastError ?? MeetingAudioCaptureFailure.unavailable(
                .microphone,
                "No meeting audio source could start."
            )
        }
    }

    private func stopSources() async {
        for capture in captures where activeSources.contains(capture.sourceID) {
            await capture.stop()
        }
        activeSources.removeAll()
    }

    private func accept(_ samples: [Float], from source: MeetingAudioSourceID) async {
        do {
            try await producer.ingest(samples, from: source)
        } catch let error as MeetingProducerError {
            switch error {
            case .invalidState(let state) where state == .paused || state == .stopping || state == .stopped:
                return
            default:
                await stopSources()
            }
        } catch {
            await stopSources()
        }
    }

    private func handle(
        _ event: MeetingAudioCaptureEvent,
        from source: MeetingAudioSourceID
    ) async {
        do {
            switch event {
            case .interrupted(let message):
                try await producer.sourceWasInterrupted(source, message: message)
            case .recovered:
                await producer.markSourceCapturing(source)
            case .failed(let failure):
                activeSources.remove(source)
                try await producer.sourceBecameUnavailable(
                    source,
                    denied: {
                        if case .permissionDenied = failure { return true }
                        return false
                    }(),
                    message: failure.localizedDescription
                )
            }
        } catch {
            await stopSources()
        }
    }
}
