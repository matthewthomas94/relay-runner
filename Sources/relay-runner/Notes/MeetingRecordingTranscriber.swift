import Foundation

/// Transcribes a finished recording after Stop in one offline pass. It reuses
/// the live producer's windows and segment IDs, emits final revisions only,
/// and keeps the model loaded just for the duration of the batch.
struct MeetingRecordingTranscriber: Sendable {
    let transcriber: MeetingWindowTranscribing
    var configuration: MeetingTranscriptProducer.Configuration = .default

    func transcribe(
        _ recording: MeetingRecordedAudioReading,
        sessionID: String,
        onEvent: @escaping @Sendable (MeetingRecordingTranscriptionEvent) -> Void
    ) async throws -> MeetingProducerFinalBoundary {
        try Task.checkCancellation()
        let gate = MeetingRecordingEventGate(onEvent)
        do {
            try await transcriber.prepare { gate.send(.model($0)) }
        } catch {
            gate.send(.model(.failed(error.localizedDescription)))
            gate.close()
            await transcriber.release()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw MeetingRecordingTranscriptionError.modelUnavailable(error.localizedDescription)
        }

        let total = recording.totalMilliseconds
        let producer = MeetingTranscriptProducer(
            sessionID: sessionID,
            transcriber: transcriber,
            configuration: configuration,
            eventSink: { event in
                if case .revision(let revision) = event, revision.isFinal {
                    gate.send(.revision(revision))
                }
            }
        )
        gate.send(.progress(processedMilliseconds: 0, totalMilliseconds: total))
        do {
            let boundary = try await withTaskCancellationHandler {
                try await producer.transcribeRecording(recording) { processed in
                    gate.send(.progress(
                        processedMilliseconds: min(processed, total),
                        totalMilliseconds: total
                    ))
                }
            } onCancel: {
                gate.close()
            }
            gate.send(.progress(processedMilliseconds: total, totalMilliseconds: total))
            await transcriber.release()
            gate.send(.model(.notLoaded))
            gate.close()
            return boundary
        } catch {
            gate.close()
            await transcriber.release()
            throw error
        }
    }
}

/// Delivers events in order until closed. Delivery holds the lock, so no
/// event reaches the caller once cancellation has closed the gate.
private final class MeetingRecordingEventGate: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: @Sendable (MeetingRecordingTranscriptionEvent) -> Void
    private var isOpen = true

    init(_ deliver: @escaping @Sendable (MeetingRecordingTranscriptionEvent) -> Void) {
        self.deliver = deliver
    }

    func send(_ event: MeetingRecordingTranscriptionEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return }
        deliver(event)
    }

    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }
}
