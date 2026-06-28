import AppKit
import QuartzCore
import SwiftUI

struct NotchStatusDisplayGeometry: Equatable {
    let frame: CGRect
    let auxiliaryTopLeftArea: CGRect
    let auxiliaryTopRightArea: CGRect

    init(
        frame: CGRect,
        auxiliaryTopLeftArea: CGRect = .zero,
        auxiliaryTopRightArea: CGRect
    ) {
        self.frame = frame
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    init(screen: NSScreen) {
        self.frame = screen.frame
        self.auxiliaryTopLeftArea = screen.auxiliaryTopLeftArea ?? .zero
        self.auxiliaryTopRightArea = screen.auxiliaryTopRightArea ?? .zero
    }
}

struct NotchStatusPlacement: Equatable {
    let visibleFrame: CGRect
    let retractedFrame: CGRect
    let activityVisibleFrame: CGRect?
    let activityRetractedFrame: CGRect?
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

    static func resolve(for state: OverlayState, hasActivityLabels: Bool) -> NotchSessionStatus {
        switch state {
        case .listening, .recording:
            return .listening
        case .messageWaiting, .preparing, .speaking:
            return .playing
        default:
            return hasActivityLabels ? .working : .notWorking
        }
    }
}

enum NotchStatusGlyph: Equatable {
    case neutral
    case listening
    case playing

    var dots: [NotchStatusGlyphDot] {
        switch self {
        case .neutral:
            return [
                NotchStatusGlyphDot(x: 5.5, y: 5.5, diameter: 3.4, color: .neutral, opacity: 0.95),
                NotchStatusGlyphDot(x: 12.5, y: 5.5, diameter: 3.4, color: .neutral, opacity: 0.95),
                NotchStatusGlyphDot(x: 5.5, y: 12.5, diameter: 3.4, color: .neutral, opacity: 0.95),
                NotchStatusGlyphDot(x: 12.5, y: 12.5, diameter: 3.4, color: .neutral, opacity: 0.95),
            ]
        case .listening:
            return Self.activityDots(colors: [.orange, .amber], brightCenter: .orange)
        case .playing:
            return Self.activityDots(colors: [.blue, .purple], brightCenter: .lavender)
        }
    }

