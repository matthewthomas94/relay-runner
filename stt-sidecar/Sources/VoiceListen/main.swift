import AVFAudio
import CoreGraphics
import FluidAudio
import Foundation

// MARK: - Configuration

let fifoPath = envOrArg("VOICE_FIFO", flag: "--fifo-path") ?? "/tmp/voice_in.fifo"
let inputMode = arg("--input-mode") ?? "caps_lock_toggle"
let vadSensitivity = arg("--vad-sensitivity") ?? "medium"
let modelVersionStr = arg("--model") ?? "parakeet-tdt-v2"

let vadThresholds: [String: Float] = ["low": 0.02, "medium": 0.008, "high": 0.003]
let vadThreshold = vadThresholds[vadSensitivity] ?? 0.008

let sampleRate = 16000
let stepMs = 500
let minSamples = sampleRate  // 1 second minimum
let keepSamples = sampleRate * 200 / 1000  // 200ms overlap

let hallucinations: Set<String> = [
    "", "you", "thank you", "thanks for watching",
    "bye", "the end", "thanks", "thank you for watching",
]

// MARK: - CLI Argument Parsing

func arg(_ flag: String) -> String? {
    let args = CommandLine.arguments
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func envOrArg(_ envKey: String, flag: String) -> String? {
    if let val = ProcessInfo.processInfo.environment[envKey] { return val }
    return arg(flag)
}

// MARK: - FIFO Helpers

func ensureFifo(_ path: String) {
    let fm = FileManager.default
    if fm.fileExists(atPath: path) {
        var sb = stat()
        stat(path, &sb)
        if (sb.st_mode & S_IFMT) == S_IFIFO { return }
        try? fm.removeItem(atPath: path)
    }
    mkfifo(path, 0o644)
}

@discardableResult
func writeToFifo(_ path: String, _ text: String) -> Bool {
    let fd = open(path, O_WRONLY | O_NONBLOCK)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    guard let data = (text + "\n").data(using: .utf8) else { return false }
    return data.withUnsafeBytes { ptr in
        Darwin.write(fd, ptr.baseAddress!, ptr.count) >= 0
    }
}

// MARK: - Caps Lock Detection & Control

func isCapsLockOn() -> Bool {
    let flags = CGEventSource.flagsState(.combinedSessionState)
    return flags.contains(.maskAlphaShift)
}


// MARK: - Thread-Safe Audio Buffer

final class AudioBuffer: @unchecked Sendable {
    private var samples: [Float] = []
    private let lock = NSLock()

    func append(_ newSamples: [Float]) {
        lock.lock()
        samples.append(contentsOf: newSamples)
        lock.unlock()
    }

    func get() -> [Float] {
        lock.lock()
        let copy = samples
        lock.unlock()
        return copy
    }

    func clear() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    func clearExceptKeep(_ keepCount: Int) {
        lock.lock()
        if samples.count > keepCount {
            samples = Array(samples.suffix(keepCount))
        }
        lock.unlock()
    }
}

// MARK: - Main

func log(_ msg: String) {
    FileHandle.standardError.write("[voice_listen] \(msg)\n".data(using: .utf8)!)
}

func run() async throws {
    // Setup FIFO first so we can send status updates
    ensureFifo(fifoPath)

    // Resolve model version
    let modelVersion: AsrModelVersion = modelVersionStr.contains("v3") ? .v3 : .v2
    log("Loading model: \(modelVersionStr) (will download if needed)...")
    writeToFifo(fifoPath, "__STATUS__:Downloading Parakeet \(modelVersionStr) model (~600MB, first launch only)...")

    // Load FluidAudio model (downloads + caches on first use)
    let models = try await AsrModels.downloadAndLoad(version: modelVersion)
    let asrManager = AsrManager()
    try await asrManager.loadModels(models)
    log("Model loaded.")
    writeToFifo(fifoPath, "__STATUS__:Model loaded.")

    log("FIFO:  \(fifoPath)")
    log("VAD:   \(vadSensitivity) (threshold \(vadThreshold))")
    log("Mode:  \(inputMode)")
    log("Listening...")
    writeToFifo(fifoPath, "__STATUS__:Listening — Caps Lock to speak.")

    // Setup audio capture — tap at native hardware format, resample to 16kHz mono
    let audioBuffer = AudioBuffer()
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let nativeFormat = inputNode.outputFormat(forBus: 0)
    let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
        log("Failed to create audio converter from \(nativeFormat) to 16kHz mono")
        return
    }

    inputNode.installTap(onBus: 0, bufferSize: 8000, format: nativeFormat) { buffer, _ in
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

    // -- Caps Lock gesture detection --
    // Each key press = one state transition. LED ON = mic active.
    //   1 press:  mic on (LED on), hold to speak, press again = mic off (LED off), send text
    //   2 rapid:  play queued TTS, or replay last if nothing queued (LED ends OFF ✓)
    let recordThresholdSec: Double = 0.3  // Hold >300ms to enter recording mode
    let tapWindowSec: Double = 0.6       // Max gap between taps in a multi-tap gesture
    let settleMs: Double = 0.7           // Wait after last transition to fire gesture
    let pollMs = 50                    // Fast polling for responsive detection

    var prevCapsOn = isCapsLockOn()
    var recording = false              // Held long enough, actively recording
    var currentSegment = ""
    var transcribeCounter = 0

    // Transition history: timestamps of recent rapid state changes
    var transitions: [Date] = []

    while true {
        try await Task.sleep(for: .milliseconds(pollMs))

        let capsOn = isCapsLockOn()
        let now = Date()

        // -- always_on mode --
        if inputMode != "caps_lock_toggle" {
            transcribeCounter += 1
            if transcribeCounter < stepMs / pollMs { continue }
            transcribeCounter = 0

            let audio = audioBuffer.get()
            guard audio.count >= minSamples else { continue }
            let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
            guard rms >= vadThreshold else { continue }

            let result = try await asrManager.transcribe(audio, source: .microphone)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            guard !hallucinations.contains(lower) else { continue }

            if writeToFifo(fifoPath, text) { log(">> \(text)") }
            audioBuffer.clearExceptKeep(keepSamples)
            continue
        }

        // -- Caps Lock toggle mode --

        // Detect state transition
        if capsOn != prevCapsOn {
            let isRapid = transitions.last.map { now.timeIntervalSince($0) < tapWindowSec } ?? true
            if isRapid && !recording {
                // Part of a rapid tap sequence
                transitions.append(now)
            } else if !recording {
                // Too slow for a tap sequence — start fresh
                transitions = [now]
            }

            // Caps Lock just turned ON (mic on)
            if capsOn {
                audioBuffer.clear()
                currentSegment = ""
            }

            // Caps Lock just turned OFF while recording (mic off) — send text
            if !capsOn && recording {
                if !currentSegment.isEmpty {
                    if writeToFifo(fifoPath, currentSegment) {
                        log(">> \(currentSegment)")
                    }
                } else {
                    writeToFifo(fifoPath, "__INTERRUPT__")
                    log(">> __INTERRUPT__")
                }
                currentSegment = ""
                audioBuffer.clear()
                recording = false
                transitions.removeAll()
            }

            prevCapsOn = capsOn
            continue
        }

        // Check if a rapid tap sequence has settled
        if !transitions.isEmpty && !recording {
            if let last = transitions.last, now.timeIntervalSince(last) > settleMs {
                let count = transitions.count

                if count == 1 && capsOn {
                    // Single press, held — will become recording (handled below)
                } else if count >= 2 {
                    // Double-tap: play queued, or replay if nothing queued
                    writeToFifo(fifoPath, "__PLAY__")
                    log(">> __PLAY__ (double-tap)")
                    transitions.removeAll()
                    continue
                }
            }
        }

        // If Caps Lock is off, nothing to do
        if !capsOn { continue }

        // Enter recording mode once held past tap threshold
        if !recording {
            if let first = transitions.first, now.timeIntervalSince(first) >= recordThresholdSec {
                recording = true
                transitions.removeAll()
                log("recording...")
            } else {
                continue  // Still within tap window, wait
            }
        }

        // Throttle transcription to ~500ms
        transcribeCounter += 1
        if transcribeCounter < stepMs / pollMs { continue }
        transcribeCounter = 0

        // Get audio window
        let audio = audioBuffer.get()
        guard audio.count >= minSamples else { continue }

        // VAD gate
        let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(audio.count))
        guard rms >= vadThreshold else { continue }

        // Transcribe
        let result = try await asrManager.transcribe(audio, source: .microphone)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }

        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard !hallucinations.contains(lower) else { continue }

        currentSegment = text
        log("(refining) \(text)")
    }
}

// Entry point
Task {
    do {
        try await run()
    } catch {
        log("Fatal error: \(error)")
        exit(1)
    }
}

// Keep the process alive
dispatchMain()
