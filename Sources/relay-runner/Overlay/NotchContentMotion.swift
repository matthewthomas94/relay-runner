import Accelerate
import AppKit
import QuartzCore

/// Eased transitions for the notch's drawn content. Copy crossfades
/// horizontally through a blur, glyph dots emerge from and retract into the
/// core while colours blend, looping glyph motion settles at rest, and the
/// hover disc fades.
struct NotchContentMotion {
    struct RGB: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        func mixed(with other: RGB, amount: CGFloat) -> RGB {
            RGB(
                red: red + (other.red - red) * amount,
                green: green + (other.green - green) * amount,
                blue: blue + (other.blue - blue) * amount
            )
        }
    }

    struct DepartingLabel: Equatable {
        let text: String
        let width: CGFloat
        let startedAt: CFTimeInterval
        let startAlpha: CGFloat
    }

    struct LabelAppearance: Equatable {
        let alpha: CGFloat
        let offset: CGFloat
        let blur: CGFloat

        static let resting = LabelAppearance(alpha: 1, offset: 0, blur: 0)
    }

    struct RenderedDot: Equatable {
        let center: CGPoint
        let diameter: CGFloat
        let color: RGB
        let alpha: CGFloat
        /// Extra soft edge while a dot is still "out of focus".
        let softness: CGFloat
        let index: Int
    }

    /// Status copy (Listening, Playing, …) is the one place text slides
    /// horizontally; everything else in the app rises and sinks.
    static let labelStyle = RelayMotion.Style(
        axis: .horizontal,
        distance: RelayMotion.Style.text.distance,
        blurRadius: RelayMotion.Style.text.blurRadius
    )
    static let glyphChangeDuration = max(RelayMotion.enterDuration, RelayMotion.changeDuration)
    static let maximumDotSoftness: CGFloat = 1.5
    static let coreCenters = [
        CGPoint(x: 14.5, y: 9.5),
        CGPoint(x: 9.5, y: 9.5),
        CGPoint(x: 9.5, y: 14.5),
        CGPoint(x: 14.5, y: 14.5),
    ]

    private(set) var departingLabels: [DepartingLabel] = []
    private(set) var labelArrivedAt: CFTimeInterval?
    private(set) var glyphSource: NotchStatusGlyph?
    private(set) var glyphChangedAt: CFTimeInterval = 0
    private(set) var settlingStatus: NotchSessionStatus?
    private(set) var settleDeadline: CFTimeInterval = 0
    private var presenceVisible = true
    private var presenceChangedAt: CFTimeInterval?
    private var presenceDuration: TimeInterval = 0
    private var hoverTarget = false
    private var hoverFrom: CGFloat = 0
    private var hoverChangedAt: CFTimeInterval?

    static func isCore(_ point: CGPoint) -> Bool {
        coreCenters.contains(point)
    }

    // MARK: Copy

    /// The outgoing label leaves first; its replacement arrives once it has gone.
    mutating func labelChanged(from old: String?, width: CGFloat, to new: String?, now: CFTimeInterval) {
        var arrival = now
        if let old, !old.isEmpty, width > 0 {
            departingLabels.append(DepartingLabel(
                text: old,
                width: width,
                startedAt: now,
                startAlpha: arrivalAppearance(now: now, reduceMotion: false).alpha
            ))
            if departingLabels.count > 2 {
                departingLabels.removeFirst(departingLabels.count - 2)
            }
            arrival += RelayMotion.replacementDelay
        }
        labelArrivedAt = new?.isEmpty == false ? arrival : nil
    }

    func arrivalAppearance(now: CFTimeInterval, reduceMotion: Bool) -> LabelAppearance {
        guard let labelArrivedAt else { return .resting }
        let progress = RelayMotion.enterCurve.progress(
            CGFloat((now - labelArrivedAt) / RelayMotion.enterDuration)
        )
        return appearance(hiddenAmount: 1 - progress, alpha: progress, reduceMotion: reduceMotion)
    }

    func departureAppearance(
        of label: DepartingLabel,
        now: CFTimeInterval,
        reduceMotion: Bool
    ) -> LabelAppearance {
        let progress = RelayMotion.exitCurve.progress(
            CGFloat((now - label.startedAt) / RelayMotion.exitDuration)
        )
        return appearance(
            hiddenAmount: progress,
            alpha: label.startAlpha * (1 - progress),
            reduceMotion: reduceMotion
        )
    }

    private func appearance(hiddenAmount: CGFloat, alpha: CGFloat, reduceMotion: Bool) -> LabelAppearance {
        let style = Self.labelStyle
        return LabelAppearance(
            alpha: alpha,
            offset: reduceMotion ? 0 : style.distance * hiddenAmount,
            blur: reduceMotion ? 0 : style.blurRadius * hiddenAmount
        )
    }

    // MARK: Surface presence

    mutating func setPresence(visible: Bool, duration: TimeInterval, now: CFTimeInterval) {
        presenceVisible = visible
        presenceChangedAt = now
        presenceDuration = duration
    }

    func presenceBlur(now: CFTimeInterval, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, let presenceChangedAt, presenceDuration > 0 else { return 0 }
        let fraction = CGFloat((now - presenceChangedAt) / presenceDuration)
        let radius = Self.labelStyle.blurRadius
        return presenceVisible
            ? radius * (1 - RelayMotion.enterCurve.progress(fraction))
            : radius * RelayMotion.exitCurve.progress(fraction)
    }

    // MARK: Glyph

    mutating func glyphChanged(from old: NotchStatusGlyph, now: CFTimeInterval) {
        glyphSource = old
        glyphChangedAt = now
    }

    /// Looping motion that stops finishes its current cycle, which always
    /// ends at the resting artwork, instead of snapping mid-turn.
    mutating func statusChanged(
        from old: NotchSessionStatus,
        to new: NotchSessionStatus,
        now: CFTimeInterval,
        reduceMotion: Bool
    ) {
        if new.animatesGlyphMotion || reduceMotion {
            settlingStatus = nil
        } else if old.animatesGlyphMotion {
            let phase = NotchStatusGlyphMotion.phase(at: now)
            settlingStatus = old
            settleDeadline = now + TimeInterval(1 - phase) * NotchStatusGlyphMotion.duration
        }
    }

    func motionStatus(for status: NotchSessionStatus, now: CFTimeInterval) -> NotchSessionStatus {
        if !status.animatesGlyphMotion, let settlingStatus, now < settleDeadline {
            return settlingStatus
        }
        return status
    }

    func glyphDots(
        target: NotchStatusGlyph,
        now: CFTimeInterval,
        reduceMotion: Bool,
        center: (CGPoint) -> CGPoint
    ) -> [RenderedDot] {
        let targetDots = target.dots
        let elapsed = now - glyphChangedAt
        guard let source = glyphSource, source != target, elapsed < Self.glyphChangeDuration else {
            return targetDots.enumerated().map { index, dot in
                RenderedDot(
                    center: center(Self.point(dot)),
                    diameter: dot.diameter,
                    color: dot.color.rgb,
                    alpha: dot.opacity,
                    softness: 0,
                    index: index
                )
            }
        }

        let enter = RelayMotion.enterCurve.progress(CGFloat(elapsed / RelayMotion.enterDuration))
        let exit = RelayMotion.exitCurve.progress(CGFloat(elapsed / RelayMotion.exitDuration))
        let change = RelayMotion.changeCurve.progress(CGFloat(elapsed / RelayMotion.changeDuration))
        let targetPoints = Set(targetDots.map { DotKey(Self.point($0)) })
        var sourceByPoint: [DotKey: NotchStatusGlyphDot] = [:]
        for dot in source.dots where sourceByPoint[DotKey(Self.point(dot))] == nil {
            sourceByPoint[DotKey(Self.point(dot))] = dot
        }
        var dots: [RenderedDot] = []

        // Dots the new glyph no longer uses retract into the core.
        for (index, dot) in source.dots.enumerated()
        where !targetPoints.contains(DotKey(Self.point(dot))) {
            let resting = Self.point(dot)
            let travel = reduceMotion ? 0 : exit
            dots.append(RenderedDot(
                center: Self.interpolate(center(resting), center(Self.nearestCore(to: resting)), travel),
                diameter: dot.diameter,
                color: dot.color.rgb,
                alpha: dot.opacity * (1 - exit),
                softness: reduceMotion ? 0 : Self.maximumDotSoftness * exit,
                index: index
            ))
        }

        for (index, dot) in targetDots.enumerated() {
            let resting = Self.point(dot)
            if let previous = sourceByPoint[DotKey(resting)] {
                dots.append(RenderedDot(
                    center: center(resting),
                    diameter: dot.diameter,
                    color: previous.color.rgb.mixed(with: dot.color.rgb, amount: change),
                    alpha: previous.opacity + (dot.opacity - previous.opacity) * change,
                    softness: 0,
                    index: index
                ))
            } else {
                // New dots emerge from the core they belong to.
                let travel = reduceMotion ? 1 : enter
                dots.append(RenderedDot(
                    center: Self.interpolate(center(Self.nearestCore(to: resting)), center(resting), travel),
                    diameter: dot.diameter,
                    color: dot.color.rgb,
                    alpha: dot.opacity * enter,
                    softness: reduceMotion ? 0 : Self.maximumDotSoftness * (1 - enter),
                    index: index
                ))
            }
        }
        return dots
    }

    // MARK: Hover

    mutating func hoverChanged(to hovered: Bool, now: CFTimeInterval) {
        hoverFrom = hoverAmount(now: now)
        hoverTarget = hovered
        hoverChangedAt = now
    }

    func hoverAmount(now: CFTimeInterval) -> CGFloat {
        let target: CGFloat = hoverTarget ? 1 : 0
        guard let hoverChangedAt else { return target }
        let progress = RelayMotion.changeCurve.progress(
            CGFloat((now - hoverChangedAt) / RelayMotion.hoverDuration)
        )
        return hoverFrom + (target - hoverFrom) * progress
    }

    // MARK: Lifecycle

    func isAnimating(now: CFTimeInterval) -> Bool {
        if departingLabels.contains(where: { now - $0.startedAt < RelayMotion.exitDuration }) { return true }
        if let labelArrivedAt, now - labelArrivedAt < RelayMotion.enterDuration { return true }
        if glyphSource != nil, now - glyphChangedAt < Self.glyphChangeDuration { return true }
        if settlingStatus != nil, now < settleDeadline { return true }
        if let presenceChangedAt, now - presenceChangedAt < presenceDuration { return true }
        if let hoverChangedAt, now - hoverChangedAt < RelayMotion.hoverDuration { return true }
        return false
    }

    mutating func prune(now: CFTimeInterval) {
        departingLabels.removeAll { now - $0.startedAt >= RelayMotion.exitDuration }
        if glyphSource != nil, now - glyphChangedAt >= Self.glyphChangeDuration {
            glyphSource = nil
        }
        if settlingStatus != nil, now >= settleDeadline {
            settlingStatus = nil
        }
    }

    // MARK: Geometry

    private struct DotKey: Hashable {
        let x: CGFloat
        let y: CGFloat

        init(_ point: CGPoint) {
            x = point.x
            y = point.y
        }
    }

    private static func point(_ dot: NotchStatusGlyphDot) -> CGPoint {
        CGPoint(x: dot.x, y: dot.y)
    }

    static func nearestCore(to point: CGPoint) -> CGPoint {
        coreCenters.min { lhs, rhs in
            hypot(lhs.x - point.x, lhs.y - point.y) < hypot(rhs.x - point.x, rhs.y - point.y)
        } ?? point
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, _ progress: CGFloat) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
}

