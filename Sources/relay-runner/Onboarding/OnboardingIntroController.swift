import AppKit
import QuartzCore
import SwiftUI

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
            cleansUpSurface: false,
            performsHandoff: shouldComplete
        )
    }
}

protocol OnboardingIntroPresenting: AnyObject {
    func present(completion: @escaping () -> Void)
    func presentPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                                 action: @escaping () -> Void)
    func presentAgentChoicePrompt(selectedProvider: GeneralConfig.AgentProvider,
                                  codexAction: @escaping () -> Void,
                                  claudeAction: @escaping () -> Void)
    func presentRuntimePrompt(_ presentation: OnboardingRuntimePromptPresentation,
                              retryAction: @escaping () -> Void)
    func presentAgentLoginPrompt(_ presentation: OnboardingAgentLoginPromptPresentation,
                                 signInAction: @escaping () -> Void)
    func presentWorkspacePrompt(currentPath: String,
                                action: @escaping () -> Void)
    func dismiss(completion: @escaping () -> Void)
}

struct OnboardingRuntimePromptPresentation: Equatable {
    let provider: GeneralConfig.AgentProvider
    let status: VenvInstaller.Status
}

struct OnboardingAgentLoginPromptPresentation: Equatable {
    let provider: GeneralConfig.AgentProvider
    let signedIn: Bool
    let message: String?
}

enum OnboardingIntroTimeline {
    static let phrases = [
        "Relay Runner",
        "First thing’s first",
        "I need a few permissions",
    ]
    static let initialBrandHold: TimeInterval = 0.70
    static let typingInterval: TimeInterval = 0.065
    static let eraseInterval: TimeInterval = 0.045
    static let phraseHold: TimeInterval = 1.05
    static let dotFieldTravel: TimeInterval = 2.00
    static let finalPhraseHold: TimeInterval = 1.50
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
    private weak var rootView: OnboardingIntroRootView?
    private var timelineTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var startedAt: CFTimeInterval?
    private var cinematicCompletion: (() -> Void)?
    private var cinematicHandoffInProgress = false

    deinit {
        timelineTimer?.invalidate()
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        rootView?.stopAnimations()
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    func present(completion: @escaping () -> Void) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            completion()
            return
        }

        cinematicCompletion = completion
        cinematicHandoffInProgress = false

        let surface = ensureSurface()
        surface.rootView.showCinematic()
        surface.rootView.timelineFrame = OnboardingIntroTimeline.frame(at: 0)
        installSkipMonitors()

        let startTimeline = { [weak self] in
            guard let self,
                  OnboardingIntroPolicy.completionPlan(
                    revealCompleted: true,
                    skipRequested: false,
                    timelineComplete: false,
                    isCompleting: self.cinematicHandoffInProgress
                  ).startsTimeline else { return }
            self.startTimeline()
        }

