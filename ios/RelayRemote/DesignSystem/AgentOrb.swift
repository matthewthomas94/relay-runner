import SwiftUI
import UIKit

/// What the agent orb's edge colour and motion follow.
enum AgentOrbState: String, CaseIterable, Equatable {
    /// Navy (#11161D) edge, resting motion.
    case idle
    /// Orange edge while the user talks.
    case listening
    /// Blue-purple edge while a reply plays.
    case playing
}

/// The agent's blob: a SwiftUI port of `buildOrbGrid` in the desktop's
/// `ParticleFieldRenderer`. Three Gaussian lobes on a halftone dot grid form
/// one liquid volume with a white core whose sparse edge takes the state's
/// colour. 168 × 112 pt on a 7 pt grid, or the Agents header's 60 × 56 pt on
/// a 6 pt grid. It is never dimmed, and it holds still with Reduce Motion on.
struct AgentOrb: View {
    let state: AgentOrbState
    /// Where in its cycle the orb starts, so neighbouring orbs do not move in step.
    var phase: Double = 0

    /// The frame, and the grid the dots sit on. The biggest dot is half the
    /// step across, as on the desktop (10 pt grid, 5 pt dots).
    var frameSize = Self.size
    var step = AgentOrbEngine.step

    static let size = CGSize(width: 168, height: 112)
    /// The Agents header (Figma Final 21, 2026-11-28): fewer, bigger dots, the
    /// biggest 3 pt like the status glyph's.
    static let headerSize = CGSize(width: 60, height: 56)
    static let headerStep: CGFloat = 6

    @State private var engine = AgentOrbEngine()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for dot in engine.dots(state: state, phase: phase, size: size, step: step, now: now,
                                       reduceMotion: reduceMotion) {
                    let rect = CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius,
                                      width: dot.radius * 2, height: dot.radius * 2)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(Color(.sRGB, red: dot.rgb.x, green: dot.rgb.y, blue: dot.rgb.z,
                                                    opacity: dot.alpha)))
                }
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .accessibilityHidden(true)
    }
}

/// The orb's maths and the state it carries between frames: the edge colour
/// crossfade and the motion blend when the state changes.
final class AgentOrbEngine {
    struct Dot {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let alpha: Double
        let rgb: SIMD3<Double>
    }

    /// Multipliers on the orb's resting motion, from the desktop's `OrbActivity`.
    struct Motion: Equatable {
        var speed: Double
        var stretch: Double
        var wander: Double
        var spread: Double

        static func of(_ state: AgentOrbState) -> Motion {
            switch state {
            case .idle: return Motion(speed: 1.8, stretch: 1.2, wander: 1.2, spread: 1)
            case .listening: return Motion(speed: 2.4, stretch: 1.6, wander: 1.1, spread: 0.95)
            case .playing: return Motion(speed: 2.8, stretch: 2, wander: 1.5, spread: 1.05)
            }
        }
    }

    static let step: CGFloat = 7
    /// How far the volume's outer bounds (each lobe's 1.3 radii) overrun the
    /// frame. Only faint edge dots live out there, so the phone lets them
    /// run off the frame and draws the body at the size of the designs.
    static let overscale = 1.12
    static let colorBlendDuration: TimeInterval = 0.3
    static let motionBlendDuration: TimeInterval = 0.8

    private var state: AgentOrbState?
    private var previousRim: SIMD3<Double>?
    private var displayedRim: SIMD3<Double>?
    private var colorChangedAt: TimeInterval = 0
    private var motionFrom = Motion.of(.idle)
    private var motionChangedAt: TimeInterval = 0
    private var phaseAtChange: Double = 0

    static func rim(_ state: AgentOrbState) -> SIMD3<Double> {
        switch state {
        case .idle: return SIMD3(17.0 / 255, 22.0 / 255, 29.0 / 255)
        case .listening: return hsb(hue: 0.04, saturation: 0.95)
        case .playing: return hsb(hue: 0.68, saturation: 0.80)
        }
    }

    private static func hsb(hue: CGFloat, saturation: CGFloat) -> SIMD3<Double> {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(hue: hue, saturation: saturation, brightness: 1, alpha: 1)
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD3(Double(red), Double(green), Double(blue))
    }

