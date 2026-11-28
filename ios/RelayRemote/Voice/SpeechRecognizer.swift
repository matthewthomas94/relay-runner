@preconcurrency import AVFoundation
import Foundation
import Speech

/// On-device transcription with `SpeechAnalyzer` and `SpeechTranscriber`
/// (RR-421), fed from an `AVAudioEngine` input tap. One analyzer serves one
/// utterance: the caller decides where an utterance ends (push-to-talk
/// release or the second tap), calls `finishUtterance()` for the
/// final text, and starts the next one.
@MainActor
final class SpeechRecognizer {
    enum Readiness: Equatable {
        case unknown
        case unsupported
        case microphoneDenied
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var readiness = Readiness.unknown
    private(set) var isCapturing = false
    private var isPreparing = false
    private(set) var locale = Locale.current
    /// The microphone's loudness and bands, per buffer (`VoiceLevelAnalysis`).
    var onVoiceLevel: ((VoiceLevel) -> Void)?
    /// The transcript so far: finalized text followed by the volatile tail.
    var onTranscript: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let tap = TapState()
    private var analyzer: SpeechAnalyzer?
    /// The analyzer for the next utterance, its model already loaded, so a
    /// press starts transcribing at once instead of loading it first.
    private var prepared: (analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber)?
    private var warming: Task<Void, Never>?
    /// The analyzer's audio format, looked up once.
    private var analyzerFormat: AVAudioFormat?
    private var resultsTask: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""

