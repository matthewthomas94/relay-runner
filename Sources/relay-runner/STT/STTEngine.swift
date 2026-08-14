import Darwin
import FluidAudio
import Foundation
import QuartzCore

/// Stores only the latest microphone RMS value. Audio callbacks use a try-lock
/// so level metering can never wait behind the UI reader; a contended update is
/// simply dropped and the next capture buffer replaces it.
final class RealtimeAudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var rms: Double = 0
    private var updatedAt: CFTimeInterval = 0

    func ingest(_ samples: [Float], now: CFTimeInterval = CACurrentMediaTime()) {
        guard !samples.isEmpty else { return }

        var sumSquares = 0.0
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer {
                let value = Double(sample)
                sumSquares += value * value
            }
        }
        let nextRMS = Darwin.sqrt(sumSquares / Double(samples.count))

        guard lock.try() else { return }
        rms = nextRMS.isFinite ? nextRMS : 0
        updatedAt = now
        lock.unlock()
    }

    func latestRMS(
        now: CFTimeInterval = CACurrentMediaTime(),
        maximumAge: TimeInterval = 0.25
    ) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard updatedAt > 0, now - updatedAt <= maximumAge else { return 0 }
        return rms
    }

    func reset() {
        lock.lock()
        rms = 0
        updatedAt = 0
        lock.unlock()
    }
}

/// FluidAudio Parakeet STT engine. Ported from stt-sidecar/Sources/VoiceListen/main.swift.
/// Runs audio capture, VAD, transcription, and gesture detection in a background task.
@Observable
final class STTEngine: @unchecked Sendable {

    // MARK: - Published state for UI/overlay

    var isRecording = false
    var wasCancelled = false
    var playRequested = false
    var playRequestedAt: CFTimeInterval?
    var playDetectedAt: Date?
    var boardToggleRequested = false
    var boardToggleRequestedAt: CFTimeInterval?
    var partialTranscription = ""
    var statusMessage = ""
    var recordingStartedSerial = 0
    var speechDetectedSerial = 0
    var deliveredTranscriptSerial = 0
    var tutorialTranscriptSerial = 0
    var tutorialActive = false

    // MARK: - Configuration

    private let modelName: String
    private let inputMode: String
    private let vadSensitivity: String

    // MARK: - Audio constants

    private let sampleRate = 16000
    private let stepMs = 500
    private let minSamples: Int      // 1 second minimum
    private let keepSamples: Int     // 200ms overlap
    private let recordingChunkSamples: Int
    private let recordingKeepSamples: Int
    private let pollMs = 50

    private let vadThresholds: [String: Float] = ["low": 0.01, "medium": 0.004, "high": 0.001]
    private var vadThreshold: Float { vadThresholds[vadSensitivity] ?? 0.008 }

    private let hallucinations: Set<String> = [
        "", "you", "thank you", "thanks for watching",
        "bye", "the end", "thanks", "thank you for watching",
    ]

    // MARK: - Internal state

    private let audioBuffer = AudioBuffer()
    @ObservationIgnored private let audioLevelMeter = RealtimeAudioLevelMeter()
    private var asrManager: AsrManager?
    private var processingTask: Task<Void, Error>?
    private let gesture: CapsLockGesture
    @ObservationIgnored private let captureInterruptionLock = NSLock()
    @ObservationIgnored private var pendingCaptureInterruption: AudioCaptureInterruption?
    @ObservationIgnored private var captureInterruptionEpoch: UInt64 = 0
    @ObservationIgnored private var routeCancellationNoticePending = false
    @ObservationIgnored private var captureReady = false
    @ObservationIgnored private lazy var audioCapture: AudioCaptureLifecycle = AudioCaptureLifecycle(
        sampleHandler: { [weak self] samples in
            self?.audioBuffer.append(samples)
            self?.audioLevelMeter.ingest(samples)
        },
        isRecording: { [weak self] in
            guard let self else { return false }
            return self.isRecording || self.gesture.isRecording
        }
    )

    // MARK: - Init

    init(config: SttConfig) {
        self.modelName = config.model
        self.inputMode = config.input_mode
        self.vadSensitivity = config.vad_sensitivity
        self.gesture = CapsLockGesture(activationKey: config.activation_key)
        self.minSamples = sampleRate      // 1 second
        self.keepSamples = sampleRate * 200 / 1000  // 200ms
        self.recordingChunkSamples = sampleRate * 25
        self.recordingKeepSamples = sampleRate
    }

