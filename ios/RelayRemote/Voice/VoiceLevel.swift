import Accelerate
@preconcurrency import AVFoundation
import Observation
import SwiftUI

/// What the microphone hears, shaped the way libraries.dev's Voice
/// (`voice-glow`, github.com/Jakubantalik/Libraries.dev at d058179b,
/// `packages/voice-glow/src/voiceDriver.ts`) shapes it: the buffer's RMS,
/// gained and passed through a noise gate and a soft saturation, and three
/// bands (80–300 Hz, 300–2000 Hz, 2–6 kHz). Each band is the loudness
/// weighted by that band's share of the voice's energy, so the bands never
/// outrun the level. All values run from 0 to 1.
struct VoiceLevel: Equatable, Sendable {
    var level: Float
    /// Lows, mids and highs.
    var bands: SIMD3<Float>

    static let silent = VoiceLevel(level: 0, bands: .zero)
}

/// The microphone's latest `VoiceLevel`, for the talk button's sound wave,
/// which moves with the voice. Its own
/// observable, so the ~23 updates a second only reach those views.
@MainActor
@Observable
final class MicLevelMeter {
    private(set) var current = VoiceLevel.silent

    func update(_ level: VoiceLevel) {
        current = level
    }
}

extension EnvironmentValues {
    /// The phone's microphone level, set at the app root (nil in previews and samples).
    @Entry var micLevel: MicLevelMeter?
}

/// Eases a `VoiceLevel` toward the microphone's, quickly up and slowly down,
/// as Voice's `follow()` does: each step moves `1 - exp(-dt / tau)` of the
/// way, with the attack time rising and the release time falling.
final class VoiceEnvelope {
    private(set) var value = VoiceLevel.silent
    private var last: TimeInterval?
    let attack: Double
    let release: Double

    init(attack: Double, release: Double) {
        self.attack = attack
        self.release = release
    }

    func follow(_ target: VoiceLevel, at time: TimeInterval) -> VoiceLevel {
        let dt = last.map { min(0.1, max(0, time - $0)) } ?? 0
        last = time
        func step(_ previous: Float, _ goal: Float) -> Float {
            let tau = goal > previous ? attack : release
            let amount = Float(1 - exp(-dt / max(0.001, tau)))
            return previous + (goal - previous) * amount
        }
        value = VoiceLevel(level: step(value.level, target.level),
                           bands: SIMD3(step(value.bands.x, target.bands.x),
                                        step(value.bands.y, target.bands.y),
                                        step(value.bands.z, target.bands.z)))
        return value
    }
}

/// Measures a microphone buffer on the audio thread.
enum VoiceLevelAnalysis {
    /// Voice's defaults: `BASE_GAIN` 5 times `sensitivity` 3.1, and a gate at 0.015.
    static let gain: Float = 5 * 3.1
    static let threshold: Float = 0.015
    static let bandRanges: [(Float, Float)] = [(80, 300), (300, 2000), (2000, 6000)]
    private static let size = 1024
    nonisolated(unsafe) private static let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
    private static let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                            count: size, isHalfWindow: false)

    /// Voice's `shape()`: nothing below the gate, then a soft curve to 1.
    static func shape(_ raw: Float, threshold: Float) -> Float {
        guard raw > threshold else { return 0 }
        let t = (raw - threshold) / max(0.001, 1 - threshold)
        return min(1, max(0, (1 - exp(-3 * t)) / (1 - exp(-3))))
    }

    static func analyse(_ buffer: AVAudioPCMBuffer) -> VoiceLevel {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return .silent }
        let count = Int(buffer.frameLength)
        let channel = UnsafeBufferPointer(start: data[0], count: count)
        let rms = vDSP.rootMeanSquare(channel)
        let level = shape(rms * gain, threshold: threshold)
        guard level > 0, let fft else { return VoiceLevel(level: level, bands: .zero) }

        // The newest `size` samples, windowed, through a real FFT.
        var samples = [Float](repeating: 0, count: size)
        let take = min(count, size)
        for index in 0..<take { samples[index] = channel[count - take + index] }
        samples = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = [Float](repeating: 0, count: size / 2)
        var power = [Float](repeating: 0, count: size / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                samples.withUnsafeBytes { bytes in
                    vDSP_ctoz(bytes.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                fft.forward(input: split, output: &split)
                power.withUnsafeMutableBufferPointer { powerPointer in
                    vDSP_zvmags(&split, 1, powerPointer.baseAddress!, 1, vDSP_Length(size / 2))
                }
            }
        }
        let binWidth = Float(buffer.format.sampleRate) / Float(size)
        var energy = SIMD3<Float>.zero
        for (band, range) in bandRanges.enumerated() {
            let low = max(1, Int(range.0 / binWidth))
            let high = min(size / 2, Int(range.1 / binWidth))
            guard high > low else { continue }
            energy[band] = power[low..<high].reduce(0, +)
        }
        let total = energy.sum()
        guard total > 0 else { return VoiceLevel(level: level, bands: SIMD3(repeating: level)) }
        // A band carrying a third of the voice reads at about the full level.
        let share = energy / total
        let bands = SIMD3<Float>(repeating: level) * simd_clamp(0.35 + share * 1.95, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return VoiceLevel(level: level, bands: bands)
    }
}