/// Draws notch copy, blurring it while it transitions. The blur is a vImage
/// tent convolution on a small bitmap (no GPU context to warm up), cached
/// per quarter-point of radius, so one transition costs a handful of
/// sub-millisecond renders.
final class NotchBlurredTextRenderer {
    static let shared = NotchBlurredTextRenderer()

    private struct Key: Hashable {
        let text: String
        let width: Int
        let height: Int
        let blurStep: Int
        let scale: Int
    }

    private var cache: [Key: NSImage] = [:]
    private var cacheOrder: [Key] = []
    private static let cacheLimit = 48

    func draw(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        in rect: NSRect,
        blur: CGFloat,
        alpha: CGFloat,
        scale: CGFloat
    ) {
        guard alpha > 0.001, rect.width > 0, rect.height > 0 else { return }
        let blurStep = Int((blur * 4).rounded())
        guard blurStep > 0 else {
            var faded = attributes
            let color = (attributes[.foregroundColor] as? NSColor) ?? .white
            faded[.foregroundColor] = color.withAlphaComponent(color.alphaComponent * alpha)
            (text as NSString).draw(in: rect, withAttributes: faded)
            return
        }

        let radius = CGFloat(blurStep) / 4
        let padding = Self.padding(for: radius)
        let key = Key(
            text: text,
            width: Int(rect.width.rounded()),
            height: Int(rect.height.rounded()),
            blurStep: blurStep,
            scale: Int((scale * 100).rounded())
        )
        let image = cache[key] ?? render(text, attributes: attributes, size: rect.size, radius: radius, scale: scale)
        guard let image else { return }
        if cache[key] == nil {
            cache[key] = image
            cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit {
                cache[cacheOrder.removeFirst()] = nil
            }
        }
        image.draw(
            in: rect.insetBy(dx: -padding, dy: -padding),
            from: .zero,
            operation: .sourceOver,
            fraction: alpha,
            respectFlipped: true,
            hints: nil
        )
    }

