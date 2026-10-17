import AVFoundation
import Foundation
import os

enum MeetingCompressedAudioError: LocalizedError, Equatable {
    case budgetExceeded(limitBytes: Int)
    case invalidAudio
    case recorderClosed
    case invalidManifest
    case missingSegment

    var errorDescription: String? {
        switch self {
        case .budgetExceeded(let limitBytes):
            return "Meeting recording reached its \(limitBytes)-byte local limit."
        case .invalidAudio:
            return "Meeting audio could not be recorded."
        case .recorderClosed:
            return "The meeting recorder is closed."
        case .invalidManifest:
            return "The meeting recording index is invalid."
        case .missingSegment:
            return "A meeting recording segment is unavailable."
        }
    }
}

/// One finalized, independently decodable AAC segment. The file name is opaque
/// and the segment never mixes sources or timing epochs.
struct MeetingCompressedAudioSegment: Codable, Equatable, Sendable {
    let sourceID: MeetingAudioSourceID
    let timingEpochID: String
    let startSample: Int
    let startMilliseconds: Int
    let sampleCount: Int
    let fileName: String
    let byteCount: Int

    private enum CodingKeys: String, CodingKey {
        case sourceID = "source_id"
        case timingEpochID = "timing_epoch_id"
        case startSample = "start_sample"
        case startMilliseconds = "start_ms"
        case sampleCount = "sample_count"
        case fileName = "file_name"
        case byteCount = "byte_count"
    }
}

private struct MeetingCompressedAudioManifest: Codable {
    var version = 1
    var sampleRate = MeetingCompressedAudioRecorder.sampleRate
    var segments: [MeetingCompressedAudioSegment] = []

    private enum CodingKeys: String, CodingKey {
        case version
        case sampleRate = "sample_rate"
        case segments
    }
}

