import AppKit
import Darwin
import QuartzCore

enum BoardUpdateStatus {
    static let workingLabel = "Checking for updates"
}

struct NotchStatusDisplayGeometry: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let auxiliaryTopLeftArea: CGRect
    let auxiliaryTopRightArea: CGRect

    init(
        frame: CGRect,
        visibleFrame: CGRect? = nil,
        auxiliaryTopLeftArea: CGRect = .zero,
        auxiliaryTopRightArea: CGRect = .zero
    ) {
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    init(screen: NSScreen) {
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
        self.auxiliaryTopLeftArea = screen.auxiliaryTopLeftArea ?? .zero
        self.auxiliaryTopRightArea = screen.auxiliaryTopRightArea ?? .zero
    }
}

struct NotchStatusPlacement: Equatable {
    let visibleFrame: CGRect
    let retractedFrame: CGRect
    let activityLabelWidth: CGFloat
    let leadingSpacerWidth: CGFloat
    let notchSpacerWidth: CGFloat
    let glyphScreenX: CGFloat
}

enum NotchSessionStatus: String, Equatable {
    case notWorking = "Not working"
    case working = "Working"
    case listening = "Listening"
    case playing = "Playing"

    var glyph: NotchStatusGlyph {
        switch self {
        case .notWorking, .working:
            return .neutral
        case .listening:
            return .listening
        case .playing:
            return .playing
        }
    }

    var animatesGlyphMotion: Bool {
        self != .notWorking
    }

    var usesGlyphShimmer: Bool {
        self == .listening || self == .playing
    }

    static func resolve(
        for state: OverlayState,
        hasActivityLabels: Bool,
        boardIsLoading: Bool = false
    ) -> NotchSessionStatus {
        switch state {
        case .listening, .recording:
            return .listening
        case .messageWaiting, .preparing, .speaking:
            return .playing
        case .sent, .processing, .acknowledgement, .sessionPrompt, .sessionReady, .programStatus, .actionGlow:
            return .working
        default:
            return hasActivityLabels || boardIsLoading ? .working : .notWorking
        }
    }
}

enum NotchStatusGlyph: Equatable {
    case neutral
    case listening
    case playing

    static let artworkSize = CGSize(width: 24, height: 24)

    var dots: [NotchStatusGlyphDot] {
        switch self {
        case .neutral:
            return [
                NotchStatusGlyphDot(x: 14.5, y: 9.5, diameter: 3, color: .white, opacity: 1),
                NotchStatusGlyphDot(x: 9.5, y: 9.5, diameter: 3, color: .white, opacity: 1),
                NotchStatusGlyphDot(x: 9.5, y: 14.5, diameter: 3, color: .white, opacity: 1),
                NotchStatusGlyphDot(x: 14.5, y: 14.5, diameter: 3, color: .white, opacity: 1),
            ]
        case .listening:
            return Self.activityDots(accent: .orange)
        case .playing:
            return Self.activityDots(accent: .blue)
        }
    }

    private static func activityDots(accent: NotchStatusDotColor) -> [NotchStatusGlyphDot] {
        let dots: [(CGFloat, CGFloat, NotchStatusDotColor)] = [
            (14.5, 9.5, .white),
            (19.5, 9.5, accent),
            (14.5, 4.5, accent),
            (9.5, 9.5, .white),
            (4.5, 9.5, accent),
            (9.5, 4.5, accent),
            (9.5, 14.5, .white),
            (9.5, 19.5, accent),
            (4.5, 14.5, accent),
            (14.5, 14.5, .white),
            (14.5, 19.5, accent),
            (19.5, 14.5, accent),
        ]
        return dots.map { x, y, color in
            NotchStatusGlyphDot(x: x, y: y, diameter: 3, color: color, opacity: 1)
        }
    }
}

struct NotchStatusGlyphDot: Equatable {
    let x: CGFloat
    let y: CGFloat
    let diameter: CGFloat
    let color: NotchStatusDotColor
    let opacity: Double
}

enum NotchStatusDotColor: Equatable {
    case white
    case orange
    case blue
}

enum NotchStatusGlyphMotion {
    static let duration: TimeInterval = 0.6

    private static let artworkCenter = CGPoint(x: 12, y: 12)
    private static let accentKeyframe: CGFloat = 0.6667
    private static let rotationKeyframe: CGFloat = 0.6683
    private static let quarterTurn: CGFloat = .pi / 2
    private static let halfStepTurn: CGFloat = .pi / 4
    private static let svgLinearEaseSamples: [CGFloat] = [
        0, 0.0188, 0.0679, 0.1374, 0.2195, 0.308, 0.3978, 0.4856, 0.5686,
        0.6452, 0.7142, 0.7753, 0.8283, 0.8735, 0.9113, 0.9423, 0.9671,
        0.9866, 1.0014, 1.0123, 1.0198, 1.0247, 1.0274, 1.0283, 1.0281,
        1.0268, 1.025, 1.0227, 1.0202, 1.0177, 1.0152, 1.0128, 1.0106,
        1.0085, 1.0068, 1.0052, 1.0039, 1.0028, 1.0018, 1.0011, 1.0005,
        1, 0.9997, 0.9995, 0.9993, 0.9992, 0.9992, 0.9992, 0.9992,
        0.9993, 0.9993,
    ]

    static func phase(at time: TimeInterval) -> CGFloat {
        let raw = time.truncatingRemainder(dividingBy: duration)
        let positive = raw >= 0 ? raw : raw + duration
        return CGFloat(positive / duration)
    }

    static func coreRotation(for status: NotchSessionStatus, phase: CGFloat) -> CGFloat {
        guard status.animatesGlyphMotion else { return 0 }
        if phase <= rotationKeyframe {
            return halfStepTurn * svgEase(phase / rotationKeyframe)
        }
        let remainingProgress = (phase - rotationKeyframe) / (1 - rotationKeyframe)
        return halfStepTurn + halfStepTurn * svgEase(remainingProgress)
    }

    static func accentOffset(for dot: NotchStatusGlyphDot, status: NotchSessionStatus, phase: CGFloat) -> CGPoint {
        guard status == .listening || status == .playing,
              dot.color != .white else {
            return .zero
        }
        let vector = accentVector(for: dot)
        let amount: CGFloat
        if phase <= accentKeyframe {
            amount = svgEase(phase / accentKeyframe)
        } else {
            amount = 1 - svgEase((phase - accentKeyframe) / (1 - accentKeyframe))
        }
        return CGPoint(x: vector.x * amount, y: vector.y * amount)
    }

    static func transformedCenter(
        for dot: NotchStatusGlyphDot,
        status: NotchSessionStatus,
        phase: CGFloat
    ) -> CGPoint {
        var center = CGPoint(x: dot.x, y: dot.y)
        if dot.color == .white {
            center = rotated(center, by: coreRotation(for: status, phase: phase))
        } else {
            let offset = accentOffset(for: dot, status: status, phase: phase)
            center.x += offset.x
            center.y += offset.y
        }
        return center
    }

    private static func svgEase(_ progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return 0 }
        guard clamped < 1 else { return 1 }

        let scaled = clamped * CGFloat(svgLinearEaseSamples.count - 1)
        let lowerIndex = min(Int(floor(scaled)), svgLinearEaseSamples.count - 2)
        let fraction = scaled - CGFloat(lowerIndex)
        let lower = svgLinearEaseSamples[lowerIndex]
        let upper = svgLinearEaseSamples[lowerIndex + 1]
        return lower + (upper - lower) * fraction
    }

    private static func accentVector(for dot: NotchStatusGlyphDot) -> CGPoint {
        switch (dot.x, dot.y) {
        case (19.5, _):
            return CGPoint(x: 1, y: 0)
        case (4.5, _):
            return CGPoint(x: -1, y: 0)
        case (_, 4.5):
            return CGPoint(x: 0, y: -1)
        case (_, 19.5):
            return CGPoint(x: 0, y: 1)
        default:
            return .zero
        }
    }

    private static func rotated(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        guard angle != 0 else { return point }
        let translatedX = point.x - artworkCenter.x
        let translatedY = point.y - artworkCenter.y
        let cosine = Darwin.cos(angle)
        let sine = Darwin.sin(angle)
        return CGPoint(
            x: artworkCenter.x + translatedX * cosine - translatedY * sine,
            y: artworkCenter.y + translatedX * sine + translatedY * cosine
        )
    }
}

