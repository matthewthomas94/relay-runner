import AppKit
import QuartzCore

struct OnboardingIntroFrame: Equatable {
    let activePhrase: String
    let text: String
    let cursorVisible: Bool
    let dotFieldProgress: CGFloat
    let dotFieldOpacity: CGFloat
    let isComplete: Bool

    var renderedText: String {
        cursorVisible ? text : Self.textWithoutCursor(text)
    }

    private static func textWithoutCursor(_ text: String) -> String {
        guard text.hasSuffix("/") else { return text }
        return String(text.dropLast())
    }
}

struct OnboardingIntroCompletionPlan: Equatable {
    let startsTimeline: Bool
    let cleansUpSurface: Bool
    let performsHandoff: Bool
}

enum OnboardingIntroPolicy {
    static let notchLabel = "Getting started"

    static func shouldPlayAutomaticIntro(
        hasOnboarded: Bool,
        wasInterrupted: Bool,
        reduceMotion: Bool
    ) -> Bool {
        !hasOnboarded && !wasInterrupted && !reduceMotion
    }

    static func completionPlan(
        revealCompleted: Bool,
        skipRequested: Bool,
        timelineComplete: Bool,
        isCompleting: Bool
    ) -> OnboardingIntroCompletionPlan {
        guard !isCompleting else {
            return OnboardingIntroCompletionPlan(
                startsTimeline: false,
                cleansUpSurface: false,
                performsHandoff: false
            )
        }
        let shouldComplete = skipRequested || timelineComplete
        return OnboardingIntroCompletionPlan(
            startsTimeline: revealCompleted && !shouldComplete,
            cleansUpSurface: shouldComplete,
            performsHandoff: shouldComplete
        )
    }
}

protocol OnboardingIntroPresenting: AnyObject {
    func present(completion: @escaping () -> Void)
}

enum OnboardingIntroTimeline {
    static let phrases = [
        "Relay Runner",
        "First thing’s first",
        "I need a few permissions",
    ]
    static let initialBrandHold: TimeInterval = 0.35
    static let typingInterval: TimeInterval = 0.035
    static let eraseInterval: TimeInterval = 0.020
    static let phraseHold: TimeInterval = 0.55
    static let dotFieldTravel: TimeInterval = 1.15
    static let finalPhraseHold: TimeInterval = 0.85
    static let cursorBlinkPeriod: TimeInterval = 0.8

    static var duration: TimeInterval {
        let brandCount = Double(phraseGraphemes(phrases[0]).count)
        let firstCopyCount = Double(phraseGraphemes(phrases[1]).count)
        let finalCopyCount = Double(phraseGraphemes(phrases[2]).count)
        return initialBrandHold
            + max(0, brandCount - 1) * typingInterval
            + dotFieldTravel
            + brandCount * eraseInterval
            + firstCopyCount * typingInterval
            + phraseHold
            + firstCopyCount * eraseInterval
            + finalCopyCount * typingInterval
            + finalPhraseHold
    }

