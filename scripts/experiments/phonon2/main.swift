import Foundation
import FluidAudio

// Offline, sample-array evaluator. Never opens capture, writes transcripts, or delivers commands.
struct Case: Decodable {
    let id: String
    let group: String
    let pcm: String
    let reference: String?
    let expectedSamples: Int
}
struct Input: Decodable {
    let cases: [Case]
    let revisions: [String: String]
}
func words(_ text: String) -> [String] {
    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}
func clean(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

@main struct Evaluation {
    static func main() async throws {
        #if !BASELINE
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        #endif
        let args = CommandLine.arguments
        guard args.count == 5 else { fatalError("usage: evaluator MODEL MODEL_DIRECTORY INPUT_JSON REPEATS") }
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        let version: AsrModelVersion
        switch args[1] {
        case "v2": version = .v2
        case "v3": version = .v3
        #if !BASELINE
        case "phonon2": version = .phonon2
        #endif
        default: fatalError("unsupported model")
        }
        let directory = URL(fileURLWithPath: args[2])
        let start = Date()
        #if BASELINE
        // Prepared by the pinned candidate loader first. No production cache is touched.
        let models = try await AsrModels.load(from: directory, version: version)
        #else
        ModelRegistry.revisionOverrides = input.revisions
        let models: AsrModels
        if ProcessInfo.processInfo.environment["RR411_OFFLINE"] == "1" {
            ModelHub.offlineMode = true
            models = try await AsrModels.load(from: directory, version: version)
        } else {
            models = try await AsrModels.downloadAndLoad(to: directory, version: version)
        }
        #endif
        #if !BASELINE
        if version == .v3 && ProcessInfo.processInfo.environment["RR411_OFFLINE"] != "1" {
            // v0.13.6 uses the legacy joint; fetch it with the SAME pinned loader.
            _ = try await ModelHub.loadModels(.parakeetV3, modelNames: ["JointDecision.mlmodelc"],
                directory: directory.deletingLastPathComponent(), computeUnits: .cpuAndNeuralEngine)
        }
        #endif
        let manager = AsrManager()
        try await manager.loadModels(models)
        try emit(["event": "prepared", "model": args[1], "seconds": Date().timeIntervalSince(start)])
        for iteration in 0..<Int(args[4])! {
            for item in input.cases where item.group != "multilingual" || args[1] == "v3" {
                let data = try Data(contentsOf: URL(fileURLWithPath: item.pcm))
                guard data.count == item.expectedSamples * 4 else { fatalError("sample count mismatch") }
                let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let begun = Date()
                do {
                    #if BASELINE
                    let result = try await manager.transcribe(samples, source: .microphone)
                    #else
                    // Fresh state per independent snapshot matches the old source-scoped reset.
                    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                    let result = try await manager.transcribe(samples, decoderState: &state)
                    #endif
                    let elapsed = Date().timeIntervalSince(begun)
                    let tokens = result.tokenTimings ?? []
                    var assembled: [String] = []
                    for token in tokens {
                        if assembled.isEmpty || token.token.first?.isWhitespace == true || assembled.last?.last?.isWhitespace == true {
                            assembled.append(token.token)
                        } else { assembled[assembled.count - 1] += token.token }
                    }
                    var row: [String: Any] = [
                        "event": "inference", "id": item.id, "group": item.group, "iteration": iteration,
                        "model": args[1], "samples": samples.count, "duration": result.duration,
                        "wall_ms": elapsed * 1000, "model_ms": result.processingTime * 1000,
                        "token_count": tokens.count, "timings_present": result.tokenTimings != nil,
                        "leading_space_tokens": tokens.filter { $0.token.first?.isWhitespace == true }.count,
                        "punctuation_tokens": tokens.filter { $0.token.rangeOfCharacter(from: .punctuationCharacters) != nil }.count,
                        "assembly_matches": words(assembled.joined(separator: " ")) == words(result.text),
                        "assembly_text_matches": clean(assembled.joined(separator: " ")) == clean(result.text),
                        "invalid_timings": tokens.filter { !$0.startTime.isFinite || !$0.endTime.isFinite || $0.startTime < 0 || $0.endTime < $0.startTime || $0.endTime > Double(samples.count) / 16000 + 0.1 }.count,
                        "confidence_count": tokens.count,
                        "confidence_min": tokens.map(\.confidence).min().map { $0 as Any } ?? NSNull(),
                        "confidence_max": tokens.map(\.confidence).max().map { $0 as Any } ?? NSNull(),
                        "last_token_end": tokens.last?.endTime as Any? ?? NSNull()
                    ]
                    if let reference = item.reference {
                        row["reference_words"] = words(reference).count
                        row["word_errors"] = distance(words(reference), words(result.text))
                        row["exact_normalized"] = words(reference) == words(result.text)
                    }
                    try emit(row)
                } catch {
                    // The deliberately sub-minimum raw case may reject; other errors fail the run.
                    guard item.id == "boundary-raw-0.1" else { throw error }
                    try emit(["event": "rejected_short", "id": item.id, "iteration": iteration, "model": args[1]])
                }
            }
        }
        await manager.cleanup()
    }
}
