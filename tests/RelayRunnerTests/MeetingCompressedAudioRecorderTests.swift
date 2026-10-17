import Foundation
import XCTest
@testable import relay_runner

final class MeetingCompressedAudioRecorderTests: XCTestCase {
    private let rate = MeetingCompressedAudioRecorder.sampleRate
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rr-404-\(UUID().uuidString)", isDirectory: true)
        roots.append(root)
        return root
    }

    /// Speech-band tone sweep (300 Hz to 3.4 kHz over `period` seconds), with a
    /// per-source offset so the two sources are distinguishable. Synthetic only.
    private func sweep(_ source: MeetingAudioSourceID, sample: Int) -> Float {
        let period = 20.0
        let t = Double(sample) / Double(rate)
        let phase = 2 * Double.pi * (300 * t + 0.5 * (3_100 / period) * t * t)
        let shift = source == .microphone ? 0.0 : 1.3
        return Float(0.4 * sin(phase + shift))
    }

    private func chunks(
        _ source: MeetingAudioSourceID,
        epoch: String,
        startSample: Int,
        totalSamples: Int,
        chunkSamples: Int
    ) -> [MeetingAcceptedAudio] {
        var result: [MeetingAcceptedAudio] = []
        var offset = 0
        var sequence = 0
        while offset < totalSamples {
            let count = min(chunkSamples, totalSamples - offset)
            let start = startSample + offset
            let samples = (0..<count).map { sweep(source, sample: start + $0) }
            result.append(MeetingAcceptedAudio(
                descriptor: MeetingAcceptedAudioDescriptor(
                    chunkID: "\(epoch)-A\(sequence)",
                    sourceID: source,
                    timingEpochID: epoch,
                    sequence: sequence,
                    startSample: start,
                    endSample: start + count,
                    startMilliseconds: start * 1_000 / rate,
                    endMilliseconds: (start + count) * 1_000 / rate,
                    sampleRate: rate,
                    sampleCount: count
                ),
                samples: samples
            ))
            offset += count
            sequence += 1
        }
        return result
    }

    private func collect(
        _ recording: MeetingCompressedAudioRecording,
        _ source: MeetingAudioSourceID,
        maximum: Int
    ) async throws -> [MeetingAcceptedAudio] {
        var result: [MeetingAcceptedAudio] = []
        for try await chunk in recording.chunks(for: source, maximumChunkSamples: maximum) {
            result.append(chunk)
        }
        return result
    }

    private func directoryBytes(_ directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    func testRoundTripAcrossEpochsGapsAndRotations() async throws {
        let directory = makeRoot()
        let recorder = try MeetingCompressedAudioRecorder(directory: directory)

        // Three epochs per source with a pause gap before the second and a
        // plain epoch change before the third. 70 s and 40 s and 35 s each
        // rotate at the 30 s cap, giving 3 + 2 + 2 segments per source.
        let plan: [(epoch: Int, start: Int, seconds: Int)] = [
            (0, 0, 70), (1, 80 * rate, 40), (2, 130 * rate, 35),
        ]
        var input: [MeetingAudioSourceID: [MeetingAcceptedAudio]] = [:]
        for entry in plan {
            var perSource: [[MeetingAcceptedAudio]] = []
            for source in MeetingAudioSourceID.allCases {
                let list = chunks(
                    source,
                    epoch: "S-\(source.rawValue)-E\(entry.epoch)",
                    startSample: entry.start,
                    totalSamples: entry.seconds * rate,
                    chunkSamples: 7_000
                )
                input[source, default: []] += list
                perSource.append(list)
            }
            for index in 0..<perSource[0].count {
                for list in perSource { try await recorder.append(list[index]) }
            }
            if entry.epoch == 0 { try await recorder.finishAll() }
        }
        try await recorder.close()

        let recording = try MeetingCompressedAudioRecording.load(directory: directory)
        XCTAssertEqual(recording.lostSegmentCount, 0)
        XCTAssertEqual(recording.segments.count, 14)
        XCTAssertEqual(Set(recording.segments.map(\.timingEpochID)).count, 6)

        let maximumChunk = 5_000
        for source in MeetingAudioSourceID.allCases {
            let original = input[source] ?? []
            let decoded = try await collect(recording, source, maximum: maximumChunk)
            XCTAssertLessThanOrEqual(decoded.map(\.samples.count).max() ?? 0, maximumChunk)
            XCTAssertEqual(
                decoded.reduce(0) { $0 + $1.samples.count },
                original.reduce(0) { $0 + $1.samples.count }
            )
            XCTAssertEqual(recording.sampleCount(for: source), decoded.reduce(0) { $0 + $1.samples.count })

            // Every decoded chunk starts where the original timeline had that sample.
            for chunk in decoded {
                XCTAssertEqual(chunk.descriptor.sampleCount, chunk.samples.count)
                let origin = try XCTUnwrap(original.first {
                    $0.descriptor.startSample <= chunk.descriptor.startSample
                        && chunk.descriptor.startSample < $0.descriptor.endSample
                })
                XCTAssertEqual(chunk.descriptor.timingEpochID, origin.descriptor.timingEpochID)
                let expected = origin.descriptor.startMilliseconds
                    + (chunk.descriptor.startSample - origin.descriptor.startSample) * 1_000 / rate
                XCTAssertLessThanOrEqual(abs(chunk.descriptor.startMilliseconds - expected), 50)
            }

            // Signal fidelity on the covered timeline: AAC at 32 kbps must stay
            // above 0.95 normalized correlation and below 30% relative RMS error.
            var dot = 0.0, inputEnergy = 0.0, decodedEnergy = 0.0, errorEnergy = 0.0
            for chunk in decoded {
                for (index, value) in chunk.samples.enumerated() {
                    let reference = Double(sweep(source, sample: chunk.descriptor.startSample + index))
                    let sample = Double(value)
                    dot += reference * sample
                    inputEnergy += reference * reference
                    decodedEnergy += sample * sample
                    errorEnergy += (reference - sample) * (reference - sample)
                }
            }
            XCTAssertGreaterThan(decodedEnergy, 0)
            XCTAssertGreaterThan(dot / (inputEnergy * decodedEnergy).squareRoot(), 0.95, "\(source)")
            XCTAssertLessThan((errorEnergy / inputEnergy).squareRoot(), 0.30, "\(source)")
        }
    }

    func testAbruptTerminationReportsOpenSegmentAndDecodesClosedOnes() async throws {
        let directory = makeRoot()
        let recorder = try MeetingCompressedAudioRecorder(directory: directory)
        for chunk in chunks(
            .microphone, epoch: "S-mic-E0", startSample: 0,
            totalSamples: 70 * rate, chunkSamples: 8_000
        ) {
            try await recorder.append(chunk)
        }

        // The recorder is still alive with its third segment open: this is
        // what a hard crash leaves behind.
        let recording = try MeetingCompressedAudioRecording.load(directory: directory)
        XCTAssertEqual(recording.segments.count, 2)
        XCTAssertEqual(recording.lostSegmentCount, 1)
        let decoded = try await collect(recording, .microphone, maximum: 16_000)
        XCTAssertEqual(decoded.reduce(0) { $0 + $1.samples.count }, 60 * rate)
        XCTAssertTrue(decoded.contains { $0.samples.contains { $0 != 0 } })
        try await recorder.close()
    }

    func testDecoderLengthDifferencesArePaddedAndTrimmedToManifestCount() async throws {
        let directory = makeRoot()
        let recorder = try MeetingCompressedAudioRecorder(directory: directory)
        for chunk in chunks(
            .microphone, epoch: "S-mic-E0", startSample: 0,
            totalSamples: rate, chunkSamples: 4_000
        ) {
            try await recorder.append(chunk)
        }
        try await recorder.close()
        let recorded = try MeetingCompressedAudioRecording.load(directory: directory)
        let segment = try XCTUnwrap(recorded.segments.first)

        for delta in [-37, 37] {
            let adjusted = MeetingCompressedAudioSegment(
                sourceID: segment.sourceID,
                timingEpochID: segment.timingEpochID,
                startSample: segment.startSample,
                startMilliseconds: segment.startMilliseconds,
                sampleCount: segment.sampleCount + delta,
                fileName: segment.fileName,
                byteCount: segment.byteCount
            )
            let recording = MeetingCompressedAudioRecording(
                directory: directory, segments: [adjusted], lostSegmentCount: 0
            )
            let decoded = try await collect(recording, .microphone, maximum: 3_000)
            XCTAssertEqual(decoded.reduce(0) { $0 + $1.samples.count }, adjusted.sampleCount)
            XCTAssertLessThanOrEqual(decoded.map(\.samples.count).max() ?? 0, 3_000)
        }
    }

    func testRecordingLivesInSessionRecoveryDirectoryWithPrivatePermissions() async throws {
        let root = makeRoot()
        let store = MeetingNoteRecoveryStore(root: root)
        let directory = try await store.recordingDirectory(sessionID: "note-1")
        XCTAssertEqual(directory.lastPathComponent, "recording")
        XCTAssertTrue(directory.deletingLastPathComponent().lastPathComponent.hasPrefix("session-"))
        XCTAssertEqual(
            directory.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
            root.standardizedFileURL
        )

        let recorder = try MeetingCompressedAudioRecorder(directory: directory)
        for source in MeetingAudioSourceID.allCases {
            for chunk in chunks(
                source, epoch: "note-1-\(source.rawValue)-E0", startSample: 0,
                totalSamples: rate, chunkSamples: 8_000
            ) {
                try await recorder.append(chunk)
            }
        }
        try await recorder.close()

        let manifest = directory.appendingPathComponent(MeetingCompressedAudioRecorder.manifestFilename)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.contains { $0.lastPathComponent == manifest.lastPathComponent })
        for file in files {
            XCTAssertEqual(try permissions(file), 0o600, file.lastPathComponent)
            XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            XCTAssertFalse(file.lastPathComponent.contains("microphone"))
            XCTAssertFalse(file.lastPathComponent.contains("note-1"))
        }
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(directory.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        try await store.removeSession(sessionID: "note-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
    }

    func testRemoveRecordingLeavesTheRestOfTheSession() async throws {
        let store = MeetingNoteRecoveryStore(root: makeRoot())
        let directory = try await store.recordingDirectory(sessionID: "note-2")
        try await store.removeRecording(sessionID: "note-2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
    }

    func testBudgetErrorIsTypedAndStopsWriting() async throws {
        let directory = makeRoot()
        let budget = 40_000
        let recorder = try MeetingCompressedAudioRecorder(directory: directory, budgetBytes: budget)
        var failure: Error?
        var written = 0
        for chunk in chunks(
            .microphone, epoch: "S-mic-E0", startSample: 0,
            totalSamples: 60 * rate, chunkSamples: 8_000
        ) {
            do { try await recorder.append(chunk); written += chunk.samples.count } catch {
                failure = error
                break
            }
        }
        XCTAssertEqual(failure as? MeetingCompressedAudioError, .budgetExceeded(limitBytes: budget))
        XCTAssertGreaterThan(written, 0)

        let before = try directoryBytes(directory)
        let next = try XCTUnwrap(chunks(
            .microphone, epoch: "S-mic-E0", startSample: written,
            totalSamples: 8_000, chunkSamples: 8_000
        ).first)
        do {
            try await recorder.append(next)
            XCTFail("expected budget error")
        } catch {
            XCTAssertEqual(error as? MeetingCompressedAudioError, .budgetExceeded(limitBytes: budget))
        }
        XCTAssertEqual(try directoryBytes(directory), before)
        try await recorder.close()
        XCTAssertLessThanOrEqual(try directoryBytes(directory), budget)
    }

    func testDefaultBudgetHoldsFourHoursOfTwoSources() {
        // 32 kbps = 4,000 bytes/s; 2 sources * 4 h * 3,600 s * 4,000 B/s.
        let fourHoursTwoSources = 2 * 4 * 3_600 * MeetingCompressedAudioRecorder.nominalBytesPerSecond
        XCTAssertEqual(fourHoursTwoSources, 115_200_000)
        XCTAssertGreaterThanOrEqual(MeetingCompressedAudioRecorder.defaultBudgetBytes, fourHoursTwoSources)
    }

    func testEncodedSizeStaysUnderTwentyMegabytesPerHourPerSource() async throws {
        let directory = makeRoot()
        let recorder = try MeetingCompressedAudioRecorder(directory: directory)
        let seconds = 300
        for chunk in chunks(
            .systemAudio, epoch: "S-sys-E0", startSample: 0,
            totalSamples: seconds * rate, chunkSamples: 16_000
        ) {
            try await recorder.append(chunk)
        }
        try await recorder.close()
        let bytes = try directoryBytes(directory)
        let perHour = bytes * 3_600 / seconds
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThanOrEqual(perHour, 20_000_000, "measured \(perHour) bytes/hour")
    }

    func testRejectsAudioAtTheWrongSampleRateAndAfterClose() async throws {
        let recorder = try MeetingCompressedAudioRecorder(directory: makeRoot())
        let good = try XCTUnwrap(chunks(
            .microphone, epoch: "S-mic-E0", startSample: 0, totalSamples: 1_000, chunkSamples: 1_000
        ).first)
        let wrongRate = MeetingAcceptedAudio(
            descriptor: MeetingAcceptedAudioDescriptor(
                chunkID: "x", sourceID: .microphone, timingEpochID: "e", sequence: 0,
                startSample: 0, endSample: 1_000, startMilliseconds: 0, endMilliseconds: 20,
                sampleRate: 48_000, sampleCount: 1_000
            ),
            samples: good.samples
        )
        do {
            try await recorder.append(wrongRate)
            XCTFail("expected invalid audio")
        } catch {
            XCTAssertEqual(error as? MeetingCompressedAudioError, .invalidAudio)
        }
        try await recorder.close()
        do {
            try await recorder.append(good)
            XCTFail("expected closed error")
        } catch {
            XCTAssertEqual(error as? MeetingCompressedAudioError, .recorderClosed)
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