    private static func padding(for radius: CGFloat) -> CGFloat {
        ceil(radius * 3)
    }

    private func render(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        size: CGSize,
        radius: CGFloat,
        scale: CGFloat
    ) -> NSImage? {
        let padding = Self.padding(for: radius)
        let pointSize = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        let width = Int(ceil(pointSize.width * scale))
        let height = Int(ceil(pointSize.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let data = context.data else { return nil }

        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            in: NSRect(x: padding, y: padding, width: size.width, height: size.height),
            withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()

        let bytesPerRow = context.bytesPerRow
        guard let output = malloc(bytesPerRow * height) else { return nil }
        var source = vImage_Buffer(
            data: data,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
        var destination = vImage_Buffer(
            data: output,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bytesPerRow
        )
        // A tent (two box passes) of this width approximates a Gaussian
        // with the requested radius; every channel is premultiplied, so a
        // uniform convolution keeps the edges clean.
        let kernel = UInt32(max(1, Int((radius * scale * 1.2).rounded())) * 2 + 1)
        let error = vImageTentConvolve_ARGB8888(
            &source,
            &destination,
            nil,
            0,
            0,
            kernel,
            kernel,
            nil,
            vImage_Flags(kvImageEdgeExtend)
        )
        guard error == kvImageNoError,
              let provider = CGDataProvider(
                dataInfo: nil,
                data: output,
                size: bytesPerRow * height,
                releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }
              ),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            free(output)
            return nil
        }
        return NSImage(cgImage: image, size: pointSize)
    }
}
