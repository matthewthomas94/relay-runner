import Foundation
import Observation
import QuartzCore

/// One presentation clock for the orchestrator's card, screen particles, and pill.
/// Each surface leaves through its lower edge before the other rises into view.
@Observable
final class AgentParticleHandoff {
    static let travelDuration = TranscriptionPill.MotionStyle.visibilityDuration

    private(set) var cardDeparture: CGFloat = 0
    private(set) var overlayDeparture: CGFloat = 1
    private(set) var pillDeparture: CGFloat = 1
    var cardBlurRadius: CGFloat { cardDeparture * TranscriptionPill.MotionStyle.exitBlurRadius }
    var overlayBlurRadius: CGFloat { overlayDeparture * TranscriptionPill.MotionStyle.exitBlurRadius }
    var pillBlurRadius: CGFloat { pillDeparture * TranscriptionPill.MotionStyle.exitBlurRadius }
    @ObservationIgnored private var visibleCards: Set<UUID> = []
    @ObservationIgnored private var cardTravel = Travel(value: 0)
    @ObservationIgnored private var overlayTravel = Travel(value: 1)
    @ObservationIgnored private var pillTravel = Travel(value: 1)
    @ObservationIgnored private var departingTheme: ParticleFieldRenderer.Theme?

    func setCardVisible(_ visible: Bool, id: UUID) {
        if visible { visibleCards.insert(id) } else { visibleCards.remove(id) }
    }

    /// Called by the existing overlay display loop, including while idle.
    func update(
        theme: ParticleFieldRenderer.Theme?,
        showsPill: Bool? = nil,
        reduceMotion: Bool,
        now: TimeInterval = CACurrentMediaTime()
    ) -> ParticleFieldRenderer.Theme? {
        if let theme {
            departingTheme = theme
            cardTravel.move(to: 1, immediately: reduceMotion || visibleCards.isEmpty, now: now)
            overlayTravel.move(to: cardTravel.value == 1 ? 0 : 1, immediately: reduceMotion, now: now)
        } else {
            // Keep rendering the last theme until it is below the screen.
            overlayTravel.move(to: 1, immediately: reduceMotion, now: now)
            cardTravel.move(to: overlayTravel.value == 1 ? 0 : 1,
                            immediately: reduceMotion || visibleCards.isEmpty, now: now)
            if overlayTravel.value == 1 { departingTheme = nil }
        }
        // A paired pill waits for the same card handoff as the particles.
        // Pill-only notices still work when screen particles are disabled.
        let pillCanEnter = theme == nil || cardTravel.value == 1
        pillTravel.move(to: (showsPill ?? (theme != nil)) && pillCanEnter ? 0 : 1,
                        immediately: reduceMotion, now: now)
        cardDeparture = cardTravel.value
        overlayDeparture = overlayTravel.value
        pillDeparture = pillTravel.value
        return cardDeparture == 1 || overlayDeparture < 1 ? departingTheme : nil
    }

    func reset() {
        cardDeparture = 0
        overlayDeparture = 1
        pillDeparture = 1
        cardTravel = Travel(value: 0)
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
