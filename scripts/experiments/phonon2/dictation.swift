import Foundation
import FluidAudio

// RR-413 offline dictation replay. Feeds public RR-411 fixtures through the
// production TranscriptAccumulator and TranscriptFilter (copied in at build
// time) on the Caps Lock loop's 500 ms snapshot cadence, 25 s chunk rollover
// and 1 s overlap. Never opens capture, writes the voice FIFO, or saves text.

struct Case: Decodable {
    let id: String
    let pcm: String
    let reference: String?
    let expectedSamples: Int
}
struct Input: Decodable {
    let cases: [Case]
    let revisions: [String: String]
}

let rate = 16_000
let stepSamples = rate / 2          // STTEngine.stepMs
let minSamples = rate               // STTEngine.minSamples
let chunkSamples = rate * 25        // STTEngine.recordingChunkSamples
let keepSamples = rate              // STTEngine.recordingKeepSamples

func words(_ text: String) -> [String] {
    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}
func distance(_ a: [String], _ b: [String]) -> Int {
    var row = Array(0...b.count)
    for (i, x) in a.enumerated() {
        var next = [i + 1]
        for (j, y) in b.enumerated() {
            next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1)))
        }
        row = next
    }
    return row.last!
}
func emit(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

/// Deterministic Gaussian noise (Box–Muller over a fixed LCG).
func noise(seconds: Double, rms: Float, seed: UInt64) -> [Float] {
    var state = seed
    func uniform() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(state >> 40) / Float(1 << 24) + 1e-7
    }
    return (0..<Int(seconds * Double(rate))).map { _ in
        rms * (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
    }
}

@main struct Dictation {
    static func main() async throws {
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        let args = CommandLine.arguments
        guard args.count == 5 else { fatalError("usage: dictation MODEL MODEL_DIRECTORY INPUT_JSON PASSES") }
        let version: AsrModelVersion
        switch args[1] {
        case "v2": version = .v2
        case "phonon2": version = .phonon2
        default: fatalError("unsupported model")
        }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        // Same pinned model revisions RR-411 measured; never downloads.
        ModelRegistry.revisionOverrides = input.revisions
        ModelHub.offlineMode = true
        let models = try await AsrModels.load(from: URL(fileURLWithPath: args[2]), version: version)
        let manager = AsrManager()
        try await manager.loadModels(models)
        var fixtures: [String: (samples: [Float], reference: String)] = [:]
        for item in input.cases {
            let data = try Data(contentsOf: URL(fileURLWithPath: item.pcm))
            guard data.count == item.expectedSamples * 4 else { fatalError("sample count mismatch") }
            fixtures[item.id] = (data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, item.reference ?? "")
        }

        func transcribe(_ audio: [Float]) async throws -> (text: String, ms: Double) {
            let begun = Date()
            // Fresh decoder state per independent snapshot, as in STTEngine.
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(audio, decoderState: &state)
            return (result.text, Date().timeIntervalSince(begun) * 1000)
        }

        // Join fixtures with 250 ms of silence into one continuous utterance.
        func stream(_ ids: [String]) -> (samples: [Float], reference: String) {
            var samples: [Float] = []
            var references: [String] = []
            for id in ids {
                guard let fixture = fixtures[id] else { fatalError("missing \(id)") }
                if !samples.isEmpty { samples += [Float](repeating: 0, count: rate / 4) }
                samples += fixture.samples
                references.append(fixture.reference)
            }
            return (samples, references.joined(separator: " "))
        }

        let commands = input.cases.map(\.id).filter { $0.hasPrefix("commands-") && !$0.hasSuffix("noise20db") }
        func fill(_ seconds: Double, from ids: [String]) -> [String] {
            var picked: [String] = []
            var total = 0
            for id in ids where Double(total) / Double(rate) < seconds {
                picked.append(id)
                total += fixtures[id]!.samples.count + rate / 4
            }
            return picked
        }
        let scenarios: [(name: String, ids: [String], stallAfter: Double?)] = [
            ("short", ["commands-325"], nil),
            ("near-15s", fill(13.5, from: commands), nil),
            ("beyond-15s", fill(16, from: commands), nil),
            ("rollover-25s", fill(27, from: commands), nil),
            ("two-rollovers", fill(58, from: commands), nil),
            // A 6 s processing stall just before rollover grows the snapshot
            // to ~31 s (delayed-processing overshoot).
            ("overshoot-31s", fill(40, from: commands), 24.4),
            // Genuine repeated speech straddling both rollovers.
            ("repeated", Array(repeating: "commands-189", count: 12), nil),
        ]

        // Silence/noise and short valid utterances against the filter.
        var probes: [(String, [Float], String)] = [
            ("silence-1s", [Float](repeating: 0, count: rate), ""),
            ("silence-3s", [Float](repeating: 0, count: rate * 3), ""),
        ]
        for rms: Float in [0.002, 0.005, 0.01, 0.03] {
            for seconds in [1.0, 3.0] {
                probes.append(("noise-rms\(rms)-\(Int(seconds))s", noise(seconds: seconds, rms: rms, seed: 413), ""))
            }
        }
        for id in ["meeting-004", "meeting-005", "meeting-017", "meeting-018", "commands-325", "commands-519"] {
            probes.append((id, fixtures[id]!.samples, fixtures[id]!.reference))
        }

        let trace = ProcessInfo.processInfo.environment["RR413_TRACE"] == "1"
        for pass in 0..<Int(args[4])! {
            for (name, audio, reference) in probes {
                let (raw, ms) = try await transcribe(audio)
                let kept = TranscriptFilter.meaningfulText(raw)
                try emit([
                    "event": "probe", "model": args[1], "pass": pass, "id": name,
                    "raw": raw, "kept": kept as Any? ?? NSNull(), "wall_ms": ms,
                    "reference": reference,
                ])
            }

            for scenario in scenarios {
                let (samples, reference) = stream(scenario.ids)
                // Virtual clock in samples. Release happens 300 ms after the
                // last speech sample; snapshots follow inference completion
                // plus the 500 ms cadence, exactly as the polling loop does.
                let release = samples.count + rate * 3 / 10
                func available(_ end: Int) -> [Float] {
                    Array(samples[0..<min(end, samples.count)]) + [Float](repeating: 0, count: max(0, end - samples.count))
                }
                var accumulator = TranscriptAccumulator()
                var start = 0
                var clock = stepSamples
                var stalled = false
                var rollovers = 0
                var maxSnapshot = 0
                var refinementMs: [Double] = []
                var firstPartialMs: Double?
                var finalText = ""
                var finalMs = 0.0
                while true {
                    if clock >= release {
                        let audio = Array(available(release)[start...])
                        if audio.count >= minSamples {
                            let (raw, ms) = try await transcribe(audio)
                            finalMs = ms
                            if let text = TranscriptFilter.meaningfulText(raw) { accumulator.refine(text) }
                        }
                        finalText = accumulator.transcript
                        break
                    }
                    let audio = Array(available(clock)[start...])
                    var elapsed = 0.0
                    if audio.count >= minSamples {
                        maxSnapshot = max(maxSnapshot, audio.count)
                        let (raw, ms) = try await transcribe(audio)
                        elapsed = ms
                        refinementMs.append(ms)
                        if let text = TranscriptFilter.meaningfulText(raw) {
                            accumulator.refine(text)
                            if trace {
                                try emit(["event": "snapshot", "scenario": scenario.name, "start": start,
                                          "end": clock, "live": text, "transcript": accumulator.transcript])
                            }
                            if firstPartialMs == nil {
                                // Capture start → first partial: 500 ms media
                                // settle plus this snapshot's offset and inference.
                                firstPartialMs = 500 + Double(clock) / Double(rate) * 1000 + ms
                            }
                        }
                        if audio.count >= chunkSamples {
                            accumulator.commitLiveSegment()
                            start += audio.count - keepSamples
                            rollovers += 1
                        }
                    }
                    if let stallAfter = scenario.stallAfter, !stalled, Double(clock) / Double(rate) >= stallAfter {
                        stalled = true
                        elapsed += 6000
                    }
                    clock += Int(elapsed / 1000 * Double(rate)) + stepSamples
                }
                let hypothesis = words(finalText)
                let expected = words(reference)
                try emit([
                    "event": "dictation", "model": args[1], "pass": pass, "scenario": scenario.name,
                    "seconds": Double(samples.count) / Double(rate), "rollovers": rollovers,
                    "max_snapshot_seconds": Double(maxSnapshot) / Double(rate),
                    "reference_words": expected.count, "hypothesis_words": hypothesis.count,
                    "word_errors": distance(expected, hypothesis),
                    "address_count": hypothesis.filter { $0 == "address" }.count,
                    "refinement_ms_max": refinementMs.max() ?? 0,
                    "refinements": refinementMs.count,
                    "first_partial_ms": firstPartialMs as Any? ?? NSNull(),
                    "release_to_final_ms": finalMs,
                    "final": finalText, "ids": scenario.ids,
                ])
            }
        }
        await manager.cleanup()
    }
}