        if surface.didCreate {
            DispatchQueue.main.async { [weak container = surface.container] in
                container?.animateReveal(completion: startTimeline)
            }
        } else {
            startTimeline()
        }
    }

    func presentPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                                 action: @escaping () -> Void) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let surface = ensureSurface()
        surface.rootView.showPermissionPrompt(presentation, action: action)

        guard surface.didCreate else { return }
        DispatchQueue.main.async { [weak container = surface.container] in
            container?.animateReveal {}
        }
    }

    func presentAgentChoicePrompt(selectedProvider: GeneralConfig.AgentProvider,
                                  codexAction: @escaping () -> Void,
                                  claudeAction: @escaping () -> Void) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let surface = ensureSurface()
        surface.rootView.showAgentChoicePrompt(
            selectedProvider: selectedProvider,
            codexAction: codexAction,
            claudeAction: claudeAction
        )

        guard surface.didCreate else { return }
        DispatchQueue.main.async { [weak container = surface.container] in
            container?.animateReveal {}
        }
    }

    func presentRuntimePrompt(_ presentation: OnboardingRuntimePromptPresentation,
                              retryAction: @escaping () -> Void) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let surface = ensureSurface()
        surface.rootView.showRuntimePrompt(presentation, retryAction: retryAction)

        guard surface.didCreate else { return }
        DispatchQueue.main.async { [weak container = surface.container] in
            container?.animateReveal {}
        }
    }

    func presentAgentLoginPrompt(_ presentation: OnboardingAgentLoginPromptPresentation,
                                 signInAction: @escaping () -> Void) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let surface = ensureSurface()
        surface.rootView.showAgentLoginPrompt(presentation, signInAction: signInAction)

        guard surface.didCreate else { return }
        DispatchQueue.main.async { [weak container = surface.container] in
            container?.animateReveal {}
        }
    }

    func presentWorkspacePrompt(currentPath: String,
                                action: @escaping () -> Void) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let surface = ensureSurface()
        surface.rootView.showWorkspacePrompt(currentPath: currentPath, action: action)

        guard surface.didCreate else { return }
        DispatchQueue.main.async { [weak container = surface.container] in
            container?.animateReveal {}
        }
    }

    func dismiss(completion: @escaping () -> Void) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let panel = panel
        let container = revealContainer

        let complete: () -> Void = { [weak self, weak panel] in
            self?.rootView?.stopAnimations()
            panel?.orderOut(nil)
            panel?.contentView = nil
            self?.panel = nil
            self?.revealContainer = nil
            self?.rootView = nil
            completion()
        }

        if let container {
            container.animateDismiss(completion: complete)
        } else {
            complete()
        }
    }

    private func ensureSurface() -> (rootView: OnboardingIntroRootView, container: BoardRevealContainerView, didCreate: Bool) {
        if let rootView, let revealContainer {
            return (rootView, revealContainer, false)
        }

        let p = BoardOverlayPanel()
        let screen = Self.currentMouseScreen() ?? NSScreen.main
        if let screen {
            p.reframe(to: screen)
        }
        let contentFrame = NSRect(origin: .zero, size: p.frame.size)
        let displayGeometry = screen.map(NotchStatusDisplayGeometry.init(screen:))
            ?? NotchStatusDisplayGeometry(screenFrame: p.frame)
        let revealPlan = BoardRevealTransitionPlanner.plan(for: displayGeometry)
        let rootView = OnboardingIntroRootView(frame: contentFrame)
        rootView.autoresizingMask = [.width, .height]
        rootView.layoutFrame = revealPlan.expandedFrame

        let container = BoardRevealContainerView(
            frame: contentFrame,
            contentView: rootView,
            displayGeometry: displayGeometry,
            startsLoading: false
        )
        container.autoresizingMask = [.width, .height]

        p.contentView = container
        p.orderFrontRegardless()
        panel = p
        revealContainer = container
        self.rootView = rootView
        return (rootView, container, true)
    }

    func skip() {
        guard OnboardingIntroPolicy.completionPlan(
            revealCompleted: false,
            skipRequested: true,
            timelineComplete: false,
            isCompleting: cinematicHandoffInProgress
        ).performsHandoff else { return }
        completeCinematic()
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
        rootView?.timelineFrame = frame
        if OnboardingIntroPolicy.completionPlan(
            revealCompleted: true,
            skipRequested: false,
            timelineComplete: frame.isComplete,
            isCompleting: cinematicHandoffInProgress
        ).performsHandoff {
            completeCinematic()
        }
    }

    private func completeCinematic() {
        guard !cinematicHandoffInProgress else { return }
        cinematicHandoffInProgress = true
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let completion = cinematicCompletion
        cinematicCompletion = nil
        completion?()
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

private final class OnboardingIntroRootView: NSView {
    var layoutFrame: NSRect = .zero {
        didSet {
            applyLayout(to: currentContentView)
            needsLayout = true
        }
    }

    var timelineFrame = OnboardingIntroTimeline.frame(at: 0) {
        didSet {
            cinematicView?.timelineFrame = timelineFrame
        }
    }

    private weak var cinematicView: OnboardingIntroCinematicView?
    private var currentContentView: NSView?

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

    func showCinematic() {
        let view = OnboardingIntroCinematicView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        view.layoutFrame = layoutFrame
        view.timelineFrame = timelineFrame
        cinematicView = view
        replaceContent(with: view)
    }

    func showPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                              action: @escaping () -> Void) {
        let view = OnboardingIntroPermissionSurfaceView(
            frame: bounds,
            presentation: presentation,
            action: action
        )
        view.autoresizingMask = [.width, .height]
        view.layoutFrame = layoutFrame
        cinematicView = nil
        replaceContent(with: view)
    }

    func showAgentChoicePrompt(selectedProvider: GeneralConfig.AgentProvider,
                               codexAction: @escaping () -> Void,
                               claudeAction: @escaping () -> Void) {
        let view = OnboardingIntroHostedSurfaceView(
            frame: bounds,
            rootView: AnyView(
                OnboardingIntroAgentChoicePromptView(
                    selectedProvider: selectedProvider,
                    codexAction: codexAction,
                    claudeAction: claudeAction
                )
            )
        )
        view.autoresizingMask = [.width, .height]
        view.layoutFrame = layoutFrame
        cinematicView = nil
        replaceContent(with: view)
    }

    func showRuntimePrompt(_ presentation: OnboardingRuntimePromptPresentation,
                           retryAction: @escaping () -> Void) {
        let view = OnboardingIntroHostedSurfaceView(
            frame: bounds,
            rootView: AnyView(
                OnboardingIntroRuntimePromptView(
                    presentation: presentation,
                    retryAction: retryAction
                )
            )
        )
        view.autoresizingMask = [.width, .height]
        view.layoutFrame = layoutFrame
        cinematicView = nil
        replaceContent(with: view)
    }

    func showAgentLoginPrompt(_ presentation: OnboardingAgentLoginPromptPresentation,
                              signInAction: @escaping () -> Void) {
        let view = OnboardingIntroHostedSurfaceView(
            frame: bounds,
            rootView: AnyView(
                OnboardingIntroAgentLoginPromptView(
                    presentation: presentation,
                    signInAction: signInAction
                )
            )
        )
        view.autoresizingMask = [.width, .height]
        view.layoutFrame = layoutFrame
        cinematicView = nil
        replaceContent(with: view)
    }

    func showWorkspacePrompt(currentPath: String,
                             action: @escaping () -> Void) {
        let view = OnboardingIntroWorkspaceSurfaceView(
            frame: bounds,
            currentPath: currentPath,
            action: action
        )
        view.autoresizingMask = [.width, .height]
        view.layoutFrame = layoutFrame
        cinematicView = nil
        replaceContent(with: view)
    }

    func stopAnimations() {
        cinematicView?.stopAnimations()
    }

    override func layout() {
        super.layout()
        currentContentView?.frame = bounds
        applyLayout(to: currentContentView)
    }

    private func replaceContent(with view: NSView) {
        currentContentView?.removeFromSuperview()
        currentContentView = view
        addSubview(view)
        applyLayout(to: view)
    }

    private func applyLayout(to view: NSView?) {
        if let view = view as? OnboardingIntroCinematicView {
            view.layoutFrame = layoutFrame
        } else if let view = view as? OnboardingIntroPermissionSurfaceView {
            view.layoutFrame = layoutFrame
        } else if let view = view as? OnboardingIntroHostedSurfaceView {
            view.layoutFrame = layoutFrame
        } else if let view = view as? OnboardingIntroWorkspaceSurfaceView {
            view.layoutFrame = layoutFrame
        }
    }
}