    private static func activityDots(
        colors: [NotchStatusDotColor],
        brightCenter: NotchStatusDotColor
    ) -> [NotchStatusGlyphDot] {
        let points: [(CGFloat, CGFloat)] = [
            (4, 4), (9, 4), (14, 4),
            (4, 9), (9, 9), (14, 9),
            (4, 14), (9, 14), (14, 14),
        ]
        return points.enumerated().map { index, point in
            let isCenter = index == 4
            return NotchStatusGlyphDot(
                x: point.0,
                y: point.1,
                diameter: isCenter ? 3.4 : 2.6,
                color: isCenter ? brightCenter : colors[index % colors.count],
                opacity: isCenter ? 1.0 : 0.78
            )
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
    case neutral
    case orange
    case amber
    case blue
    case purple
    case lavender
}

enum NotchStatusPlacementPlanner {
    static let surfaceSize = CGSize(width: 30, height: 30)
    static let activitySurfaceSize = CGSize(width: 168, height: 30)

    private static let notchGap: CGFloat = 8
    private static let menuBarGap: CGFloat = 4
    private static let screenEdgeGap: CGFloat = 8

    static func placement(for geometry: NotchStatusDisplayGeometry) -> NotchStatusPlacement? {
        let rightArea = geometry.auxiliaryTopRightArea

        // On notched Macs, AppKit reports the unobscured menu-bar strip to the
        // right of the camera housing here. Non-notched and external displays
        // report an empty rect, so the status surface stays hidden instead of
        // guessing at a surprising fallback position.
        guard !rightArea.isEmpty,
              rightArea.width >= surfaceSize.width + notchGap else {
            return nil
        }

        let maximumX = rightArea.maxX - surfaceSize.width - screenEdgeGap
        let preferredX = rightArea.minX + notchGap
        let x = max(
            geometry.frame.minX + screenEdgeGap,
            min(preferredX, maximumX)
        )

        // Keep the surface below the menu-bar auxiliary area so it sits near
        // the notch without covering menu extras or the camera cutout.
        let preferredY = rightArea.minY - surfaceSize.height - menuBarGap
        let maximumY = geometry.frame.maxY - surfaceSize.height - screenEdgeGap
        let y = max(
            geometry.frame.minY + screenEdgeGap,
            min(preferredY, maximumY)
        )

        let visibleFrame = CGRect(
            x: x,
            y: y,
            width: surfaceSize.width,
            height: surfaceSize.height
        )
        let retractedFrame = CGRect(
            x: max(geometry.frame.minX + screenEdgeGap, rightArea.minX - surfaceSize.width * 0.7),
            y: min(y + 2, maximumY),
            width: surfaceSize.width,
            height: surfaceSize.height
        )

        let activityPlacement = activityFrames(for: geometry)

        return NotchStatusPlacement(
            visibleFrame: visibleFrame,
            retractedFrame: retractedFrame,
            activityVisibleFrame: activityPlacement?.visible,
            activityRetractedFrame: activityPlacement?.retracted
        )
    }

    private static func activityFrames(for geometry: NotchStatusDisplayGeometry) -> (visible: CGRect, retracted: CGRect)? {
        let leftArea = geometry.auxiliaryTopLeftArea
        guard !leftArea.isEmpty,
              leftArea.width >= activitySurfaceSize.width + notchGap else {
            return nil
        }

        let preferredX = leftArea.maxX - activitySurfaceSize.width - notchGap
        let x = max(geometry.frame.minX + screenEdgeGap, preferredX)

        let preferredY = leftArea.minY - activitySurfaceSize.height - menuBarGap
        let maximumY = geometry.frame.maxY - activitySurfaceSize.height - screenEdgeGap
        let y = max(
            geometry.frame.minY + screenEdgeGap,
            min(preferredY, maximumY)
        )

        let visibleFrame = CGRect(
            x: x,
            y: y,
            width: activitySurfaceSize.width,
            height: activitySurfaceSize.height
        )
        let retractedFrame = CGRect(
            x: min(leftArea.maxX - activitySurfaceSize.width * 0.25, geometry.frame.maxX - activitySurfaceSize.width),
            y: min(y + 2, maximumY),
            width: activitySurfaceSize.width,
            height: activitySurfaceSize.height
        )
        return (visibleFrame, retractedFrame)
    }
}

enum NotchActivityLabelPlanner {
    private static let maximumLabels = 3

    static func labels(
        for state: OverlayState,
        activeRuns: [RunState] = [],
        tickets: [Ticket] = [],
        bridgeRecoveryInFlight: Bool = false,
        now: Date = Date()
    ) -> [String] {
        var labels: [String] = []

        if bridgeRecoveryInFlight {
            labels.append("Reconnecting session")
        }
        if let stateLabel = label(for: state) {
            labels.append(stateLabel)
        }

        let runLabels = activeRuns
            .filter(\.isActive)
            .sorted { lhs, rhs in
                if lhs.runId != rhs.runId { return lhs.runId > rhs.runId }
                return (lhs.activityAt ?? 0) > (rhs.activityAt ?? 0)
            }
            .compactMap { label(for: $0, now: now) }
        labels.append(contentsOf: runLabels)

        if hasWaitingDependency(in: tickets) {
            labels.append("Waiting dependency")
        }

        return conciseUnique(labels).prefix(maximumLabels).map { $0 }
    }

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
        case .sessionPrompt:
            return "Waiting session"
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

    static func hasWaitingDependency(in tickets: [Ticket]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })
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

final class NotchStatusController {
    private var panel: NotchStatusPanel?
    private var activityPanel: NotchStatusPanel?
    private var active = false
    private var status: NotchSessionStatus = .notWorking
    private var activityLabels: [String] = []
    private var activityIndex = 0
    private var carouselTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?
    private var lastPlacement: NotchStatusPlacement?
    private var loggedMissingNotch = false

    deinit {
        carouselTimer?.invalidate()
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
                updatePlacement(animated: false)
            }
            return
        }

        self.active = active
        if active {
            show()
            if !activityLabels.isEmpty {
                showActivity()
            }
        } else {
            hide()
        }
    }