enum NotchStatusPlacementPlanner {
    static let glyphSize = CGSize(width: 30, height: 34)
    static let compactLeadingWingWidth: CGFloat = 19
    static let compactNotchLeadInWidth: CGFloat = 8
    static let compactNotchLeadOutWidth: CGFloat = 8
    static let fallbackNotchSpacerWidth: CGFloat = 190
    static let maximumActivityLabelWidth: CGFloat = 650
    static let maximumWorkingProgressLabelWidth: CGFloat = maximumActivityLabelWidth / 2
    static let fallbackSurfaceWidth: CGFloat =
        compactNotchLeadInWidth + fallbackNotchSpacerWidth + glyphSize.width + compactNotchLeadOutWidth

    private static let screenEdgeGap: CGFloat = 8
    private static let activityLabelMeasurementPadding: CGFloat =
        NotchActivityLabelRenderPolicy.textLeadingInset
        + NotchActivityLabelRenderPolicy.textRightGlyphClearance
        + 8

    static func placement(
        for geometry: NotchStatusDisplayGeometry,
        activityLabelWidth: CGFloat = 0
    ) -> NotchStatusPlacement? {
        let requestedLabelWidth = max(0, min(activityLabelWidth, maximumActivityLabelWidth))
        let notchFrame = notchFrame(for: geometry)
        let trailingLeadOutWidth = Self.compactNotchLeadOutWidth
        let leadingSpacerWidth = compactNotchLeadInWidth
        let notchSpacerWidth = notchFrame?.width ?? fallbackNotchSpacerWidth
        let compactSurfaceWidth =
            leadingSpacerWidth + notchSpacerWidth + glyphSize.width + trailingLeadOutWidth
        let desiredTrailingEdge = notchFrame.map {
            $0.maxX + glyphSize.width + trailingLeadOutWidth
        } ?? geometry.frame.midX + compactSurfaceWidth / 2
        let trailingEdge = min(
            desiredTrailingEdge,
            geometry.frame.maxX - screenEdgeGap
        )
        let availableSurfaceWidth = trailingEdge - geometry.frame.minX - screenEdgeGap

        guard compactSurfaceWidth <= availableSurfaceWidth else {
            return nil
        }

        // Keep the compact surface's trailing edge as the stable screen-space
        // anchor. If a label would cross the opposite screen edge, truncate
        // its allocation instead of allowing the glyph and right edge to move.
        let labelWidth = min(
            requestedLabelWidth,
            availableSurfaceWidth - compactSurfaceWidth
        )
        let surfaceWidth = compactSurfaceWidth + labelWidth
        let x = trailingEdge - surfaceWidth

        let surfaceTop = geometry.frame.maxY
        let preferredY = surfaceTop - glyphSize.height
        let maximumY = surfaceTop - glyphSize.height
        let y = max(
            geometry.frame.minY + screenEdgeGap,
            min(preferredY, maximumY)
        )

        let visibleFrame = CGRect(
            x: x,
            y: y,
            width: surfaceWidth,
            height: glyphSize.height
        )
        let glyphScreenX = trailingEdge - glyphSize.width - trailingLeadOutWidth
        let retractedFrame = CGRect(
            x: x,
            y: min(y + 2, maximumY),
            width: surfaceWidth,
            height: glyphSize.height
        )

        return NotchStatusPlacement(
            visibleFrame: visibleFrame,
            retractedFrame: retractedFrame,
            activityLabelWidth: labelWidth,
            leadingSpacerWidth: leadingSpacerWidth,
            notchSpacerWidth: notchSpacerWidth,
            glyphScreenX: glyphScreenX
        )
    }

    static func activityLabelWidth(for label: String?) -> CGFloat {
        guard let label,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0
        }
        let font = AppTypography.appKitFont(.notchStatus)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return min(maximumActivityLabelWidth, ceil(textWidth) + activityLabelMeasurementPadding)
    }

    private static func notchFrame(for geometry: NotchStatusDisplayGeometry) -> CGRect? {
        let leftArea = geometry.auxiliaryTopLeftArea
        let rightArea = geometry.auxiliaryTopRightArea
        guard !leftArea.isEmpty,
              !rightArea.isEmpty,
              leftArea.maxX < rightArea.minX else {
            return nil
        }

        let top = max(leftArea.maxY, rightArea.maxY)
        let height = max(leftArea.height, rightArea.height)
        guard height > 0 else { return nil }

        return CGRect(
            x: leftArea.maxX,
            y: top - height,
            width: rightArea.minX - leftArea.maxX,
            height: height
        )
    }
}

enum NotchStatusSurfaceShape {
    static let notchContactCornerRadius: CGFloat = 12

    struct TopContact: Equatable {
        let startX: CGFloat
        let endX: CGFloat
        let radius: CGFloat
    }

    static func topContactCornerRadius(notchSpacerWidth: CGFloat) -> CGFloat {
        notchSpacerWidth > 0 ? notchContactCornerRadius : 0
    }

    static func topContact(
        activityLabelWidth: CGFloat,
        leadingSpacerWidth: CGFloat,
        notchSpacerWidth: CGFloat,
        boundsWidth: CGFloat,
        boundsHeight: CGFloat
    ) -> TopContact? {
        guard notchSpacerWidth > 0,
              boundsWidth > 0,
              boundsHeight > 0 else {
            return nil
        }
        let compactLeadingInset = max(0, leadingSpacerWidth)
        let startX = min(compactLeadingInset, boundsWidth)
        let endX = boundsWidth
        let radius = min(
            notchContactCornerRadius,
            max(0, endX - startX) / 2,
            boundsHeight / 2
        )
        guard radius > 0 else { return nil }
        return TopContact(startX: startX, endX: endX, radius: radius)
    }

    static func renderedTopShoulderRadius(
        for topContact: TopContact?,
        boundsHeight: CGFloat
    ) -> CGFloat {
        guard let topContact else { return 0 }
        return min(topContact.radius, compactTopShoulderDepth(boundsHeight: boundsHeight))
    }

    static func renderedBottomCornerRadius(
        for topContact: TopContact?,
        boundsHeight: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        guard let topContact else {
            return min(boundsHeight / 2, availableWidth / 2)
        }
        return min(
            topContact.radius * 1.1,
            boundsHeight * 0.38,
            availableWidth / 2
        )
    }