private final class OnboardingIntroCinematicView: NSView {
    var layoutFrame: NSRect = .zero {
        didSet { layoutSubtreeIfNeeded() }
    }

    var timelineFrame = OnboardingIntroTimeline.frame(at: 0) {
        didSet {
            textView.timelineFrame = timelineFrame
            particleHost.update(progress: timelineFrame.dotFieldProgress,
                                opacity: timelineFrame.dotFieldOpacity)
        }
    }

    private let particleHost = OnboardingIntroParticleHostView(frame: .zero)
    private let textView = OnboardingIntroTextView(frame: .zero)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        particleHost.autoresizingMask = []
        textView.frame = bounds
        textView.autoresizingMask = [.width, .height]
        addSubview(particleHost)
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func stopAnimations() {
        particleHost.stop()
    }

    override func layout() {
        super.layout()
        particleHost.frame = layoutFrame
        particleHost.layoutSubtreeIfNeeded()
        textView.frame = bounds
        textView.layoutFrame = layoutFrame
    }
}

private final class OnboardingIntroParticleHostView: NSView {
    private let renderer = ParticleFieldRenderer()
    private var attached = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutRenderer()
    }

    override func layout() {
        super.layout()
        layoutRenderer()
    }

    func update(progress: CGFloat, opacity: CGFloat) {
        let clampedProgress = min(max(progress, 0), 1)
        let clampedOpacity = min(max(opacity, 0), 1)
        alphaValue = clampedOpacity
        layer?.transform = CATransform3DMakeTranslation(
            0,
            (1 - clampedProgress) * bounds.height * 0.08,
            0
        )
        guard clampedOpacity > 0 else {
            renderer.setIntensity(0)
            renderer.transition(to: nil)
            return
        }
        ensureAttached()
        renderer.setIntensity(Double(clampedOpacity))
        renderer.transition(to: .tts)
    }

    func stop() {
        renderer.transition(to: nil)
    }

    private func ensureAttached() {
        guard !attached else { return }
        renderer.attach(to: self)
        attached = true
    }

    private func layoutRenderer() {
        ensureAttached()
        renderer.layoutInBounds(bounds, backingScale: window?.screen?.backingScaleFactor)
    }
}

