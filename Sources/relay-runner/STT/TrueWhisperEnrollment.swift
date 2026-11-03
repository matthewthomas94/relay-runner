import Foundation
import Observation
import TrueWhisper

/// Records True Whisper templates for one word at a time: open the camera,
/// wait for a face, then `takesPerWord` spoken-cue takes. Each kept take is
/// saved as soon as it is recorded, so Stop keeps the takes already stored.
/// The frame source is stopped as soon as a recording ends, however it ends.
@MainActor
@Observable
final class TrueWhisperEnrollment {
    static let vocabulary = ["stop", "cancel", "play", "replay"]
    static let takesPerWord = 10
    static let minimumFrames = 6
    /// Fewer than this many takes does not count as an enrolled word.
    static let enrolledTakes = 3

    struct Timing {
        var takeSeconds: Double = 1.5
        var countdownStepSeconds: Double = 0.7
        var facePollSeconds: Double = 0.1
        var faceTimeoutSeconds: Double = 15
    }

    enum Phase: Equatable {
        case idle
        case waitingForFace
        case cue(take: Int)
        case countdown(take: Int, remaining: Int)
        case recording(take: Int)
    }

    enum Failure: Error, Equatable {
        case noFace
        case tooManyShortTakes
        case camera
        case store
    }

    private(set) var word: String?
    private(set) var phase: Phase = .idle
    private(set) var discardedTakes = 0
    private(set) var failure: Failure?
    private(set) var counts: [String: Int] = [:]

    @ObservationIgnored let store: TemplateStore
    @ObservationIgnored private let makeSource: () -> FrameSource
    @ObservationIgnored private let speak: (String) async -> Void
    @ObservationIgnored private let sleep: (Double) async throws -> Void
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        store: TemplateStore = TemplateStore(),
        timing: Timing = Timing(),
        makeSource: @escaping () -> FrameSource = { LipCaptureSession() },
        speak: @escaping (String) async -> Void = TrueWhisperSpeech.say,
        sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.store = store
        self.timing = timing
        self.makeSource = makeSource
        self.speak = speak
        self.sleep = sleep
    }

    var isRecording: Bool { word != nil }

    /// At least two words have enough takes for the classifier to choose between.
    var isReady: Bool { Self.isReady(counts) }

    static func isReady(_ counts: [String: Int]) -> Bool {
        counts.values.filter { $0 >= enrolledTakes }.count >= 2
    }

    func reloadCounts() {
        counts = Dictionary(grouping: store.load(), by: \.label).mapValues(\.count)
    }

    /// Starts recording `word`. Ignored while another recording runs.
    func record(_ word: String) {
        guard !isRecording else { return }
        self.word = word
        failure = nil
        discardedTakes = 0
        task = Task { [weak self] in
            await self?.run(word)
        }
    }

    /// Aborts the current recording. Takes already stored are kept.
    func stop() {
        task?.cancel()
    }

    /// Waits for the current recording, if any, to finish tearing down.
    func waitUntilIdle() async {
        await task?.value
    }

    func clearAll() throws {
        guard !isRecording else { return }
        try store.save([])
        reloadCounts()
    }

    private func run(_ word: String) async {
        let source = makeSource()
        let buffer = FrameBuffer()
        source.onFrame = { t, g in buffer.push(t, g) }
        defer {
            source.stop()
            source.onFrame = nil
            phase = .idle
            self.word = nil
            task = nil
        }
        do {
            do { try source.start() } catch { throw Failure.camera }
            phase = .waitingForFace
            var waited = 0.0
            while buffer.drain().isEmpty {
                guard waited < timing.faceTimeoutSeconds else { throw Failure.noFace }
                try await sleep(timing.facePollSeconds)
                waited += timing.facePollSeconds
            }

            var stored = 0
            while stored < Self.takesPerWord {
                guard discardedTakes < Self.takesPerWord else { throw Failure.tooManyShortTakes }
                let take = stored + 1
                phase = .cue(take: take)
                await speak(word)
                try Task.checkCancellation()
                for remaining in [3, 2, 1] {
                    phase = .countdown(take: take, remaining: remaining)
                    async let spoken: Void = speak(String(remaining))
                    try await sleep(timing.countdownStepSeconds)
                    await spoken
                }
                _ = buffer.drain()
                phase = .recording(take: take)
                try await sleep(timing.takeSeconds)
                let frames = buffer.drain().map(\.g)
                guard frames.count >= Self.minimumFrames else {
                    discardedTakes += 1
                    continue
                }
                do {
                    try store.save(store.load() + [Template(label: word, frames: frames)])
                } catch { throw Failure.store }
                stored += 1
                counts[word, default: 0] += 1
            }
        } catch let failure as Failure {
            self.failure = failure
        } catch {
            // Cancelled by Stop: stored takes stay.
        }
    }
}

/// Speaks enrollment cues with the system `say` command, as the spike did.
enum TrueWhisperSpeech {
    static func say(_ text: String) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [text]
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume()
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