    func setStatus(_ status: NotchSessionStatus) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setStatus(status)
            }
            return
        }

        guard self.status != status else { return }
        self.status = status
        updateStatusContent()
        updateActivityContent()
    }

    func setActivityLabels(_ labels: [String]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setActivityLabels(labels)
            }
            return
        }

        let compactLabels = Array(labels.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard compactLabels != activityLabels else {
            if active, !compactLabels.isEmpty {
                updateActivityPlacement(animated: false)
            }
            return
        }

        activityLabels = compactLabels
        activityIndex = 0

        guard active, !activityLabels.isEmpty else {
            hideActivity()
            return
        }

        updateActivityContent()
        showActivity()
        updateCarousel()
    }

    private func show() {
        installScreenParametersObserver()

        guard let placement = currentPlacement() else {
            if !loggedMissingNotch {
                NSLog("[RelayRunner] Notch status surface hidden: no display exposes an auxiliary top-right notch area.")
                loggedMissingNotch = true
            }
            panel?.orderOut(nil)
            hideActivity()
            return
        }

        loggedMissingNotch = false
        lastPlacement = placement

        let panel = panel ?? NotchStatusPanel()
        if self.panel == nil {
            self.panel = panel
        }
        updateStatusContent()

        panel.setFrame(placement.retractedFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration(0.22)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.95, 0.2, 1.0)
            panel.animator().setFrame(placement.visibleFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        removeScreenParametersObserver()
        hideActivity()

        guard let panel else { return }
        let targetFrame = currentPlacement()?.retractedFrame
            ?? lastPlacement?.retractedFrame
            ?? panel.frame.offsetBy(dx: -10, dy: 2)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration(0.18)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func updatePlacement(animated: Bool) {
        guard let placement = currentPlacement() else {
            panel?.orderOut(nil)
            hideActivity()
            return
        }
        lastPlacement = placement

        guard let panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration(0.18)
                panel.animator().setFrame(placement.visibleFrame, display: true)
            }
        } else {
            panel.setFrame(placement.visibleFrame, display: true)
        }
        if activityLabels.isEmpty {
            hideActivity()
        } else {
            showActivity()
        }
    }

    private func showActivity() {
        installScreenParametersObserver()

        guard let placement = currentPlacement(),
              let visibleFrame = placement.activityVisibleFrame,
              let retractedFrame = placement.activityRetractedFrame else {
            activityPanel?.orderOut(nil)
            stopCarousel()
            return
        }

        lastPlacement = placement

        let panel = activityPanel ?? NotchStatusPanel()
        if activityPanel == nil {
            self.activityPanel = panel
        }
        updateActivityContent()

        guard !panel.isVisible else {
            updateActivityPlacement(animated: true)
            updateCarousel()
            return
        }

        panel.setFrame(retractedFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration(0.24)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.98, 0.18, 1.0)
            panel.animator().setFrame(visibleFrame, display: true)
            panel.animator().alphaValue = 1
        }
        updateCarousel()
    }

    private func hideActivity() {
        stopCarousel()

        guard let panel = activityPanel else { return }
        let targetFrame = currentPlacement()?.activityRetractedFrame
            ?? lastPlacement?.activityRetractedFrame
            ?? panel.frame.offsetBy(dx: 12, dy: 2)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationDuration(0.18)
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1.0, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func updateActivityPlacement(animated: Bool) {
        guard !activityLabels.isEmpty,
              let panel = activityPanel,
              let placement = currentPlacement(),
              let visibleFrame = placement.activityVisibleFrame else {
            activityPanel?.orderOut(nil)
            stopCarousel()
            return
        }

        lastPlacement = placement
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration(0.18)
                panel.animator().setFrame(visibleFrame, display: true)
            }
        } else {
            panel.setFrame(visibleFrame, display: true)
        }
    }

    private func updateActivityContent() {
        guard let panel = activityPanel,
              let label = activityLabels[safe: activityIndex] else {
            return
        }
        panel.contentView = NSHostingView(rootView: NotchActivityCapsuleView(status: status, label: label))
    }

    private func updateStatusContent() {
        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: NotchStatusIconView(status: status))
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
        updateActivityContent()
    }

    private func currentPlacement() -> NotchStatusPlacement? {
        // Multi-display rule: prefer the notched display under the pointer;
        // otherwise keep the icon on the first display that reports a notch.
        // Non-notched displays stay empty rather than growing a detached badge.
        if let mouseScreen = NSScreen.screens.first(where: { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }),
           let placement = Self.placement(for: mouseScreen) {
            return placement
        }

        for screen in NSScreen.screens {
            if let placement = Self.placement(for: screen) {
                return placement
            }
        }

        return nil
    }

    private static func placement(for screen: NSScreen) -> NotchStatusPlacement? {
        NotchStatusPlacementPlanner.placement(for: NotchStatusDisplayGeometry(screen: screen))
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

private final class NotchStatusPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }
}

