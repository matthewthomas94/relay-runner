import AppKit
import CoreGraphics

/// The libraries.dev hero sketch, element by element, as a frame evaluator.
/// `docs/specs/skeleton-generation.md` breaks the reference down; the names
/// here follow it. Everything is a pure function of the scene, the element's
/// progress `a` (fraction of `duration`) and the elapsed milliseconds `s`.
enum SkeletonGeneration {
    // MARK: Timeline

    static let duration: TimeInterval = 2.4 * RelayMotion.durationScale
    /// Elements start one after another, as the hero's tiles do.
    static let elementStagger: TimeInterval = 0.1
    static let dotsWindow = 0.0...0.3
    static let probeWindow = 0.02...0.24
    static let guidesWindow = 0.04...0.3
    static let outlineWindow = 0.1...0.42
    static let partsWindow = 0.28...0.74
    static let revealWindow = 0.74...1.055
    static let cleanWindow = 0.84...1.04
    /// Constructed, with the reveal yet to start. The sketch waits here,
    /// dots crawling, until the host hands off.
    static let holdProgress = 0.74
    static let endProgress = 1.09

    // MARK: Geometry

    static let margin: CGFloat = 44
    static let fieldPitch: CGFloat = 15
    /// Wire dots sit on the notch glyph's 5pt pitch.
    static let wireGap: CGFloat = 5
    static let guideGap: CGFloat = 6.5
    static let keyGuideReach: CGFloat = 16
    static let flyerCount = 44
    /// Dots crawl along every path at 16 px/s.
    static let crawlSpeed: CGFloat = 0.016
    /// The reference draws 2.1px wire dots; Relay draws the glyph's 3pt dot
    /// and keeps every other radius in proportion.
    static let glyphScale: CGFloat = 3 / 2.1
    static let wireDotRadius: CGFloat = 1.5
    static let fieldDotRadius: CGFloat = 1.05 * glyphScale
    static let fieldLitGrowth: CGFloat = 0.85 * glyphScale
    static let outlineHeadRadius: CGFloat = 2.8 * glyphScale
    static let partHeadRadius: CGFloat = 2.4 * glyphScale
    static let capRadius: CGFloat = 1.7 * glyphScale
    static let flyerRadius: CGFloat = 1.6 * glyphScale
    static let handleSize: CGFloat = 5 * glyphScale
    static let keyHandleSize: CGFloat = 4 * glyphScale
    static let reticleInset: CGFloat = 5
    static let maxKeysPerElement = 3
    static let maxPartsPerElement = 60

    // MARK: Easing