    /// The orb's dots at `now`, in SwiftUI's y-down coordinates.
    func dots(state: AgentOrbState, phase initialPhase: Double, size: CGSize, step: CGFloat = step,
              now: TimeInterval, reduceMotion: Bool) -> [Dot] {
        if self.state == nil {
            self.state = state
            motionFrom = Motion.of(state)
            motionChangedAt = now
            phaseAtChange = initialPhase
            colorChangedAt = now
        } else if self.state != state {
            let shown = motion(at: now, reduceMotion: reduceMotion)
            motionFrom = shown.motion
            phaseAtChange = shown.phase
            motionChangedAt = now
            previousRim = displayedRim
            colorChangedAt = now
            self.state = state
        }

        let target = Self.rim(state)
        let progress = reduceMotion ? 1 : min(1, max(0, (now - colorChangedAt) / Self.colorBlendDuration))
        let previous = previousRim ?? target
        let rim = previous + (target - previous) * RelayMotion.smoothstep(progress)
        displayedRim = rim

        let (motion, phase) = self.motion(at: now, reduceMotion: reduceMotion)
        return Self.grid(rim: rim, motion: motion, phase: phase, size: size, step: step)
    }

    /// The motion and phase at `now`. Speed ramps linearly over the blend, so
    /// the phase it integrates to never jumps.
    private func motion(at now: TimeInterval, reduceMotion: Bool) -> (motion: Motion, phase: Double) {
        let target = Motion.of(state ?? .idle)
        guard !reduceMotion else { return (target, phaseAtChange) }
        let duration = Self.motionBlendDuration
        let since = max(0, now - motionChangedAt)
        let ramp = min(since, duration)
        let progress = ramp / duration
        let ease = RelayMotion.smoothstep(progress)
        func mix(_ from: Double, _ to: Double, _ amount: Double) -> Double { from + (to - from) * amount }
        let phase = phaseAtChange + motionFrom.speed * ramp
            + (target.speed - motionFrom.speed) * ramp * ramp / (2 * duration)
            + target.speed * (since - ramp)
        return (Motion(speed: mix(motionFrom.speed, target.speed, progress),
                       stretch: mix(motionFrom.stretch, target.stretch, ease),
                       wander: mix(motionFrom.wander, target.wander, ease),
                       spread: mix(motionFrom.spread, target.spread, ease)), phase)
    }

    /// `buildOrbGrid`, sized for the phone.
    static func grid(rim: SIMD3<Double>, motion: Motion, phase: Double, size: CGSize,
                     step: CGFloat = step) -> [Dot] {
        let spread = motion.spread
        let stretch = sin(phase * 0.72) * 0.10 * motion.stretch
        let curl = sin(phase * 0.53) * 0.055 * motion.wander
        let lobes: [(x: Double, y: Double, rx: Double, ry: Double)] = [
            (-0.27 * spread + curl, -0.15 * spread + sin(phase * 0.61) * 0.055 * motion.wander,
             0.64 + stretch, 0.59 / (1 + stretch)),
            (0.26 * spread - curl, 0.28 * spread + sin(phase * 0.47) * 0.055 * motion.wander,
             0.54 - stretch * 0.4, 0.57 + sin(phase * 0.58) * 0.045 * motion.stretch),
            (0.20 * spread + sin(phase * 0.43) * 0.065 * motion.wander, -0.26 * spread - curl * 0.5,
             0.50 + sin(phase * 0.67) * 0.035 * motion.stretch, 0.47 + stretch * 0.4),
        ]
        let left = lobes.map { $0.x - $0.rx * 1.3 }.min()!
        let right = lobes.map { $0.x + $0.rx * 1.3 }.max()!
        let bottom = lobes.map { $0.y - $0.ry * 1.3 }.min()!
        let top = lobes.map { $0.y + $0.ry * 1.3 }.max()!
        let scale = min(max(1, Double(size.width)) / (right - left),
                        max(1, Double(size.height)) / (top - bottom)) * overscale
        let cols = Int(size.width / step)
        let rows = Int(size.height / step)
        var result: [Dot] = []
        result.reserveCapacity(cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                // Desktop maths runs y-up; draw it flipped into y-down.
                let x = CGFloat(col) * step + (size.width - CGFloat(cols - 1) * step) / 2
                let y = CGFloat(row) * step + (size.height - CGFloat(rows - 1) * step) / 2
                let nx = Double(x - size.width / 2) / scale + (left + right) / 2
                let ny = Double(y - size.height / 2) / scale + (bottom + top) / 2
                var density = 0.0
                for lobe in lobes {
                    let dx = (nx - lobe.x) / lobe.rx
                    let dy = (ny - lobe.y) / lobe.ry
                    density += exp(-2 * (dx * dx + dy * dy))
                }
                let body = max(0, min(1, (density - 0.035) / 0.85))
                guard body > 0.001 else { continue }
                let highlight = min(1, body / 0.7)
                let white = highlight * highlight * (3 - 2 * highlight)
                let rgb = rim + (SIMD3<Double>(repeating: 1) - rim) * white
                let radius = step * 0.25 * CGFloat(pow(body, 0.72))
                let alpha = min(1, body * 5)
                guard radius > 0.1, alpha > 0.02 else { continue }
                result.append(Dot(x: x, y: size.height - y, radius: radius, alpha: alpha, rgb: rgb))
            }
        }
        return result
    }
}
