import Darwin
import FluidAudio
import Foundation

// RR-416 real-time two-source note soak. Feeds public RR-411 fixtures, with
// low-level noise gaps, to the production MeetingTranscriptProducer (copied in
// at build time) on a 100 ms wall-clock cadence per source:
//   - a live producer runs the real model on every window as it closes, which
//     measures final-window lag, queue depth and memory under real-time load;
//   - a record-only producer (the shipping note path) hands accepted audio to a
//     disk spool, then MeetingRecordingTranscriber transcribes it after Stop.
// Never opens capture, writes the voice FIFO, or saves transcript text.

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
let tickSamples = 1_600                     // ~100 ms per source, as the note session batches
let sources: [MeetingAudioSourceID] = [.microphone, .systemAudio]

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func words(_ text: String) -> [String] {
    text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
}

/// Word edit operations (substitutions, deletions, insertions).
func edits(_ reference: [String], _ hypothesis: [String]) -> (s: Int, d: Int, i: Int) {
    let n = reference.count, m = hypothesis.count
    var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { cost[i][0] = i }
    for j in 0...m { cost[0][j] = j }
    if n > 0 && m > 0 {
        for i in 1...n {
            for j in 1...m {
                cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1,
                                 cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1))
            }
        }
    }
    var i = n, j = m, s = 0, d = 0, ins = 0
    while i > 0 || j > 0 {
        if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (reference[i - 1] == hypothesis[j - 1] ? 0 : 1) {
            if reference[i - 1] != hypothesis[j - 1] { s += 1 }
            i -= 1; j -= 1
        } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
            d += 1; i -= 1
        } else {
            ins += 1; j -= 1
        }
    }
    return (s, d, ins)
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let rank = max(1, Int((p * Double(sorted.count)).rounded(.up)))
    return sorted[rank - 1]
}

/// Collects producer events from any thread.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var finals: [(revision: MeetingTranscriptSegmentRevision, at: UInt64)] = []
    private(set) var partialCount = 0
    private(set) var issues: [String] = []

    func record(_ event: MeetingProducerEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .revision(let revision):
            if revision.isFinal { finals.append((revision, now())) } else { partialCount += 1 }
        case .issue(let issue):
            issues.append(issue.code.rawValue)
        default:
            break
        }
    }

    func snapshot() -> (finals: [(revision: MeetingTranscriptSegmentRevision, at: UInt64)], partials: Int, issues: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (finals, partialCount, issues)
    }
}

/// Disk spool standing in for the compressed note recorder, so accepted audio
/// is not held in memory.
final class Spool: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [MeetingAudioSourceID: FileHandle] = [:]
    let urls: [MeetingAudioSourceID: URL]
    private(set) var descriptors: [MeetingAudioSourceID: [MeetingAcceptedAudioDescriptor]] = [:]

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [MeetingAudioSourceID: URL] = [:]
        for source in sources {
            let url = directory.appendingPathComponent("\(source.rawValue).f32")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            urls[source] = url
            handles[source] = try FileHandle(forWritingTo: url)
        }
        self.urls = urls
    }

    func append(_ audio: MeetingAcceptedAudio) throws {
        lock.lock(); defer { lock.unlock() }
        let source = audio.descriptor.sourceID
        try audio.samples.withUnsafeBufferPointer { try handles[source]!.write(contentsOf: Data(buffer: $0)) }
        descriptors[source, default: []].append(audio.descriptor)
    }

    func close() throws {
        lock.lock(); defer { lock.unlock() }
        for handle in handles.values { try handle.close() }
    }
}

struct SpoolRecording: MeetingRecordedAudioReading {
    let timingEpochs: [MeetingTimingEpoch]
    let urls: [MeetingAudioSourceID: URL]
    let descriptors: [MeetingAudioSourceID: [MeetingAcceptedAudioDescriptor]]

    var totalMilliseconds: Int {
        descriptors.values.joined().reduce(0) { $0 + $1.sampleCount * 1_000 / $1.sampleRate }
    }