    static let easeOut = RelayMotion.Curve(x1: 0.16, y1: 1, x2: 0.3, y2: 1)
    static let easeSoft = RelayMotion.enterCurve

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: Double) -> CGFloat {
        from + (to - from) * CGFloat(t)
    }

    /// Smoothstep between two progress values.
    static func smooth(_ from: Double, _ to: Double, _ t: Double) -> Double {
        let l = clamp((t - from) / (to - from))
        return l * l * (3 - 2 * l)
    }

    /// Linear progress through a window.
    static func span(_ window: ClosedRange<Double>, _ t: Double) -> Double {
        clamp((t - window.lowerBound) / (window.upperBound - window.lowerBound))
    }

    static func eased(_ t: Double) -> Double { Double(easeOut.progress(CGFloat(t))) }
    static func soft(_ t: Double) -> Double { Double(easeSoft.progress(CGFloat(t))) }

    /// The reference's deterministic hash, so the sketch repeats exactly.
    static func hash(_ x: Double) -> Double {
        let a = sin(x * 127.1 + 311.7) * 43_758.5453
        return a - floor(a)
    }

    /// The time at which `easeOut` reaches `value`.
    static func inverseEaseOut(_ value: Double) -> Double {
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<26 {
            let mid = (lower + upper) / 2
            if eased(mid) < value { lower = mid } else { upper = mid }
        }
        return lower
    }

    // MARK: Paths

    /// A polyline with arc-length lookup, so dots can be placed at exact
    /// distances along any contour.
    struct SampledPath {
        let points: [CGPoint]
        let cumulative: [CGFloat]

        init(points: [CGPoint]) {
            self.points = points
            var cumulative: [CGFloat] = [0]
            cumulative.reserveCapacity(points.count)
            for index in 1..<max(1, points.count) {
                cumulative.append(cumulative[index - 1] + hypot(points[index].x - points[index - 1].x,
                                                                 points[index].y - points[index - 1].y))
            }
            self.cumulative = cumulative
        }

        var length: CGFloat { cumulative.last ?? 0 }

        func point(at distance: CGFloat) -> CGPoint {
            guard points.count > 1 else { return points.first ?? .zero }
            let distance = min(max(0, distance), length)
            var low = 0
            var high = cumulative.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if cumulative[mid] <= distance { low = mid } else { high = mid }
            }
            let segment = cumulative[high] - cumulative[low]
            let t = segment > 0 ? (distance - cumulative[low]) / segment : 0
            return CGPoint(x: points[low].x + (points[high].x - points[low].x) * t,
                           y: points[low].y + (points[high].y - points[low].y) * t)
        }

        static func arc(center: CGPoint, radius: CGFloat, from: CGFloat, to: CGFloat) -> [CGPoint] {
            let steps = max(2, Int((abs(to - from) * max(radius, 1) / 2).rounded(.up)))
            return (0...steps).map { step in
                let angle = from + (to - from) * CGFloat(step) / CGFloat(steps)
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
        }

        /// Half of a rounded rect from top centre to bottom centre, down the
        /// right or the left side. The reference traces both at once.
        static func half(of rect: CGRect, radius: CGFloat, right: Bool) -> SampledPath {
            let r = max(0, min(radius, rect.width / 2, rect.height / 2))
            let top = CGPoint(x: rect.midX, y: rect.minY)
            let bottom = CGPoint(x: rect.midX, y: rect.maxY)
            var points = [top]
            if right {
                points.append(CGPoint(x: rect.maxX - r, y: rect.minY))
                points += arc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, from: -.pi / 2, to: 0)
                points.append(CGPoint(x: rect.maxX, y: rect.maxY - r))
                points += arc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, from: 0, to: .pi / 2)
            } else {
                points.append(CGPoint(x: rect.minX + r, y: rect.minY))
                points += arc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, from: -.pi / 2, to: -.pi)
                points.append(CGPoint(x: rect.minX, y: rect.maxY - r))
                points += arc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, from: .pi, to: .pi / 2)
            }
            points.append(bottom)
            return SampledPath(points: points)
        }

        /// A closed rounded rect from the top-left corner's end, clockwise.
        static func roundedRect(_ rect: CGRect, radius: CGFloat) -> SampledPath {
            let r = max(0, min(radius, rect.width / 2, rect.height / 2))
            var points = [CGPoint(x: rect.minX + r, y: rect.minY), CGPoint(x: rect.maxX - r, y: rect.minY)]
            points += arc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, from: -.pi / 2, to: 0)
            points.append(CGPoint(x: rect.maxX, y: rect.maxY - r))
            points += arc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, from: 0, to: .pi / 2)
            points.append(CGPoint(x: rect.minX + r, y: rect.maxY))
            points += arc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, from: .pi / 2, to: .pi)
            points.append(CGPoint(x: rect.minX, y: rect.minY + r))
            points += arc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, from: .pi, to: 1.5 * .pi)
            return SampledPath(points: points)
        }

        static func line(from: CGPoint, to: CGPoint) -> SampledPath {
            SampledPath(points: [from, to])
        }
    }

    /// Dots along a path up to `progress`, crawling with elapsed time, and
    /// the head position while the trace is live.
    static func trace(_ path: SampledPath, progress: Double, elapsedMs: Double, gap: CGFloat)
        -> (dots: [CGPoint], head: CGPoint?) {
        guard progress > 0, path.length > 0 else { return ([], nil) }
        let placed = Int(path.length * CGFloat(min(1, progress)) / gap)
        let offset = (CGFloat(elapsedMs) * crawlSpeed).truncatingRemainder(dividingBy: gap)
        var dots: [CGPoint] = []
        dots.reserveCapacity(placed + 1)
        for index in 0...placed {
            let distance = offset + CGFloat(index) * gap
            guard distance <= path.length else { break }
            dots.append(path.point(at: distance))
        }
        let head = progress < 1 ? path.point(at: CGFloat(placed) * gap) : nil
        return (dots, head)
    }

    // MARK: Scene

    struct Stroke {
        let path: SampledPath
        let gap: CGFloat
        /// Strokes with the same index trace together (a key box's halves).
        let index: Int
        let caps: Bool
    }

    struct Part {
        enum Kind: Equatable { case frame, button, text }
        let kind: Kind
        let rect: CGRect
        let key: Bool
        let strokes: [Stroke]
        let strokeCount: Int
        let start: Double
        let end: Double

        var name: String {
            switch kind {
            case .frame: return "FRAME"
            case .button: return "BUTTON"
            case .text: return "TEXT"
            }
        }
    }

    struct Flyer {
        let from: CGPoint
        let to: CGPoint
        let start: Double
        let arrival: Double
    }

    struct FieldDot {
        let center: CGPoint
        let element: Int
        let distance: CGFloat
        let edge: CGFloat
        let inside: Bool
        let speed: Double
        let phase: Double
        let trail: Double
    }

    struct Element {
        let rect: CGRect
        let radius: CGFloat
        let seed: Double
        let halves: [SampledPath]
        let guides: [SampledPath]
        let parts: [Part]
        let flyers: [Flyer]
        let maxDistance: CGFloat
        /// Where the dimension readout's baseline sits.
        let readoutAnchor: CGPoint
    }

    struct Scene {
        let bounds: CGRect
        let elements: [Element]
        let dots: [FieldDot]

        var keyRects: [CGRect] { elements.flatMap { $0.parts.filter(\.key).map(\.rect) } }
    }

    /// Builds the scene a layout sketches: its surfaces become elements, the
    /// bones inside them their parts, and one dot field covers the view.
    static func scene(bounds: CGRect, surfaces: [CGRect], bones: [SkeletonBone]) -> Scene {
        let rects = SkeletonConstruction.annotatedRects(surfaces: surfaces, bones: bones)
        guard !rects.isEmpty, bounds.width > 0, bounds.height > 0 else {
            return Scene(bounds: bounds, elements: [], dots: [])
        }
        func radius(of rect: CGRect) -> CGFloat {
            bones.first { $0.rect == rect }?.radius ?? 16
        }

        // Each bone belongs to the element containing it, else the nearest.
        var grouped: [[SkeletonBone]] = Array(repeating: [], count: rects.count)
        for bone in bones where !rects.contains(bone.rect) {
            let index = rects.firstIndex { $0.contains(bone.rect) } ?? rects.indices.min {
                outside(bone.rect.center, of: rects[$0]) < outside(bone.rect.center, of: rects[$1])
            } ?? 0
            grouped[index].append(bone)
        }

        var dots: [FieldDot] = []
        var maxDistance = Array(repeating: CGFloat(0), count: rects.count)
        var y = bounds.minY + fieldPitch / 2
        while y < bounds.maxY {
            var x = bounds.minX + fieldPitch / 2
            while x < bounds.maxX {
                let point = CGPoint(x: x, y: y)
                let column = Double((x / fieldPitch).rounded())
                let element = rects.indices.min { outside(point, of: rects[$0]) < outside(point, of: rects[$1]) } ?? 0
                let rect = rects[element]
                let u = outside(point, of: rect)
                let d = hypot(x - rect.midX, y - rect.midY)
                maxDistance[element] = max(maxDistance[element], d)
                dots.append(FieldDot(
                    center: point, element: element, distance: d, edge: 1 - CGFloat(clamp(Double(u / margin))),
                    inside: u == 0, speed: 0.07 + 0.09 * hash(column * 7.13 + Double(element + 1) * 31.7),
                    phase: hash(column * 3.71 + Double(element + 1) * 11.3) * 900,
                    trail: 50 + 70 * hash(column * 1.91 + Double(element + 1))
                ))
                x += fieldPitch
            }
            y += fieldPitch
        }

        let elements = rects.enumerated().map { index, rect -> Element in
            let seed = Double(index + 1)
            let r = radius(of: rect)
            let halves = [SampledPath.half(of: rect, radius: r, right: true),
                          SampledPath.half(of: rect, radius: r, right: false)]
            let m = margin
            let guides = [
                SampledPath.line(from: CGPoint(x: rect.minX - m, y: rect.minY), to: CGPoint(x: rect.maxX + m, y: rect.minY)),
                SampledPath.line(from: CGPoint(x: rect.maxX, y: rect.minY - m), to: CGPoint(x: rect.maxX, y: rect.maxY + m)),
                SampledPath.line(from: CGPoint(x: rect.maxX + m, y: rect.maxY), to: CGPoint(x: rect.minX - m, y: rect.maxY)),
                SampledPath.line(from: CGPoint(x: rect.minX, y: rect.maxY + m), to: CGPoint(x: rect.minX, y: rect.minY - m)),
            ]
            let parts = parts(for: grouped[index], in: rect)
            let flyers = (0..<flyerCount).map { t -> Flyer in
                let half = halves[t % 2]
                let fraction = 0.06 + 0.9 * (Double(t / 2) / 21)
                let target = half.point(at: half.length * CGFloat(fraction))
                let angle = hash(Double(t) * 9.1 + seed) * .pi * 2
                let distance = 30 + 70 * hash(Double(t) * 4.7 + seed * 2)
                let arrival = outlineWindow.lowerBound
                    + (outlineWindow.upperBound - outlineWindow.lowerBound) * inverseEaseOut(fraction)
                return Flyer(from: CGPoint(x: target.x + CGFloat(cos(angle) * distance),
                                           y: target.y + CGFloat(sin(angle) * distance)),
                             to: target, start: arrival - 0.09, arrival: arrival)
            }
            let above = rect.minY - bounds.minY >= 20
            let anchor = above ? CGPoint(x: rect.minX, y: rect.minY - 10) : CGPoint(x: rect.minX + 10, y: rect.minY + 17)
            return Element(rect: rect, radius: r, seed: seed, halves: halves, guides: guides, parts: parts,
                           flyers: flyers, maxDistance: maxDistance[index], readoutAnchor: anchor)
        }
        return Scene(bounds: bounds, elements: elements, dots: dots)
    }

    /// Distance from a point to the outside of a rect; 0 inside.
    static func outside(_ point: CGPoint, of rect: CGRect) -> CGFloat {
        max(0, rect.minX - point.x, point.x - rect.maxX, rect.minY - point.y, point.y - rect.maxY)
    }

    private static func parts(for bones: [SkeletonBone], in element: CGRect) -> [Part] {
        let ordered = Array(bones.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
            .prefix(maxPartsPerElement))
        let keyRects = Array(
            ordered.filter { $0.style == .outline }
                .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
                .prefix(maxKeysPerElement)
                .map(\.rect)
        )
        let count = ordered.count
        let windowLength = partsWindow.upperBound - partsWindow.lowerBound
        let partLength = min(0.2, windowLength * 0.6)
        return ordered.enumerated().map { index, bone -> Part in
            let start = partsWindow.lowerBound
                + (count > 1 ? (windowLength - partLength) * (Double(index) / Double(count - 1)) : 0)
            let key = keyRects.contains(bone.rect)
            let kind: Part.Kind
            let strokes: [Stroke]
            if bone.style == .outline {
                kind = .frame
                strokes = key
                    ? [Stroke(path: .half(of: bone.rect, radius: bone.radius, right: true), gap: wireGap, index: 0, caps: false),
                       Stroke(path: .half(of: bone.rect, radius: bone.radius, right: false), gap: wireGap, index: 0, caps: false)]
                    : [Stroke(path: .roundedRect(bone.rect, radius: bone.radius), gap: wireGap, index: 0, caps: false)]
            } else if bone.rect.width <= 32, bone.rect.height <= 32, bone.rect.width <= bone.rect.height * 2 {
                kind = .button
                strokes = [Stroke(path: .roundedRect(bone.rect, radius: bone.radius), gap: wireGap, index: 0, caps: false)]
            } else {
                kind = .text
                let y = bone.rect.minY + bone.rect.height * 0.56
                strokes = [Stroke(path: .line(from: CGPoint(x: bone.rect.minX, y: y), to: CGPoint(x: bone.rect.maxX, y: y)),
                                  gap: wireGap, index: 0, caps: true)]
            }
            return Part(kind: kind, rect: bone.rect, key: key, strokes: strokes,
                        strokeCount: Set(strokes.map(\.index)).count, start: start, end: start + partLength)
        }
    }

    // MARK: Frame

    struct Frame {
        struct Dot {
            var center: CGPoint
            var radius: CGFloat
            var alpha: Double
            var strong: Bool
        }

        struct Handle {
            var center: CGPoint
            var size: CGFloat
            var alpha: Double
        }

        struct Reticle {
            var element: Int
            var rect: CGRect
            var arm: CGFloat
            var alpha: Double
        }

        struct Label {
            enum Kind { case readout, tag, coordinates, keyDimension }
            var kind: Kind
            var element: Int
            /// Which of the element's key boxes a `keyDimension` belongs to.
            var key: Int = 0
            var text: String
            /// Left end of the baseline.
            var baseline: CGPoint
            var alpha: Double
        }

        var field: [Dot] = []
        var wires: [Dot] = []
        var handles: [Handle] = []
        var reticles: [Reticle] = []
        var labels: [Label] = []
    }

    /// Everything to draw for one moment. `progress[i]` is element `i`'s
    /// fraction of the duration; `elapsedMs` drives the crawl and the rain.
    static func evaluate(_ scene: Scene, progress: [Double], elapsedMs: Double) -> Frame {
        var frame = Frame()
        guard !scene.elements.isEmpty else { return frame }
        let duration = duration * 1_000
        var reticles: [CGRect?] = []
        var reticleAlpha: [Double] = []
        var probes: [(x: CGFloat, alpha: Double)] = []
        var fronts: [CGFloat] = []
        var rain: [Double] = []
        var cleans: [Double] = []
        var fades: [Double] = []

        for (index, element) in scene.elements.enumerated() {
            let a = progress.indices.contains(index) ? progress[index] : 0
            let s = elapsedMs - Double(index) * elementStagger * 1_000
            let rect = element.rect
            let clean = 1 - smooth(cleanWindow.lowerBound, cleanWindow.upperBound, a)
            let fade = soft(span(revealWindow.lowerBound...(revealWindow.upperBound + 0.03), a))
            let wireAlpha = 1 - fade
            cleans.append(clean)
            fades.append(fade)
            fronts.append(CGFloat(eased(span(dotsWindow, a))) * (element.maxDistance + 60))
            rain.append(smooth(0.04, 0.2, a) * (1 - smooth(0.62, 0.86, a)))

            // Probe.
            let v = span(probeWindow, a)
            let probeX = lerp(rect.minX - margin, rect.maxX + margin, eased(v))
            let probeAlpha = v > 0 && v < 1 ? smooth(0, 0.1, v) * (1 - smooth(0.85, 1, v)) : 0
            probes.append((probeX, probeAlpha))
            if probeAlpha > 0 {
                let probe = SampledPath.line(from: CGPoint(x: probeX, y: rect.minY - margin),
                                             to: CGPoint(x: probeX, y: rect.maxY + margin))
                for dot in trace(probe, progress: 1, elapsedMs: s, gap: wireGap).dots {
                    frame.wires.append(.init(center: dot, radius: wireDotRadius, alpha: probeAlpha * 0.8, strong: false))
                }
            }

            // Guides.
            let guideAlpha = 0.5 * (1 - smooth(0.66, 0.92, a))
            let guideLength = guidesWindow.upperBound - guidesWindow.lowerBound - 0.09
            for (g, guide) in element.guides.enumerated() {
                let p = eased(clamp((a - guidesWindow.lowerBound - Double(g) * 0.03) / guideLength))
                guard p > 0, guideAlpha > 0 else { continue }
                for dot in trace(guide, progress: p, elapsedMs: s, gap: guideGap).dots {
                    frame.wires.append(.init(center: dot, radius: wireDotRadius, alpha: guideAlpha, strong: false))
                }
            }

            // Outline, its heads, and the readout counting up with it.
            let q = eased(span(outlineWindow, a))
            var liveHead: CGPoint?
            for half in element.halves {
                let traced = trace(half, progress: q, elapsedMs: s, gap: wireGap)
                for dot in traced.dots {
                    frame.wires.append(.init(center: dot, radius: wireDotRadius, alpha: wireAlpha, strong: false))
                }
                if let head = traced.head {
                    frame.wires.append(.init(center: head, radius: outlineHeadRadius, alpha: wireAlpha, strong: true))
                    liveHead = head
                }
            }
            frame.labels.append(.init(
                kind: .readout, element: index,
                text: SkeletonConstruction.readout(width: rect.width * CGFloat(q), height: rect.height * CGFloat(q),
                                                   time: min(a, 1) * duration / 1_000),
                baseline: element.readoutAnchor,
                alpha: a > outlineWindow.lowerBound ? (1 - smooth(0.66, 0.9, a)) * 0.9 : 0
            ))

            // Corner handles pop in, the top pair first.
            for (corner, at) in [(CGPoint(x: rect.minX, y: rect.minY), 0.17), (CGPoint(x: rect.maxX, y: rect.minY), 0.17),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), 0.37), (CGPoint(x: rect.minX, y: rect.maxY), 0.37)] {
                let scale = eased(clamp((a - at) / 0.1)) * (1 - smooth(0.82, 0.96, a))
                if scale > 0.01 {
                    frame.handles.append(.init(center: corner, size: handleSize * CGFloat(scale), alpha: 1))
                }
            }

            // Flyers arrive as the trace reaches their spot.
            for flyer in element.flyers where a >= flyer.start && a < flyer.arrival + 0.01 {
                let i = clamp((a - flyer.start) / (flyer.arrival - flyer.start))
                let e = eased(i)
                frame.wires.append(.init(
                    center: CGPoint(x: lerp(flyer.from.x, flyer.to.x, e), y: lerp(flyer.from.y, flyer.to.y, e)),
                    radius: flyerRadius, alpha: smooth(0, 0.25, i), strong: true
                ))
            }

            // Parts trace in, each stroke staggered inside its part.
            let keyFade = 1 - smooth(revealWindow.lowerBound - 0.02, revealWindow.lowerBound + 0.1, a)
            var keyIndex = 0
            for part in element.parts {
                let i = clamp((a - part.start) / (part.end - part.start))
                for stroke in part.strokes {
                    let p = eased(clamp(i * Double(part.strokeCount) - Double(stroke.index) * 0.75))
                    let traced = trace(stroke.path, progress: p, elapsedMs: s, gap: stroke.gap)
                    for dot in traced.dots {
                        frame.wires.append(.init(center: dot, radius: wireDotRadius, alpha: wireAlpha, strong: false))
                    }
                    if let head = traced.head {
                        frame.wires.append(.init(center: head, radius: partHeadRadius, alpha: wireAlpha, strong: true))
                        liveHead = head
                    }
                    if stroke.caps, p > 0 {
                        frame.wires.append(.init(center: stroke.path.point(at: 0), radius: capRadius,
                                                 alpha: wireAlpha, strong: true))
                        if p >= 1 {
                            frame.wires.append(.init(center: stroke.path.point(at: stroke.path.length), radius: capRadius,
                                                     alpha: wireAlpha, strong: true))
                        }
                    }
                }
                guard part.key else { continue }
                // Key chrome: guides past the corners, handles, a size that counts up.
                let guideStart = part.start - 0.03
                let handleScale = eased(clamp((a - part.start - 0.04) / 0.08))
                let grown = eased(i)
                let b = keyGuideReach
                let box = part.rect
                let keyGuides = [
                    SampledPath.line(from: CGPoint(x: box.minX - b, y: box.minY), to: CGPoint(x: box.maxX + b, y: box.minY)),
                    SampledPath.line(from: CGPoint(x: box.maxX, y: box.minY - b), to: CGPoint(x: box.maxX, y: box.maxY + b)),
                    SampledPath.line(from: CGPoint(x: box.maxX + b, y: box.maxY), to: CGPoint(x: box.minX - b, y: box.maxY)),
                    SampledPath.line(from: CGPoint(x: box.minX, y: box.maxY + b), to: CGPoint(x: box.minX, y: box.minY - b)),
                ]
                for (g, guide) in keyGuides.enumerated() {
                    let p = eased(clamp((a - guideStart - Double(g) * 0.012) / 0.1))
                    guard p > 0, keyFade > 0 else { continue }
                    for dot in trace(guide, progress: p, elapsedMs: s, gap: guideGap).dots {
                        frame.wires.append(.init(center: dot, radius: wireDotRadius, alpha: 0.5 * keyFade, strong: false))
                    }
                }
                let scale = handleScale * keyFade
                if scale > 0.01 {
                    for corner in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                                   CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)] {
                        frame.handles.append(.init(center: corner, size: keyHandleSize * CGFloat(scale), alpha: 1))
                    }
                }
                frame.labels.append(.init(
                    kind: .keyDimension, element: index, key: keyIndex,
                    text: SkeletonConstruction.dimension(width: box.width * CGFloat(grown), height: box.height * CGFloat(grown)),
                    baseline: CGPoint(x: box.minX, y: box.minY - 5),
                    alpha: a > guideStart ? 0.9 * keyFade : 0
                ))
                keyIndex += 1
            }

            // The reticle frames the part under construction; its tag names it.
            let current = element.parts.lastIndex { a >= $0.start }
            var reticle: CGRect?
            var tagAlpha = 0.0
            if let current, a < revealWindow.lowerBound + 0.06 {
                let part = element.parts[current]
                let previous = current > 0 ? element.parts[current - 1].rect : rect
                let h = eased(clamp((a - part.start) / 0.05))
                let box = CGRect(
                    x: lerp(previous.minX, part.rect.minX, h), y: lerp(previous.minY, part.rect.minY, h),
                    width: lerp(previous.width, part.rect.width, h), height: lerp(previous.height, part.rect.height, h)
                ).insetBy(dx: -reticleInset, dy: -reticleInset)
                tagAlpha = smooth(partsWindow.lowerBound, partsWindow.lowerBound + 0.04, a)
                    * (1 - smooth(revealWindow.lowerBound, revealWindow.lowerBound + 0.06, a))
                reticle = box
                frame.reticles.append(.init(element: index, rect: box, arm: min(7, box.width / 3, box.height / 3),
                                            alpha: tagAlpha))
                frame.labels.append(.init(
                    kind: .tag, element: index,
                    text: SkeletonConstruction.tag(name: part.name, width: part.rect.width, height: part.rect.height),
                    baseline: CGPoint(x: box.minX, y: box.minY - 4), alpha: tagAlpha
                ))
            }
            reticles.append(reticle)
            reticleAlpha.append(tagAlpha)

            // The coordinate readout rides with whichever head is live.
            frame.labels.append(.init(
                kind: .coordinates, element: index,
                text: SkeletonConstruction.coordinates(x: (liveHead?.x ?? rect.minX) - rect.minX,
                                                       y: (liveHead?.y ?? rect.minY) - rect.minY),
                baseline: CGPoint(x: (liveHead?.x ?? rect.minX) + 6, y: (liveHead?.y ?? rect.minY) - 5),
                alpha: liveHead == nil ? 0 : 1
            ))
        }

        // The field: wavefront, ring, rain, reticle glow and probe glow.
        frame.field.reserveCapacity(scene.dots.count)
        for dot in scene.dots {
            let index = dot.element
            let element = scene.elements[index]
            let a = progress.indices.contains(index) ? progress[index] : 0
            let s = elapsedMs - Double(index) * elementStagger * 1_000
            let behind = Double(fronts[index] - dot.distance)
            let shown = clamp(behind / 50)
            guard shown > 0 else { continue }
            let ring = a < dotsWindow.upperBound + 0.05 ? exp(-pow((behind - 6) / 14, 2)) : 0
            let spanLength = Double(element.rect.height + 2 * margin)
            let trailY = (s * dot.speed + dot.phase).truncatingRemainder(dividingBy: spanLength + dot.trail) - Double(margin)
            let along = trailY - Double(dot.center.y - element.rect.minY)
            let trail = along >= 0 && along < dot.trail
                ? pow(1 - along / dot.trail, 1.6) * rain[index] * shown * Double(dot.edge) : 0
            var glow = 0.0
            if let box = reticles[index] {
                let outsideBox = max(box.minX - dot.center.x, dot.center.x - box.maxX,
                                     box.minY - dot.center.y, dot.center.y - box.maxY, 0)
                glow = max(0, 1 - Double(outsideBox) / 16) * (outsideBox == 0 ? 1 : 0.6) * reticleAlpha[index] * 0.8
            }
            let probe = probes[index].alpha > 0
                ? exp(-pow(Double(dot.center.x - probes[index].x) / 9, 2)) * probes[index].alpha * shown : 0
            let lit = max(ring, trail, glow, probe)
            let alpha = max(shown * 0.5 * Double(dot.edge), lit * Double(dot.edge)) * cleans[index] * (1 - fades[index])
            guard alpha > 0.005 else { continue }
            frame.field.append(.init(center: dot.center, radius: fieldDotRadius + fieldLitGrowth * CGFloat(lit),
                                     alpha: alpha, strong: lit > 0.35))
        }
        return frame
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
