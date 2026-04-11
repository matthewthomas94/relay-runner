import AVFAudio
import FluidAudio
import Foundation

/// FluidAudio Parakeet STT engine. Ported from stt-sidecar/Sources/VoiceListen/main.swift.
/// Runs audio capture, VAD, transcription, and gesture detection in a background task.
@Observable
final class STTEngine: @unchecked Sendable {

    // MARK: - Published state for UI/overlay

    var isRecording = false
    var partialTranscription = ""
    var statusMessage = ""

    // MARK: - Configuration

    private let modelName: String
    private let inputMode: String
    private let vadSensitivity: String

    // MARK: - Audio constants

    private let sampleRate = 16000
    private let stepMs = 500
    private let minSamples: Int      // 1 second minimum
    private let keepSamples: Int     // 200ms overlap
    private let pollMs = 50

    private let vadThresholds: [String: Float] = ["low": 0.02, "medium": 0.008, "high": 0.003]
    private var vadThreshold: Float { vadThresholds[vadSensitivity] ?? 0.008 }

    private let hallucinations: Set<String> = [
        "", "you", "thank you", "thanks for watching",
        "bye", "the end", "thanks", "thank you for watching",
    ]

    // MARK: - Internal state

    private var audioEngine: AVAudioEngine?
    private let audioBuffer = AudioBuffer()
    private var asrManager: AsrManager?
    private var processingTask: Task<Void, Error>?
    private let gesture: CapsLockGesture

    // MARK: - Init

    init(config: SttConfig) {
        self.modelName = config.model
        self.inputMode = config.input_mode
        self.vadSensitivity = config.vad_sensitivity
        self.gesture = CapsLockGesture(activationKey: config.activation_key)
        self.minSamples = sampleRate      // 1 second
        self.keepSamples = sampleRate * 200 / 1000  // 200ms
    }

    // MARK: - Lifecycle

    func start() async throws {
        FIFOWriter.ensureFifo(FIFOWriter.voiceFifoPath)

        // Load model
        let modelVersion: AsrModelVersion = modelName.contains("v3") ? .v3 : .v2
        NSLog("[STTEngine] Loading model: \(modelName)...")
        statusMessage = "Loading STT model..."
        FIFOWriter.write("__STATUS__:Loading Parakeet \(modelName) model...")

        let models = try await AsrModels.downloadAndLoad(version: modelVersion)
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.asrManager = manager
        NSLog("[STTEngine] Model loaded.")
        statusMessage = "Listening"
        FIFOWriter.write("__STATUS__:Listening")

        // Setup audio capture
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            NSLog("[STTEngine] Failed to create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 8000, format: nativeFormat) { [audioBuffer] buffer, _ in
            let ratio = 16000.0 / nativeFormat.sampleRate
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard frameCount > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)
            else { return }

            var error: NSError?
            var consumed = false
            converter.convert(to: converted, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, let channelData = converted.floatChannelData {
                let samples = Array(UnsafeBufferPointer(
                    start: channelData[0], count: Int(converted.frameLength)
                ))
                audioBuffer.append(samples)
            }
        }

        try engine.start()
        self.audioEngine = engine
        NSLog("[STTEngine] Audio capture started. Mode: \(inputMode)")

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

    func stop() {
        processingTask?.cancel()
        processingTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        asrManager = nil
        isRecording = false
        partialTranscription = ""
        statusMessage = ""
        gesture.reset()
        NSLog("[STTEngine] Stopped.")
    }

    // MARK: - Always-on mode

    private func runAlwaysOnMode() async throws {
        var transcribeCounter = 0

        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(pollMs))
            transcribeCounter += 1
            if transcribeCounter < stepMs / pollMs { continue }
            transcribeCounter = 0

            let audio = audioBuffer.get()
            guard audio.count >= minSamples else { continue }

            let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
            guard rms >= vadThreshold else { continue }

            guard let manager = asrManager else { continue }
            let result = try await manager.transcribe(audio, source: .microphone)
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
        var currentSegment = ""
        var transcribeCounter = 0
        var mediaSettleDeadline: Date?

        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(pollMs))

            // Poll gesture detector
            if let event = gesture.poll(currentSegment: currentSegment) {
                switch event {
                case .startRecording:
                    audioBuffer.clear()
                    currentSegment = ""
                    mediaSettleDeadline = Date().addingTimeInterval(Double(mediaSettleMs) / 1000)
                    isRecording = true
                    partialTranscription = "Preparing\u{2026}"
                    NSLog("[STTEngine] Settling (\(mediaSettleMs)ms for media pause)")
                    FIFOWriter.write("__STATUS__:preparing...")

                case .stopRecording(let text):
                    if FIFOWriter.write(text) {
                        NSLog("[STTEngine] >> \(text)")
                    }
                    currentSegment = ""
                    audioBuffer.clear()
                    isRecording = false
                    partialTranscription = ""
                    mediaSettleDeadline = nil

                case .interrupt:
                    FIFOWriter.write("__INTERRUPT__")
                    NSLog("[STTEngine] >> __INTERRUPT__")
                    currentSegment = ""
                    audioBuffer.clear()
                    isRecording = false
                    partialTranscription = ""
                    mediaSettleDeadline = nil

                case .play:
                    FIFOWriter.write("__PLAY__")
                    NSLog("[STTEngine] >> __PLAY__ (double-tap)")
                    continue
                }
            }

            // Media settle: wait for audio bleed-through to clear before recording
            if let deadline = mediaSettleDeadline {
                if Date() >= deadline {
                    audioBuffer.clear()
                    mediaSettleDeadline = nil
                    partialTranscription = ""
                    NSLog("[STTEngine] Recording (settled)")
                    FIFOWriter.write("__STATUS__:recording...")
                }
                continue  // Skip transcription during settle period
            }

            // Update published recording state
            let nowRecording = gesture.isRecording
            if nowRecording != isRecording {
                isRecording = nowRecording
                if nowRecording {
                    NSLog("[STTEngine] Recording...")
                    FIFOWriter.write("__STATUS__:recording...")
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

            // VAD gate
            let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
            guard rms >= vadThreshold else { continue }

            // Transcribe
            guard let manager = asrManager else { continue }
            let result = try await manager.transcribe(audio, source: .microphone)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard !hallucinations.contains(lower) else { continue }

            currentSegment = text
            partialTranscription = text
            NSLog("[STTEngine] (refining) \(text)")
            FIFOWriter.write("__STATUS__:(refining) \(text)")
        }
    }
}