    /// Inject the modal-confirmation hooks for Relay Actions `propose_action`
    /// prompts. When `stateMachine.pendingConfirmation != nil`, double-tap
    /// Option/Control are routed to `resolver(true|false)` instead of the
    /// default play/cancel behavior. AppState calls this once during
    /// startOverlay() to bridge the gesture monitor to the ActionsConfirmBus
    /// actor without exposing the private gesture object.
    func wireConfirmationGate(stateMachine: StateMachine, resolver: @escaping (Bool) -> Void) {
        gesture.stateMachine = stateMachine
        gesture.confirmationResolver = resolver
    }

    // MARK: - Lifecycle

    func start() async throws {
        FIFOWriter.ensureFifo(FIFOWriter.voiceFifoPath)

        // Load model (with download progress feedback)
        let modelVersion: AsrModelVersion = modelName.contains("v3") ? .v3 : .v2
        NSLog("[STTEngine] Loading model: \(modelName)...")
        statusMessage = "Loading STT model..."
        FIFOWriter.write("__STATUS__:Loading Parakeet \(modelName) model...")

        let models = try await AsrModels.downloadAndLoad(version: modelVersion) { [weak self] progress in
            let pct = Int(progress.fractionCompleted * 100)
            let message: String
            switch progress.phase {
            case .listing:
                message = "Checking models..."
            case .downloading(let completed, let total):
                message = "Downloading model \(completed)/\(total) (\(pct)%)"
            case .compiling(let name):
                message = "Compiling \(name)..."
            }
            Task { @MainActor in
                self?.statusMessage = message
            }
            FIFOWriter.write("__STATUS__:\(message)")
            NSLog("[STTEngine] \(message)")
        }
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.asrManager = manager
        NSLog("[STTEngine] Model loaded.")
        statusMessage = "Listening"
        FIFOWriter.write("__STATUS__:Listening")

        audioCapture.onWillReconfigure = { [weak self] interruption in
            self?.prepareForCaptureReconfiguration(interruption)
        }
        audioCapture.onRecovery = { [weak self] recovery in
            self?.captureDidRecover(recovery)
        }
        if let route = try audioCapture.start() {
            setCaptureReady(true)
            NSLog(
                "[STTEngine] Audio capture started. device=\(route.deviceID) " +
                "format=\(route.sampleRate)Hz/\(route.channelCount)ch mode=\(inputMode)"
            )
        }

        // Start processing loop
        processingTask = Task { [weak self] in
            guard let self else { return }
            if self.inputMode == "caps_lock_toggle" {
                try await self.runCapsLockMode()
            } else {
                try await self.runAlwaysOnMode()
            }
        }
    }

    func toggleRecording() {
        gesture.toggleActivation()
    }

    func recordingAudioRMS() -> Double {
        audioLevelMeter.latestRMS()
    }

    /// Cancel an in-progress recording externally (e.g. no session to send to).
    func cancelRecording() {
        guard isRecording else { return }
        gesture.reset()
        resetRecordingBuffer()
        isRecording = false
        partialTranscription = ""
    }

    func stop() {
        audioBuffer.accepting = false
        captureInterruptionLock.lock()
        captureInterruptionEpoch &+= 1
        captureReady = false
        pendingCaptureInterruption = nil
        routeCancellationNoticePending = false
        captureInterruptionLock.unlock()
        processingTask?.cancel()
        processingTask = nil
        audioCapture.stop()
        asrManager = nil
        isRecording = false
        partialTranscription = ""
        statusMessage = ""
        resetRecordingBuffer()
        gesture.reset()
        NSLog("[STTEngine] Stopped.")
    }

    private func resetRecordingBuffer() {
        audioBuffer.accepting = false
        audioBuffer.clear()
        audioBuffer.setMaxSamples(AudioBuffer.defaultMaxSamples)
        audioLevelMeter.reset()
    }

