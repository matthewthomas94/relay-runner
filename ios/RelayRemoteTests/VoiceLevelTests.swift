import AVFoundation
import XCTest
@testable import RelayRemote

final class VoiceLevelTests: XCTestCase {
    private func tone(_ frequency: Double, amplitude: Float, frames: Int = 2048) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        for index in 0..<frames {
            samples[index] = amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / 48_000))
        }
        return buffer
    }

    func testRoomNoiseIsGatedOut() {
        XCTAssertEqual(VoiceLevelAnalysis.analyse(tone(200, amplitude: 0)), .silent)
        XCTAssertEqual(VoiceLevelAnalysis.analyse(tone(200, amplitude: 0.0005)).level, 0,
                       "below Voice's 0.015 gate")
    }

    func testSpeechLoudnessReadsHighButStaysWithinOne() {
        let level = VoiceLevelAnalysis.analyse(tone(200, amplitude: 0.1)).level
        XCTAssertGreaterThan(level, 0.5)
        XCTAssertLessThanOrEqual(level, 1)
    }

    func testBandsFollowWhereTheEnergyIs() {
        let low = VoiceLevelAnalysis.analyse(tone(150, amplitude: 0.1))
        XCTAssertGreaterThan(low.bands.x, low.bands.z, "a low voice moves the lows")
        let high = VoiceLevelAnalysis.analyse(tone(3_500, amplitude: 0.1))
        XCTAssertGreaterThan(high.bands.z, high.bands.x, "sibilance moves the highs")
        XCTAssertLessThanOrEqual(high.bands.max(), high.level, "no band outruns the level")
    }

    func testEnvelopeRisesFasterThanItFalls() {
        let envelope = VoiceEnvelope(attack: 0.05, release: 0.5)
        _ = envelope.follow(.silent, at: 0)
        let up = envelope.follow(VoiceLevel(level: 1, bands: SIMD3(repeating: 1)), at: 0.05).level
        let down = VoiceEnvelope(attack: 0.05, release: 0.5)
        _ = down.follow(VoiceLevel(level: 1, bands: SIMD3(repeating: 1)), at: 0)
        _ = down.follow(VoiceLevel(level: 1, bands: SIMD3(repeating: 1)), at: 0.1)
        _ = down.follow(VoiceLevel(level: 1, bands: SIMD3(repeating: 1)), at: 0.2)
        let held = down.value.level
        let fallen = held - down.follow(.silent, at: 0.25).level
        XCTAssertGreaterThan(up, fallen, "a syllable lands faster than it fades")
    }
}
