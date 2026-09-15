import Foundation
import QuartzCore

/// One presentation clock keeps the screen particles and pill moving together.
final class VoiceOverlayMotion {
    static let travelDuration = TranscriptionPill.MotionStyle.visibilityDuration

    private(set) var overlayDeparture: CGFloat = 1
    private(set) var pillDeparture: CGFloat = 1
    var overlayBlurRadius: CGFloat { overlayDeparture * TranscriptionPill.MotionStyle.exitBlurRadius }
    var pillBlurRadius: CGFloat { pillDeparture * TranscriptionPill.MotionStyle.exitBlurRadius }
    private var overlayTravel = Travel(value: 1)
    private var pillTravel = Travel(value: 1)
    private var departingTheme: ParticleFieldRenderer.Theme?

    /// Called by the existing overlay display loop, including while idle.
    func update(
        theme: ParticleFieldRenderer.Theme?,
        showsPill: Bool? = nil,
        reduceMotion: Bool,
        now: TimeInterval = CACurrentMediaTime()
    ) -> ParticleFieldRenderer.Theme? {
        if let theme {
            departingTheme = theme
        }
        overlayTravel.move(to: theme == nil ? 1 : 0, immediately: reduceMotion, now: now)
        // Keep rendering the last theme until it is below the screen.
        if theme == nil, overlayTravel.value == 1 { departingTheme = nil }
        // Pill-only notices still work when screen particles are disabled.
        pillTravel.move(to: (showsPill ?? (theme != nil)) ? 0 : 1,
                        immediately: reduceMotion, now: now)
        overlayDeparture = overlayTravel.value
        pillDeparture = pillTravel.value
        return departingTheme
    }

    func reset() {
        overlayDeparture = 1
        pillDeparture = 1
        overlayTravel = Travel(value: 1)
        pillTravel = Travel(value: 1)
        departingTheme = nil
    }

    private struct Travel {
        private(set) var value: CGFloat
        private var startValue: CGFloat
        private var target: CGFloat
        private var startedAt: TimeInterval = 0

        init(value: CGFloat) {
            self.value = value
            startValue = value
            target = value
        }

        mutating func move(to destination: CGFloat, immediately: Bool, now: TimeInterval) {
            advance(now: now)
            if immediately {
                value = destination
                startValue = destination
                target = destination
            } else if destination != target {
                startValue = value
                startedAt = now
                target = destination
            }
        }

        private mutating func advance(now: TimeInterval) {
            let distance = abs(target - startValue)
            guard distance > 0 else { return }
            let t = max(0, min(1, (now - startedAt) / (travelDuration * distance)))
            let eased = t * t * (3 - 2 * t)
            value = startValue + (target - startValue) * eased
        }
    }
}