    func chunks(for source: MeetingAudioSourceID) -> AsyncThrowingStream<MeetingAcceptedAudio, Error> {
        let url = urls[source]!
        let list = descriptors[source] ?? []
        return AsyncThrowingStream { continuation in
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                for descriptor in list {
                    let data = try handle.read(upToCount: descriptor.sampleCount * 4) ?? Data()
                    guard data.count == descriptor.sampleCount * 4 else { throw CocoaError(.fileReadCorruptFile) }
                    let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                    continuation.yield(MeetingAcceptedAudio(descriptor: descriptor, samples: samples))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Speech clips laid on each source's timeline with noise gaps between them.
struct Schedule {
    struct Placement { let start: Int; let id: String }
    let placements: [Placement]
    let totalSamples: Int

    init(ids: [String], lengths: [String: Int], totalSamples: Int, seed: UInt64) {
        var state = seed
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        var placements: [Placement] = []
        var cursor = Int(uniform() * 2 * Double(rate))
        var index = 0
        while true {
            let id = ids[index % ids.count]
            guard cursor + lengths[id]! <= totalSamples else { break }
            placements.append(Placement(start: cursor, id: id))
            cursor += lengths[id]! + Int((0.3 + uniform() * 2.2) * Double(rate))
            index += 1
        }
        self.placements = placements
        self.totalSamples = totalSamples
    }
}

@main struct NoteSoak {
    static func main() async throws {
        AppLogger.minimumLevel = .error
        AppLogger.mirrorsToConsole = false
        let args = CommandLine.arguments
        if args.count == 8, args[1] == "probe" {
            // probe MODEL_NAME MODEL_DIRECTORY INPUT_JSON SOURCE_F32 START_MS END_MS: one
            // window through the production transcriber, with token timings.
            let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
            ModelRegistry.revisionOverrides = input.revisions
            ModelHub.offlineMode = true
            let data = try Data(contentsOf: URL(fileURLWithPath: args[5]))
            let all = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let start = Int(args[6])! * 16, end = Int(args[7])! * 16
            let directory = URL(fileURLWithPath: args[3])
            let transcriber = FluidAudioMeetingTranscriber(modelName: args[2]) { model, _ in
                let models = try await AsrModels.load(from: directory, version: model.asrVersion)
                let manager = AsrManager()
                try await manager.loadModels(models)
                return manager
            }
            try await transcriber.prepare { _ in }
            let result = try await transcriber.transcribe(MeetingTranscriptionRequest(
                segmentID: "probe", sourceID: .microphone, timingEpochID: "probe", windowSequence: 0, revision: 1,
                contextStartMilliseconds: Int(args[6])!, ownedStartMilliseconds: Int(args[6])!,
                ownedEndMilliseconds: Int(args[7])!, ownedEndSample: end, isFinal: true,
                samples: Array(all[start..<end])))
            print("TEXT", result.text)
            for token in result.tokens { print(String(format: "%.2f-%.2f", token.startSeconds, token.endSeconds), token.text) }
            return
        }
        guard args.count == 6 || args.count == 8 else {
            fatalError("usage: notesoak MODEL_NAME MODEL_DIRECTORY INPUT_JSON MINUTES SPOOL_DIRECTORY [BASELINE_NAME BASELINE_DIRECTORY]")
        }
        let modelName = args[1]
        let modelDirectory = URL(fileURLWithPath: args[2])
        let minutes = Double(args[4])!
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
        ModelRegistry.revisionOverrides = input.revisions
        ModelHub.offlineMode = true

        var clips: [String: (samples: [Float], reference: String)] = [:]
        for item in input.cases where item.id.hasPrefix("meeting-")
            || (item.id.hasPrefix("commands-") && !item.id.hasSuffix("noise20db")) {
            let data = try Data(contentsOf: URL(fileURLWithPath: item.pcm))
            guard data.count == item.expectedSamples * 4 else { fatalError("sample count mismatch") }
            clips[item.id] = (data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, item.reference ?? "")
        }
        // Alternate meeting and command clips; the system source starts halfway
        // through the list so the two streams carry different speech.
        let meetings = clips.keys.filter { $0.hasPrefix("meeting-") }.sorted()
        let commands = clips.keys.filter { $0.hasPrefix("commands-") }.sorted()
        var order: [String] = []
        for index in 0..<max(meetings.count, commands.count) {
            if index < meetings.count { order.append(meetings[index]) }
            if index < commands.count { order.append(commands[index]) }
        }
        let rotated = Array(order[(order.count / 2)...]) + Array(order[..<(order.count / 2)])
        let totalSamples = Int(minutes * 60) * rate
        let lengths = clips.mapValues(\.samples.count)
        let schedules: [MeetingAudioSourceID: Schedule] = [
            .microphone: Schedule(ids: order, lengths: lengths, totalSamples: totalSamples, seed: 416),
            .systemAudio: Schedule(ids: rotated, lengths: lengths, totalSamples: totalSamples, seed: 4160),
        ]
        // A fixed ~-60 dBFS noise floor between clips, like an open microphone.
        var noiseState: UInt64 = 416
        let noiseFloor: [Float] = (0..<rate).map { _ in
            noiseState = noiseState &* 6364136223846793005 &+ 1442695040888963407
            return (Float(noiseState >> 40) / Float(1 << 24) - 0.5) * 0.002
        }
        func chunk(_ source: MeetingAudioSourceID, from start: Int) -> [Float] {
            var samples = (start..<(start + tickSamples)).map { noiseFloor[$0 % rate] }
            for placement in schedules[source]!.placements {
                let clip = clips[placement.id]!.samples
                let lower = max(start, placement.start), upper = min(start + tickSamples, placement.start + clip.count)
                guard lower < upper else { continue }
                for sample in lower..<upper { samples[sample - start] = clip[sample - placement.start] }
            }
            return samples
        }

        func loader(_ directory: URL) -> FluidAudioMeetingTranscriber.ManagerLoader {
            { model, _ in
                let models = try await AsrModels.load(from: directory, version: model.asrVersion)
                let manager = AsrManager()
                try await manager.loadModels(models)
                return manager
            }
        }

        let liveLog = EventLog()
        let recordLog = EventLog()
        let spool = try Spool(directory: URL(fileURLWithPath: args[5]))
        let live = MeetingTranscriptProducer(
            sessionID: "rr416-soak-live",
            transcriber: FluidAudioMeetingTranscriber(modelName: modelName, loadManager: loader(modelDirectory)),
            eventSink: { liveLog.record($0) }
        )
        let record = MeetingTranscriptProducer(
            sessionID: "rr416-soak-record",
            transcriber: FluidAudioMeetingTranscriber(modelName: modelName, loadManager: loader(modelDirectory)),
            transcribesLive: false,
            acceptedAudioSink: { try spool.append($0) },
            eventSink: { recordLog.record($0) }
        )

        let memoryBefore = footprintMB()
        let prepareStarted = now()
        // Live start prepares the model before the clock starts.
        try await live.start()
        let prepareMs = Double(now() - prepareStarted) / 1e6
        let memoryLoaded = footprintMB()
        emit(["event": "start", "model": modelName, "minutes": minutes, "prepare_ms": prepareMs,
              "footprint_mb_before": memoryBefore, "footprint_mb_loaded": memoryLoaded,
              "clips_per_source": sources.map { schedules[$0]!.placements.count }])

        let clock = ContinuousClock()
        let ticks = totalSamples / tickSamples
        let origin = now()
        let started = clock.now
        try await record.start(timelineOriginNanoseconds: origin)
        var lateness: [Double] = []
        var ingestMs: [Double] = []
        var samples: [[String: Any]] = []
        for tick in 0..<ticks {
            // Audio for this tick exists only once its 100 ms has elapsed.
            let deadline = started + .milliseconds(100 * (tick + 1))
            try await clock.sleep(until: deadline)
            let late = clock.now - deadline
            lateness.append(Double(late.components.attoseconds) / 1e15 + Double(late.components.seconds) * 1000)
            for source in sources {
                let audio = chunk(source, from: tick * tickSamples)
                let pts = origin + UInt64(tick * tickSamples) * 62_500
                let before = now()
                try await live.ingest(audio, from: source, presentationTimeNanoseconds: pts)
                try await record.ingest(audio, from: source, presentationTimeNanoseconds: pts)
                ingestMs.append(Double(now() - before) / 1e6)
            }
            if tick % 300 == 299 {
                let metrics = await live.currentMetrics()
                let sample: [String: Any] = [
                    "event": "sample", "elapsed_s": (tick + 1) / 10, "footprint_mb": footprintMB(),
                    "queued": metrics.queuedWindowCount, "max_queued": metrics.maximumQueuedWindowCount,
                    "processed": metrics.processedWindowCount, "dropped_samples": metrics.droppedAudioSampleCount,
                    "skipped_partials": metrics.skippedPartialRevisionCount,
                    "latest_processing_ms": metrics.latestProcessingMilliseconds,
                    "live_buffered_samples": await live.bufferedSampleCount(),
                    "record_buffered_samples": await record.bufferedSampleCount(),
                ]
                samples.append(sample)
                emit(sample)
            }
        }
        let stopAt = now()
        let liveBoundary = try await live.stop()
        await live.waitUntilIdle()
        let recordBoundary = try await record.stop()
        try spool.close()
        let liveStopDrainMs = Double(now() - stopAt) / 1e6

        // Post-Stop batch: the shipping note path.
        let recording = SpoolRecording(timingEpochs: recordBoundary.timingEpochs, urls: spool.urls,
                                       descriptors: spool.descriptors)
        let batchLog = EventLog()
        let batchStarted = now()
        var batchPeakMB = footprintMB()
        let peakTask = Task {
            var peak = 0.0
            while !Task.isCancelled {
                peak = max(peak, footprintMB())
                try? await Task.sleep(for: .seconds(1))
            }
            return peak
        }
        let batchBoundary = try await MeetingRecordingTranscriber(
            transcriber: FluidAudioMeetingTranscriber(modelName: modelName, loadManager: loader(modelDirectory))
        ).transcribe(recording, sessionID: "rr416-soak-record") { event in
            if case .revision(let revision) = event { batchLog.record(.revision(revision)) }
        }
        let batchMs = Double(now() - batchStarted) / 1e6
        peakTask.cancel()
        batchPeakMB = max(batchPeakMB, await peakTask.value)

        func score(_ log: EventLog, boundary: MeetingProducerFinalBoundary, measureLag: Bool) -> [String: Any] {
            let snapshot = log.snapshot()
            var result: [String: Any] = [
                "final_events": snapshot.finals.count,
                "boundary_segments": boundary.finalSegmentRevisionByID.count,
                "issues": snapshot.issues,
                "dropped_audio_samples": boundary.metrics.droppedAudioSampleCount,
                "dropped_audio_frames": boundary.metrics.droppedAudioFrameCount,
                "max_queued_windows": boundary.metrics.maximumQueuedWindowCount,
                "transcription_failures": boundary.metrics.transcriptionFailureCount,
                "max_processing_ms": boundary.metrics.maximumProcessingMilliseconds,
            ]
            var lags: [Double] = []
            var perSource: [String: Any] = [:]
            for source in sources {
                let finals = snapshot.finals.filter { $0.revision.sourceID == source }
                    .sorted { $0.revision.startMilliseconds < $1.revision.startMilliseconds }
                let duplicateIDs = finals.count - Set(finals.map(\.revision.segmentID)).count
                // Owned ranges tile the timeline. A window that heard nothing
                // emits no segment, so only a gap overlapping speech counts.
                let speech = schedules[source]!.placements.map {
                    ($0.start * 1_000 / rate, ($0.start + clips[$0.id]!.samples.count) * 1_000 / rate)
                }
                var overlaps = 0
                var speechGaps = 0
                var silentWindowGaps = 0
                var cursor = 0
                for end in finals.map({ ($0.revision.startMilliseconds, $0.revision.endMilliseconds) })
                    + [(totalSamples * 1_000 / rate, totalSamples * 1_000 / rate)] {
                    if end.0 < cursor { overlaps += 1 }
                    if end.0 > cursor {
                        if speech.contains(where: { $0.0 < end.0 && $0.1 > cursor }) { speechGaps += 1 } else { silentWindowGaps += 1 }
                    }
                    cursor = max(cursor, end.1)
                }
                let hypothesis = finals.map(\.revision.text).joined(separator: " ")
                let reference = schedules[source]!.placements.map { clips[$0.id]!.reference }.joined(separator: " ")
                let (s, d, i) = edits(words(reference), words(hypothesis))
                let referenceWords = words(reference).count
                perSource[source.rawValue] = [
                    "segments": finals.count, "duplicate_segment_ids": duplicateIDs, "overlapping_segments": overlaps,
                    "speech_gaps": speechGaps, "silent_window_gaps": silentWindowGaps,
                    "reference_words": referenceWords, "substitutions": s, "deletions": d, "insertions": i,
                    "wer": Double(s + d + i) / Double(max(1, referenceWords)),
                ]
                if measureLag {
                    // Lag from when the window's last audio (owned end + 1 s overlap)
                    // existed to the final revision. The stop-flushed tail is excluded.
                    for final in finals where final.at < stopAt {
                        let closed = origin + UInt64(final.revision.endMilliseconds + 1_000) * 1_000_000
                        lags.append(Double(Int64(final.at) - Int64(closed)) / 1e6)
                    }
                }
            }
            result["sources"] = perSource
            if measureLag {
                result["final_lag_ms"] = ["count": lags.count, "p50": percentile(lags, 0.5),
                                          "p95": percentile(lags, 0.95), "max": lags.max() ?? 0]
                result["partials"] = snapshot.partials
            }
            return result
        }

        let liveScore = score(liveLog, boundary: liveBoundary, measureLag: true)
        let batchScore = score(batchLog, boundary: batchBoundary, measureLag: false)
        // Live and post-Stop finals share window IDs; compare their text.
        func key(_ revision: MeetingTranscriptSegmentRevision) -> String {
            "\(revision.sourceID.rawValue)-\(revision.startMilliseconds)"
        }
        let liveText = Dictionary(liveLog.snapshot().finals.map { (key($0.revision), $0.revision.text) },
                                  uniquingKeysWith: { a, _ in a })
        let batchFinals = batchLog.snapshot().finals
        let identical = batchFinals.filter { liveText[key($0.revision)] == $0.revision.text }.count
        if let dump = ProcessInfo.processInfo.environment["NOTESOAK_SEGMENTS"] {
            // Optional per-window diagnostic; stays under the caller's path, outside Git.
            var lines: [String] = []
            for (path, log) in [("live", liveLog), ("post_stop", batchLog)] {
                for final in log.snapshot().finals {
                    let data = try JSONSerialization.data(withJSONObject: [
                        "path": path, "key": key(final.revision), "text": final.revision.text,
                        "end_ms": final.revision.endMilliseconds,
                    ], options: [.sortedKeys])
                    lines.append(String(decoding: data, as: UTF8.self))
                }
            }
            try lines.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
        }

        // The same recording through the baseline model's post-Stop path.
        var baseline: [String: Any] = [:]
        if args.count == 8 {
            let baselineLog = EventLog()
            let baselineStarted = now()
            let baselineBoundary = try await MeetingRecordingTranscriber(
                transcriber: FluidAudioMeetingTranscriber(
                    modelName: args[6], loadManager: loader(URL(fileURLWithPath: args[7])))
            ).transcribe(recording, sessionID: "rr416-soak-record") { event in
                if case .revision(let revision) = event { baselineLog.record(.revision(revision)) }
            }
            baseline = score(baselineLog, boundary: baselineBoundary, measureLag: false)
            baseline["model"] = args[6]
            baseline["wall_ms"] = Double(now() - baselineStarted) / 1e6
        }
        let footprints = samples.compactMap { $0["footprint_mb"] as? Double }
        let half = footprints.count / 2
        emit([
            "event": "summary", "model": modelName, "minutes": minutes, "prepare_ms": prepareMs,
            "tick_lateness_ms": ["p95": percentile(lateness, 0.95), "max": lateness.max() ?? 0],
            "ingest_ms": ["p99": percentile(ingestMs, 0.99), "max": ingestMs.max() ?? 0],
            "live_stop_drain_ms": liveStopDrainMs,
            "footprint_mb": [
                "before_load": memoryBefore, "loaded": memoryLoaded,
                "first_half_max": footprints.prefix(half).max() ?? 0,
                "second_half_max": footprints.suffix(from: half).max() ?? 0,
                "end": footprints.last ?? 0, "batch_peak": batchPeakMB,
            ],
            "record_only": [
                "dropped_audio_samples": recordBoundary.metrics.droppedAudioSampleCount,
                "accepted_chunks": recordBoundary.metrics.acceptedChunkCount,
                "accepted_samples": sources.map { recordBoundary.metrics.acceptedSamplesBySource[$0] ?? 0 },
                "max_buffered_samples": samples.compactMap { $0["record_buffered_samples"] as? Int }.max() ?? 0,
            ],
            "live": liveScore,
            "post_stop_baseline": baseline,
            "post_stop": batchScore.merging([
                "wall_ms": batchMs,
                "real_time_factor": batchMs / (minutes * 60_000 * Double(sources.count)),
                "segments_identical_to_live": identical,
            ]) { a, _ in a },
        ])
    }
}