    static func frame(at elapsed: TimeInterval) -> OnboardingIntroFrame {
        guard elapsed < duration else {
            return frame(
                phrase: phrases.last ?? "",
                visible: phraseGraphemes(phrases.last ?? ""),
                cursorVisible: true,
                isComplete: true
            )
        }

        var cursor = max(0, elapsed)
        let brand = phrases[0]
        let brandGraphemes = phraseGraphemes(brand)

        if cursor < initialBrandHold {
            return frame(
                phrase: brand,
                visible: Array(brandGraphemes.prefix(1)),
                compactCursor: true,
                cursorVisible: blinkingCursorVisible(at: cursor),
                dotFieldOpacity: 0
            )
        }
        cursor -= initialBrandHold

        let brandTypeDuration = Double(max(0, brandGraphemes.count - 1)) * typingInterval
        if cursor < brandTypeDuration {
            let visibleCount = min(
                brandGraphemes.count,
                1 + Int(cursor / typingInterval)
            )
            return frame(
                phrase: brand,
                visible: Array(brandGraphemes.prefix(visibleCount)),
                cursorVisible: true,
                dotFieldOpacity: 0
            )
        }
        cursor -= brandTypeDuration

        if cursor < dotFieldTravel {
            return frame(
                phrase: brand,
                visible: brandGraphemes,
                cursorVisible: blinkingCursorVisible(at: cursor),
                dotFieldProgress: CGFloat(cursor / dotFieldTravel),
                dotFieldOpacity: 1
            )
        }
        cursor -= dotFieldTravel

        let brandEraseDuration = Double(brandGraphemes.count) * eraseInterval
        if cursor < brandEraseDuration {
            let erasedCount = min(brandGraphemes.count, Int(cursor / eraseInterval) + 1)
            let remainingCount = max(0, brandGraphemes.count - erasedCount)
            return frame(
                phrase: brand,
                visible: Array(brandGraphemes.prefix(remainingCount)),
                compactCursor: remainingCount == 1,
                cursorVisible: true,
                dotFieldProgress: 1,
                dotFieldOpacity: 1
            )
        }
        cursor -= brandEraseDuration

        let firstCopy = phrases[1]
        let firstCopyGraphemes = phraseGraphemes(firstCopy)
        let firstTypeDuration = Double(firstCopyGraphemes.count) * typingInterval
        if cursor < firstTypeDuration {
            let visibleCount = min(firstCopyGraphemes.count, Int(cursor / typingInterval))
            return frame(phrase: firstCopy, visible: Array(firstCopyGraphemes.prefix(visibleCount)))
        }
        cursor -= firstTypeDuration

        if cursor < phraseHold {
            return frame(
                phrase: firstCopy,
                visible: firstCopyGraphemes,
                cursorVisible: blinkingCursorVisible(at: cursor)
            )
        }
        cursor -= phraseHold

        let firstEraseDuration = Double(firstCopyGraphemes.count) * eraseInterval
        if cursor < firstEraseDuration {
            let erasedCount = min(firstCopyGraphemes.count, Int(cursor / eraseInterval) + 1)
            let remainingCount = max(0, firstCopyGraphemes.count - erasedCount)
            return frame(
                phrase: firstCopy,
                visible: Array(firstCopyGraphemes.prefix(remainingCount)),
                cursorVisible: true
            )
        }
        cursor -= firstEraseDuration

        let finalCopy = phrases[2]
        let finalCopyGraphemes = phraseGraphemes(finalCopy)
        let finalTypeDuration = Double(finalCopyGraphemes.count) * typingInterval
        if cursor < finalTypeDuration {
            let visibleCount = min(finalCopyGraphemes.count, Int(cursor / typingInterval))
            return frame(phrase: finalCopy, visible: Array(finalCopyGraphemes.prefix(visibleCount)))
        }
        cursor -= finalTypeDuration

        return frame(
            phrase: finalCopy,
            visible: finalCopyGraphemes,
            cursorVisible: blinkingCursorVisible(at: cursor)
        )
    }

    private static func frame(
        phrase: String,
        visible: [Character],
        compactCursor: Bool = false,
        cursorVisible: Bool = true,
        dotFieldProgress: CGFloat = 0,
        dotFieldOpacity: CGFloat = 0,
        isComplete: Bool = false
    ) -> OnboardingIntroFrame {
        let prefix = String(visible)
        let text = if prefix.isEmpty {
            "/"
        } else if compactCursor {
            "\(prefix)/"
        } else {
            "\(prefix) /"
        }
        return OnboardingIntroFrame(
            activePhrase: phrase,
            text: text,
            cursorVisible: cursorVisible,
            dotFieldProgress: min(max(dotFieldProgress, 0), 1),
            dotFieldOpacity: min(max(dotFieldOpacity, 0), 1),
            isComplete: isComplete
        )
    }

    private static func blinkingCursorVisible(at elapsed: TimeInterval) -> Bool {
        elapsed.truncatingRemainder(dividingBy: cursorBlinkPeriod) < cursorBlinkPeriod / 2
    }

    private static func phraseGraphemes(_ phrase: String) -> [Character] {
        Array(phrase)
    }
}

struct OnboardingHalftoneFieldFrame: Equatable {
    let frame: CGRect
    let clipFrame: CGRect
    let scale: CGFloat
}

enum OnboardingHalftoneFieldLayout {
    static let referenceWorkspaceSize = CGSize(width: 1688, height: 736)
    static let referenceFieldSize = CGSize(width: 1917, height: 840)
    static let referenceStartOrigin = CGPoint(x: -114, y: 374)
    static let referenceRaisedY: CGFloat = 94
    static let dotSpacing: CGFloat = 16.95

    static func plan(in workspaceFrame: CGRect, progress: CGFloat) -> OnboardingHalftoneFieldFrame {
        let scale = workspaceFrame.width / referenceWorkspaceSize.width
        let clamped = min(max(progress, 0), 1)
        let y = referenceStartOrigin.y
            + (referenceRaisedY - referenceStartOrigin.y) * clamped
        let frame = CGRect(
            x: workspaceFrame.minX + referenceStartOrigin.x * scale,
            y: workspaceFrame.minY + y * scale,
            width: referenceFieldSize.width * scale,
            height: referenceFieldSize.height * scale
        )
        return OnboardingHalftoneFieldFrame(
            frame: frame,
            clipFrame: workspaceFrame,
            scale: scale
        )
    }