/// Records accepted meeting audio as rolling AAC-LC `.m4a` segments, one track
/// per source. A plain `.m4a` is unreadable until finalized, so each segment is
/// closed on a new timing epoch, a discontinuity, `maxSegmentSamples`,
/// `finishAll()` and `close()`, and the manifest is rewritten atomically after
/// every close. A hard crash loses at most the open segment per source.
///
/// Audio and file contents are never logged; only counters and cause codes.
actor MeetingCompressedAudioRecorder {
    static let sampleRate = 16_000
    static let bitRate = 32_000
    static let manifestFilename = "manifest.json"
    static let segmentExtension = "m4a"
    static let maxSegmentSeconds = 30
    static let maxSegmentSamples = maxSegmentSeconds * sampleRate

    /// Nominal encoded size: 32 kbps = 4,000 bytes/s per source. Two sources for
    /// 4 hours is 2 * 4 * 3,600 * 4,000 = 115,200,000 bytes (about 110 MiB).
    /// 192 MiB (201,326,592 bytes) leaves roughly 75% headroom for container
    /// overhead and bitrate variance, i.e. about 7 hours of two-source audio.
    static let defaultBudgetBytes = 192 * 1_024 * 1_024
    static let nominalBytesPerSecond = bitRate / 8
    /// Conservative per-segment container cost (ftyp/moov/packet tables) used
    /// when projecting the size of a segment that is still open.
    static let segmentOverheadBytes = 4_096

    private static let logger = Logger(subsystem: "com.relayrunner.app", category: "notes")

    private struct OpenSegment {
        let url: URL
        var file: AVAudioFile?
        let fileName: String
        let timingEpochID: String
        let startSample: Int
        let startMilliseconds: Int
        var sampleCount = 0
    }

    private struct Slice {
        let startsNewSegment: Bool
        let range: Range<Int>
    }

    private let directory: URL
    private let budgetBytes: Int
    private let segmentSamples: Int
    private let fileManager: FileManager
    private let format: AVAudioFormat
    private var manifest: MeetingCompressedAudioManifest
    private var open: [MeetingAudioSourceID: OpenSegment] = [:]
    private var closedBytes: Int
    private var isClosed = false

    init(
        directory: URL,
        budgetBytes: Int = MeetingCompressedAudioRecorder.defaultBudgetBytes,
        segmentSamples: Int = MeetingCompressedAudioRecorder.maxSegmentSamples,
        fileManager: FileManager = .default
    ) throws {
        precondition(budgetBytes > 0 && segmentSamples > 0)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw MeetingCompressedAudioError.invalidAudio
        }
        self.directory = directory
        self.budgetBytes = budgetBytes
        self.segmentSamples = segmentSamples
        self.fileManager = fileManager
        self.format = format
        try Self.prepareDirectory(directory, fileManager: fileManager)
        let existing = try MeetingCompressedAudioRecording.loadManifest(
            in: directory,
            fileManager: fileManager
        )
        manifest = existing ?? MeetingCompressedAudioManifest()
        closedBytes = manifest.segments.reduce(0) { $0 + $1.byteCount }
    }

    /// Owner-only directory that macOS backups skip.
    static func prepareDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try excludeFromBackup(url)
    }

    static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func append(_ audio: MeetingAcceptedAudio) throws {
        guard !isClosed else { throw MeetingCompressedAudioError.recorderClosed }
        let descriptor = audio.descriptor
        guard descriptor.sampleRate == Self.sampleRate,
              descriptor.sampleCount == audio.samples.count else {
            Self.logger.error("meeting recorder rejected audio cause=invalid_descriptor")
            throw MeetingCompressedAudioError.invalidAudio
        }
        guard !audio.samples.isEmpty else { return }

        let slices = plan(audio)
        let projected = slices.reduce(0) { total, slice in
            total + Self.projectedBytes(samples: slice.range.count)
                + (slice.startsNewSegment ? Self.segmentOverheadBytes : 0)
        }
        guard openProjectedBytes() + closedBytes + projected <= budgetBytes else {
            Self.logger.error("meeting recorder budget reached cause=budget_exceeded")
            throw MeetingCompressedAudioError.budgetExceeded(limitBytes: budgetBytes)
        }

        for slice in slices {
            if slice.startsNewSegment {
                try closeSegment(for: descriptor.sourceID)
                try openSegment(
                    for: descriptor,
                    offset: slice.range.lowerBound
                )
            }
            try write(audio.samples[slice.range], source: descriptor.sourceID)
        }
    }

    /// Finalizes every open segment (pause or stop). The recorder stays usable.
    func finishAll() throws {
        var firstError: Error?
        for source in MeetingAudioSourceID.allCases {
            do { try closeSegment(for: source) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    func close() throws {
        guard !isClosed else { return }
        defer { isClosed = true }
        try finishAll()
    }

    var recordedSegments: [MeetingCompressedAudioSegment] { manifest.segments }

    // MARK: - Segmenting

    /// Splits a chunk at rotation boundaries so no segment exceeds
    /// `segmentSamples`, and starts a new one on a new epoch or a timeline gap.
    private func plan(_ audio: MeetingAcceptedAudio) -> [Slice] {
        let descriptor = audio.descriptor
        var slices: [Slice] = []
        var offset = 0
        let current = open[descriptor.sourceID]
        var currentCount = current?.sampleCount ?? 0
        var continues = current.map {
            $0.timingEpochID == descriptor.timingEpochID
                && $0.startSample + currentCount == descriptor.startSample
        } ?? false
        while offset < audio.samples.count {
            if !continues || currentCount >= segmentSamples {
                currentCount = 0
                slices.append(Slice(
                    startsNewSegment: true,
                    range: offset..<min(audio.samples.count, offset + segmentSamples)
                ))
            } else {
                slices.append(Slice(
                    startsNewSegment: false,
                    range: offset..<min(audio.samples.count, offset + segmentSamples - currentCount)
                ))
            }
            currentCount += slices[slices.count - 1].range.count
            offset = slices[slices.count - 1].range.upperBound
            continues = true
        }
        return slices
    }

    private func openSegment(for descriptor: MeetingAcceptedAudioDescriptor, offset: Int) throws {
        let fileName = UUID().uuidString.lowercased() + "." + Self.segmentExtension
        let url = directory.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.bitRate,
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try Self.excludeFromBackup(url)
        } catch {
            Self.logger.error("meeting recorder open failed cause=encoder_open")
            try? fileManager.removeItem(at: url)
            throw error
        }
        let startSample = descriptor.startSample + offset
        open[descriptor.sourceID] = OpenSegment(
            url: url,
            file: file,
            fileName: fileName,
            timingEpochID: descriptor.timingEpochID,
            startSample: startSample,
            startMilliseconds: descriptor.startMilliseconds
                + offset * 1_000 / Self.sampleRate
        )
    }

    private func write(_ samples: ArraySlice<Float>, source: MeetingAudioSourceID) throws {
        guard var segment = open[source],
              let file = segment.file,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            throw MeetingCompressedAudioError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }
        do {
            try file.write(from: buffer)
        } catch {
            Self.logger.error("meeting recorder write failed cause=encoder_write")
            throw error
        }
        segment.sampleCount += samples.count
        open[source] = segment
    }

    private func closeSegment(for source: MeetingAudioSourceID) throws {
        guard var segment = open.removeValue(forKey: source) else { return }
        // Releasing the last reference finalizes the container.
        segment.file = nil
        let url = segment.url
        let entry: MeetingCompressedAudioSegment
        do {
            let size = try (url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            entry = MeetingCompressedAudioSegment(
                sourceID: source,
                timingEpochID: segment.timingEpochID,
                startSample: segment.startSample,
                startMilliseconds: segment.startMilliseconds,
                sampleCount: segment.sampleCount,
                fileName: segment.fileName,
                byteCount: size
            )
        } catch {
            Self.logger.error("meeting recorder close failed cause=segment_size")
            throw error
        }
        guard segment.sampleCount > 0 else {
            try? fileManager.removeItem(at: url)
            return
        }
        manifest.segments.append(entry)
        closedBytes += entry.byteCount
        try writeManifest()
        Self.logger.info(
            "meeting recorder segment closed samples=\(entry.sampleCount) bytes=\(entry.byteCount)"
        )
    }

    private func writeManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let url = directory.appendingPathComponent(Self.manifestFilename)
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try Self.excludeFromBackup(url)
    }

    // MARK: - Budget

    private static func projectedBytes(samples: Int) -> Int {
        (samples * nominalBytesPerSecond + sampleRate - 1) / sampleRate
    }

    private func openProjectedBytes() -> Int {
        open.values.reduce(0) {
            $0 + Self.segmentOverheadBytes + Self.projectedBytes(samples: $1.sampleCount)
        }
    }
}