    private func prepareForCaptureReconfiguration(_ interruption: AudioCaptureInterruption) {
        audioBuffer.accepting = false
        audioBuffer.clear()
        audioLevelMeter.reset()
        captureInterruptionLock.lock()
        captureInterruptionEpoch &+= 1
        captureReady = false
        if interruption.recordingOutcome == .cancelRecording {
            routeCancellationNoticePending = true
        }
        if let pendingCaptureInterruption {
            let outcome: AudioCaptureInterruption.RecordingOutcome =
                pendingCaptureInterruption.recordingOutcome == .cancelRecording ||
                interruption.recordingOutcome == .cancelRecording
                    ? .cancelRecording
                    : .idle
            self.pendingCaptureInterruption = AudioCaptureInterruption(
                reasons: pendingCaptureInterruption.reasons.union(interruption.reasons),
                recordingOutcome: outcome
            )
        } else {
            pendingCaptureInterruption = interruption
        }
        captureInterruptionLock.unlock()
    }

    private func takeCaptureInterruption() -> AudioCaptureInterruption? {
        captureInterruptionLock.lock()
        defer { captureInterruptionLock.unlock() }
        let interruption = pendingCaptureInterruption
        pendingCaptureInterruption = nil
        return interruption
    }

    private func currentCaptureEpoch() -> UInt64 {
        captureInterruptionLock.lock()
        defer { captureInterruptionLock.unlock() }
        return captureInterruptionEpoch
    }

    private func captureEpochIsCurrent(_ epoch: UInt64) -> Bool {
        currentCaptureEpoch() == epoch
    }

    private func setCaptureReady(_ ready: Bool) {
        captureInterruptionLock.lock()
        captureReady = ready
        captureInterruptionLock.unlock()
    }

    private func isCaptureReady() -> Bool {
        captureInterruptionLock.lock()
        defer { captureInterruptionLock.unlock() }
        return captureReady
    }

    private func captureDidRecover(_ recovery: AudioCaptureRecovery) {
        captureInterruptionLock.lock()
        let cancelledRecording = routeCancellationNoticePending
        routeCancellationNoticePending = false
        captureInterruptionLock.unlock()

        if let error = recovery.error {
            setCaptureReady(false)
            audioBuffer.accepting = false
            statusMessage = error.localizedDescription
            FIFOWriter.write("__STATUS__:\(error.localizedDescription)")
            NSLog(
                "[STTEngine] Audio route recovery failed. " +
                "reasons=\(recovery.reasons.sorted().joined(separator: ",")) error=\(error)"
            )
            return
        }

        guard let route = recovery.route else { return }
        setCaptureReady(true)
        audioBuffer.clear()
        audioBuffer.setMaxSamples(AudioBuffer.defaultMaxSamples)
        audioBuffer.accepting = inputMode != "caps_lock_toggle"
        let message = cancelledRecording
            ? "Microphone changed — recording cancelled. Ready to retry."
            : "Listening"
        statusMessage = message
        FIFOWriter.write("__STATUS__:\(message)")
        let previousID = recovery.previousRoute.map { String($0.deviceID) } ?? "none"
        NSLog(
            "[STTEngine] Audio route recovered. previous=\(previousID) " +
            "current=\(route.deviceID) format=\(route.sampleRate)Hz/\(route.channelCount)ch " +
            "reasons=\(recovery.reasons.sorted().joined(separator: ","))"
        )
    }

    // MARK: - Always-on mode

    private func runAlwaysOnMode() async throws {
        var transcribeCounter = 0

        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(pollMs))
            _ = takeCaptureInterruption()
            transcribeCounter += 1
            if transcribeCounter < stepMs / pollMs { continue }
            transcribeCounter = 0

            let audio = audioBuffer.get()
            guard audio.count >= minSamples else { continue }

            let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
            guard rms >= vadThreshold else { continue }

            guard let manager = asrManager else { continue }
            let captureEpoch = currentCaptureEpoch()
            let result = try await manager.transcribe(audio, source: .microphone)
            guard captureEpochIsCurrent(captureEpoch) else { continue }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard !hallucinations.contains(lower) else { continue }

