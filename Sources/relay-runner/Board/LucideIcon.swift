import SwiftUI

// Renders the Lucide icons in LucideIcons.generated.swift (made by
// scripts/generate-lucide-icons.py) in the Graphical kit's outlined style:
// stroke width 1.5 on Lucide's 24-unit viewBox, scaled with the icon, round
// caps and joins, no fill.

/// One SVG child element of a Lucide icon, in the 24×24 viewBox.
enum LucideElement {
    case path(String)
    case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
    case ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat)
    /// A missing `rx` or `ry` takes the other's value, as in SVG.
    case rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, rx: CGFloat? = nil, ry: CGFloat? = nil)
    case line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
    /// Flat x, y pairs.
    case polyline([CGFloat])
    case polygon([CGFloat])
    /// An element Lucide fills with `currentColor` as well as stroking, such as
    /// the dot in key-round.
    indirect case filled(LucideElement)
}

/// An icon's outline in viewBox units: every element is stroked, and the
/// `filled` ones are also filled.
struct LucideGeometry {
    var stroke = Path()
    var fill = Path()
}

extension LucideGeometry {
    init(elements: [LucideElement]) throws {
        self.init()
        for element in elements {
            try add(element, filled: false)
        }
    }

    private mutating func add(_ element: LucideElement, filled: Bool) throws {
        var shape = Path()
        switch element {
        case .path(let data):
            shape = try LucidePathParser.parse(data)
        case .circle(let cx, let cy, let r):
            shape.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        case .ellipse(let cx, let cy, let rx, let ry):
            shape.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
        case .rect(let x, let y, let width, let height, let rx, let ry):
            guard width > 0, height > 0 else { return }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            let cornerWidth = min(max(rx ?? ry ?? 0, 0), width / 2)
            let cornerHeight = min(max(ry ?? rx ?? 0, 0), height / 2)
            if cornerWidth > 0, cornerHeight > 0 {
                shape.addPath(Path(CGPath(roundedRect: rect, cornerWidth: cornerWidth,
                                          cornerHeight: cornerHeight, transform: nil)))
            } else {
                shape.addRect(rect)
            }
        case .line(let x1, let y1, let x2, let y2):
            shape.move(to: CGPoint(x: x1, y: y1))
            shape.addLine(to: CGPoint(x: x2, y: y2))
        case .polyline(let coordinates), .polygon(let coordinates):
            let points = stride(from: 0, to: coordinates.count - 1, by: 2).map {
                CGPoint(x: coordinates[$0], y: coordinates[$0 + 1])
            }
            shape.addLines(points)
            if case .polygon = element { shape.closeSubpath() }
        case .filled(let inner):
            try add(inner, filled: true)
            return
        }
        stroke.addPath(shape)
        if filled { fill.addPath(shape) }
    }
}

extension LucideIcon {
    /// The icon's outline in viewBox units. Every icon is parsed once, on first use.
    var geometry: LucideGeometry { Self.geometries[self] ?? LucideGeometry() }

    private static let geometries: [LucideIcon: LucideGeometry] = Dictionary(
        uniqueKeysWithValues: allCases.map { icon -> (LucideIcon, LucideGeometry) in
            do {
                return (icon, try LucideGeometry(elements: icon.elements))
            } catch {
                assertionFailure("Lucide icon \(icon.rawValue): \(error)")
                return (icon, LucideGeometry())
            }
        }
    )
}

/// A Lucide icon's outline, aspect-fitted from the 24×24 viewBox into the
/// shape's rect. `LucideImage` strokes it with Lucide's styling.
struct LucideShape: Shape {
    let icon: LucideIcon
    /// `true` gives only the elements Lucide also fills, such as the dot in
    /// key-round; `false` gives every element, for stroking.
    var filledElementsOnly = false

    func path(in rect: CGRect) -> Path {
        let geometry = icon.geometry
        return (filledElementsOnly ? geometry.fill : geometry.stroke)
            .applying(Self.viewBoxTransform(into: rect))
    }

    /// Maps the 24×24 viewBox into `rect`, centred, keeping its aspect ratio.
    static func viewBoxTransform(into rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / 24
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: rect.midX - 12 * scale, ty: rect.midY - 12 * scale)
    }
}

/// A Lucide icon in a fixed `size`×`size` frame, coloured by the inherited
/// `foregroundStyle`. For an inline control icon pass the label's font size.
/// It is hidden from accessibility: label the control that contains it.
struct LucideImage: View {
    let icon: LucideIcon
    let size: CGFloat
    let strokeWidth: CGFloat