/// Read side of a session's recording: a snapshot of the manifest plus a lazy,
/// bounded-memory decoder per source.
struct MeetingCompressedAudioRecording: Sendable {
    let directory: URL
    let segments: [MeetingCompressedAudioSegment]
    /// `.m4a` files present on disk but absent from the manifest: segments that
    /// were still open (never finalized) when the process stopped.
    let lostSegmentCount: Int

    static func load(
        directory: URL,
        fileManager: FileManager = .default
    ) throws -> MeetingCompressedAudioRecording {
        let manifest = try loadManifest(in: directory, fileManager: fileManager)
        let known = Set((manifest?.segments ?? []).map(\.fileName))
        let onDisk = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let lost = onDisk.filter {
            $0.pathExtension == MeetingCompressedAudioRecorder.segmentExtension
                && !known.contains($0.lastPathComponent)
        }.count
        return MeetingCompressedAudioRecording(
            directory: directory,
            segments: manifest?.segments ?? [],
            lostSegmentCount: lost
        )
    }

    fileprivate static func loadManifest(
        in directory: URL,
        fileManager: FileManager
    ) throws -> MeetingCompressedAudioManifest? {
        let url = directory.appendingPathComponent(MeetingCompressedAudioRecorder.manifestFilename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let manifest = try? JSONDecoder().decode(
            MeetingCompressedAudioManifest.self,
            from: Data(contentsOf: url)
        ), manifest.version == 1, manifest.sampleRate == MeetingCompressedAudioRecorder.sampleRate else {
            throw MeetingCompressedAudioError.invalidManifest
        }
        return manifest
    }

    func sampleCount(for source: MeetingAudioSourceID) -> Int {
        segments.filter { $0.sourceID == source }.reduce(0) { $0 + $1.sampleCount }
    }

    /// Decodes one source in timeline order. No chunk exceeds
    /// `maximumChunkSamples`, and only one chunk is resident at a time.
    func chunks(
        for source: MeetingAudioSourceID,
        maximumChunkSamples: Int = 16_000 * 10
    ) -> Chunks {
        precondition(maximumChunkSamples > 0)
        return Chunks(
            directory: directory,
            segments: segments.filter { $0.sourceID == source }
                .enumerated()
                .sorted { ($0.element.startSample, $0.offset) < ($1.element.startSample, $1.offset) }
                .map(\.element),
            maximumChunkSamples: maximumChunkSamples
        )
    }

    struct Chunks: AsyncSequence {
        typealias Element = MeetingAcceptedAudio

        let directory: URL
        let segments: [MeetingCompressedAudioSegment]
        let maximumChunkSamples: Int

        func makeAsyncIterator() -> Iterator {
            Iterator(directory: directory, segments: segments, maximumChunkSamples: maximumChunkSamples)
        }

        struct Iterator: AsyncIteratorProtocol {
            let directory: URL
            let segments: [MeetingCompressedAudioSegment]
            let maximumChunkSamples: Int
            private var segmentIndex = 0
            private var offset = 0
            private var sequence = 0
            private var file: AVAudioFile?

            init(
                directory: URL,
                segments: [MeetingCompressedAudioSegment],
                maximumChunkSamples: Int
            ) {
                self.directory = directory
                self.segments = segments
                self.maximumChunkSamples = maximumChunkSamples
            }

            mutating func next() async throws -> MeetingAcceptedAudio? {
                while segmentIndex < segments.count {
                    let segment = segments[segmentIndex]
                    if offset >= segment.sampleCount {
                        segmentIndex += 1
                        offset = 0
                        file = nil
                        continue
                    }
                    let count = Swift.min(maximumChunkSamples, segment.sampleCount - offset)
                    let samples = try read(count, from: segment)
                    let rate = MeetingCompressedAudioRecorder.sampleRate
                    let startSample = segment.startSample + offset
                    let startMilliseconds = segment.startMilliseconds + offset * 1_000 / rate
                    let descriptor = MeetingAcceptedAudioDescriptor(
                        chunkID: "\(segment.timingEpochID)-R\(sequence)",
                        sourceID: segment.sourceID,
                        timingEpochID: segment.timingEpochID,
                        sequence: sequence,
                        startSample: startSample,
                        endSample: startSample + count,
                        startMilliseconds: startMilliseconds,
                        endMilliseconds: segment.startMilliseconds
                            + (offset + count) * 1_000 / rate,
                        sampleRate: rate,
                        sampleCount: count
                    )
                    offset += count
                    sequence += 1
                    return MeetingAcceptedAudio(descriptor: descriptor, samples: samples)
                }
                return nil
            }

            /// Returns exactly `count` samples: a decoder that ends early is
            /// zero-padded and one that over-delivers is ignored past the
            /// manifest's recorded count.
            private mutating func read(
                _ count: Int,
                from segment: MeetingCompressedAudioSegment
            ) throws -> [Float] {
                if file == nil {
                    let url = directory.appendingPathComponent(segment.fileName)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw MeetingCompressedAudioError.missingSegment
                    }
                    file = try AVAudioFile(
                        forReading: url,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                }
                var samples = [Float](repeating: 0, count: count)
                guard let file,
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: AVAudioFrameCount(count)
                      ) else {
                    throw MeetingCompressedAudioError.invalidAudio
                }
                var filled = 0
                while filled < count, file.framePosition < file.length {
                    buffer.frameLength = 0
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(count - filled))
                    let frames = Int(buffer.frameLength)
                    guard frames > 0, let channel = buffer.floatChannelData?[0] else { break }
                    samples.withUnsafeMutableBufferPointer { destination in
                        destination.baseAddress!.advanced(by: filled)
                            .update(from: channel, count: frames)
                    }
                    filled += frames
                }
                return samples
            }
        }
    }
}