    static func compactNotchCutoutPath(
        in rect: NSRect,
        topContact: TopContact
    ) -> NSBezierPath {
        let leftWallX = rect.minX + topContact.startX
        let rightLeadOutWidth = min(
            NotchStatusPlacementPlanner.compactNotchLeadOutWidth,
            max(0, rect.maxX - leftWallX)
        )
        let rightWallX = rect.maxX - rightLeadOutWidth
        let leftCutoutWidth = max(0, leftWallX - rect.minX)
        let rightCutoutWidth = max(0, rect.maxX - rightWallX)
        let baseRadius = renderedBottomCornerRadius(
            for: topContact,
            boundsHeight: rect.height,
            availableWidth: max(0, rightWallX - leftWallX)
        )
        let cutoutDepth = min(
            rect.height - baseRadius,
            compactTopShoulderDepth(boundsHeight: rect.height)
        )
        let baseControl = baseRadius * 0.5522847498307936
        let leftCutoutControlX = leftCutoutWidth * 0.5522847498307936
        let rightCutoutControlX = rightCutoutWidth * 0.5522847498307936
        let cutoutControlY = cutoutDepth * 0.5522847498307936
        let path = NSBezierPath()

        path.move(to: NSPoint(x: leftWallX, y: rect.maxY - baseRadius))
        path.curve(
            to: NSPoint(x: leftWallX + baseRadius, y: rect.maxY),
            controlPoint1: NSPoint(x: leftWallX, y: rect.maxY - baseRadius + baseControl),
            controlPoint2: NSPoint(x: leftWallX + baseRadius - baseControl, y: rect.maxY)
        )
        path.line(to: NSPoint(x: rightWallX - baseRadius, y: rect.maxY))
        path.curve(
            to: NSPoint(x: rightWallX, y: rect.maxY - baseRadius),
            controlPoint1: NSPoint(x: rightWallX - baseRadius + baseControl, y: rect.maxY),
            controlPoint2: NSPoint(x: rightWallX, y: rect.maxY - baseRadius + baseControl)
        )
        path.line(to: NSPoint(x: rightWallX, y: rect.minY + cutoutDepth))
        path.curve(
            to: NSPoint(x: rect.maxX, y: rect.minY),
            controlPoint1: NSPoint(x: rightWallX, y: rect.minY + cutoutDepth - cutoutControlY),
            controlPoint2: NSPoint(x: rect.maxX - rightCutoutControlX, y: rect.minY)
        )
        path.line(to: NSPoint(x: rect.minX, y: rect.minY))
        path.curve(
            to: NSPoint(x: leftWallX, y: rect.minY + cutoutDepth),
            controlPoint1: NSPoint(x: rect.minX + leftCutoutControlX, y: rect.minY),
            controlPoint2: NSPoint(x: leftWallX, y: rect.minY + cutoutDepth - cutoutControlY)
        )
        path.line(to: NSPoint(x: leftWallX, y: rect.maxY - baseRadius))
        path.close()
        return path
    }

    private static func compactTopShoulderDepth(boundsHeight: CGFloat) -> CGFloat {
        max(4, boundsHeight * 0.22)
    }
}

struct NotchVisualLabelPresentation: Equatable {
    let labels: [String]
    let hoverLabel: String?
}

/// The complete set of state-driven copy allowed on the notch surface.
/// Background activity is tracked separately so hidden labels never make
/// active work look idle.
enum NotchVisualLabelAllowlist {
    static func presentation(
        for state: OverlayState,
        bridgeStartingUp: Bool = false
    ) -> NotchVisualLabelPresentation {
        if bridgeStartingUp {
            return NotchVisualLabelPresentation(
                labels: ["Starting up..."],
                hoverLabel: "Starting session"
            )
        }

        let label: String?
        switch state {
        case .listening, .recording:
            label = "Listening"
        case .sent:
            label = "Sending voice"
        case .cancelled(.stt):
            label = "Recording cancelled"
        case .cancelled(.tts):
            label = "Response cancelled"
        case .acknowledgement:
            label = "Acknowledged"
        case .messageWaiting:
            label = "Response ready"
        case .preparing:
            label = "Preparing speech"
        case .speaking:
            label = "Playing"
        case .speechFailed:
            label = "Speech unavailable"
        case .actionGlow(awaitingConfirmation: nil):
            label = "Using screen"
        case .idle, .paused, .processing, .sessionPrompt, .sessionReady,
             .programStatus, .actionGlow:
            label = nil
        }
        return NotchVisualLabelPresentation(
            labels: label.map { [$0] } ?? [],
            hoverLabel: label
        )
    }
}

enum NotchActivityLabelPlanner {
    static func labels(
        for state: OverlayState,
        foregroundActivity: String? = nil,
        activeRuns: [RunState] = [],
        tickets: [Ticket] = [],
        bridgeRecoveryInFlight: Bool = false,
        bridgeStartingUp: Bool = false,
        now: Date = Date()
    ) -> [String] {
        NotchVisualLabelAllowlist.presentation(
            for: state,
            bridgeStartingUp: bridgeStartingUp
        ).labels
    }

    static func hoverLabel(
        for state: OverlayState,
        foregroundActivity: String? = nil,
        activeRuns: [RunState] = [],
        tickets: [Ticket] = [],
        bridgeRecoveryInFlight: Bool = false,
        bridgeStartingUp: Bool = false,
        now: Date = Date(),
        ticketForRun: ((RunState) -> Ticket?)? = nil
    ) -> String? {
        NotchVisualLabelAllowlist.presentation(
            for: state,
            bridgeStartingUp: bridgeStartingUp
        ).hoverLabel
    }

    static func hasActiveWork(
        state: OverlayState,
        foregroundActivity: String? = nil,
        activeRuns: [RunState] = [],
        tickets: [Ticket] = [],
        bridgeRecoveryInFlight: Bool = false,
        bridgeStartingUp: Bool = false,
        boardIsLoading: Bool = false,
        now: Date = Date()
    ) -> Bool {
        if state != .idle && state != .paused {
            return true
        }
        if label(forWorkingProgress: foregroundActivity) != nil {
            return true
        }
        if bridgeRecoveryInFlight || bridgeStartingUp || boardIsLoading {
            return true
        }
        if sortedActiveRuns(activeRuns).contains(where: { label(for: $0, now: now) != nil }) {
            return true
        }
        return hasWaitingDependency(in: tickets)
    }

    /// Shared status language for consumers such as the bottom transcription
    /// pill. Notch visibility is governed only by NotchVisualLabelAllowlist.
    static func label(for state: OverlayState) -> String? {
        switch state {
        case .idle, .paused:
            return nil
        case .listening, .recording:
            return "Listening"
        case .sent:
            return "Sending voice"
        case .cancelled(.stt):
            return "Recording cancelled"
        case .cancelled(.tts):
            return "Response cancelled"
        case .processing:
            return "Thinking"
        case .acknowledgement:
            return "Acknowledged"
        case .messageWaiting:
            return "Response ready"
        case .preparing:
            return "Preparing speech"
        case .speaking:
            return "Playing"
        case .speechFailed:
            return "Speech unavailable"
        case .sessionPrompt:
            return "Waiting session"
        case .sessionReady:
            return "Session ready"
        case .programStatus:
            return "Checking status"
        case .actionGlow(let prompt):
            return prompt == nil ? "Using screen" : "Awaiting approval"
        }
    }

    static func label(for run: RunState, now: Date = Date()) -> String? {
        switch run.state {
        case "Claimed":
            return "Dispatching worker"
        case "Stalled":
            return "Worker stalled"
        case "Running":
            if let activity = run.activityChip(now: now) {
                return label(forWorkerActivity: activity, fallback: "Worker running")
            }
            return "Worker running"
        default:
            return nil
        }
    }

    static func label(forWorkerActivity activity: String, fallback: String = "Worker running") -> String {
        let trimmed = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let lower = trimmed.lowercased()
        let rawCommand = looksLikeRawCommand(trimmed)

        if lower == "idle" { return "Worker idle" }
        if rawCommand && !isRecognizedCommandActivity(lower) { return fallback }
        if lower.contains("test") { return "Running tests" }
        if lower.contains("build") { return "Building project" }
        if lower.contains("lint") { return "Running lint" }
        if lower.contains("edit") || lower.contains("writ") { return "Editing files" }
        if lower.contains("read") || lower.contains("inspect") { return "Reading code" }
        if lower.contains("search") || lower.contains("grep") || lower.contains("find") { return "Searching code" }
        if lower.contains("commit") { return "Committing changes" }
        if lower.contains("stag") || lower.contains("git") { return "Reviewing changes" }
        if lower.contains("plan") { return "Planning work" }
        if lower.contains("research") || lower.contains("web") { return "Researching" }
        if lower.contains("delegat") || lower.contains("sub-agent") { return "Dispatching worker" }
        if lower.contains("mov") && lower.contains("ticket") { return "Moving ticket" }
        if lower.contains("ticket") { return "Updating ticket" }
        if looksLikeRawCommand(trimmed) { return fallback }

        return compactWords(trimmed, fallback: fallback)
    }