    static func dotDiameter(localX: CGFloat, localY: CGFloat, scale: CGFloat) -> CGFloat {
        let vertical = smoothStep(edge0: 120 * scale, edge1: 830 * scale, value: localY)
        let wave = 0.5 + 0.5 * sin((localX / max(scale, 0.001)) * 0.034 + (localY / max(scale, 0.001)) * 0.022)
        return (1.05 + 9.95 * vertical + 1.1 * wave * vertical) * scale
    }

    static func dotAlpha(localX: CGFloat,
                         localY: CGFloat,
                         fieldSize: CGSize,
                         diameter: CGFloat) -> CGFloat {
        let vertical = smoothStep(edge0: fieldSize.height * 0.16, edge1: fieldSize.height * 0.72, value: localY)
        let leftFade = smoothStep(edge0: 0, edge1: fieldSize.width * 0.12, value: localX)
        let rightFade = smoothStep(edge0: 0, edge1: fieldSize.width * 0.12, value: fieldSize.width - localX)
        let sizeBoost = min(max((diameter - 1) / 11, 0), 1)
        return min(max((0.22 + 0.78 * vertical) * leftFade * rightFade * (0.78 + 0.22 * sizeBoost), 0), 1)
    }

    private static func smoothStep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return value < edge0 ? 0 : 1 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

enum OnboardingIntroTextLayout {
    static let lineHeight: CGFloat = 66
    static let referenceWorkspaceHeight: CGFloat = 736
    static let referenceTextTop: CGFloat = 325

    static func drawRect(
        in layoutFrame: CGRect,
        reserveWidth: CGFloat,
        visibleWidth: CGFloat
    ) -> CGRect {
        let scale = layoutFrame.height / referenceWorkspaceHeight
        return CGRect(
            x: layoutFrame.midX - reserveWidth / 2,
            y: layoutFrame.minY + referenceTextTop * scale,
            width: max(reserveWidth, visibleWidth),
            height: lineHeight * scale
        )
    }
}

final class OnboardingIntroController: OnboardingIntroPresenting {
    private var panel: BoardOverlayPanel?
    private weak var revealContainer: BoardRevealContainerView?
    private weak var textView: OnboardingIntroTextView?
    private var timelineTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var startedAt: CFTimeInterval?
    private var completion: (() -> Void)?
    private var isCompleting = false

    deinit {
        timelineTimer?.invalidate()
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    func present(completion: @escaping () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completion()
            return
        }

        self.completion = completion
        isCompleting = false

        let p = BoardOverlayPanel()
        let screen = Self.currentMouseScreen() ?? NSScreen.main
        if let screen {
            p.reframe(to: screen)
        }
        let contentFrame = NSRect(origin: .zero, size: p.frame.size)
        let displayGeometry = screen.map(NotchStatusDisplayGeometry.init(screen:))
            ?? NotchStatusDisplayGeometry(screenFrame: p.frame)
        let revealPlan = BoardRevealTransitionPlanner.plan(for: displayGeometry)
        let textView = OnboardingIntroTextView(frame: contentFrame)
        textView.autoresizingMask = [.width, .height]
        textView.layoutFrame = revealPlan.expandedFrame
        textView.timelineFrame = OnboardingIntroTimeline.frame(at: 0)

        let container = BoardRevealContainerView(
            frame: contentFrame,
            contentView: textView,
            displayGeometry: displayGeometry,
            startsLoading: false
        )
        container.autoresizingMask = [.width, .height]

        p.contentView = container
        p.orderFrontRegardless()
        panel = p
        revealContainer = container
        self.textView = textView
        installSkipMonitors()

        DispatchQueue.main.async { [weak self, weak container] in
            container?.animateReveal { [weak self] in
                guard let self,
                      OnboardingIntroPolicy.completionPlan(
                        revealCompleted: true,
                        skipRequested: false,
                        timelineComplete: false,
                        isCompleting: self.isCompleting
                      ).startsTimeline else { return }
                self.startTimeline()
            }
        }
    }

    func skip() {
        guard OnboardingIntroPolicy.completionPlan(
            revealCompleted: false,
            skipRequested: true,
            timelineComplete: false,
            isCompleting: isCompleting
        ).cleansUpSurface else { return }
        finish()
    }

    private func startTimeline() {
        startedAt = CACurrentMediaTime()
        timelineTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timelineTimer = timer
        tick()
    }

    private func tick() {
        guard let startedAt else { return }
        let frame = OnboardingIntroTimeline.frame(at: CACurrentMediaTime() - startedAt)
        textView?.timelineFrame = frame
        if OnboardingIntroPolicy.completionPlan(
            revealCompleted: true,
            skipRequested: false,
            timelineComplete: frame.isComplete,
            isCompleting: isCompleting
        ).cleansUpSurface {
            finish()
        }
    }

