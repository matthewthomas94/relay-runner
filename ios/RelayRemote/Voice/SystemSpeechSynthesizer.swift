import AVFoundation
import Foundation
import RelayRemoteKit

/// `AVSpeechSynthesizer` behind the kit's `SpeechSynthesizing`: one text at a
/// time and exactly one completion per text, `true` when it finished and
/// `false` when it was stopped. Prefers an Enhanced or Premium voice for the
/// device language when the user has installed one (RR-421).
@MainActor
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var completion: (@MainActor (Bool) -> Void)?
    private(set) var voice: AVSpeechSynthesisVoice?

    var isPaused: Bool { synthesizer.isPaused }

    override init() {
        super.init()
        synthesizer.delegate = self
        voice = Self.preferredVoice()
    }

    /// The Mac's speech speed (0.5...2.0x), applied to the phone's own voice.
    var speed: Double = 1

    /// AVSpeech rates are not linear: the default (0.5) is natural speech and
    /// 1.0 is very fast. Map 1x to the default, 2x to near the top and 0.5x
    /// halfway to the minimum.
    static func utteranceRate(for speed: Double) -> Float {
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let clamped = min(max(speed, 0.5), 2)
        let value: Double
        if clamped >= 1 {
            value = base + (Double(AVSpeechUtteranceMaximumSpeechRate) * 0.9 - base) * (clamped - 1)
        } else {
            value = base - (base - Double(AVSpeechUtteranceMinimumSpeechRate)) * (1 - clamped)
        }
        return Float(value)
    }

    func speak(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        finish(played: false)
        self.completion = completion
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.utteranceRate(for: speed)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        guard completion != nil else { return }
        if !synthesizer.stopSpeaking(at: .immediate) {
            finish(played: false)
        }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    private func finish(played: Bool) {
        guard let completion else { return }
        self.completion = nil
        completion(played)
    }

    nonisolated private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onMain { self.finish(played: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onMain { self.finish(played: false) }
    }
}