    /// `strokeWidth` is in viewBox units, so it scales with `size`.
    init(_ icon: LucideIcon, size: CGFloat, strokeWidth: CGFloat = 1.5) {
        self.icon = icon
        self.size = size
        self.strokeWidth = strokeWidth
    }

    var body: some View {
        ZStack {
            if !icon.geometry.fill.isEmpty {
                LucideShape(icon: icon, filledElementsOnly: true).fill()
            }
            LucideShape(icon: icon)
                .stroke(style: StrokeStyle(lineWidth: strokeWidth * size / 24,
                                           lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Parses SVG path data into a `Path`: every command (M L H V C S Q T A Z),
/// absolute and relative, with elliptical arcs converted to cubic Béziers.
/// Accepts the compact forms SVG allows, such as `1.5.5`, `-1-1`, `2e-3` and
/// packed arc flags (`a2 2 0 012 2`).
enum LucidePathParser {
    struct SyntaxError: Error, CustomStringConvertible {
        let reason: String
        let offset: Int
        var description: String { "\(reason) at offset \(offset)" }
    }

    static func parse(_ data: String) throws -> Path {
        var reader = Reader(bytes: Array(data.utf8))
        var builder = Builder()
        var command: UInt8?
        while true {
            reader.skipSeparators()
            guard let byte = reader.peek else { break }
            if Reader.isCommand(byte) {
                if command == nil, byte | 0x20 != ascii("m") {
                    throw reader.error("path data must start with a moveto")
                }
                reader.index += 1
                command = byte
            } else {
                // Bare numbers repeat the previous command; after a moveto
                // they are linetos.
                guard let previous = command, previous | 0x20 != ascii("z") else {
                    throw reader.error("expected a command")
                }
                if previous == ascii("M") { command = ascii("L") }
                if previous == ascii("m") { command = ascii("l") }
            }
            if let command { try builder.apply(command, from: &reader) }
        }
        return builder.path
    }

    private static func ascii(_ character: Unicode.Scalar) -> UInt8 { UInt8(ascii: character) }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        static func isCommand(_ byte: UInt8) -> Bool {
            "MmZzLlHhVvCcSsQqTtAa".utf8.contains(byte)
        }

        func error(_ reason: String) -> SyntaxError { SyntaxError(reason: reason, offset: index) }

        mutating func skipSeparators() {
            while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A
                    || byte == 0x0C || byte == 0x0D || byte == ascii(",") {
                index += 1
            }
        }

        mutating func number() throws -> CGFloat {
            skipSeparators()
            let start = index
            if let sign = peek, sign == ascii("+") || sign == ascii("-") { index += 1 }
            var digits = skipDigits()
            if peek == ascii(".") {
                index += 1
                digits += skipDigits()
            }
            guard digits > 0 else {
                index = start
                throw error("expected a number")
            }
            if let marker = peek, marker == ascii("e") || marker == ascii("E") {
                var next = index + 1
                if next < bytes.count, bytes[next] == ascii("+") || bytes[next] == ascii("-") { next += 1 }
                if next < bytes.count, Self.isDigit(bytes[next]) {
                    index = next
                    _ = skipDigits()
                }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw SyntaxError(reason: "malformed number", offset: start)
            }
            return CGFloat(value)
        }

        /// An arc flag is a single 0 or 1 and needs no separator after it.
        mutating func flag() throws -> Bool {
            skipSeparators()
            switch peek {
            case ascii("0"): index += 1; return false
            case ascii("1"): index += 1; return true
            default: throw error("expected an arc flag")
            }
        }

        mutating func point(from origin: CGPoint) throws -> CGPoint {
            let x = try number()
            let y = try number()
            return CGPoint(x: origin.x + x, y: origin.y + y)
        }

        private mutating func skipDigits() -> Int {
            let start = index
            while let byte = peek, Self.isDigit(byte) { index += 1 }
            return index - start
        }

        private static func isDigit(_ byte: UInt8) -> Bool { byte >= ascii("0") && byte <= ascii("9") }
    }

    private struct Builder {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// After a closepath, the next drawing command starts a new subpath there.
        var needsMove = false
        /// The previous segment's last control point, for S and T reflection.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        mutating func apply(_ command: UInt8, from reader: inout Reader) throws {
            let lowercase = command | 0x20
            let origin = command == lowercase ? current : .zero
            var cubicControl: CGPoint?
            var quadControl: CGPoint?
            if lowercase != ascii("m"), lowercase != ascii("z"), needsMove {
                path.move(to: current)
                needsMove = false
            }
            switch lowercase {
            case ascii("m"):
                let point = try reader.point(from: origin)
                path.move(to: point)
                current = point
                subpathStart = point
                needsMove = false
            case ascii("l"):
                lineTo(try reader.point(from: origin))
            case ascii("h"):
                lineTo(CGPoint(x: origin.x + (try reader.number()), y: current.y))
            case ascii("v"):
                lineTo(CGPoint(x: current.x, y: origin.y + (try reader.number())))
            case ascii("c"):
                let control1 = try reader.point(from: origin)
                let control2 = try reader.point(from: origin)
                let end = try reader.point(from: origin)
                path.addCurve(to: end, control1: control1, control2: control2)
                current = end
                cubicControl = control2
            case ascii("s"):
                let control1 = reflected(lastCubicControl)
                let control2 = try reader.point(from: origin)
                let end = try reader.point(from: origin)
                path.addCurve(to: end, control1: control1, control2: control2)
                current = end
                cubicControl = control2
            case ascii("q"):
                let control = try reader.point(from: origin)
                let end = try reader.point(from: origin)
                path.addQuadCurve(to: end, control: control)
                current = end
                quadControl = control
            case ascii("t"):
                let control = reflected(lastQuadControl)
                let end = try reader.point(from: origin)
                path.addQuadCurve(to: end, control: control)
                current = end
                quadControl = control
            case ascii("a"):
                let rx = try reader.number()
                let ry = try reader.number()
                let rotation = try reader.number()
                let largeArc = try reader.flag()
                let sweep = try reader.flag()
                let end = try reader.point(from: origin)
                arc(to: end, rx: rx, ry: ry, rotation: rotation, largeArc: largeArc, sweep: sweep)
            default: // z
                path.closeSubpath()
                current = subpathStart
                needsMove = true
            }
            lastCubicControl = cubicControl
            lastQuadControl = quadControl
        }

        private mutating func lineTo(_ point: CGPoint) {
            path.addLine(to: point)
            current = point
        }

        /// The previous control point reflected through the current point, or
        /// the current point when the previous segment was another kind.
        private func reflected(_ control: CGPoint?) -> CGPoint {
            guard let control else { return current }
            return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
        }

        /// Endpoint-to-centre conversion from SVG 1.1 implementation notes
        /// F.6.5 and F.6.6, then one cubic per quarter turn or less.
        private mutating func arc(to end: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat,
                                  largeArc: Bool, sweep: Bool) {
            let start = current
            current = end
            guard start != end else { return }
            var rx = abs(rx)
            var ry = abs(ry)
            guard rx > 0, ry > 0 else {
                path.addLine(to: end)
                return
            }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi)
            let sinPhi = sin(phi)
            let halfDX = (start.x - end.x) / 2
            let halfDY = (start.y - end.y) / 2
            let x1 = cosPhi * halfDX + sinPhi * halfDY
            let y1 = -sinPhi * halfDX + cosPhi * halfDY

            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                rx *= lambda.squareRoot()
                ry *= lambda.squareRoot()
            }
            let rx2 = rx * rx
            let ry2 = ry * ry
            let numerator = rx2 * ry2 - rx2 * y1 * y1 - ry2 * x1 * x1
            let denominator = rx2 * y1 * y1 + ry2 * x1 * x1
            var coefficient = (max(0, numerator) / denominator).squareRoot()
            if largeArc == sweep { coefficient = -coefficient }
            let centerX1 = coefficient * rx * y1 / ry
            let centerY1 = -coefficient * ry * x1 / rx
            let centerX = cosPhi * centerX1 - sinPhi * centerY1 + (start.x + end.x) / 2
            let centerY = sinPhi * centerX1 + cosPhi * centerY1 + (start.y + end.y) / 2

            let ux = (x1 - centerX1) / rx
            let uy = (y1 - centerY1) / ry
            let vx = (-x1 - centerX1) / rx
            let vy = (-y1 - centerY1) / ry
            let startAngle = atan2(uy, ux)
            var sweepAngle = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
            if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

            func onEllipse(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: centerX + rx * x * cosPhi - ry * y * sinPhi,
                        y: centerY + rx * x * sinPhi + ry * y * cosPhi)
            }
            let segments = max(1, Int((abs(sweepAngle) / (.pi / 2) - 1e-9).rounded(.up)))
            let delta = sweepAngle / CGFloat(segments)
            let handle = 4 / 3 * tan(delta / 4)
            var angle = startAngle
            for segment in 0..<segments {
                let next = angle + delta
                let control1 = onEllipse(cos(angle) - handle * sin(angle), sin(angle) + handle * cos(angle))
                let control2 = onEllipse(cos(next) + handle * sin(next), sin(next) - handle * cos(next))
                let point = segment == segments - 1 ? end : onEllipse(cos(next), sin(next))
                path.addCurve(to: point, control1: control1, control2: control2)
                angle = next
            }
        }
    }
}