private final class OnboardingIntroPermissionSurfaceView: NSView {
    var layoutFrame: NSRect = .zero {
        didSet { needsLayout = true }
    }

    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect,
         presentation: OnboardingPermissionPromptPresentation,
         action: @escaping () -> Void) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
        update(presentation: presentation, action: action)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        hostingView.frame = layoutFrame
    }

    private func update(presentation: OnboardingPermissionPromptPresentation,
                        action: @escaping () -> Void) {
        hostingView.rootView = AnyView(
            ZStack {
                Color.clear
                OnboardingPermissionPromptView(
                    presentation: presentation,
                    action: action
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

private final class OnboardingIntroHostedSurfaceView: NSView {
    var layoutFrame: NSRect = .zero {
        didSet { needsLayout = true }
    }

    private let hostingView: NSHostingView<AnyView>

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, rootView: AnyView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        hostingView.frame = layoutFrame
    }
}

private final class OnboardingIntroWorkspaceSurfaceView: NSView {
    var layoutFrame: NSRect = .zero {
        didSet { needsLayout = true }
    }

    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect,
         currentPath: String,
         action: @escaping () -> Void) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
        update(currentPath: currentPath, action: action)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        hostingView.frame = layoutFrame
    }

    private func update(currentPath: String,
                        action: @escaping () -> Void) {
        hostingView.rootView = AnyView(
            ZStack {
                Color.clear
                OnboardingIntroWorkspacePromptView(
                    currentPath: currentPath,
                    action: action
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }
}

struct OnboardingIntroAgentChoicePromptView: View {
    let selectedProvider: GeneralConfig.AgentProvider
    let codexAction: () -> Void
    let claudeAction: () -> Void

    var body: some View {
        VStack(spacing: 54) {
            Text("Which coding agent should Relay Runner start with? /")
                .font(AppTypography.font(.onboardingHero))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: OnboardingPermissionTreatment.promptMaxWidth)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 18) {
                OnboardingIntroWhiteActionButton(
                    title: "Codex",
                    accessibilityLabel: providerAccessibilityLabel(.codex),
                    action: codexAction
                )
                OnboardingIntroWhiteActionButton(
                    title: "Claude",
                    accessibilityLabel: providerAccessibilityLabel(.claude),
                    action: claudeAction
                )
            }

        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: OnboardingPermissionTreatment.promptMinHeight)
        .accessibilityElement(children: .contain)
    }

    private func providerAccessibilityLabel(_ provider: GeneralConfig.AgentProvider) -> String {
        selectedProvider == provider
            ? "\(provider.displayName), currently selected"
            : provider.displayName
    }
}

struct OnboardingIntroRuntimePromptView: View {
    let presentation: OnboardingRuntimePromptPresentation
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 38) {
            Text(title)
                .font(AppTypography.font(.onboardingHero))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: OnboardingPermissionTreatment.promptMaxWidth)
                .accessibilityAddTraits(.isHeader)

            runtimeStatus

            if showsRetry {
                OnboardingIntroWhiteActionButton(
                    title: "Retry",
                    accessibilityLabel: "Retry \(presentation.provider.displayName) setup",
                    action: retryAction
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: OnboardingPermissionTreatment.promptMinHeight)
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch presentation.status {
        case .failed:
            return "\(presentation.provider.displayName) setup needs attention /"
        case .succeeded:
            return "\(presentation.provider.displayName) is ready /"
        case .idle, .running:
            return "Preparing \(presentation.provider.displayName) /"
        }
    }

    @ViewBuilder
    private var runtimeStatus: some View {
        switch presentation.status {
        case .idle:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Starting setup...")
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.white.opacity(0.72))
            }
        case .running(let message, let progress):
            VStack(spacing: 12) {
                if let progress {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(message)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        case .succeeded:
            Text("Runtime and \(presentation.provider.displayName) command are available.")
                .font(AppTypography.font(.body))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
        case .failed(let message):
            Text(message)
                .font(AppTypography.font(.body))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
        }
    }

    private var showsRetry: Bool {
        if case .failed = presentation.status { return true }
        return false
    }
}

struct OnboardingIntroAgentLoginPromptView: View {
    let presentation: OnboardingAgentLoginPromptPresentation
    let signInAction: () -> Void

    var body: some View {
        VStack(spacing: 54) {
            Text("Sign in to \(presentation.provider.displayName) /")
                .font(AppTypography.font(.onboardingHero))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: OnboardingPermissionTreatment.promptMaxWidth)
                .accessibilityAddTraits(.isHeader)

            if presentation.signedIn {
                Text("Signed in.")
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                OnboardingIntroWhiteActionButton(
                    title: "Sign in",
                    accessibilityLabel: "Sign in to \(presentation.provider.displayName)",
                    action: signInAction
                )
            }

            if let message = presentation.message {
                Text(message)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: OnboardingPermissionTreatment.promptMinHeight)
        .accessibilityElement(children: .contain)
    }
}

struct OnboardingIntroWorkspacePromptView: View {
    let currentPath: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Text("Choose your workspace /")
                .font(AppTypography.font(.onboardingHero))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: OnboardingPermissionTreatment.promptMaxWidth)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 14) {
                Text(currentPath)
                    .font(AppTypography.font(.body))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: 640)
                    .frame(height: 52)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.12))
                    )

                OnboardingIntroWhiteActionButton(
                    title: "Browse\u{2026}",
                    accessibilityLabel: "Browse for workspace folder",
                    height: 52,
                    action: action
                )
            }

            Text(OnboardingView.workspaceFolderHelpText)
                .font(AppTypography.font(.body))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
        }
        .padding(.horizontal, 34)
        .frame(maxWidth: .infinity)
        .frame(minHeight: OnboardingPermissionTreatment.promptMinHeight)
    }
}

struct OnboardingIntroWhiteActionButton: View {
    let title: String
    var accessibilityLabel: String?
    var width: CGFloat = OnboardingPermissionTreatment.buttonSize.width
    var height: CGFloat = OnboardingPermissionTreatment.buttonSize.height
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.font(.permissionButton))
                .foregroundStyle(Color(nsColor: OnboardingPermissionTreatment.buttonBorderColor))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingPermissionTreatment.buttonCornerRadius, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingPermissionTreatment.buttonCornerRadius, style: .continuous)
                        .stroke(Color(nsColor: OnboardingPermissionTreatment.buttonBorderColor), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
        .help(accessibilityLabel ?? title)
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
        visibleText.draw(in: drawRect, withAttributes: attributes)
    }
}