    static func label(forDetailedWorkerActivity activity: String, fallback: String = "Worker running") -> String {
        let trimmed = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let lower = trimmed.lowercased()
        let rawCommand = looksLikeRawCommand(trimmed)

        if lower == "idle" { return "Worker idle" }
        if rawCommand && !isRecognizedCommandActivity(lower) { return fallback }
        if rawCommand { return label(forWorkerActivity: trimmed, fallback: fallback) }
        return label(forWorkingProgress: trimmed) ?? fallback
    }

    static func label(forWorkingProgress progress: String?) -> String? {
        let words = (progress ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let normalized = words.joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        if normalized.count <= 180 { return normalized }
        let clipped = String(normalized.prefix(177))
        return clipped.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func hasWaitingDependency(in tickets: [Ticket]) -> Bool {
        let byID = Dictionary(tickets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tickets.contains { ticket in
            guard ticket.status == .ready,
                  !ticket.canceled,
                  ticket.runId == nil,
                  !ticket.dependsOn.isEmpty else {
                return false
            }
            return ticket.dependsOn.contains { byID[$0]?.status != .done }
        }
    }

    private static func conciseUnique(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for label in labels {
            let compact = compactWords(label, fallback: "")
            guard !compact.isEmpty else { continue }
            let key = compact.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(compact)
        }
        return result
    }

    private static func sortedActiveRuns(_ activeRuns: [RunState]) -> [RunState] {
        activeRuns
            .filter(\.isActive)
            .sorted { lhs, rhs in
                if lhs.runId != rhs.runId { return lhs.runId > rhs.runId }
                return (lhs.activityAt ?? 0) > (rhs.activityAt ?? 0)
            }
    }

    private static func label(
        forActiveRunDetail run: RunState,
        ticket: Ticket?,
        now: Date
    ) -> String? {
        guard run.isActive else { return nil }

        var text = "\(run.ticketId) run \(run.runId)"
        if let detail = detail(for: run, ticket: ticket, now: now) {
            text += ": \(detail)"
        }
        if let providerLabel = providerLabel(for: run) {
            text += " (\(providerLabel))"
        }
        return label(forWorkingProgress: text)
    }

    private static func detail(for run: RunState, ticket: Ticket?, now: Date) -> String? {
        let activityDetail: String?
        switch run.state {
        case "Claimed":
            activityDetail = "Dispatching worker"
        case "Stalled":
            activityDetail = "Worker stalled"
        case "Running":
            if let activity = run.activityChip(now: now) {
                activityDetail = label(forDetailedWorkerActivity: activity)
            } else {
                activityDetail = "Worker running"
            }
        default:
            activityDetail = nil
        }

        let title = ticket?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (activityDetail, title?.isEmpty == false ? title : nil) {
        case let (.some(activity), .some(title)) where activity != title:
            return "\(activity) - \(title)"
        case let (.some(activity), _):
            return activity
        case let (_, .some(title)):
            return title
        default:
            return nil
        }
    }

    private static func providerLabel(for run: RunState) -> String? {
        let provider = run.providerKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = run.modelAlias?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let providerLabel = provider.flatMap { value -> String? in
            guard !value.isEmpty else { return nil }
            switch value.lowercased() {
            case "codex":
                return "Codex"
            case "claude":
                return "Claude"
            default:
                return value
            }
        }
        let modelLabel = model?.isEmpty == false ? model : nil

        switch (providerLabel, modelLabel) {
        case let (.some(providerLabel), .some(modelLabel)):
            return "\(providerLabel)/\(modelLabel)"
        case let (.some(providerLabel), .none):
            return providerLabel
        case let (.none, .some(modelLabel)):
            return modelLabel
        case (.none, .none):
            return nil
        }
    }

    private static func compactWords(_ text: String, fallback: String) -> String {
        let words = text
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return fallback }
        let clipped = words.prefix(4).joined(separator: " ")
        return clipped.count <= 28 ? clipped : fallback
    }

    private static func looksLikeRawCommand(_ text: String) -> Bool {
        text.contains(";")
            || text.contains("&&")
            || text.contains("|")
            || text.contains("/")
            || text.contains("$")
            || text.contains("--")
    }

    private static func isRecognizedCommandActivity(_ lowercasedText: String) -> Bool {
        lowercasedText.contains("swift test")
            || lowercasedText.contains("swift build")
            || lowercasedText.contains("xcodebuild")
            || lowercasedText.contains("pytest")
            || lowercasedText.contains("npm ")
            || lowercasedText.contains("pnpm ")
            || lowercasedText.contains("yarn ")
            || lowercasedText.contains("make ")
            || lowercasedText.contains("just ")
            || lowercasedText.contains("git ")
    }
}

enum NotchStatusAnimationPolicy {
    static func duration(_ defaultDuration: TimeInterval, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : defaultDuration
    }
}

struct NotchStatusPanelFrameTransition {
    let startFrame: CGRect
    let targetFrame: CGRect

    func frame(at progress: CGFloat) -> CGRect {
        let progress = min(max(progress, 0), 1)
        let minX = interpolate(startFrame.minX, targetFrame.minX, progress: progress)
        let maxX = interpolate(startFrame.maxX, targetFrame.maxX, progress: progress)
        let minY = interpolate(startFrame.minY, targetFrame.minY, progress: progress)
        let maxY = interpolate(startFrame.maxY, targetFrame.maxY, progress: progress)
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}

enum NotchStatusPanelFrameAnimationTiming {
    static func easedProgress(_ progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        guard progress > 0, progress < 1 else { return progress }

        // Match the existing (0.16, 1.0, 0.28, 1.0) frame timing while
        // interpolating the panel's screen-space edges as one geometry.
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<12 {
            let candidate = (lower + upper) / 2
            if cubicBezier(candidate, first: 0.16, second: 0.28) < progress {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return cubicBezier((lower + upper) / 2, first: 1, second: 1)
    }

    private static func cubicBezier(_ t: CGFloat, first: CGFloat, second: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 3 * inverse * inverse * t * first
            + 3 * inverse * t * t * second
            + t * t * t
    }
}

enum NotchActivityLabelRenderPolicy {
    static let workingStatusRevealDuration: TimeInterval = 2.0
    static let hoverScrollDelay: TimeInterval = 1.0
    static let scrollGap: CGFloat = 36
    static let textLeadingInset: CGFloat = 13
    static let notchedTextLeadingInset: CGFloat =
        textLeadingInset + NotchStatusPlacementPlanner.compactNotchLeadInWidth
    static let textRightGlyphClearance: CGFloat = 34
    static let textGlyphGap: CGFloat = 8
    static let textHeight: CGFloat = 16

    static func lineBreakMode(isScrolling: Bool) -> NSLineBreakMode {
        isScrolling ? .byClipping : .byTruncatingTail
    }

    static func shouldScrollLabel(
        status: NotchSessionStatus,
        glyphHovered: Bool,
        hoverDuration: TimeInterval,
        textWidth: CGFloat,
        availableWidth: CGFloat,
        reduceMotion: Bool
    ) -> Bool {
        guard status == .working,
              glyphHovered,
              !reduceMotion,
              hoverDuration >= hoverScrollDelay else {
            return false
        }
        return textWidth > availableWidth
    }

    static func scrollStride(textWidth: CGFloat) -> CGFloat {
        max(0, textWidth) + scrollGap
    }

    static func scrollOffset(
        hoverDuration: TimeInterval,
        textWidth: CGFloat
    ) -> CGFloat {
        let stride = scrollStride(textWidth: textWidth)
        guard stride > 0 else { return 0 }

        let elapsed = max(0, hoverDuration - hoverScrollDelay)
        let duration = max(4.0, min(12.0, TimeInterval(stride / 50)))
        let phase = elapsed.truncatingRemainder(dividingBy: duration) / duration
        return stride * CGFloat(phase)
    }

    static func hoverStartTime(
        current: CFTimeInterval?,
        glyphHovered: Bool,
        labelChanged: Bool,
        now: CFTimeInterval
    ) -> CFTimeInterval? {
        guard glyphHovered else { return nil }
        return current ?? now
    }

    static func shouldAnimatePlacementTransition(
        status: NotchSessionStatus,
        oldWorkingGlyphHovered: Bool,
        newWorkingGlyphHovered: Bool
    ) -> Bool {
        // Hover state is hit-tested inside the same window whose frame changes
        // to reveal the trace label. Animating that frame can make the glyph
        // briefly leave and re-enter its hover frame, producing a rapid
        // expand/collapse loop. Keep the hover transition itself animated now
        // that the glyph is screen-anchored during frame updates, but still
        // suppress no-op transitions.
        status == .working && oldWorkingGlyphHovered != newWorkingGlyphHovered
    }

    static func shouldAnimateContentPlacementUpdate(
        status: NotchSessionStatus,
        workingGlyphHovered: Bool,
        workingProgressLabel: String?
    ) -> Bool {
        guard status == .working,
              workingGlyphHovered,
              workingProgressLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return true
        }
        return false
    }

    static func shouldDeferContentUpdate(
        previousActivityLabelWidth: CGFloat,
        nextActivityLabelWidth: CGFloat,
        animated: Bool
    ) -> Bool {
        animated && previousActivityLabelWidth > nextActivityLabelWidth
    }

    static func shouldApplyDeferredContentUpdate(
        scheduledGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        scheduledGeneration == currentGeneration
    }

    static func labelTextRect(
        activityLabelWidth: CGFloat,
        boundsHeight: CGFloat,
        glyphFrame: NSRect? = nil,
        isNotched: Bool = false
    ) -> NSRect {
        let leadingInset = isNotched ? notchedTextLeadingInset : textLeadingInset
        var rect = NSRect(
            x: leadingInset,
            y: (boundsHeight - textHeight) / 2,
            width: max(0, activityLabelWidth - leadingInset - textRightGlyphClearance),
            height: textHeight
        )
        if let glyphFrame {
            let maxTextX = min(rect.maxX, glyphFrame.minX - textGlyphGap)
            rect.size.width = max(0, maxTextX - rect.minX)
        }
        return rect
    }
}

struct NotchStatusPresentationUpdatePlan: Equatable {
    let shouldRestartWorkingReveal: Bool
    let shouldAnimatePlacement: Bool
}

enum NotchStatusPresentationUpdatePolicy {
    static func plan(
        statusChanged: Bool,
        activityLabelsChanged: Bool,
        workingProgressChanged: Bool,
        nextStatus: NotchSessionStatus,
        workingRevealWasActive: Bool,
        workingGlyphHovered: Bool
    ) -> NotchStatusPresentationUpdatePlan {
        let presentationChanged = statusChanged || activityLabelsChanged || workingProgressChanged
        let shouldRestartWorkingReveal = nextStatus == .working && presentationChanged
        let shouldAnimatePlacement: Bool
        if nextStatus == .working {
            shouldAnimatePlacement = shouldRestartWorkingReveal
                && !workingRevealWasActive
                && !workingGlyphHovered
        } else {
            shouldAnimatePlacement = presentationChanged
        }
        return NotchStatusPresentationUpdatePlan(
            shouldRestartWorkingReveal: shouldRestartWorkingReveal,
            shouldAnimatePlacement: shouldAnimatePlacement
        )
    }
}

enum NotchHoverInteractionPolicy {
    static func frame(
        glyphFrame: NSRect,
        boundsHeight: CGFloat,
        activityLabelWidth: CGFloat,
        leadingSpacerWidth: CGFloat,
        notchSpacerWidth: CGFloat,
        status: NotchSessionStatus,
        glyphHovered: Bool,
        workingProgressLabel: String?,
        hoverSlop: CGFloat
    ) -> NSRect {
        let glyphHoverFrame = glyphFrame.insetBy(dx: -hoverSlop, dy: -hoverSlop)
        guard status == .working,
              glyphHovered,
              let workingProgressLabel,
              !workingProgressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              activityLabelWidth > 0 else {
            return glyphHoverFrame
        }

        let leadingWidth = activityLabelWidth + leadingSpacerWidth + notchSpacerWidth
        return NSRect(
            x: glyphFrame.minX - leadingWidth - hoverSlop,
            y: -hoverSlop,
            width: leadingWidth
                + glyphFrame.width
                + NotchStatusPlacementPlanner.compactNotchLeadOutWidth
                + hoverSlop * 2,
            height: boundsHeight + hoverSlop * 2
        )
    }
}

final class NotchStatusController {
    private var panel: NotchStatusPanel?
    private let pillView = NotchStatusPillContentView()
    private var active = false
    private var status: NotchSessionStatus = .notWorking
    private var activityLabels: [String] = []
    private var workingProgressLabel: String?
    private var workingGlyphHovered = false
    private var workingStatusRevealActive = false
    private var activityIndex = 0
    private var carouselTimer: Timer?
    private var workingStatusRevealTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?
    private var lastPlacement: NotchStatusPlacement?
    private var placementAnimationGeneration = 0
    private var loggedMissingNotch = false

    init() {
        pillView.onWorkingGlyphHoverChanged = { [weak self] hovered in
            self?.setWorkingGlyphHovered(hovered)
        }
    }

    deinit {
        carouselTimer?.invalidate()
        workingStatusRevealTimer?.invalidate()
        removeScreenParametersObserver()
    }

    func setActive(_ active: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setActive(active)
            }
            return
        }

        guard self.active != active else {
            if active {
                if let panel, panel.isVisible {
                    updatePlacement(animated: false)
                } else {
                    show()
                }
            }
            return
        }

        self.active = active
        if active {
            beginWorkingStatusRevealIfNeeded()
            show()
        } else {
            stopWorkingStatusReveal()
            hide()
        }
    }

    func setGlyphClickHandler(_ handler: @escaping () -> Void) {
        pillView.onGlyphClicked = handler
    }

    func setPresentation(
        status nextStatus: NotchSessionStatus,
        activityLabels labels: [String],
        workingProgressLabel label: String?
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setPresentation(
                    status: nextStatus,
                    activityLabels: labels,
                    workingProgressLabel: label
                )
            }
            return
        }

        let compactLabels = Array(labels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let normalized = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let progress = normalized?.isEmpty == true ? nil : normalized
        let statusChanged = status != nextStatus
        let activityLabelsChanged = activityLabels != compactLabels
        let workingProgressChanged = workingProgressLabel != progress
        let plan = NotchStatusPresentationUpdatePolicy.plan(
            statusChanged: statusChanged,
            activityLabelsChanged: activityLabelsChanged,
            workingProgressChanged: workingProgressChanged,
            nextStatus: nextStatus,
            workingRevealWasActive: workingStatusRevealActive,
            workingGlyphHovered: workingGlyphHovered
        )

        guard statusChanged || activityLabelsChanged || workingProgressChanged else {
            if active {
                updatePlacement(animated: false)
            } else {
                updateStatusContent()
            }
            return
        }

        status = nextStatus
        if activityLabelsChanged {
            activityLabels = compactLabels
            activityIndex = 0
            updateCarousel()
        }
        workingProgressLabel = progress
        if nextStatus == .working {
            if plan.shouldRestartWorkingReveal {
                beginWorkingStatusRevealIfNeeded()
            }
        } else {
            workingGlyphHovered = false
            stopWorkingStatusReveal()
        }

        if active {
            updatePlacement(
                animated: plan.shouldAnimatePlacement && shouldAnimateContentPlacementUpdate
            )
        } else {
            updateStatusContent()
        }
    }

    func clearWorkingActivity() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.clearWorkingActivity()
            }
            return
        }
        setPresentation(
            status: status,
            activityLabels: [],
            workingProgressLabel: nil
        )
    }

    private func show() {
        placementAnimationGeneration &+= 1
        installScreenParametersObserver()

        guard let placement = currentPlacement() else {
            if !loggedMissingNotch {
                NSLog("[RelayRunner] Notch status surface hidden: no display exposes an auxiliary top-right notch area.")
                loggedMissingNotch = true
            }
            panel?.stopFrameAnimation()
            panel?.orderOut(nil)
            return
        }

        loggedMissingNotch = false
        lastPlacement = placement

        let panel = panel ?? NotchStatusPanel()
        if self.panel == nil {
            self.panel = panel
        }

        panel.stopFrameAnimation()
        panel.setFrame(placement.retractedFrame, display: false)
        updateStatusContent()
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        let duration = animationDuration(0.34)
        pillView.redrawDuringFrameAnimation(duration: duration)
        panel.animateFrame(to: placement.visibleFrame, duration: duration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.28, 1.0)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        placementAnimationGeneration &+= 1
        let animationGeneration = placementAnimationGeneration
        removeScreenParametersObserver()
        stopCarousel()

        guard let panel else { return }
        let targetFrame = currentPlacement()?.retractedFrame
            ?? lastPlacement?.retractedFrame
            ?? panel.frame.offsetBy(dx: 0, dy: 2)
        let duration = animationDuration(0.24)

        pillView.redrawDuringFrameAnimation(duration: duration)
        panel.animateFrame(to: targetFrame, duration: duration) { [weak self, weak panel] in
            guard let self,
                  self.placementAnimationGeneration == animationGeneration,
                  !self.active else {
                return
            }
            panel?.orderOut(nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0.0, 1.0, 1.0)
            panel.animator().alphaValue = 0
        }
    }

    private func updatePlacement(animated: Bool) {
        let previousPlacement = lastPlacement
        guard let placement = currentPlacement() else {
            placementAnimationGeneration &+= 1
            panel?.stopFrameAnimation()
            panel?.orderOut(nil)
            return
        }
        lastPlacement = placement
        placementAnimationGeneration &+= 1
        let animationGeneration = placementAnimationGeneration

        guard let panel else {
            show()
            return
        }
        if animated {
            let shouldDeferContentUpdate = NotchActivityLabelRenderPolicy.shouldDeferContentUpdate(
                previousActivityLabelWidth: previousPlacement?.activityLabelWidth ?? 0,
                nextActivityLabelWidth: placement.activityLabelWidth,
                animated: true
            )
            if !shouldDeferContentUpdate {
                updateStatusContent()
            }
            let duration = animationDuration(0.36)
            pillView.redrawDuringFrameAnimation(duration: duration)
            panel.animateFrame(to: placement.visibleFrame, duration: duration) { [weak self] in
                guard shouldDeferContentUpdate,
                      let self,
                      NotchActivityLabelRenderPolicy.shouldApplyDeferredContentUpdate(
                        scheduledGeneration: animationGeneration,
                        currentGeneration: self.placementAnimationGeneration
                      ) else {
                    return
                }
                self.updateStatusContent()
            }
        } else {
            panel.stopFrameAnimation()
            panel.setFrame(placement.visibleFrame, display: true)
            updateStatusContent()
        }
    }

    private func updateStatusContent() {
        guard let panel else { return }
        if panel.contentView !== pillView {
            pillView.frame = CGRect(origin: .zero, size: panel.frame.size)
            pillView.autoresizingMask = [.width, .height]
            panel.contentView = pillView
        }
        pillView.frame = CGRect(origin: .zero, size: panel.frame.size)
        pillView.apply(
            status: status,
            label: displayedActivityLabel,
            activityLabelWidth: lastPlacement?.activityLabelWidth ?? 0,
            leadingSpacerWidth: lastPlacement?.leadingSpacerWidth ?? NotchStatusPlacementPlanner.compactLeadingWingWidth,
            notchSpacerWidth: lastPlacement?.notchSpacerWidth ?? 0,
            glyphScreenX: lastPlacement?.glyphScreenX
        )
    }

    private func updateCarousel() {
        stopCarousel()
        guard activityLabels.count > 1 else { return }
        carouselTimer = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { [weak self] _ in
            self?.advanceActivityLabel()
        }
    }

    private func stopCarousel() {
        carouselTimer?.invalidate()
        carouselTimer = nil
    }

    private func advanceActivityLabel() {
        guard !activityLabels.isEmpty else { return }
        activityIndex = (activityIndex + 1) % activityLabels.count
        let workingRevealWasActive = workingStatusRevealActive
        beginWorkingStatusRevealIfNeeded()
        if active {
            updatePlacement(
                animated: !workingRevealWasActive
                    && !workingGlyphHovered
                    && shouldAnimateContentPlacementUpdate
            )
        } else {
            updateStatusContent()
        }
    }

    private func currentPlacement() -> NotchStatusPlacement? {
        // Multi-display rule: prefer the notched display under the pointer;
        // otherwise use the display under the pointer, including external
        // displays that need the centered continuous-pill fallback.
        if let mouseScreen = NSScreen.screens.first(where: { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }),
           let placement = placement(for: mouseScreen) {
            return placement
        }

        for screen in NSScreen.screens {
            if let placement = placement(for: screen) {
                return placement
            }
        }

        return nil
    }

    private func placement(for screen: NSScreen) -> NotchStatusPlacement? {
        let labelWidth = Self.displayedActivityLabelWidth(
            status: status,
            compactLabel: activityLabels[safe: activityIndex],
            workingProgressLabel: workingProgressLabel,
            workingGlyphHovered: workingGlyphHovered,
            workingStatusRevealActive: workingStatusRevealActive
        )
        return NotchStatusPlacementPlanner.placement(
            for: NotchStatusDisplayGeometry(screen: screen),
            activityLabelWidth: labelWidth
        )
    }

    private var displayedActivityLabel: String? {
        Self.displayedActivityLabel(
            status: status,
            compactLabel: activityLabels[safe: activityIndex],
            workingProgressLabel: workingProgressLabel,
            workingGlyphHovered: workingGlyphHovered,
            workingStatusRevealActive: workingStatusRevealActive
        )
    }

    static func displayedActivityLabel(
        status: NotchSessionStatus,
        compactLabel: String?,
        workingProgressLabel: String?,
        workingGlyphHovered: Bool,
        workingStatusRevealActive: Bool
    ) -> String? {
        if status == .working {
            if workingGlyphHovered,
               let workingProgressLabel,
               !workingProgressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return workingProgressLabel
            }
            guard workingStatusRevealActive else { return nil }
            return compactLabel ?? workingProgressLabel
        }
        return compactLabel
    }

    static func displayedActivityLabelWidth(
        status: NotchSessionStatus,
        compactLabel: String?,
        workingProgressLabel: String?,
        workingGlyphHovered: Bool,
        workingStatusRevealActive: Bool
    ) -> CGFloat {
        let label = displayedActivityLabel(
            status: status,
            compactLabel: compactLabel,
            workingProgressLabel: workingProgressLabel,
            workingGlyphHovered: workingGlyphHovered,
            workingStatusRevealActive: workingStatusRevealActive
        )
        let measuredWidth = NotchStatusPlacementPlanner.activityLabelWidth(for: label)
        return status == .working
            ? min(measuredWidth, NotchStatusPlacementPlanner.maximumWorkingProgressLabelWidth)
            : measuredWidth
    }

    private var shouldAnimateContentPlacementUpdate: Bool {
        NotchActivityLabelRenderPolicy.shouldAnimateContentPlacementUpdate(
            status: status,
            workingGlyphHovered: workingGlyphHovered,
            workingProgressLabel: workingProgressLabel
        )
    }

    private func setWorkingGlyphHovered(_ hovered: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setWorkingGlyphHovered(hovered)
            }
            return
        }

        let effectiveHover = status == .working && hovered
        guard workingGlyphHovered != effectiveHover else { return }
        let shouldAnimate = NotchActivityLabelRenderPolicy.shouldAnimatePlacementTransition(
            status: status,
            oldWorkingGlyphHovered: workingGlyphHovered,
            newWorkingGlyphHovered: effectiveHover
        )
        workingGlyphHovered = effectiveHover
        if active {
            updatePlacement(animated: shouldAnimate)
        } else {
            updateStatusContent()
        }
    }

    private func beginWorkingStatusRevealIfNeeded() {
        guard status == .working else { return }
        workingStatusRevealTimer?.invalidate()
        workingStatusRevealActive = true

        let timer = Timer(
            timeInterval: NotchActivityLabelRenderPolicy.workingStatusRevealDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.workingStatusRevealTimer = nil
            guard self.workingStatusRevealActive else { return }
            self.workingStatusRevealActive = false
            if self.active {
                self.updatePlacement(animated: !self.workingGlyphHovered)
            } else {
                self.updateStatusContent()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        workingStatusRevealTimer = timer
    }

    private func stopWorkingStatusReveal() {
        workingStatusRevealTimer?.invalidate()
        workingStatusRevealTimer = nil
        workingStatusRevealActive = false
    }

    private func installScreenParametersObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePlacement(animated: false)
        }
    }

    private func removeScreenParametersObserver() {
        guard let observer = screenParametersObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        screenParametersObserver = nil
    }

    private func animationDuration(_ defaultDuration: TimeInterval) -> TimeInterval {
        NotchStatusAnimationPolicy.duration(
            defaultDuration,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

final class NotchStatusPanel: NSPanel {
    private var frameAnimationTimer: Timer?
    private var frameAnimationCompletion: (() -> Void)?

    var isFrameAnimationRunning: Bool {
        frameAnimationTimer != nil
    }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        // Keep the notch above Workspace while leaving ActionGlow one level
        // higher so Relay Vision feedback is never obscured by app surfaces.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    deinit {
        stopFrameAnimation()
    }

    func animateFrame(
        to targetFrame: CGRect,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        stopFrameAnimation()

        let transition = NotchStatusPanelFrameTransition(
            startFrame: frame,
            targetFrame: targetFrame
        )
        guard duration > 0 else {
            setFrame(targetFrame, display: true)
            completion?()
            return
        }

        let startTime = CACurrentMediaTime()
        frameAnimationCompletion = completion
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = CACurrentMediaTime() - startTime
            let linearProgress = min(1, CGFloat(elapsed / duration))
            let easedProgress = NotchStatusPanelFrameAnimationTiming.easedProgress(linearProgress)
            self.setFrame(transition.frame(at: easedProgress), display: true)

            guard linearProgress >= 1 else { return }
            timer.invalidate()
            self.frameAnimationTimer = nil
            let completion = self.frameAnimationCompletion
            self.frameAnimationCompletion = nil
            completion?()
        }
        RunLoop.main.add(timer, forMode: .common)
        frameAnimationTimer = timer
    }

    func stopFrameAnimation() {
        frameAnimationTimer?.invalidate()
        frameAnimationTimer = nil
        frameAnimationCompletion = nil
    }
}

