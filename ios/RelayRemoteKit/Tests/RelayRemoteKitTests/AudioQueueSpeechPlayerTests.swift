import Foundation
import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

/// Plays real AAC-LC ADTS, encoded the way services/remote_audio.py does, through
/// the AudioQueue player at zero volume. macOS only: the iPhone plays the same
/// code, checked by hand.
@MainActor
final class AudioQueueSpeechPlayerTests: XCTestCase {
    private static let afconvert = "/usr/bin/afconvert"

    /// One sentence the way the Mac encodes it: 24 kHz mono 48 kbps ADTS.
    private func encodedSentence(seconds: Double, frequency: Double) throws -> Data {
        #if os(macOS)
        guard FileManager.default.isExecutableFile(atPath: Self.afconvert) else {
            throw XCTSkip("afconvert is not available")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rr458-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("speech.wav")
        let output = folder.appendingPathComponent("speech.aac")
        try Self.wave(seconds: seconds, frequency: frequency).write(to: wav)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.afconvert)
        process.arguments = ["-f", "adts", "-d", "aac@24000", "-b", "48000", "-s", "0", wav.path, output.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: output)
        #else
        throw XCTSkip("encoding needs afconvert on macOS")
        #endif
    }

    /// 16-bit mono PCM WAV at 24 kHz.
    private static func wave(seconds: Double, frequency: Double) -> Data {
        let rate = 24_000
        let count = Int(Double(rate) * seconds)
        var samples = Data(capacity: count * 2)
        for index in 0..<count {
            let value = Int16(sin(2 * .pi * frequency * Double(index) / Double(rate)) * 8000)
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var data = Data("RIFF".utf8) + le(UInt32(36 + samples.count)) + Data("WAVEfmt ".utf8)
        data += le(UInt32(16)) + le(UInt16(1)) + le(UInt16(1)) + le(UInt32(rate)) + le(UInt32(rate * 2))
        data += le(UInt16(2)) + le(UInt16(16)) + Data("data".utf8) + le(UInt32(samples.count)) + samples
        return data
    }

    private func play(_ slices: [Data], on player: AudioQueueSpeechPlayer) async -> (AudioPlaybackEnd?, TimeInterval) {
        var result: AudioPlaybackEnd?
        let started = Date()
        player.startStream(format: .aac, sampleRate: 24000) { result = $0 }
        for slice in slices {
            player.append(slice)
            await Task.yield()
        }
        player.endStream()
        let deadline = Date().addingTimeInterval(10)
        while result == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return (result, Date().timeIntervalSince(started))
    }

    private static func slices(_ data: Data, size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }

    func testSlicesCutMidFramePlayToTheEndOfTwoConcatenatedSentences() async throws {
        let first = try encodedSentence(seconds: 0.5, frequency: 440)
        let second = try encodedSentence(seconds: 0.5, frequency: 660)
        let player = AudioQueueSpeechPlayer()
        player.volume = 0
        // Odd slice sizes split ADTS frames, as the Mac's 24 KiB parts do.
        let (end, elapsed) = await play(Self.slices(first + second, size: 777), on: player)
        XCTAssertEqual(end, .finished)
        XCTAssertGreaterThan(elapsed, 0.8, "the whole second of audio played before completion")
    }

    func testStopReportsStoppedAtOnce() async throws {
        let data = try encodedSentence(seconds: 2, frequency: 440)
        let player = AudioQueueSpeechPlayer()
        player.volume = 0
        var result: AudioPlaybackEnd?
        player.startStream(format: .aac, sampleRate: 24000) { result = $0 }
        player.append(data)
        player.stop()
        XCTAssertEqual(result, .stopped)
    }

    func testUndecodableStreamFails() async {
        let player = AudioQueueSpeechPlayer()
        player.volume = 0
        let (end, _) = await play([Data(repeating: 0x42, count: 4096)], on: player)
        XCTAssertEqual(end, .failed)
    }

    func testUnsupportedFormatFails() {
        let player = AudioQueueSpeechPlayer()
        var result: AudioPlaybackEnd?
        player.startStream(format: .opus, sampleRate: 48000) { result = $0 }
        XCTAssertEqual(result, .failed)
    }
}