    private func finish() {
        guard !isCompleting else { return }
        isCompleting = true
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let completion = self.completion
        self.completion = nil
        let panel = panel
        let container = revealContainer

        let complete: () -> Void = { [weak self, weak panel] in
            panel?.orderOut(nil)
            panel?.contentView = nil
            self?.panel = nil
            self?.revealContainer = nil
            self?.textView = nil
            completion?()
        }

        if let container {
            container.animateDismiss(completion: complete)
        } else {
            complete()
        }
    }

    private func installSkipMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async { self?.skip() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async { self?.skip() }
            return event
        }
    }

    private func removeSkipMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private static func currentMouseScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            NSMouseInRect(NSEvent.mouseLocation, screen.frame, false)
        }
    }
}

private final class OnboardingIntroTextView: NSView {
    var layoutFrame: NSRect = .zero {
        didSet { needsDisplay = true }
    }

    var timelineFrame = OnboardingIntroTimeline.frame(at: 0) {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layoutFrame = frameRect
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityLabel("Relay Runner setup is getting started")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let font = AppTypography.appKitFont(.onboardingHero)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = OnboardingIntroTextLayout.lineHeight
        paragraph.maximumLineHeight = OnboardingIntroTextLayout.lineHeight
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let reserveText = "\(timelineFrame.activePhrase) /" as NSString
        let visibleText = timelineFrame.renderedText as NSString
        let reserveSize = reserveText.size(withAttributes: attributes)
        let drawRect = OnboardingIntroTextLayout.drawRect(
            in: layoutFrame,
            reserveWidth: reserveSize.width,
            visibleWidth: visibleText.size(withAttributes: attributes).width
        )
        drawHalftoneFieldIfNeeded()
        visibleText.draw(in: drawRect, withAttributes: attributes)
    }

    private func drawHalftoneFieldIfNeeded() {
        guard timelineFrame.dotFieldOpacity > 0 else { return }
        let plan = OnboardingHalftoneFieldLayout.plan(
            in: layoutFrame,
            progress: timelineFrame.dotFieldProgress
        )
        guard plan.scale > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plan.clipFrame).addClip()

        let fieldFrame = plan.frame
        let spacing = OnboardingHalftoneFieldLayout.dotSpacing * plan.scale
        guard spacing > 0 else { return }
        let startColumn = max(0, Int(floor((plan.clipFrame.minX - fieldFrame.minX) / spacing)) - 1)
        let endColumn = Int(ceil((plan.clipFrame.maxX - fieldFrame.minX) / spacing)) + 1
        let startRow = max(0, Int(floor((plan.clipFrame.minY - fieldFrame.minY) / spacing)) - 1)
        let endRow = Int(ceil((plan.clipFrame.maxY - fieldFrame.minY) / spacing)) + 1
        let fieldSize = fieldFrame.size

        for row in startRow...endRow {
            let localY = CGFloat(row) * spacing
            guard localY >= 0, localY <= fieldSize.height else { continue }
            for column in startColumn...endColumn {
                let localX = CGFloat(column) * spacing
                guard localX >= 0, localX <= fieldSize.width else { continue }

                let jitter = deterministicJitter(column: column, row: row, scale: plan.scale)
                let center = CGPoint(
                    x: fieldFrame.minX + localX + jitter.x,
                    y: fieldFrame.minY + localY + jitter.y
                )
                guard plan.clipFrame.insetBy(dx: -14, dy: -14).contains(center) else { continue }

                let diameter = OnboardingHalftoneFieldLayout.dotDiameter(
                    localX: localX,
                    localY: localY,
                    scale: plan.scale
                )
                let alpha = OnboardingHalftoneFieldLayout.dotAlpha(
                    localX: localX,
                    localY: localY,
                    fieldSize: fieldSize,
                    diameter: diameter
                ) * timelineFrame.dotFieldOpacity
                guard alpha > 0.01 else { continue }

                let blueMix = min(max(localY / max(fieldSize.height, 1), 0), 1)
                let color = NSColor(
                    srgbRed: 0.12 + 0.18 * (1 - blueMix),
                    green: 0.22 + 0.42 * (1 - blueMix),
                    blue: 1.0,
                    alpha: alpha * 0.82
                )
                color.setFill()
                NSBezierPath(ovalIn: CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )).fill()
            }
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func deterministicJitter(column: Int, row: Int, scale: CGFloat) -> CGPoint {
        let seed = Double(column * 73_856_093 ^ row * 19_349_663)
        return CGPoint(
            x: CGFloat(sin(seed) * 1.4) * scale,
            y: CGFloat(cos(seed * 0.73) * 1.4) * scale
        )
    }
}
