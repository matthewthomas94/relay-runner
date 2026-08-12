import AppKit
import Observation
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
        text
    }

    var cursorOpacity: CGFloat {
        cursorVisible ? 1 : OnboardingCursorBlink.minimumOpacity
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
                                continueAction: @escaping () -> Void,
                                browseAction: @escaping () -> Void)
    func presentTutorial(_ presentation: OnboardingTutorialPresentation,
                         retryAction: @escaping () -> Void)
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

enum OnboardingPromptTransitionPolicy: Equatable {
    case cursorLed
    case opacity
}

enum OnboardingPromptPhase: CaseIterable, Equatable {
    case permission
    case agentChoice
    case runtime
    case agentLogin
    case workspace
    case tutorial

    var transitionPolicy: OnboardingPromptTransitionPolicy {
        self == .tutorial ? .opacity : .cursorLed
    }
}

enum OnboardingIntroPromptCopy {
    static let agentChoice = "Which coding agent should Relay Runner start with? /"
    static let workspace = "Choose your workspace /"

    static func runtime(_ presentation: OnboardingRuntimePromptPresentation) -> String {
        switch presentation.status {
        case .failed:
            return "\(presentation.provider.displayName) setup needs attention /"
        case .succeeded:
            return "\(presentation.provider.displayName) is ready /"
        case .idle, .running:
            return "Preparing \(presentation.provider.displayName) /"
        }
    }

    static func agentLogin(_ presentation: OnboardingAgentLoginPromptPresentation) -> String {
        "Sign in to \(presentation.provider.displayName) /"
    }
}

enum OnboardingPromptTiming {
    static let typingInterval: TimeInterval = 0.065 / 2.25
    static let eraseInterval = typingInterval
    static let initialHold: TimeInterval = 0.36
    static let finalHold: TimeInterval = 0.32
}

enum OnboardingIntroTimeline {
    static let phrases = [
        "Relay Runner",
        "First thing’s first",
        "I need a few permissions",
    ]
    static let initialBrandHold: TimeInterval = 0.70
    static let typingInterval = OnboardingPromptTiming.typingInterval
    static let eraseInterval = OnboardingPromptTiming.eraseInterval
    static let brandSettle = OnboardingPromptTiming.initialHold
    static let phraseHold: TimeInterval = 1.05
    static let dotFieldTravel: TimeInterval = 4.00
    static let finalPhraseHold: TimeInterval = 1.50
    static let cursorBlinkPeriod: TimeInterval = 0.8

    static var duration: TimeInterval {
        let brandCount = Double(phraseGraphemes(phrases[0]).count)
        let firstCopyCount = Double(phraseGraphemes(phrases[1]).count)
        let finalCopyCount = Double(phraseGraphemes(phrases[2]).count)
        return initialBrandHold
            + max(0, brandCount - 1) * typingInterval
            + dotFieldTravel
            + brandSettle
            + brandCount * eraseInterval
            + firstCopyCount * typingInterval
            + phraseHold
            + firstCopyCount * eraseInterval
            + finalCopyCount * typingInterval
            + finalPhraseHold
    }

    static func frame(at elapsed: TimeInterval) -> OnboardingIntroFrame {
        let timelineElapsed = max(0, elapsed)
        guard elapsed < duration else {
            return frame(
                phrase: phrases.last ?? "",
                visible: phraseGraphemes(phrases.last ?? ""),
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed),
                isComplete: true
            )
        }

        var cursor = timelineElapsed
        let brand = phrases[0]
        let brandGraphemes = phraseGraphemes(brand)