final class NotchStatusPillContentView: NSView {
    private var status: NotchSessionStatus = .notWorking
    private var label: String?
    private var activityLabelWidth: CGFloat = 0
    private var leadingSpacerWidth: CGFloat = NotchStatusPlacementPlanner.compactLeadingWingWidth
    private var notchSpacerWidth: CGFloat = 0
    private var glyphScreenX: CGFloat?
    private var waveTimer: Timer?
    private var frameAnimationTimer: Timer?
    private var frameAnimationEnd: Date?
    private var hoverTrackingArea: NSTrackingArea?
    private var glyphHovered = false
    private var glyphHoverStartedAt: CFTimeInterval?
    var onWorkingGlyphHoverChanged: ((Bool) -> Void)?
    var onGlyphClicked: (() -> Void)?
    private static let glyphHoverSlop: CGFloat = 8

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        waveTimer?.invalidate()
        frameAnimationTimer?.invalidate()
    }

    func apply(
        status: NotchSessionStatus,
        label: String?,
        activityLabelWidth: CGFloat,
        leadingSpacerWidth: CGFloat,
        notchSpacerWidth: CGFloat,
        glyphScreenX: CGFloat?
    ) {
        let statusChanged = self.status != status
        let glyphChanged = self.status.glyph != status.glyph
        let labelChanged = self.label != label
        self.status = status
        self.label = label
        self.activityLabelWidth = activityLabelWidth
        self.leadingSpacerWidth = leadingSpacerWidth
        self.notchSpacerWidth = notchSpacerWidth
        self.glyphScreenX = glyphScreenX
        glyphHoverStartedAt = NotchActivityLabelRenderPolicy.hoverStartTime(
            current: glyphHoverStartedAt,
            glyphHovered: glyphHovered,
            labelChanged: labelChanged,
            now: CACurrentMediaTime()
        )
        if statusChanged {
            notifyWorkingGlyphHoverChanged()
        }
        updateWaveTimer(restart: glyphChanged || statusChanged)
        updateTrackingAreas()
        needsDisplay = true
    }

    func redrawDuringFrameAnimation(duration: TimeInterval) {
        guard duration > 0 else { return }
        frameAnimationEnd = Date().addingTimeInterval(duration + 0.06)
        if frameAnimationTimer != nil { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.refreshGlyphHoverFromMouseLocation()
            self.needsDisplay = true
            if let end = self.frameAnimationEnd, Date() >= end {
                timer.invalidate()
                self.frameAnimationTimer = nil
                self.frameAnimationEnd = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameAnimationTimer = timer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWaveTimer(restart: false)
        if window == nil {
            setGlyphHovered(false)
        }
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        refreshGlyphHoverFromMouseLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        updateGlyphHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateGlyphHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        refreshGlyphHoverFromMouseLocation()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), currentGlyphFrame().contains(point) else {
            super.mouseDown(with: event)
            return
        }

        setGlyphHovered(true)
        onGlyphClicked?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshGlyphHoverFromMouseLocation()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor(calibratedWhite: 0, alpha: 0.985).setFill()
        bottomRoundedPillPath(in: bounds).fill()

        let labelWidth = drawLabelIfNeeded()
        drawGlyph(after: labelWidth)
    }

    private func bottomRoundedPillPath(in rect: NSRect) -> NSBezierPath {
        let topContact = NotchStatusSurfaceShape.topContact(
            activityLabelWidth: activityLabelWidth,
            leadingSpacerWidth: leadingSpacerWidth,
            notchSpacerWidth: notchSpacerWidth,
            boundsWidth: rect.width,
            boundsHeight: rect.height
        )
        if let topContact, topContact.startX > 0 {
            return NotchStatusSurfaceShape.compactNotchCutoutPath(in: rect, topContact: topContact)
        }
        let bottomRadius = NotchStatusSurfaceShape.renderedBottomCornerRadius(
            for: topContact,
            boundsHeight: rect.height,
            availableWidth: rect.width
        )
        let topRadius = NotchStatusSurfaceShape.renderedTopShoulderRadius(
            for: topContact,
            boundsHeight: rect.height
        )
        let topStartX = rect.minX + (topContact?.startX ?? 0)
        let topEndX = rect.minX + (topContact?.endX ?? rect.width)
        let bottomControl = bottomRadius * 0.5522847498307936
        let topControl = topRadius * 0.5522847498307936
        let path = NSBezierPath()

        path.move(to: NSPoint(x: rect.minX, y: rect.maxY - bottomRadius))
        path.curve(
            to: NSPoint(x: rect.minX + bottomRadius, y: rect.maxY),
            controlPoint1: NSPoint(x: rect.minX, y: rect.maxY - bottomRadius + bottomControl),
            controlPoint2: NSPoint(x: rect.minX + bottomRadius - bottomControl, y: rect.maxY)
        )
        path.line(to: NSPoint(x: rect.maxX - bottomRadius, y: rect.maxY))
        path.curve(
            to: NSPoint(x: rect.maxX, y: rect.maxY - bottomRadius),
            controlPoint1: NSPoint(x: rect.maxX - bottomRadius + bottomControl, y: rect.maxY),
            controlPoint2: NSPoint(x: rect.maxX, y: rect.maxY - bottomRadius + bottomControl)
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + topRadius))
        if topRadius > 0 {
            path.curve(
                to: NSPoint(x: topEndX - topRadius, y: rect.minY),
                controlPoint1: NSPoint(x: topEndX, y: rect.minY + topRadius - topControl),
                controlPoint2: NSPoint(x: topEndX - topRadius + topControl, y: rect.minY)
            )
        }
        path.line(to: NSPoint(x: topStartX + topRadius, y: rect.minY))
        if topRadius > 0 {
            path.curve(
                to: NSPoint(x: topStartX, y: rect.minY + topRadius),
                controlPoint1: NSPoint(x: topStartX + topRadius - topControl, y: rect.minY),
                controlPoint2: NSPoint(x: topStartX, y: rect.minY + topRadius - topControl)
            )
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + topRadius))
        path.close()
        return path
    }

    private func drawLabelIfNeeded() -> CGFloat {
        guard let label, activityLabelWidth > 0 else { return 0 }

        let font = AppTypography.appKitFont(.notchStatus)
        let labelString = label as NSString
        let textWidth = labelString.size(withAttributes: [.font: font]).width
        let glyphFrame = currentGlyphFrame(labelWidth: activityLabelWidth)
        let textRect = NotchActivityLabelRenderPolicy.labelTextRect(
            activityLabelWidth: activityLabelWidth,
            boundsHeight: bounds.height,
            glyphFrame: glyphFrame,
            isNotched: notchSpacerWidth > 0
        )
        guard textRect.width > 0 else { return activityLabelWidth }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hoverDuration = glyphHoverStartedAt.map { CACurrentMediaTime() - $0 } ?? 0
        let isScrolling = NotchActivityLabelRenderPolicy.shouldScrollLabel(
            status: status,
            glyphHovered: glyphHovered,
            hoverDuration: hoverDuration,
            textWidth: textWidth,
            availableWidth: textRect.width,
            reduceMotion: reduceMotion
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = NotchActivityLabelRenderPolicy.lineBreakMode(
            isScrolling: isScrolling
        )
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let drawRect: NSRect
        if isScrolling {
            let offset = NotchActivityLabelRenderPolicy.scrollOffset(
                hoverDuration: hoverDuration,
                textWidth: textWidth
            )
            drawRect = NSRect(
                x: textRect.minX - offset,
                y: textRect.minY,
                width: textWidth,
                height: textRect.height
            )
        } else {
            drawRect = textRect
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: textRect).addClip()
        if isScrolling {
            let stride = NotchActivityLabelRenderPolicy.scrollStride(textWidth: textWidth)
            var x = drawRect.minX
            while x < textRect.maxX {
                labelString.draw(
                    in: NSRect(x: x, y: textRect.minY, width: textWidth, height: textRect.height),
                    withAttributes: attributes
                )
                x += stride
            }
        } else {
            labelString.draw(in: drawRect, withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return activityLabelWidth
    }

    private func drawGlyph(after labelWidth: CGFloat) {
        let glyph = status.glyph
        let glyphSize = NotchStatusPlacementPlanner.glyphSize
        let glyphFrame = currentGlyphFrame(labelWidth: labelWidth)
        let dotOrigin = CGPoint(
            x: glyphFrame.minX + (glyphSize.width - NotchStatusGlyph.artworkSize.width) / 2,
            y: glyphFrame.minY + (glyphSize.height - NotchStatusGlyph.artworkSize.height) / 2
        )
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let activeShimmer = status.usesGlyphShimmer && !reduceMotion
        let time = CACurrentMediaTime()
        let shouldAnimateMotion = shouldAnimateGlyphMotion(reduceMotion: reduceMotion)
        let motionPhase = shouldAnimateMotion ? NotchStatusGlyphMotion.phase(at: time) : 0

        if glyphHovered {
            NSColor(calibratedWhite: 0.85, alpha: 0.25).setFill()
            NSBezierPath(
                ovalIn: NSRect(x: dotOrigin.x + 2, y: dotOrigin.y + 2, width: 20, height: 20)
            ).fill()
        }

        for (index, dot) in glyph.dots.enumerated() {
            let shimmer = activeShimmer
                ? 0.72 + 0.28 * ((Darwin.sin(time * 5.2 + Double(index) * 0.62) + 1) / 2)
                : 1
            let diameter = dot.diameter
            let center = reduceMotion
                ? CGPoint(x: dot.x, y: dot.y)
                : NotchStatusGlyphMotion.transformedCenter(for: dot, status: status, phase: motionPhase)
            let rect = NSRect(
                x: dotOrigin.x + center.x - diameter / 2,
                y: dotOrigin.y + center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            dot.color.nsColor.withAlphaComponent(dot.opacity * shimmer).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    private func updateWaveTimer(restart: Bool) {
        let shouldAnimate = shouldAnimateGlyphMotion(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ) && window != nil

        if restart {
            waveTimer?.invalidate()
            waveTimer = nil
        }

        if shouldAnimate {
            guard waveTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            waveTimer = timer
        } else {
            waveTimer?.invalidate()
            waveTimer = nil
        }
    }

    private func shouldAnimateGlyphMotion(reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        switch status {
        case .working:
            return true
        case .listening, .playing:
            return true
        case .notWorking:
            return false
        }
    }

    private func updateGlyphHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setGlyphHovered(glyphHoverFrame().contains(point))
    }

    private func refreshGlyphHoverFromMouseLocation() {
        guard let window else {
            setGlyphHovered(false)
            return
        }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let point = convert(windowPoint, from: nil)
        setGlyphHovered(glyphHoverFrame().contains(point))
    }

    private func setGlyphHovered(_ hovered: Bool) {
        guard glyphHovered != hovered else { return }
        glyphHovered = hovered
        glyphHoverStartedAt = hovered ? CACurrentMediaTime() : nil
        updateWaveTimer(restart: true)
        needsDisplay = true
        notifyWorkingGlyphHoverChanged()
    }

    private func notifyWorkingGlyphHoverChanged() {
        onWorkingGlyphHoverChanged?(status == .working && glyphHovered)
    }

    private func currentGlyphFrame(labelWidth: CGFloat? = nil) -> NSRect {
        let glyphSize = NotchStatusPlacementPlanner.glyphSize
        let resolvedLabelWidth = labelWidth ?? activityLabelWidth
        let naturalGlyphX = resolvedLabelWidth + leadingSpacerWidth + notchSpacerWidth
        let anchoredGlyphX = glyphScreenX.map { screenX in
            screenX - (window?.frame.minX ?? 0)
        } ?? naturalGlyphX
        let glyphX = min(max(0, anchoredGlyphX), max(0, bounds.width - glyphSize.width))
        let glyphY = max(0, (bounds.height - glyphSize.height) / 2)
        return NSRect(origin: CGPoint(x: glyphX, y: glyphY), size: glyphSize)
    }

    func glyphFrameInScreenCoordinates() -> NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(currentGlyphFrame(), to: nil))
    }

    func glyphHoverFrameInScreenCoordinates() -> NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(glyphHoverFrame(), to: nil))
    }

    private func glyphHoverFrame() -> NSRect {
        NotchHoverInteractionPolicy.frame(
            glyphFrame: currentGlyphFrame(),
            boundsHeight: bounds.height,
            activityLabelWidth: activityLabelWidth,
            leadingSpacerWidth: leadingSpacerWidth,
            notchSpacerWidth: notchSpacerWidth,
            status: status,
            glyphHovered: glyphHovered,
            workingProgressLabel: label,
            hoverSlop: Self.glyphHoverSlop
        )
    }
}

private extension NotchStatusDotColor {
    var nsColor: NSColor {
        switch self {
        case .white:
            return .white
        case .orange:
            return NSColor(calibratedRed: 0.949, green: 0.439, blue: 0.047, alpha: 1)
        case .blue:
            return NSColor(calibratedRed: 0.169, green: 0.067, blue: 0.910, alpha: 1)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
