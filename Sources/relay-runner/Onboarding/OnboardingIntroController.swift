import AppKit
import QuartzCore

struct OnboardingIntroFrame: Equatable {
    let activePhrase: String
    let text: String
    let isComplete: Bool
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

enum OnboardingIntroTimeline {
    static let phrases = [
        "First thing’s first",
        "I need a few permissions",
        "Relay Runner",
    ]
    static let typingInterval: TimeInterval = 0.035
    static let eraseInterval: TimeInterval = 0.020
    static let phraseHold: TimeInterval = 0.55

    static var duration: TimeInterval {
        phrases.reduce(0) { total, phrase in
            let count = Double(phraseGraphemes(phrase).count)
            return total + count * typingInterval + phraseHold + count * eraseInterval
        }
    }

    static func frame(at elapsed: TimeInterval) -> OnboardingIntroFrame {
        guard elapsed < duration else {
            return OnboardingIntroFrame(activePhrase: phrases.last ?? "", text: "/", isComplete: true)
        }

        var cursor = max(0, elapsed)
        for phrase in phrases {
            let graphemes = phraseGraphemes(phrase)
            let typeDuration = Double(graphemes.count) * typingInterval
            if cursor < typeDuration {
                let visibleCount = min(graphemes.count, Int(cursor / typingInterval))
                return frame(phrase: phrase, visible: Array(graphemes.prefix(visibleCount)))
            }
            cursor -= typeDuration

            if cursor < phraseHold {
                return frame(phrase: phrase, visible: graphemes)
            }
            cursor -= phraseHold

            let eraseDuration = Double(graphemes.count) * eraseInterval
            if cursor < eraseDuration {
                let erasedCount = min(graphemes.count, Int(cursor / eraseInterval) + 1)
                let remainingCount = max(0, graphemes.count - erasedCount)
                return frame(phrase: phrase, visible: Array(graphemes.prefix(remainingCount)))
            }
            cursor -= eraseDuration
        }

        return OnboardingIntroFrame(activePhrase: phrases.last ?? "", text: "/", isComplete: true)
    }

    private static func frame(phrase: String, visible: [Character]) -> OnboardingIntroFrame {
        let prefix = String(visible)
        let text = prefix.isEmpty ? "/" : "\(prefix) /"
        return OnboardingIntroFrame(activePhrase: phrase, text: text, isComplete: false)
    }

    private static func phraseGraphemes(_ phrase: String) -> [Character] {
        Array(phrase)
    }
}

final class OnboardingIntroController {
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
        let textView = OnboardingIntroTextView(frame: contentFrame)
        textView.autoresizingMask = [.width, .height]
        textView.timelineFrame = OnboardingIntroTimeline.frame(at: 0)

        let container = BoardRevealContainerView(
            frame: contentFrame,
            contentView: textView,
            displayGeometry: screen.map(NotchStatusDisplayGeometry.init(screen:))
                ?? NotchStatusDisplayGeometry(screenFrame: p.frame),
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
    var timelineFrame = OnboardingIntroTimeline.frame(at: 0) {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        paragraph.minimumLineHeight = 72
        paragraph.maximumLineHeight = 72
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let reserveText = "\(timelineFrame.activePhrase) /" as NSString
        let visibleText = timelineFrame.text as NSString
        let reserveSize = reserveText.size(withAttributes: attributes)
        let lineHeight: CGFloat = 72
        let drawRect = NSRect(
            x: bounds.midX - reserveSize.width / 2,
            y: bounds.midY - lineHeight / 2,
            width: max(reserveSize.width, visibleText.size(withAttributes: attributes).width),
            height: lineHeight
        )
        visibleText.draw(in: drawRect, withAttributes: attributes)
    }
}