        if cursor < initialBrandHold {
            return frame(
                phrase: brand,
                visible: Array(brandGraphemes.prefix(1)),
                compactCursor: true,
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed),
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
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed),
                dotFieldOpacity: 0
            )
        }
        cursor -= brandTypeDuration

        if cursor < dotFieldTravel {
            let progress = CGFloat(easeInOut(cursor / dotFieldTravel))
            return frame(
                phrase: brand,
                visible: brandGraphemes,
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed),
                dotFieldProgress: progress,
                dotFieldOpacity: progress
            )
        }
        cursor -= dotFieldTravel

        if cursor < brandSettle {
            return frame(
                phrase: brand,
                visible: brandGraphemes,
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed),
                dotFieldProgress: 1,
                dotFieldOpacity: 1
            )
        }
        cursor -= brandSettle

        let brandEraseDuration = Double(brandGraphemes.count) * eraseInterval
        if cursor < brandEraseDuration {
            let erasedCount = min(brandGraphemes.count, Int(cursor / eraseInterval))
            let remainingCount = max(0, brandGraphemes.count - erasedCount)
            return frame(
                phrase: brand,
                visible: Array(brandGraphemes.prefix(remainingCount)),
                compactCursor: remainingCount == 1,
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed),
                dotFieldProgress: 1,
                dotFieldOpacity: CGFloat(1 - easeInOut(cursor / brandEraseDuration))
            )
        }
        cursor -= brandEraseDuration

        let firstCopy = phrases[1]
        let firstCopyGraphemes = phraseGraphemes(firstCopy)
        let firstTypeDuration = Double(firstCopyGraphemes.count) * typingInterval
        if cursor < firstTypeDuration {
            let phase = easeInOut(cursor / firstTypeDuration)
            let visibleCount = min(firstCopyGraphemes.count, Int(phase * Double(firstCopyGraphemes.count)))
            return frame(
                phrase: firstCopy,
                visible: Array(firstCopyGraphemes.prefix(visibleCount)),
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed)
            )
        }
        cursor -= firstTypeDuration

        if cursor < phraseHold {
            return frame(
                phrase: firstCopy,
                visible: firstCopyGraphemes,
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed)
            )
        }
        cursor -= phraseHold

        let firstEraseDuration = Double(firstCopyGraphemes.count) * eraseInterval
        if cursor < firstEraseDuration {
            let phase = easeInOut(cursor / firstEraseDuration)
            let erasedCount = min(firstCopyGraphemes.count, Int(phase * Double(firstCopyGraphemes.count)) + 1)
            let remainingCount = max(0, firstCopyGraphemes.count - erasedCount)
            return frame(
                phrase: firstCopy,
                visible: Array(firstCopyGraphemes.prefix(remainingCount)),
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed)
            )
        }
        cursor -= firstEraseDuration

        let finalCopy = phrases[2]
        let finalCopyGraphemes = phraseGraphemes(finalCopy)
        let finalTypeDuration = Double(finalCopyGraphemes.count) * typingInterval
        if cursor < finalTypeDuration {
            let phase = easeInOut(cursor / finalTypeDuration)
            let visibleCount = min(finalCopyGraphemes.count, Int(phase * Double(finalCopyGraphemes.count)))
            return frame(
                phrase: finalCopy,
                visible: Array(finalCopyGraphemes.prefix(visibleCount)),
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed)
            )
        }
        cursor -= finalTypeDuration

        return frame(
            phrase: finalCopy,
            visible: finalCopyGraphemes,
            cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed)
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

    private static func phraseGraphemes(_ phrase: String) -> [Character] {
        Array(phrase)
    }

    static func easeInOut(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

enum OnboardingCursorBlink {
    static let minimumOpacity: CGFloat = 0.5

    static func opacity(at elapsed: TimeInterval, reduceMotion: Bool = false) -> CGFloat {
        if reduceMotion {
            return 0.82
        }

        let cycle = max(0, elapsed).truncatingRemainder(dividingBy: OnboardingIntroTimeline.cursorBlinkPeriod)
        let progress = cycle / OnboardingIntroTimeline.cursorBlinkPeriod
        let wave = 0.5 + 0.5 * cos(progress * .pi * 2)
        let eased = CGFloat(OnboardingIntroTimeline.easeInOut(wave))
        return minimumOpacity + (1 - minimumOpacity) * eased
    }

    static func isVisible(at elapsed: TimeInterval) -> Bool {
        opacity(at: elapsed) >= (minimumOpacity + (1 - minimumOpacity) / 2)
    }
}

enum OnboardingPromptTransitionTimeline {
    static let initialHold = OnboardingPromptTiming.initialHold
    static let finalHold = OnboardingPromptTiming.finalHold
    static let typingInterval = OnboardingPromptTiming.typingInterval
    static let eraseInterval = OnboardingPromptTiming.eraseInterval

    static func duration(from source: String, to target: String) -> TimeInterval {
        let sourceCount = Double(phrase(from: source).count)
        let targetCount = Double(phrase(from: target).count)
        guard sourceCount > 0 || targetCount > 0 else { return 0 }
        return initialHold
            + sourceCount * eraseInterval
            + targetCount * typingInterval
            + finalHold
    }

    static func frame(from source: String, to target: String, at elapsed: TimeInterval) -> OnboardingIntroFrame {
        let sourcePhrase = phrase(from: source)
        let targetPhrase = phrase(from: target)
        let timelineElapsed = max(0, elapsed)
        guard sourcePhrase != targetPhrase else {
            return makeFrame(
                phrase: targetPhrase,
                visible: targetPhrase,
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed),
                isComplete: true
            )
        }

        var cursor = timelineElapsed
        if cursor < initialHold {
            return makeFrame(
                phrase: sourcePhrase,
                visible: sourcePhrase,
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed)
            )
        }
        cursor -= initialHold

        let eraseDuration = Double(sourcePhrase.count) * eraseInterval
        if cursor < eraseDuration {
            let phase = OnboardingIntroTimeline.easeInOut(cursor / eraseDuration)
            let erasedCount = min(sourcePhrase.count, Int(phase * Double(sourcePhrase.count)) + 1)
            return makeFrame(
                phrase: sourcePhrase,
                visible: Array(sourcePhrase.prefix(max(0, sourcePhrase.count - erasedCount))),
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed)
            )
        }
        cursor -= eraseDuration

        let typeDuration = Double(targetPhrase.count) * typingInterval
        if cursor < typeDuration {
            let phase = OnboardingIntroTimeline.easeInOut(cursor / typeDuration)
            let visibleCount = min(targetPhrase.count, Int(phase * Double(targetPhrase.count)))
            return makeFrame(
                phrase: targetPhrase,
                visible: Array(targetPhrase.prefix(visibleCount)),
                cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed)
            )
        }
        cursor -= typeDuration

        return makeFrame(
            phrase: targetPhrase,
            visible: targetPhrase,
            cursorVisible: OnboardingCursorBlink.isVisible(at: timelineElapsed),
            isComplete: cursor >= finalHold
        )
    }

    static func presentationFrame(
        from source: String,
        to target: String,
        at elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> OnboardingIntroFrame {
        guard reduceMotion else {
            return frame(from: source, to: target, at: elapsed)
        }
        let targetPhrase = phrase(from: target)
        return makeFrame(
            phrase: targetPhrase,
            visible: targetPhrase,
            cursorVisible: true,
            isComplete: true
        )
    }

    static func phrase(from text: String) -> [Character] {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("/") {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Array(normalized)
    }

    private static func makeFrame(
        phrase: [Character],
        visible: [Character],
        cursorVisible: Bool = true,
        isComplete: Bool = false
    ) -> OnboardingIntroFrame {
        let prefix = String(visible)
        return OnboardingIntroFrame(
            activePhrase: String(phrase),
            text: prefix.isEmpty ? "/" : "\(prefix) /",
            cursorVisible: cursorVisible,
            dotFieldProgress: 0,
            dotFieldOpacity: 0,
            isComplete: isComplete
        )
    }

}

enum OnboardingFlowMotion {
    static let surfaceTransitionDuration: TimeInterval = 0.48
    static let contentTransitionDuration: TimeInterval = 0.42
    static let controlsRevealDuration: TimeInterval = 0.36
    static let completedStepHold: TimeInterval = 0.85

    static var contentAnimation: Animation {
        .easeInOut(duration: contentTransitionDuration)
    }
}

enum OnboardingIntroTextLayout {
    static let lineHeight: CGFloat = 66
    static let referenceWorkspaceHeight: CGFloat = 736
    static let referenceTextTop: CGFloat = 325

    static func permissionControlsTop(forHeight height: CGFloat) -> CGFloat {
        let scale = height / referenceWorkspaceHeight
        return (referenceTextTop + lineHeight + 54) * scale
    }

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

private struct OnboardingIntroPromptContentLayout<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(maxWidth: .infinity)
                .padding(
                    .top,
                    OnboardingIntroTextLayout.permissionControlsTop(forHeight: proxy.size.height)
                )
        }
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
    private var lastPromptText = ""

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
        let initialFrame = OnboardingIntroTimeline.frame(at: 0)
        lastPromptText = initialFrame.text
        surface.rootView.timelineFrame = initialFrame
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
        surface.rootView.showPermissionPrompt(
            presentation,
            transitionFrom: lastPromptText,
            action: action
        )
        lastPromptText = presentation.prompt

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
        let prompt = OnboardingIntroPromptCopy.agentChoice
        surface.rootView.showAgentChoicePrompt(
            selectedProvider: selectedProvider,
            transitionFrom: lastPromptText,
            codexAction: codexAction,
            claudeAction: claudeAction
        )
        lastPromptText = prompt

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
        let prompt = OnboardingIntroPromptCopy.runtime(presentation)
        surface.rootView.showRuntimePrompt(
            presentation,
            transitionFrom: lastPromptText,
            retryAction: retryAction
        )
        lastPromptText = prompt

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
        let prompt = OnboardingIntroPromptCopy.agentLogin(presentation)
        surface.rootView.showAgentLoginPrompt(
            presentation,
            transitionFrom: lastPromptText,
            signInAction: signInAction
        )
        lastPromptText = prompt

        guard surface.didCreate else { return }
        DispatchQueue.main.async { [weak container = surface.container] in
            container?.animateReveal {}
        }
    }

    func presentWorkspacePrompt(currentPath: String,
                                continueAction: @escaping () -> Void,
                                browseAction: @escaping () -> Void) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let surface = ensureSurface()
        surface.rootView.showWorkspacePrompt(
            currentPath: currentPath,
            transitionFrom: lastPromptText,
            continueAction: continueAction,
            browseAction: browseAction
        )
        lastPromptText = OnboardingIntroPromptCopy.workspace

        guard surface.didCreate else { return }
        DispatchQueue.main.async { [weak container = surface.container] in
            container?.animateReveal {}
        }
    }

    func presentTutorial(_ presentation: OnboardingTutorialPresentation,
                         retryAction: @escaping () -> Void) {
        timelineTimer?.invalidate()
        timelineTimer = nil
        removeSkipMonitors()

        let surface = ensureSurface()
        surface.rootView.showTutorial(presentation, retryAction: retryAction)

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
        // First-run setup is modal. Giving its fresh panel key eligibility on
        // every presentation keeps SwiftUI button hit-testing reliable after
        // earlier onboarding panels have been dismissed for System Settings.
        p.keyEligible = true
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
        p.makeKey()
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
        lastPromptText = frame.text
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
    private var runtimeModel: OnboardingIntroRuntimeSurfaceModel?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

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
        runtimeModel = nil
        replaceContent(with: view, policy: .cursorLed)
    }

    func showPermissionPrompt(_ presentation: OnboardingPermissionPromptPresentation,
                              transitionFrom: String,
                              action: @escaping () -> Void) {
        runtimeModel = nil
        showPrompt(
            phase: .permission,
            title: presentation.prompt,
            transitionFrom: transitionFrom,
            content: AnyView(
                OnboardingIntroPermissionControlsView(
                    presentation: presentation,
                    action: action
                )
            )
        )
    }

    func showAgentChoicePrompt(selectedProvider: GeneralConfig.AgentProvider,
                               transitionFrom: String,
                               codexAction: @escaping () -> Void,
                               claudeAction: @escaping () -> Void) {
        runtimeModel = nil
        showPrompt(
            phase: .agentChoice,
            title: OnboardingIntroPromptCopy.agentChoice,
            transitionFrom: transitionFrom,
            content: AnyView(
                OnboardingIntroAgentChoicePromptView(
                    selectedProvider: selectedProvider,
                    codexAction: codexAction,
                    claudeAction: claudeAction
                )
            )
        )
    }

    func showRuntimePrompt(_ presentation: OnboardingRuntimePromptPresentation,
                           transitionFrom: String,
                           retryAction: @escaping () -> Void) {
        let model: OnboardingIntroRuntimeSurfaceModel
        if let runtimeModel {
            model = runtimeModel
            model.retryAction = retryAction
            if model.presentation != presentation {
                if reduceMotion {
                    model.presentation = presentation
                } else {
                    withAnimation(OnboardingFlowMotion.contentAnimation) {
                        model.presentation = presentation
                    }
                }
            }
        } else {
            model = OnboardingIntroRuntimeSurfaceModel(
                presentation: presentation,
                retryAction: retryAction
            )
            runtimeModel = model
        }
        showPrompt(
            phase: .runtime,
            title: OnboardingIntroPromptCopy.runtime(presentation),
            transitionFrom: transitionFrom,
            content: AnyView(OnboardingIntroRuntimePromptView(model: model))
        )
    }

    func showAgentLoginPrompt(_ presentation: OnboardingAgentLoginPromptPresentation,
                              transitionFrom: String,
                              signInAction: @escaping () -> Void) {
        runtimeModel = nil
        showPrompt(
            phase: .agentLogin,
            title: OnboardingIntroPromptCopy.agentLogin(presentation),
            transitionFrom: transitionFrom,
            content: AnyView(
                OnboardingIntroAgentLoginPromptView(
                    presentation: presentation,
                    signInAction: signInAction
                )
            )
        )
    }

    func showWorkspacePrompt(currentPath: String,
                             transitionFrom: String,
                             continueAction: @escaping () -> Void,
                             browseAction: @escaping () -> Void) {
        runtimeModel = nil
        showPrompt(
            phase: .workspace,
            title: OnboardingIntroPromptCopy.workspace,
            transitionFrom: transitionFrom,
            content: AnyView(
                OnboardingIntroWorkspacePromptView(
                    currentPath: currentPath,
                    continueAction: continueAction,
                    browseAction: browseAction
                )
            )
        )
    }

    func showTutorial(_ presentation: OnboardingTutorialPresentation,
                      retryAction: @escaping () -> Void) {
        runtimeModel = nil
        let view = OnboardingIntroHostedSurfaceView(
            frame: bounds,
            rootView: AnyView(
                OnboardingTutorialView(
                    presentation: presentation,
                    retryAction: retryAction
                )
            )
        )
        view.autoresizingMask = [.width, .height]
        view.layoutFrame = layoutFrame
        cinematicView = nil
        replaceContent(with: view, policy: OnboardingPromptPhase.tutorial.transitionPolicy)
    }

    func stopAnimations() {
        cinematicView?.stopAnimations()
    }

    override func layout() {
        super.layout()
        currentContentView?.frame = bounds
        applyLayout(to: currentContentView)
    }

    private func showPrompt(
        phase: OnboardingPromptPhase,
        title: String,
        transitionFrom: String,
        content: AnyView
    ) {
        cinematicView = nil
        if let promptView = currentContentView as? OnboardingIntroPromptSurfaceView {
            promptView.update(title: title, content: content)
            return
        }

        let view = OnboardingIntroPromptSurfaceView(
            frame: bounds,
            title: title,
            transitionFrom: transitionFrom,
            content: content
        )
        view.autoresizingMask = [.width, .height]
        view.layoutFrame = layoutFrame
        replaceContent(with: view, policy: phase.transitionPolicy)
    }

    private func replaceContent(with view: NSView, policy: OnboardingPromptTransitionPolicy) {
        let oldView = currentContentView
        currentContentView = view
        view.frame = bounds
        view.alphaValue = policy == .opacity && oldView != nil && !reduceMotion ? 0 : 1
        oldView.flatMap { $0 as? OnboardingIntroCinematicView }?.stopAnimations()

        if policy == .cursorLed {
            oldView?.removeFromSuperview()
        }
        addSubview(view)
        applyLayout(to: view)
        view.layoutSubtreeIfNeeded()

        guard policy == .opacity, let oldView else { return }
        guard !reduceMotion else {
            oldView.removeFromSuperview()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = OnboardingFlowMotion.surfaceTransitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            oldView.animator().alphaValue = 0
            view.animator().alphaValue = 1
        } completionHandler: {
            oldView.removeFromSuperview()
        }
    }

    private func applyLayout(to view: NSView?) {
        if let view = view as? OnboardingIntroCinematicView {
            view.layoutFrame = layoutFrame
        } else if let view = view as? OnboardingIntroPromptSurfaceView {
            view.layoutFrame = layoutFrame
        } else if let view = view as? OnboardingIntroHostedSurfaceView {
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

    private let particleClipView = NSView(frame: .zero)
    private let particleHost = OnboardingIntroParticleHostView(frame: .zero)
    private let textView = OnboardingIntroTextView(frame: .zero)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        particleClipView.wantsLayer = true
        particleClipView.layer?.backgroundColor = NSColor.clear.cgColor
        particleClipView.layer?.masksToBounds = true
        particleHost.autoresizingMask = []
        textView.frame = bounds
        textView.autoresizingMask = [.width, .height]
        particleClipView.addSubview(particleHost)
        addSubview(particleClipView)
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
        particleClipView.frame = layoutFrame
        particleHost.frame = particleClipView.bounds
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

    func update(progress _: CGFloat, opacity: CGFloat) {
        let clampedOpacity = min(max(opacity, 0), 1)
        alphaValue = clampedOpacity
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

private final class OnboardingIntroPromptSurfaceView: NSView {
    var layoutFrame: NSRect = .zero {
        didSet { needsLayout = true }
    }

    private let textView = OnboardingIntroTextView(frame: .zero)
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    private var transitionSource: String
    private var transitionTarget: String
    private let reduceMotion: Bool
    private var transitionTimer: Timer?
    private var transitionStartedAt: CFTimeInterval?
    private var controlsVisible = false

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect,
         title: String,
         transitionFrom: String,
         content: AnyView) {
        transitionSource = transitionFrom
        transitionTarget = title
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        textView.frame = bounds
        textView.autoresizingMask = [.width, .height]
        textView.reservePhrases = [transitionFrom, title]
        textView.timelineFrame = OnboardingPromptTransitionTimeline.presentationFrame(
            from: transitionFrom,
            to: title,
            at: 0,
            reduceMotion: reduceMotion
        )
        textView.setAccessibilityLabel(String(OnboardingPromptTransitionTimeline.phrase(from: title)))
        addSubview(textView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.alphaValue = 0
        hostingView.isHidden = true
        hostingView.rootView = content
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        transitionTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        startTransitionIfNeeded()
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        textView.layoutFrame = layoutFrame
        hostingView.frame = layoutFrame
    }

    func update(title: String, content: AnyView) {
        hostingView.rootView = content
        textView.setAccessibilityLabel(String(OnboardingPromptTransitionTimeline.phrase(from: title)))
        if transitionTarget == title, transitionTimer != nil {
            return
        }

        let source = textView.timelineFrame.text
        guard OnboardingPromptTransitionTimeline.phrase(from: source)
                != OnboardingPromptTransitionTimeline.phrase(from: title) else {
            transitionSource = title
            transitionTarget = title
            textView.reservePhrases = [title]
            textView.timelineFrame = OnboardingPromptTransitionTimeline.presentationFrame(
                from: title,
                to: title,
                at: 0,
                reduceMotion: reduceMotion
            )
            showControls()
            return
        }

        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStartedAt = nil
        transitionSource = source
        transitionTarget = title
        textView.reservePhrases = [source, title]
        textView.timelineFrame = OnboardingPromptTransitionTimeline.presentationFrame(
            from: source,
            to: title,
            at: 0,
            reduceMotion: reduceMotion
        )
        controlsVisible = false
        hostingView.alphaValue = 0
        hostingView.isHidden = true
        startTransitionIfNeeded()
    }

    private func startTransitionIfNeeded() {
        guard transitionTimer == nil, transitionStartedAt == nil else { return }
        let duration = OnboardingPromptTransitionTimeline.duration(
            from: transitionSource,
            to: transitionTarget
        )
        transitionStartedAt = CACurrentMediaTime()
        if reduceMotion || duration <= 0 {
            textView.timelineFrame = OnboardingPromptTransitionTimeline.presentationFrame(
                from: transitionSource,
                to: transitionTarget,
                at: duration,
                reduceMotion: reduceMotion
            )
            showControls()
            return
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickTransition()
        }
        RunLoop.main.add(timer, forMode: .common)
        transitionTimer = timer
        tickTransition()
    }

    private func tickTransition() {
        guard let transitionStartedAt else { return }
        let elapsed = CACurrentMediaTime() - transitionStartedAt
        let frame = OnboardingPromptTransitionTimeline.presentationFrame(
            from: transitionSource,
            to: transitionTarget,
            at: elapsed,
            reduceMotion: reduceMotion
        )
        textView.timelineFrame = frame
        guard frame.isComplete else { return }
        transitionTimer?.invalidate()
        transitionTimer = nil
        showControls()
    }

    private func showControls() {
        guard !controlsVisible else {
            hostingView.isHidden = false
            hostingView.alphaValue = 1
            return
        }
        controlsVisible = true
        hostingView.isHidden = false
        guard !reduceMotion else {
            hostingView.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = OnboardingFlowMotion.controlsRevealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hostingView.animator().alphaValue = 1
        }
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

@Observable
private final class OnboardingIntroRuntimeSurfaceModel {
    var presentation: OnboardingRuntimePromptPresentation
    @ObservationIgnored var retryAction: () -> Void

    init(presentation: OnboardingRuntimePromptPresentation,
         retryAction: @escaping () -> Void) {
        self.presentation = presentation
        self.retryAction = retryAction
    }
}

struct OnboardingIntroAgentChoicePromptView: View {
    let selectedProvider: GeneralConfig.AgentProvider
    let codexAction: () -> Void
    let claudeAction: () -> Void

    var body: some View {
        OnboardingIntroPromptContentLayout {
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
        .accessibilityElement(children: .contain)
    }

    private func providerAccessibilityLabel(_ provider: GeneralConfig.AgentProvider) -> String {
        selectedProvider == provider
            ? "\(provider.displayName), currently selected"
            : provider.displayName
    }
}

private enum OnboardingRuntimeVisualPhase: Equatable {
    case idle
    case indeterminate
    case determinate
    case succeeded
    case failed

    init(status: VenvInstaller.Status) {
        switch status {
        case .idle:
            self = .idle
        case .running(_, nil):
            self = .indeterminate
        case .running(_, .some):
            self = .determinate
        case .succeeded:
            self = .succeeded
        case .failed:
            self = .failed
        }
    }
}

private struct OnboardingIntroRuntimePromptView: View {
    let model: OnboardingIntroRuntimeSurfaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: OnboardingRuntimePromptPresentation {
        model.presentation
    }

    var body: some View {
        OnboardingIntroPromptContentLayout {
            VStack(spacing: 24) {
                runtimeStatus

                if showsRetry {
                    OnboardingIntroWhiteActionButton(
                        title: "Retry",
                        accessibilityLabel: "Retry \(presentation.provider.displayName) setup",
                        action: model.retryAction
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var runtimeStatus: some View {
        ZStack {
            switch presentation.status {
            case .idle:
                ProgressView()
                    .controlSize(.small)
                    .transition(reduceMotion ? .identity : .opacity)
            case .running(_, let progress):
                if let progress {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)
                        .animation(
                            reduceMotion ? nil : OnboardingFlowMotion.contentAnimation,
                            value: progress
                        )
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .font(AppTypography.symbolFont(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .transition(reduceMotion ? .identity : .opacity)
                    .accessibilityLabel("Setup complete")
            case .failed(let errorMessage):
                Text(errorMessage)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(minHeight: 24)
        .animation(
            reduceMotion ? nil : OnboardingFlowMotion.contentAnimation,
            value: OnboardingRuntimeVisualPhase(status: presentation.status)
        )
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
        OnboardingIntroPromptContentLayout {
            VStack(spacing: 24) {
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
        }
        .accessibilityElement(children: .contain)
    }
}

struct OnboardingIntroWorkspacePromptView: View {
    static let controlHeight: CGFloat = 52 * OnboardingPermissionTreatment.actionScale
    let currentPath: String
    let continueAction: () -> Void
    let browseAction: () -> Void

    var body: some View {
        OnboardingIntroPromptContentLayout {
            VStack(spacing: 28) {
                HStack(spacing: 14) {
                    Text(currentPath)
                        .font(AppTypography.font(.body))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: 640)
                        .frame(height: Self.controlHeight)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.12))
                        )

                    HStack(spacing: 8) {
                        OnboardingIntroWhiteActionButton(
                            title: "Continue",
                            accessibilityLabel: "Continue with the current workspace folder",
                            height: Self.controlHeight,
                            action: continueAction
                        )
                        .keyboardShortcut(.defaultAction)

                        OnboardingIntroWhiteActionButton(
                            title: "Browse\u{2026}",
                            accessibilityLabel: "Browse for workspace folder",
                            height: Self.controlHeight,
                            action: browseAction
                        )
                    }
                }

                Text(OnboardingView.workspaceFolderHelpText)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
            }
            .padding(.horizontal, 34)
        }
    }
}

struct OnboardingBlinkingTitle: View {
    private let text: String
    private let reduceMotionOverride: Bool?
    @Environment(\.accessibilityReduceMotion) private var environmentReduceMotion

    init(_ text: String, reduceMotion: Bool? = nil) {
        self.text = text
        reduceMotionOverride = reduceMotion
    }

    var body: some View {
        let reduceMotion = reduceMotionOverride ?? environmentReduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            Self.styledText(
                text,
                at: context.date.timeIntervalSinceReferenceDate,
                reduceMotion: reduceMotion
            )
        }
        .font(AppTypography.font(.onboardingHero))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.72)
        .frame(maxWidth: OnboardingPermissionTreatment.promptMaxWidth)
        .accessibilityLabel(String(OnboardingPromptTransitionTimeline.phrase(from: text)))
        .accessibilityAddTraits(.isHeader)
    }

    static func renderedText(_ text: String, at _: TimeInterval) -> String {
        let phrase = String(OnboardingPromptTransitionTimeline.phrase(from: text))
        return "\(phrase) /"
    }

    static func cursorOpacity(at elapsed: TimeInterval, reduceMotion: Bool = false) -> CGFloat {
        OnboardingCursorBlink.opacity(at: elapsed, reduceMotion: reduceMotion)
    }

    private static func styledText(_ text: String,
                                   at elapsed: TimeInterval,
                                   reduceMotion: Bool) -> Text {
        let phrase = String(OnboardingPromptTransitionTimeline.phrase(from: text))
        return Text("\(phrase) ").foregroundColor(.white)
            + Text("/").foregroundColor(
                .white.opacity(cursorOpacity(at: elapsed, reduceMotion: reduceMotion))
            )
    }
}

private struct OnboardingIntroPermissionControlsView: View {
    let presentation: OnboardingPermissionPromptPresentation
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 24) {
                OnboardingIntroWhiteActionButton(
                    title: presentation.buttonTitle,
                    accessibilityLabel: presentation.buttonTitle,
                    action: action
                )
                .keyboardShortcut(.defaultAction)
                .disabled(!presentation.isButtonEnabled)

                if let supportingCopy = presentation.supportingCopy {
                    Text(supportingCopy)
                        .font(AppTypography.font(.body))
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(
                .top,
                OnboardingIntroTextLayout.permissionControlsTop(forHeight: proxy.size.height)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.prompt)
    }
}

struct OnboardingIntroWhiteActionButton: View {
    static let hoverScale: CGFloat = 1
    static let hoverAnimation: Animation = .easeInOut(duration: 0.16)

    let title: String
    var accessibilityLabel: String?
    var width: CGFloat = OnboardingPermissionTreatment.buttonSize.width
    var height: CGFloat = OnboardingPermissionTreatment.buttonSize.height
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        let showsHover = isEnabled && isHovering
        Button(action: action) {
            Text(title)
                .font(AppTypography.font(
                    .permissionButton,
                    size: OnboardingPermissionTreatment.buttonLabelSize
                ))
                .foregroundStyle(Color(nsColor: OnboardingPermissionTreatment.buttonBorderColor))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingPermissionTreatment.buttonCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(showsHover ? 0.86 : 1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingPermissionTreatment.buttonCornerRadius, style: .continuous)
                        .stroke(
                            Color(nsColor: OnboardingPermissionTreatment.buttonBorderColor)
                                .opacity(showsHover ? 0.72 : 1),
                            lineWidth: showsHover ? 1.5 : 1
                        )
                )
        }
        .buttonStyle(.plain)
        .scaleEffect(Self.hoverScale)
        .shadow(color: .white.opacity(showsHover ? 0.16 : 0), radius: 7)
        .animation(Self.hoverAnimation, value: showsHover)
        .onHover { isHovering = $0 }
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

    var reservePhrases: [String] = [] {
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
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let visibleText = timelineFrame.renderedText as NSString
        let attributedText = NSMutableAttributedString(
            string: timelineFrame.renderedText,
            attributes: attributes
        )
        let cursorRange = visibleText.range(of: "/", options: .backwards)
        if cursorRange.location != NSNotFound {
            attributedText.addAttribute(
                .foregroundColor,
                value: NSColor.white.withAlphaComponent(timelineFrame.cursorOpacity),
                range: cursorRange
            )
        }
        let reserveCandidates = reservePhrases.isEmpty
            ? ["\(timelineFrame.activePhrase) /"]
            : reservePhrases
        let reserveWidth = reserveCandidates
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
        let drawRect = OnboardingIntroTextLayout.drawRect(
            in: layoutFrame,
            reserveWidth: reserveWidth,
            visibleWidth: visibleText.size(withAttributes: attributes).width
        )
        attributedText.draw(in: drawRect)
    }
}