    /// Makes sure the microphone is allowed and the on-device model is
    /// installed. Without `prompting` an undecided microphone permission is
    /// left alone, so the system prompt appears on the first press, not at launch.
    func prepare(prompting: Bool) async {
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            readiness = .microphoneDenied
            return
        case .undetermined:
            guard prompting else { return }
            guard await AVAudioApplication.requestRecordPermission() else {
                readiness = .microphoneDenied
                return
            }
        default:
            break
        }
        guard readiness != .ready, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        locale = Self.pickLocale(from: await SpeechTranscriber.supportedLocales)
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [probe]) {
        case .unsupported:
            readiness = .unsupported
        case .installed:
            readiness = .ready
            warmUp()
        case .supported, .downloading:
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    readiness = .downloading(0)
                    let observation = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                        let fraction = progress.fractionCompleted
                        Task { @MainActor in self?.readiness = .downloading(fraction) }
                    }
                    defer { observation.invalidate() }
                    try await request.downloadAndInstall()
                }
                readiness = .ready
                warmUp()
            } catch {
                readiness = .failed("model")
            }
        @unknown default:
            readiness = .failed("model")
        }
    }

    /// Starts the microphone if needed and a fresh analyzer for one utterance.
    func startUtterance() async throws {
        try startEngineIfNeeded()
        // A warm-up still loading the model finishes first; it is the same work.
        await warming?.value
        let next: (analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber)
        if let prepared {
            next = prepared
            self.prepared = nil
        } else {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            next = (SpeechAnalyzer(modules: [transcriber]), transcriber)
        }
        let (analyzer, transcriber) = next
        guard let format = await format(for: transcriber),
              let converter = AVAudioConverter(from: engine.inputNode.outputFormat(forBus: 0), to: format) else {
            throw RecognizerError.noAudioFormat
        }
        finalText = ""
        volatileText = ""
        // Audio queues in the stream from here, so nothing said while the
        // analyzer starts is lost.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        tap.begin(continuation: continuation, converter: converter, format: format)
        self.analyzer = analyzer
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    await MainActor.run { self?.handle(text: text, isFinal: isFinal) }
                }
            } catch {
                // The analyzer finished or was cancelled.
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Ends the current utterance, flushes the analyzer and returns its text.
    func finishUtterance() async -> String {
        tap.end()
        guard let analyzer else { return "" }
        self.analyzer = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await awaitResults(timeout: 2)
        warmUp()
        return Self.join(finalText, volatileText)
    }

    /// Drops the current utterance without a result.
    func cancelUtterance() async {
        tap.end()
        guard let analyzer else { return }
        self.analyzer = nil
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        finalText = ""
        volatileText = ""
        warmUp()
    }

    /// Keep the microphone open but stop feeding the analyzer, for example
    /// while the phone itself is speaking.
    func pauseFeeding() {
        tap.setFeeding(false)
    }

    /// Feeds the analyzer again after `pauseFeeding`, if an utterance is open.
    func resumeFeeding() {
        guard analyzer != nil else { return }
        tap.setFeeding(true)
    }

    func stopCapture() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
    }

    // MARK: - Internals

    /// Loads the next utterance's analyzer and model ahead of the press.
    private func warmUp() {
        guard readiness == .ready, prepared == nil, warming == nil else { return }
        warming = Task { [weak self] in
            guard let self else { return }
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            if let format = await format(for: transcriber) {
                try? await analyzer.prepareToAnalyze(in: format)
            }
            prepared = (analyzer, transcriber)
            warming = nil
        }
    }

    private func format(for transcriber: SpeechTranscriber) async -> AVAudioFormat? {
        if let analyzerFormat { return analyzerFormat }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        analyzerFormat = format
        return format
    }

    private func startEngineIfNeeded() throws {
        guard !isCapturing else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecognizerError.noAudioFormat }
        let tap = self.tap
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let level = VoiceLevelAnalysis.analyse(buffer)
            tap.feed(buffer)
            Task { @MainActor [weak self] in self?.onVoiceLevel?(level) }
        }
        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    private func handle(text: String, isFinal: Bool) {
        if isFinal {
            finalText = Self.join(finalText, text)
            volatileText = ""
        } else {
            volatileText = text
        }
        onTranscript?(Self.join(finalText, volatileText))
    }

    private func awaitResults(timeout: TimeInterval) async {
        guard let resultsTask else { return }
        self.resultsTask = nil
        let waiter = Task { await resultsTask.value }
        let timer = Task { try? await Task.sleep(for: .seconds(timeout)); waiter.cancel() }
        await waiter.value
        timer.cancel()
    }

    private static func join(_ head: String, _ tail: String) -> String {
        let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHead = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHead.isEmpty { return trimmedTail }
        if trimmedTail.isEmpty { return trimmedHead }
        return trimmedHead + " " + trimmedTail
    }

    /// The device language when the model supports it, else English, else
    /// whatever the model offers first.
    static func pickLocale(from supported: [Locale]) -> Locale {
        let wanted = Locale.current.identifier(.bcp47).lowercased()
        if let exact = supported.first(where: { $0.identifier(.bcp47).lowercased() == wanted }) { return exact }
        let language = Locale.current.language.languageCode?.identifier.lowercased()
        if let sameLanguage = supported.first(where: { $0.language.languageCode?.identifier.lowercased() == language }) {
            return sameLanguage
        }
        return supported.first(where: { $0.identifier(.bcp47).lowercased() == "en-us" }) ?? supported.first ?? Locale(identifier: "en-US")
    }

    enum RecognizerError: Error {
        case noAudioFormat
    }

    /// Shared with the audio thread: converts tap buffers to the analyzer's
    /// format and yields them while an utterance is open.
    private final class TapState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<AnalyzerInput>.Continuation?
        private var converter: AVAudioConverter?
        private var format: AVAudioFormat?
        private var feeding = false

        func begin(continuation: AsyncStream<AnalyzerInput>.Continuation, converter: AVAudioConverter, format: AVAudioFormat) {
            lock.withLock {
                self.continuation?.finish()
                self.continuation = continuation
                self.converter = converter
                self.format = format
                feeding = true
            }
        }

        func setFeeding(_ on: Bool) {
            lock.withLock { feeding = on }
        }

        func end() {
            lock.withLock {
                feeding = false
                continuation?.finish()
                continuation = nil
            }
        }

        func feed(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard feeding, let continuation, let converter, let format else { return }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, converted.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }
}