            if FIFOWriter.write(text) { NSLog("[STTEngine] >> \(text)") }
            audioBuffer.clearExceptKeep(keepSamples)
        }
    }

    // MARK: - Caps Lock toggle mode

    /// Brief delay before capturing speech, so media has time to pause
    /// and any bleed-through audio is discarded.
    private let mediaSettleMs = 500

    private func runCapsLockMode() async throws {
        var transcript = TranscriptAccumulator()
        var transcribeCounter = 0
        var mediaSettleDeadline: Date?

        // Don't accumulate audio while idle — saves memory over long sessions
        resetRecordingBuffer()

        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(pollMs))

            if let interruption = takeCaptureInterruption() {
                let cancelledRecording = interruption.recordingOutcome == .cancelRecording
                gesture.reset()
                transcript.reset()
                resetRecordingBuffer()
                isRecording = false
                partialTranscription = ""
                mediaSettleDeadline = nil
                if cancelledRecording {
                    wasCancelled = true
                    let message = "Microphone changed — recording cancelled. Ready to retry."
                    statusMessage = message
                    writeVoiceOutput("__CANCEL__")
                    writeVoiceOutput("__STATUS__:\(message)")
                    NSLog(
                        "[STTEngine] Recording cancelled for audio route recovery. " +
                        "reasons=\(interruption.reasons.sorted().joined(separator: ","))"
                    )
                }
                continue
            }

            // Poll gesture detector
            if let event = gesture.poll(currentSegment: transcript.transcript) {
                switch event {
                case .startRecording:
                    guard isCaptureReady() else {
                        gesture.reset()
                        isRecording = false
                        partialTranscription = ""
                        let message = statusMessage.isEmpty
                            ? "Microphone input is recovering. Try again in a moment."
                            : statusMessage
                        writeVoiceOutput("__STATUS__:\(message)")
                        continue
                    }
                    // Kill TTS playback immediately (but don't notify Claude yet —
                    // that waits until after settle to avoid breaking double-tap play)
                    writeVoiceOutput("__TTS_STOP__")
                    audioBuffer.setMaxSamples(nil)
                    audioBuffer.accepting = true
                    audioBuffer.clear()
                    transcript.reset()
                    mediaSettleDeadline = Date().addingTimeInterval(Double(mediaSettleMs) / 1000)
                    isRecording = true
                    recordingStartedSerial += 1
                    partialTranscription = "Preparing\u{2026}"
                    NSLog("[STTEngine] Settling (\(mediaSettleMs)ms for media pause)")
                    writeVoiceOutput("__STATUS__:preparing...")

                case .stopRecording(_):
                    let captureEpoch = currentCaptureEpoch()
                    let finalText = try await finalizeRecordingTranscript(into: &transcript)
                    guard captureEpochIsCurrent(captureEpoch) else { continue }
                    if let finalText {
                        if tutorialActive {
                            tutorialTranscriptSerial += 1
                            NSLog("[STTEngine] Tutorial transcript consumed locally")
                        } else if writeVoiceOutput(finalText) {
                            deliveredTranscriptSerial += 1
                            NSLog("[STTEngine] >> \(finalText)")
                        }
                    }
                    transcript.reset()
                    resetRecordingBuffer()
                    isRecording = false
                    partialTranscription = ""
                    mediaSettleDeadline = nil

                case .cancel:
                    writeVoiceOutput("__CANCEL__")
                    NSLog("[STTEngine] Cancelled (2x Ctrl)")
                    transcript.reset()
                    resetRecordingBuffer()
                    isRecording = false
                    wasCancelled = true
                    partialTranscription = ""
                    mediaSettleDeadline = nil

                case .interrupt:
                    let captureEpoch = currentCaptureEpoch()
                    let finalText = try await finalizeRecordingTranscript(into: &transcript)
                    guard captureEpochIsCurrent(captureEpoch) else { continue }
                    if let finalText {
                        if tutorialActive {
                            tutorialTranscriptSerial += 1
                            NSLog("[STTEngine] Tutorial transcript consumed locally")
                        } else if writeVoiceOutput(finalText) {
                            deliveredTranscriptSerial += 1
                            NSLog("[STTEngine] >> \(finalText)")
                        }
                    } else {
                        writeVoiceOutput("__INTERRUPT__")
                        NSLog("[STTEngine] >> __INTERRUPT__")
                    }
                    transcript.reset()
                    resetRecordingBuffer()
                    isRecording = false
                    partialTranscription = ""
                    mediaSettleDeadline = nil

                case .play:
                    let detectedAt = Date()
                    playRequested = true
                    playRequestedAt = CACurrentMediaTime()
                    playDetectedAt = detectedAt
                    writeVoiceOutput(Self.playControl(detectedAt: detectedAt))
                    NSLog("[STTEngine] >> __PLAY__ (double-tap)")
                    continue

                case .boardToggle:
                    boardToggleRequested = true
                    boardToggleRequestedAt = CACurrentMediaTime()
                    NSLog("[STTEngine] Workspace toggle requested (double-tap Shift)")
                    continue
                }
            }

            // Media settle: wait for audio bleed-through to clear before recording
            if let deadline = mediaSettleDeadline {
                if Date() >= deadline {
                    audioBuffer.clear()
                    mediaSettleDeadline = nil
                    partialTranscription = ""
                    if gesture.isRecording {
                        // Recording barge-in is speech-only. The completed
                        // transcript is classified before any provider preemption.
                        NSLog("[STTEngine] Recording (settled, speech muted)")
                    } else {
                        NSLog("[STTEngine] Settle expired (awaiting gesture)")
                    }
                    writeVoiceOutput("__STATUS__:recording...")
                }
                continue  // Skip transcription during settle period
            }

            // Update published recording state
            let nowRecording = gesture.isRecording
            if nowRecording != isRecording {
                isRecording = nowRecording
                if nowRecording {
                    NSLog("[STTEngine] Recording...")
                    writeVoiceOutput("__STATUS__:recording...")
                }
            }

            // If not recording, nothing to transcribe
            guard gesture.isRecording else { continue }

            // Throttle transcription to ~500ms
            transcribeCounter += 1
            if transcribeCounter < stepMs / pollMs { continue }
            transcribeCounter = 0

            let audio = audioBuffer.get()
            guard audio.count >= minSamples else { continue }

            let captureEpoch = currentCaptureEpoch()
            guard let text = try await transcribeMeaningfulText(audio),
                  captureEpochIsCurrent(captureEpoch)
            else { continue }

            transcript.refine(text)
            speechDetectedSerial += 1
            let renderedTranscript = transcript.transcript
            partialTranscription = renderedTranscript
            NSLog("[STTEngine] (refining) \(renderedTranscript)")
            writeVoiceOutput("__STATUS__:(refining) \(renderedTranscript)")

            if audio.count >= recordingChunkSamples {
                transcript.commitLiveSegment()
                audioBuffer.discardPrefix(upTo: audio.count, keeping: recordingKeepSamples)
                partialTranscription = transcript.transcript
            }
        }
    }

    private func finalizeRecordingTranscript(into transcript: inout TranscriptAccumulator) async throws -> String? {
        let audio = audioBuffer.get()
        if audio.count >= minSamples, let text = try await transcribeMeaningfulText(audio) {
            transcript.refine(text)
        }
        return transcript.hasTranscript ? transcript.transcript : nil
    }

    private func transcribeMeaningfulText(_ audio: [Float]) async throws -> String? {
        guard let manager = asrManager else { return nil }
        let result = try await manager.transcribe(audio, source: .microphone)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard !hallucinations.contains(lower) else { return nil }

        return text
    }

    @discardableResult
    private func writeVoiceOutput(_ text: String) -> Bool {
        Self.writeVoiceOutput(text, tutorialActive: tutorialActive)
    }

    @discardableResult
    static func writeVoiceOutput(
        _ text: String,
        tutorialActive: Bool,
        writer: (String) -> Bool = { FIFOWriter.write($0) }
    ) -> Bool {
        guard !tutorialActive else { return false }
        return writer(text)
    }

    static func playControl(detectedAt: Date) -> String {
        String(format: "__PLAY__:%.6f", detectedAt.timeIntervalSince1970)
    }

    func recordPlaybackAcknowledgement(detectedAt: Date, acknowledgedAt: Date) {
        writeVoiceOutput(Self.playAcknowledgementControl(
            detectedAt: detectedAt,
            acknowledgedAt: acknowledgedAt
        ))
    }

    static func playAcknowledgementControl(
        detectedAt: Date,
        acknowledgedAt: Date
    ) -> String {
        String(
            format: "__PLAY_ACK__:%.6f:%.6f",
            detectedAt.timeIntervalSince1970,
            acknowledgedAt.timeIntervalSince1970
        )
    }
}