private struct NotchStatusIconView: View {
    let status: NotchSessionStatus

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.94))
                .shadow(color: status.glyph.shadowColor.opacity(0.34), radius: 5, y: 1)

            NotchDotMatrixView(glyph: status.glyph)
        }
        .frame(
            width: NotchStatusPlacementPlanner.surfaceSize.width,
            height: NotchStatusPlacementPlanner.surfaceSize.height
        )
    }
}

private struct NotchActivityCapsuleView: View {
    let status: NotchSessionStatus
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            NotchDotMatrixView(glyph: status.glyph, scale: 0.62)
                .frame(width: 14, height: 14)

            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(
            width: NotchStatusPlacementPlanner.activitySurfaceSize.width,
            height: NotchStatusPlacementPlanner.activitySurfaceSize.height
        )
        .background {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.94))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: Color.black.opacity(0.28), radius: 8, y: 2)
        }
    }
}

private struct NotchDotMatrixView: View {
    let glyph: NotchStatusGlyph
    var scale: CGFloat = 1

    var body: some View {
        ZStack {
            ForEach(Array(glyph.dots.enumerated()), id: \.offset) { _, dot in
                Circle()
                    .fill(dot.color.swiftUIColor.opacity(dot.opacity))
                    .frame(width: dot.diameter * scale, height: dot.diameter * scale)
                    .position(x: dot.x * scale, y: dot.y * scale)
            }
        }
        .frame(width: 18 * scale, height: 18 * scale)
    }
}

private extension NotchStatusGlyph {
    var shadowColor: Color {
        switch self {
        case .neutral:
            return .white
        case .listening:
            return NotchStatusDotColor.orange.swiftUIColor
        case .playing:
            return NotchStatusDotColor.purple.swiftUIColor
        }
    }
}

private extension NotchStatusDotColor {
    var swiftUIColor: Color {
        switch self {
        case .neutral:
            return Color.white
        case .orange:
            return Color(red: 1.0, green: 0.32, blue: 0.06)
        case .amber:
            return Color(red: 1.0, green: 0.62, blue: 0.18)
        case .blue:
            return Color(red: 0.22, green: 0.26, blue: 1.0)
        case .purple:
            return Color(red: 0.48, green: 0.34, blue: 1.0)
        case .lavender:
            return Color(red: 0.82, green: 0.78, blue: 1.0)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
