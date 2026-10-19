import QuartzCore
import SwiftUI

struct SessionWheelWorkspaceGlyph: View {
    let isWorkspaceVisible: Bool
    let isPickingProject: Bool
    let status: NotchSessionStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion = NotchContentMotion()

    private enum Symbol { case status, close, back }
    private var symbol: Symbol {
        isPickingProject ? .back : isWorkspaceVisible ? .close : .status
    }

    var body: some View {
        let animates = !reduceMotion && symbol == .status
            && (status.animatesGlyphMotion || motion.isAnimating(now: CACurrentMediaTime()))
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !animates)) { _ in
            let dots = (reduceMotion ? NotchContentMotion() : motion).renderedGlyphDots(
                status: status, now: CACurrentMediaTime(), reduceMotion: reduceMotion
            )
            SessionWheelWorkspaceGlyphDrawing(dots: dots, closeProgress: symbol == .close ? 1 : 0,
                                               backProgress: symbol == .back ? 1 : 0,
                                               reduceMotion: reduceMotion)
                .animation(reduceMotion ? RelayMotion.change(reduceMotion: true)
                           : RelayMotion.changeCurve.animation(duration: RelayMotion.enterDuration + RelayMotion.changeDuration),
                           value: symbol)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .onChange(of: status) { old, new in
            let now = CACurrentMediaTime()
            if old.glyph != new.glyph { motion.glyphChanged(from: old.glyph, now: now) }
            motion.statusChanged(from: old, to: new, now: now, reduceMotion: reduceMotion)
        }
        .task(id: status) {
            // Stop the display clock after the current notch cycle has settled.
            do { try await Task.sleep(for: .seconds(NotchStatusGlyphMotion.duration)) }
            catch { return }
            motion.prune(now: CACurrentMediaTime())
        }
    }
}

/// A single animatable drawing keeps its current shape when a click reverses it.
/// Each symbol contracts into the shared bead before it stretches into the next.
struct SessionWheelWorkspaceGlyphDrawing: View, Animatable {
    let dots: [NotchContentMotion.RenderedDot]
    var closeProgress: CGFloat
    var backProgress: CGFloat = 0
    let reduceMotion: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(closeProgress, backProgress) }
        set {
            closeProgress = newValue.first
            backProgress = newValue.second
        }
    }

    var body: some View {
        Canvas { context, _ in
            let close = min(max(closeProgress, 0), 1)
            let back = min(max(backProgress, 0), 1)
            let status = max(1 - close - back, 0)
            if reduceMotion {
                var source = context
                source.opacity = status
                for dot in dots { draw(dot, merge: 0, in: source) }
                var target = context
                target.opacity = close
                drawCross(expansion: 1, in: target)
                target.opacity = back
                drawArrow(expansion: 1, in: target)
            } else {
                let merge = min((close + back) / 0.65, 1)
                // Keep the notch's accent colours until they join the white core.
                for dot in dots where dot.color != NotchStatusDotColor.white.rgb {
                    var accent = context
                    accent.opacity = 1 - merge
                    draw(dot, merge: merge, in: accent)
                }
                context.drawLayer { liquid in
                    let dominant = max(status, max(close, back))
                    if dominant < 1 {
                        liquid.addFilter(.alphaThreshold(min: 0.5, color: .white))
                        liquid.addFilter(.blur(radius: sin(.pi * dominant) * 0.9))
                    }
                    liquid.drawLayer { shapes in
                        if merge < 1 {
                            for dot in dots where dot.color == NotchStatusDotColor.white.rgb {
                                draw(dot, merge: merge, in: shapes)
                            }
                        } else if back > 0.65 {
                            drawArrow(expansion: (back - 0.65) / 0.35, in: shapes)
                        } else {
                            drawCross(expansion: max((close - 0.65) / 0.35, 0), in: shapes)
                        }
                    }
                }
            }
        }
        .frame(width: 24, height: 24)
    }

    private func draw(_ dot: NotchContentMotion.RenderedDot, merge: CGFloat, in context: GraphicsContext) {
        let center = CGPoint(x: dot.center.x + (12 - dot.center.x) * merge,
                             y: dot.center.y + (12 - dot.center.y) * merge)
        let diameter = dot.diameter + (4 - dot.diameter) * merge
        let color = dot.color.mixed(with: NotchStatusDotColor.white.rgb, amount: merge)
        var context = context
        context.opacity *= dot.alpha
        if dot.softness > 0 { context.addFilter(.blur(radius: dot.softness)) }
        context.fill(Path(ellipseIn: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                           width: diameter, height: diameter)),
                     with: .color(Color(red: color.red, green: color.green, blue: color.blue)))
    }

    private func drawCross(expansion: CGFloat, in context: GraphicsContext) {
        let width = 4 - 2 * expansion
        drawBead(diameter: width, in: context)
        var cross = Path()
        for corner in NotchContentMotion.coreCenters {
            cross.move(to: CGPoint(x: 12, y: 12))
            cross.addLine(to: CGPoint(x: 12 + (corner.x - 12) * 1.6 * expansion,
                                     y: 12 + (corner.y - 12) * 1.6 * expansion))
        }
        context.stroke(cross, with: .color(.white), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func drawArrow(expansion: CGFloat, in context: GraphicsContext) {
        let width = 4 - 2 * expansion
        drawBead(diameter: width, in: context)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: 12 + x * expansion, y: 12 + y * expansion)
        }
        var arrow = Path()
        arrow.move(to: point(0, -5))
        arrow.addLine(to: point(-5, 0))
        arrow.addLine(to: point(0, 5))
        arrow.move(to: point(-5, 0))
        arrow.addLine(to: point(5, 0))
        context.stroke(arrow, with: .color(.white),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func drawBead(diameter: CGFloat, in context: GraphicsContext) {
        context.fill(Path(ellipseIn: CGRect(x: 12 - diameter / 2, y: 12 - diameter / 2,
                                           width: diameter, height: diameter)), with: .color(.white))
    }
}
