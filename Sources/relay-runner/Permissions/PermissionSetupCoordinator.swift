import AppKit
import ApplicationServices
import QuartzCore
import SwiftUI

enum PermissionSetupSource: Equatable {
    case onboarding
    case settingsPermissions
    case hostedTool
    case permissionRecovery

    var windowDiscoveryTimeout: TimeInterval {
        switch self {
        case .onboarding:
            return 12
        case .settingsPermissions, .permissionRecovery:
            return 10
        case .hostedTool:
            return 8
        }
    }
}

enum PermissionSetupNotchState: Equatable {
    case gettingStarted
    case microphone
    case accessibility
    case inputMonitoring
    case screenRecording
    case granted(PermissionKind)

    init(permission: PermissionKind) {
        switch permission {
        case .microphone:      self = .microphone
        case .accessibility:   self = .accessibility
        case .inputMonitoring: self = .inputMonitoring
        case .screenRecording: self = .screenRecording
        }
    }

    var label: String {
        switch self {
        case .gettingStarted:  return "Getting started"
        case .microphone:      return "Microphone"
        case .accessibility:   return "Accessibility"
        case .inputMonitoring: return "Input monitoring"
        case .screenRecording: return "Screen recording"
        case .granted(let permission):
            return "\(PermissionSetupNotchState(permission: permission).label) granted"
        }
    }
}

struct PermissionSetupRequest: Equatable {
    let permission: PermissionKind
    let source: PermissionSetupSource
    let purpose: String
    let bundleURL: URL?

    init(permission: PermissionKind,
         source: PermissionSetupSource,
         purpose: String = "",
         bundleURL: URL? = Bundle.main.bundleURL) {
        self.permission = permission
        self.source = source
        self.purpose = purpose
        self.bundleURL = bundleURL
    }
}

extension Notification.Name {
    static let relayPermissionSetupGrantReady = Notification.Name("relayPermissionSetupGrantReady")
    static let relayPermissionSetupEndedWithoutGrant = Notification.Name("relayPermissionSetupEndedWithoutGrant")
}

struct PermissionSetupLifecycleEvent: Equatable {
    let permission: PermissionKind
    let source: PermissionSetupSource
}

protocol PermissionSetupPermissionManaging: AnyObject {
    func status(for kind: PermissionKind) -> PermissionStatus
    func requestMicrophonePrompt(completion: @escaping (Bool) -> Void)
    func promptAccessibility()
    func registerForInputMonitoringList()
    func promptInputMonitoring()
    func promptScreenRecording()
    func openSettings(for kind: PermissionKind)
}

extension PermissionsManager: PermissionSetupPermissionManaging {}

protocol PermissionSetupCompanionControlling: AnyObject {
    var isRealDragActive: Bool { get }

    func show(request: PermissionSetupRequest,
              onDragStateChanged: @escaping (Bool) -> Void,
              onLifecycleEnded: @escaping () -> Void)
    func showSuccess(for request: PermissionSetupRequest)
    func cancel()
}

final class PermissionSetupCoordinator {
    static let successAcknowledgementDelay: TimeInterval = 0.65

    private struct ActiveSetup {
        let request: PermissionSetupRequest
        var grantPendingUntilDragEnds = false
        var completionPosted = false
    }

    private let permissions: PermissionSetupPermissionManaging
    private let setSetupNotchState: (PermissionSetupNotchState?) -> Void
    private let postGrantReady: (PermissionKind, PermissionSetupSource) -> Void
    private let postEndedWithoutGrant: (PermissionKind, PermissionSetupSource) -> Void
    private let companion: PermissionSetupCompanionControlling
    private let successAcknowledgementDelay: TimeInterval
    private var active: ActiveSetup?
    private var grantReadyTimer: Timer?

    init(permissions: PermissionSetupPermissionManaging,
         setSetupNotchState: @escaping (PermissionSetupNotchState?) -> Void,
         postGrantReady: @escaping (PermissionKind, PermissionSetupSource) -> Void = { kind, _ in
             NotificationCenter.default.post(
                name: .relayPermissionSetupGrantReady,
                object: kind.rawValue
             )
         },
         postEndedWithoutGrant: @escaping (PermissionKind, PermissionSetupSource) -> Void = { kind, source in
             NotificationCenter.default.post(
                name: .relayPermissionSetupEndedWithoutGrant,
                object: PermissionSetupLifecycleEvent(permission: kind, source: source)
             )
         },
         companion: PermissionSetupCompanionControlling = PermissionSetupCompanionController(),
         successAcknowledgementDelay: TimeInterval = PermissionSetupCoordinator.successAcknowledgementDelay) {
        self.permissions = permissions
        self.setSetupNotchState = setSetupNotchState
        self.postGrantReady = postGrantReady
        self.postEndedWithoutGrant = postEndedWithoutGrant
        self.companion = companion
        self.successAcknowledgementDelay = successAcknowledgementDelay
    }

    deinit {
        cancel()
    }

    var activePermission: PermissionKind? {
        active?.request.permission
    }

    var isGrantDeferredByDrag: Bool {
        active?.grantPendingUntilDragEnds == true
    }

    func request(_ permission: PermissionKind,
                 source: PermissionSetupSource,
                 purpose: String = "") {
        let request = PermissionSetupRequest(
            permission: permission,
            source: source,
            purpose: purpose,
            bundleURL: Bundle.main.bundleURL
        )
        cancel(restoreNotch: false)
        active = ActiveSetup(request: request)
        setSetupNotchState(PermissionSetupNotchState(permission: permission))

        switch permission {
        case .microphone:
            permissions.requestMicrophonePrompt { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.markGranted(permission)
                } else {
                    self.endWithoutGrant(request)
                }
            }
        case .accessibility:
            permissions.promptAccessibility()
            permissions.openSettings(for: permission)
            showCompanion(for: request)
        case .inputMonitoring:
            permissions.registerForInputMonitoringList()
            permissions.promptInputMonitoring()
            permissions.openSettings(for: permission)
            showCompanion(for: request)
        case .screenRecording:
            permissions.promptScreenRecording()
            permissions.openSettings(for: permission)
            showCompanion(for: request)
        }
    }

    func cancel(source: PermissionSetupSource? = nil, restoreNotch: Bool = true) {
        if let source, active?.request.source != source {
            return
        }
        grantReadyTimer?.invalidate()
        grantReadyTimer = nil
        companion.cancel()
        active = nil
        if restoreNotch {
            setSetupNotchState(nil)
        }
    }

    func permissionStatusChanged(_ permission: PermissionKind, status: PermissionStatus) {
        guard status == .granted else { return }
        markGranted(permission)
    }

    func shouldDeferAutoAdvance(for permission: PermissionKind) -> Bool {
        active?.request.permission == permission && isGrantDeferredByDrag
    }

    private func showCompanion(for request: PermissionSetupRequest) {
        companion.show(
            request: request,
            onDragStateChanged: { [weak self] dragging in
                self?.realDragStateChanged(dragging)
            },
            onLifecycleEnded: { [weak self] in
                self?.endWithoutGrant(request)
            }
        )
    }

    private func endWithoutGrant(_ request: PermissionSetupRequest) {
        guard let active,
              active.request == request,
              !active.completionPosted else {
            return
        }
        cancel()
        postEndedWithoutGrant(request.permission, request.source)
    }

    private func markGranted(_ permission: PermissionKind) {
        guard var active, active.request.permission == permission else { return }
        if companion.isRealDragActive {
            active.grantPendingUntilDragEnds = true
            self.active = active
            return
        }
        finishGranted(active)
    }

    private func realDragStateChanged(_ dragging: Bool) {
        guard var active else { return }
        if dragging {
            active.grantPendingUntilDragEnds = permissions.status(for: active.request.permission) == .granted
            self.active = active
            return
        }
        if active.grantPendingUntilDragEnds || permissions.status(for: active.request.permission) == .granted {
            finishGranted(active)
        }
    }

    private func finishGranted(_ active: ActiveSetup) {
        guard !active.completionPosted else { return }
        var completed = active
        completed.grantPendingUntilDragEnds = false
        completed.completionPosted = true
        self.active = completed
        companion.showSuccess(for: active.request)
        setSetupNotchState(.granted(active.request.permission))
        scheduleGrantReady(for: active.request)
    }

    private func scheduleGrantReady(for request: PermissionSetupRequest) {
        grantReadyTimer?.invalidate()

        let complete = { [weak self] in
            guard let self,
                  let active = self.active,
                  active.request == request,
                  active.completionPosted else {
                return
            }
            self.grantReadyTimer?.invalidate()
            self.grantReadyTimer = nil
            self.companion.cancel()
            self.active = nil
            self.setSetupNotchState(nil)
            self.postGrantReady(request.permission, request.source)
        }

        guard successAcknowledgementDelay > 0 else {
            complete()
            return
        }

        let timer = Timer(timeInterval: successAcknowledgementDelay, repeats: false) { _ in
            complete()
        }
        RunLoop.main.add(timer, forMode: .common)
        grantReadyTimer = timer
    }
}

struct PermissionCompanionDemoDisplayPolicy {
    static func shouldRunDisplayLink(reduceMotion: Bool, isPaused: Bool, isAttachedToWindow: Bool = true) -> Bool {
        isAttachedToWindow && !reduceMotion && !isPaused
    }
}

struct PermissionCompanionDemoClock: Equatable {
    private(set) var elapsed: TimeInterval = 0
    private var previousTimestamp: TimeInterval?

    mutating func tick(timestamp: TimeInterval, isPaused: Bool) {
        guard !isPaused else {
            freeze()
            return
        }

        defer { previousTimestamp = timestamp }
        guard let previousTimestamp else { return }
        elapsed += max(0, timestamp - previousTimestamp)
    }

    mutating func freeze() {
        previousTimestamp = nil
    }
}

struct PermissionCompanionDirectionalHint: Equatable {
    let start: CGPoint
    let end: CGPoint
    let opacity: CGFloat
}

struct PermissionCompanionInteractionModel: Equatable {
    static let idleDelay: TimeInterval = 0.85

    private(set) var isPaused = false
    private(set) var dragActive = false
    private(set) var hoverActive = false
    private(set) var pendingTimerID: Int?
    private var nextTimerID = 0

    mutating func recordUserActivity(now: TimeInterval = 0) -> Int? {
        isPaused = true
        guard !dragActive, !hoverActive else {
            pendingTimerID = nil
            return nil
        }
        return scheduleResume()
    }

    mutating func beginHover() -> Bool {
        guard !hoverActive else { return false }
        hoverActive = true
        isPaused = true
        pendingTimerID = nil
        return true
    }

    mutating func endHover() -> Int? {
        guard hoverActive else { return nil }
        hoverActive = false
        guard !dragActive else { return nil }
        isPaused = true
        return scheduleResume()
    }

    private mutating func scheduleResume() -> Int {
        nextTimerID += 1
        pendingTimerID = nextTimerID
        return nextTimerID
    }

    mutating func beginRealDrag() {
        dragActive = true
        isPaused = true
        pendingTimerID = nil
    }

    mutating func endRealDrag() -> Int? {
        guard dragActive else { return nil }
        dragActive = false
        guard !hoverActive else { return nil }
        isPaused = true
        return scheduleResume()
    }

    mutating func fireIdleTimer(_ id: Int) {
        guard pendingTimerID == id, !dragActive else { return }
        pendingTimerID = nil
        isPaused = false
    }
}

protocol PermissionCompanionDemoDisplayLinking: AnyObject {
    func add(to runloop: RunLoop, forMode mode: RunLoop.Mode)
    func invalidate()
}

extension CADisplayLink: PermissionCompanionDemoDisplayLinking {}

protocol PermissionCompanionOverlayPanel: AnyObject {
    var isVisible: Bool { get }
    var windowNumber: Int { get }
    var ignoresMouseEvents: Bool { get set }

    func orderFrontRegardless()
    func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int)
}

extension NSPanel: PermissionCompanionOverlayPanel {}

struct PermissionCompanionPanelOrdering {
    static func apply(interactivePanel: PermissionCompanionOverlayPanel,
                      demoPanel: PermissionCompanionOverlayPanel,
                      isRealDragActive: Bool) {
        demoPanel.ignoresMouseEvents = true

        if !interactivePanel.isVisible {
            interactivePanel.orderFrontRegardless()
        }
        guard !isRealDragActive else { return }
        if !demoPanel.isVisible {
            demoPanel.orderFrontRegardless()
        }
        demoPanel.order(.above, relativeTo: interactivePanel.windowNumber)
    }
}

struct PermissionCompanionAnimationPlanner {
    enum Phase: Equatable {
        case staticHint
        case approach
        case press
        case drag
        case release
        case hold
        case reset
    }

    struct State: Equatable {
        let phase: Phase
        let cursor: CGPoint
        let ghostCenter: CGPoint?
        let ghostOpacity: CGFloat
        let directionalHint: PermissionCompanionDirectionalHint?
    }

    static let loopDuration: TimeInterval = 3.3

    static func state(elapsed: TimeInterval,
                      idlePoint: CGPoint,
                      iconCenter: CGPoint,
                      targetCenter: CGPoint,
                      reduceMotion: Bool) -> State {
        guard !reduceMotion else {
            return State(
                phase: .staticHint,
                cursor: idlePoint,
                ghostCenter: nil,
                ghostOpacity: 0,
                directionalHint: PermissionCompanionDirectionalHint(
                    start: iconCenter,
                    end: targetCenter,
                    opacity: 0.9
                )
            )
        }

        let t = elapsed.truncatingRemainder(dividingBy: loopDuration)
        if t < 0.65 {
            return State(
                phase: .approach,
                cursor: lerp(idlePoint, iconCenter, easedProgress(t / 0.65)),
                ghostCenter: nil,
                ghostOpacity: 0,
                directionalHint: nil
            )
        }
        if t < 0.82 {
            return State(
                phase: .press,
                cursor: iconCenter,
                ghostCenter: nil,
                ghostOpacity: 0,
                directionalHint: nil
            )
        }
        if t < 1.95 {
            let progress = easedProgress((t - 0.82) / 1.13)
            let point = lerp(iconCenter, targetCenter, progress)
            return State(
                phase: .drag,
                cursor: point,
                ghostCenter: point,
                ghostOpacity: 0.88,
                directionalHint: nil
            )
        }
        if t < 2.25 {
            return State(
                phase: .release,
                cursor: targetCenter,
                ghostCenter: targetCenter,
                ghostOpacity: 0.82,
                directionalHint: nil
            )
        }
        if t < 2.85 {
            let opacity = CGFloat(1 - ((t - 2.25) / 0.6))
            return State(
                phase: .hold,
                cursor: targetCenter,
                ghostCenter: targetCenter,
                ghostOpacity: max(0, opacity * 0.6),
                directionalHint: nil
            )
        }
        return State(
            phase: .reset,
            cursor: lerp(targetCenter, idlePoint, easedProgress((t - 2.85) / 0.45)),
            ghostCenter: nil,
            ghostOpacity: 0,
            directionalHint: nil
        )
    }

    private static func easedProgress(_ t: TimeInterval) -> CGFloat {
        let clamped = min(max(CGFloat(t), 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let clamped = min(max(t, 0), 1)
        return CGPoint(
            x: a.x + (b.x - a.x) * clamped,
            y: a.y + (b.y - a.y) * clamped
        )
    }
}

struct PermissionCompanionPlacementPlanner {
    enum Anchor: Equatable {
        case belowList
        case right
        case left
        case bottom
        case fallback
    }

    struct Plan: Equatable {
        let frame: CGRect
        let anchor: Anchor
    }

    static let companionSize = CGSize(width: 140, height: 142)
    static let preferredGap: CGFloat = 32
    static let outsideGap: CGFloat = 18

    static func plan(settingsFrame: CGRect,
                     targetRect: CGRect,
                     visibleFrame: CGRect,
                     companionSize: CGSize = companionSize) -> Plan {
        let candidates: [(Anchor, CGRect)] = [
            (
                .belowList,
                CGRect(
                    x: targetRect.midX - companionSize.width / 2,
                    y: targetRect.minY - preferredGap - companionSize.height,
                    width: companionSize.width,
                    height: companionSize.height
                )
            ),
            (
                .right,
                CGRect(
                    x: settingsFrame.maxX + outsideGap,
                    y: targetRect.midY - companionSize.height / 2,
                    width: companionSize.width,
                    height: companionSize.height
                )
            ),
            (
                .left,
                CGRect(
                    x: settingsFrame.minX - outsideGap - companionSize.width,
                    y: targetRect.midY - companionSize.height / 2,
                    width: companionSize.width,
                    height: companionSize.height
                )
            ),
            (
                .bottom,
                CGRect(
                    x: settingsFrame.midX - companionSize.width / 2,
                    y: settingsFrame.minY - outsideGap - companionSize.height,
                    width: companionSize.width,
                    height: companionSize.height
                )
            ),
        ]

        for (anchor, candidate) in candidates {
            guard visibleFrame.contains(candidate) else { continue }
            guard !candidate.intersects(targetRect) else { continue }
            if anchor != .belowList {
                guard !candidate.intersects(settingsFrame) else { continue }
            }
            return Plan(frame: candidate, anchor: anchor)
        }

        let fallbackCandidates = [
            CGRect(
                x: targetRect.maxX + outsideGap,
                y: targetRect.midY - companionSize.height / 2,
                width: companionSize.width,
                height: companionSize.height
            ),
            CGRect(
                x: targetRect.minX - outsideGap - companionSize.width,
                y: targetRect.midY - companionSize.height / 2,
                width: companionSize.width,
                height: companionSize.height
            ),
            CGRect(
                x: targetRect.midX - companionSize.width / 2,
                y: targetRect.maxY + outsideGap,
                width: companionSize.width,
                height: companionSize.height
            ),
            CGRect(
                x: targetRect.midX - companionSize.width / 2,
                y: targetRect.minY - outsideGap - companionSize.height,
                width: companionSize.width,
                height: companionSize.height
            ),
            CGRect(
                x: visibleFrame.maxX - companionSize.width,
                y: visibleFrame.midY - companionSize.height / 2,
                width: companionSize.width,
                height: companionSize.height
            ),
            CGRect(
                x: visibleFrame.midX - companionSize.width / 2,
                y: visibleFrame.midY - companionSize.height / 2,
                width: companionSize.width,
                height: companionSize.height
            ),
        ]
        for fallback in fallbackCandidates {
            let clamped = clamp(fallback, to: visibleFrame)
            if !clamped.intersects(targetRect) {
                return Plan(frame: clamped, anchor: .fallback)
            }
        }
        return Plan(frame: clamp(fallbackCandidates.last!, to: visibleFrame), anchor: .fallback)
    }

    static func pendingDiscoveryFallbackFrame(visibleFrame: CGRect,
                                              companionSize: CGSize = companionSize) -> CGRect {
        CGRect(
            x: visibleFrame.midX - companionSize.width / 2,
            y: visibleFrame.minY + preferredGap,
            width: companionSize.width,
            height: companionSize.height
        )
    }

    static func clamp(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width),
            y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }
}

struct PermissionDisplayGeometry: Equatable {
    let displayID: CGDirectDisplayID
    let cgBounds: CGRect
    let appKitFrame: CGRect
    let visibleFrame: CGRect
}

struct PermissionSettingsWindowObservation: Equatable {
    let windowFrame: CGRect
    let targetRect: CGRect
    let visibleFrame: CGRect
    let displayID: CGDirectDisplayID
}

enum PermissionSettingsWindowFinder {
    static func appKitFrame(fromTopLeftBounds bounds: CGRect,
                            display: PermissionDisplayGeometry) -> CGRect {
        let localX = bounds.minX - display.cgBounds.minX
        let localYFromTop = bounds.minY - display.cgBounds.minY
        return CGRect(
            x: display.appKitFrame.minX + localX,
            y: display.appKitFrame.maxY - localYFromTop - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    static func bestDisplay(for bounds: CGRect,
                            displays: [PermissionDisplayGeometry]) -> PermissionDisplayGeometry? {
        displays.max { lhs, rhs in
            lhs.cgBounds.intersection(bounds).area < rhs.cgBounds.intersection(bounds).area
        }
    }

    static func discover() -> PermissionSettingsWindowObservation? {
        let settingsApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.SystemSettings"
            || $0.bundleIdentifier == "com.apple.systempreferences"
        }
        let settingsPIDs = Set(settingsApps.map(\.processIdentifier))
        guard !settingsPIDs.isEmpty,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              settingsPIDs.contains(frontmost.processIdentifier) else {
            return nil
        }

        let displays = liveDisplays()
        guard !displays.isEmpty,
              let raw = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }

        for entry in raw {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowIsOnscreen as String] as? Bool) == true,
                  let ownerPIDNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  settingsPIDs.contains(pid_t(ownerPIDNumber.int32Value)),
                  let bounds = cgWindowBounds(entry),
                  bounds.width >= 320,
                  bounds.height >= 260,
                  let display = bestDisplay(for: bounds, displays: displays) else {
                continue
            }
            let frame = appKitFrame(fromTopLeftBounds: bounds, display: display)
            return PermissionSettingsWindowObservation(
                windowFrame: frame,
                targetRect: targetRect(in: frame),
                visibleFrame: display.visibleFrame,
                displayID: display.displayID
            )
        }
        return nil
    }

    static func targetRect(in settingsFrame: CGRect) -> CGRect {
        let topInset = max(82, settingsFrame.height * 0.13)
        let preferredBottomInset = max(
            settingsFrame.height * 0.36,
            PermissionCompanionPlacementPlanner.companionSize.height
            + PermissionCompanionPlacementPlanner.preferredGap
            + 12
        )
        let maxBottomInset = max(88, settingsFrame.height - topInset - 72)
        let bottomInset = min(preferredBottomInset, maxBottomInset)
        let minY = settingsFrame.minY + bottomInset
        let maxY = settingsFrame.maxY - topInset
        return CGRect(
            x: settingsFrame.minX + settingsFrame.width * 0.42,
            y: minY,
            width: settingsFrame.width * 0.50,
            height: max(72, maxY - minY)
        )
    }

    private static func liveDisplays() -> [PermissionDisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let id = CGDirectDisplayID(number.uint32Value)
            return PermissionDisplayGeometry(
                displayID: id,
                cgBounds: CGDisplayBounds(id),
                appKitFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    private static func cgWindowBounds(_ entry: [String: Any]) -> CGRect? {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let x = number(bounds["X"]),
              let y = number(bounds["Y"]),
              let width = number(bounds["Width"]),
              let height = number(bounds["Height"]) else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func number(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat { return value }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
        return nil
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

struct PermissionCompanionFallbackPlan: Equatable {
    let permission: PermissionKind
    let purpose: String
    let payloadURL: URL?
    let revealURL: URL
    let payloadEnabled: Bool

    var instructions: String {
        let pane = permission.displayName
        let action: String
        if payloadEnabled {
            action = "If Relay Runner is missing, reveal it in Finder, use System Settings' + button in \(pane), choose Relay Runner.app, then turn on its switch."
        } else {
            action = "Relay Runner is not running from a reachable .app bundle. Reveal it in Finder, then use System Settings' + button in \(pane) to add Relay Runner.app manually."
        }
        return "\(purposeSentence) \(action)"
    }

    var accessibilityLabel: String {
        "\(permission.displayName) permission. \(purposeSentence) Drag Relay Runner.app, or reveal it in Finder and use System Settings' plus button."
    }

    private var purposeSentence: String {
        if !purpose.isEmpty {
            return purpose
        }
        switch permission {
        case .microphone:
            return "Microphone lets Relay Runner capture your speech for local transcription."
        case .accessibility:
            return "Accessibility lets Relay Runner host Relay Actions for clicking, typing, pressing keys, scrolling, and UI automation."
        case .inputMonitoring:
            return "Input Monitoring lets Relay Runner detect global trigger keys and the double-tap Shift Workspace hotkey."
        case .screenRecording:
            return "Screen Recording lets Relay Vision capture screenshots for visual grounding."
        }
    }

    static func make(permission: PermissionKind,
                     purpose: String,
                     bundleURL: URL?,
                     expectedBundleIdentifier: String = PermissionCompanionAppBundleIdentity.relayRunnerBundleIdentifier,
                     bundleIdentity: (URL) -> PermissionCompanionAppBundleIdentity? = PermissionCompanionAppBundleIdentity.read,
                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                     isExecutableFile: (String) -> Bool = { path in
                         var isDirectory: ObjCBool = false
                         return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                             && !isDirectory.boolValue
                             && FileManager.default.isExecutableFile(atPath: path)
                     }) -> PermissionCompanionFallbackPlan {
        let payloadURL = validApplicationBundleURL(
            bundleURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            bundleIdentity: bundleIdentity,
            fileExists: fileExists,
            isExecutableFile: isExecutableFile
        )
        let revealURL: URL
        if let payloadURL {
            revealURL = payloadURL
        } else if let bundleURL, fileExists(bundleURL.path) {
            revealURL = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            revealURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        }
        return PermissionCompanionFallbackPlan(
            permission: permission,
            purpose: purpose,
            payloadURL: payloadURL,
            revealURL: revealURL,
            payloadEnabled: payloadURL != nil
        )
    }

    private static func validApplicationBundleURL(_ bundleURL: URL?,
                                                  expectedBundleIdentifier: String,
                                                  bundleIdentity: (URL) -> PermissionCompanionAppBundleIdentity?,
                                                  fileExists: (String) -> Bool,
                                                  isExecutableFile: (String) -> Bool) -> URL? {
        guard let bundleURL else { return nil }
        let resolved = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.isFileURL,
              resolved.pathExtension == "app",
              resolved.lastPathComponent == RelayInstallerContext.bundleName,
              fileExists(resolved.path) else {
            return nil
        }
        guard let identity = bundleIdentity(resolved),
              identity.bundleIdentifier == expectedBundleIdentifier,
              identity.executableName == PermissionCompanionAppBundleIdentity.relayRunnerExecutableName,
              let executableURL = identity.executableURL?.standardizedFileURL.resolvingSymlinksInPath(),
              executableURL.lastPathComponent == PermissionCompanionAppBundleIdentity.relayRunnerExecutableName,
              executableURL.path.hasPrefix(resolved.appendingPathComponent("Contents/MacOS", isDirectory: true).path + "/"),
              isExecutableFile(executableURL.path) else {
            return nil
        }
        return resolved
    }
}

struct PermissionCompanionAppBundleIdentity: Equatable {
    static let relayRunnerBundleIdentifier = "com.relayrunner.app"
    static let relayRunnerExecutableName = "relay-runner"

    let bundleIdentifier: String?
    let executableName: String?
    let executableURL: URL?

    static func read(from url: URL) -> PermissionCompanionAppBundleIdentity? {
        guard let bundle = Bundle(url: url) else { return nil }
        return PermissionCompanionAppBundleIdentity(
            bundleIdentifier: bundle.bundleIdentifier,
            executableName: bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
            executableURL: bundle.executableURL
        )
    }
}

final class PermissionSetupCompanionController: PermissionSetupCompanionControlling {
    private var interactivePanel: NSPanel?
    private var interactiveHostingView: NSHostingView<PermissionCompanionCard>?
    private var demoPanel: NSPanel?
    private var demoView: PermissionCompanionDemoView?
    private var pollTimer: Timer?
    private var idleTimer: Timer?
    private var activeRequest: PermissionSetupRequest?
    private var firstShownAt: Date?
    private var hasSeenSettingsWindow = false
    private var interactionModel = PermissionCompanionInteractionModel()
    private var onDragStateChanged: ((Bool) -> Void)?
    private var onLifecycleEnded: (() -> Void)?

    private(set) var isRealDragActive = false

    deinit {
        cancel()
    }

    func show(request: PermissionSetupRequest,
              onDragStateChanged: @escaping (Bool) -> Void,
              onLifecycleEnded: @escaping () -> Void) {
        cancel()
        activeRequest = request
        firstShownAt = Date()
        self.onDragStateChanged = onDragStateChanged
        self.onLifecycleEnded = onLifecycleEnded
        showFallbackPosition(for: request)
        startPolling()
    }

    func cancel() {
        pollTimer?.invalidate()
        pollTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        interactivePanel?.close()
        demoPanel?.close()
        interactivePanel = nil
        interactiveHostingView = nil
        demoPanel = nil
        demoView = nil
        activeRequest = nil
        firstShownAt = nil
        hasSeenSettingsWindow = false
        isRealDragActive = false
        interactionModel = PermissionCompanionInteractionModel()
        onDragStateChanged = nil
        onLifecycleEnded = nil
    }

    func showSuccess(for request: PermissionSetupRequest) {
        pollTimer?.invalidate()
        pollTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        demoPanel?.close()
        demoPanel = nil
        demoView = nil
        isRealDragActive = false
        interactionModel = PermissionCompanionInteractionModel()

        guard let panel = interactivePanel else { return }
        let fallback = PermissionCompanionFallbackPlan.make(
            permission: request.permission,
            purpose: request.purpose,
            bundleURL: request.bundleURL
        )
        let root = PermissionCompanionCard(
            fallback: fallback,
            isGranted: true,
            onUserInteraction: {},
            onHoverChanged: { _ in },
            onDragStateChanged: { _ in },
            onReveal: {},
            onOpenSettings: {}
        )
        let hostingView = NSHostingView(rootView: root)
        panel.contentView = hostingView
        interactiveHostingView = hostingView
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.pollSettingsWindow()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollSettingsWindow()
    }

    private func pollSettingsWindow() {
        guard let request = activeRequest else { return }
        guard !isRealDragActive else { return }
        guard let observation = PermissionSettingsWindowFinder.discover() else {
            if hasSeenSettingsWindow || hasTimedOut(request) {
                let ended = onLifecycleEnded
                cancel()
                ended?()
            }
            return
        }
        hasSeenSettingsWindow = true
        let plan = PermissionCompanionPlacementPlanner.plan(
            settingsFrame: observation.windowFrame,
            targetRect: observation.targetRect,
            visibleFrame: observation.visibleFrame
        )
        showPanels(
            request: request,
            frame: plan.frame,
            visibleFrame: observation.visibleFrame,
            targetRect: observation.targetRect
        )
    }

    private func hasTimedOut(_ request: PermissionSetupRequest) -> Bool {
        guard let firstShownAt else { return false }
        return Date().timeIntervalSince(firstShownAt) > request.source.windowDiscoveryTimeout
    }

    private func showFallbackPosition(for request: PermissionSetupRequest) {
        guard let screen = NSScreen.main else { return }
        let size = PermissionCompanionPlacementPlanner.companionSize
        let frame = PermissionCompanionPlacementPlanner.clamp(
            PermissionCompanionPlacementPlanner.pendingDiscoveryFallbackFrame(
                visibleFrame: screen.visibleFrame,
                companionSize: size
            ),
            to: screen.visibleFrame
        )
        let target = CGRect(
            x: frame.maxX + 140,
            y: frame.midY - 36,
            width: 120,
            height: 72
        )
        showPanels(
            request: request,
            frame: frame,
            visibleFrame: screen.visibleFrame,
            targetRect: target
        )
    }

    private func showPanels(request: PermissionSetupRequest,
                            frame: CGRect,
                            visibleFrame: CGRect,
                            targetRect: CGRect) {
        let fallback = PermissionCompanionFallbackPlan.make(
            permission: request.permission,
            purpose: request.purpose,
            bundleURL: request.bundleURL
        )
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panel = interactivePanel ?? makeInteractivePanel()
        if interactiveHostingView == nil || panel.contentView == nil {
            let root = PermissionCompanionCard(
                fallback: fallback,
                isGranted: false,
                onUserInteraction: { [weak self] in self?.recordUserActivity() },
                onHoverChanged: { [weak self] hovering in self?.setIconHovering(hovering) },
                onDragStateChanged: { [weak self] dragging in self?.setRealDragActive(dragging) },
                onReveal: {
                    NSWorkspace.shared.activateFileViewerSelecting([fallback.revealURL])
                },
                onOpenSettings: { [weak self] in
                    guard let request = self?.activeRequest else { return }
                    self?.recordUserActivity()
                    NSWorkspace.shared.open(URL(string: request.permission.settingsURL)!)
                }
            )
            let hostingView = NSHostingView(rootView: root)
            panel.contentView = hostingView
            interactiveHostingView = hostingView
        }
        panel.setFrame(frame, display: true)
        interactivePanel = panel

        let demo = demoPanel ?? makeDemoPanel(frame: visibleFrame)
        demo.setFrame(visibleFrame, display: true)
        let view = demoView ?? PermissionCompanionDemoView(
            frame: CGRect(origin: .zero, size: visibleFrame.size),
            reduceMotion: reduceMotion
        )
        view.frame = CGRect(origin: .zero, size: visibleFrame.size)
        view.icon = fallback.payloadURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(named: NSImage.applicationIconName)
        view.iconCenter = CGPoint(
            x: frame.midX - visibleFrame.minX,
            y: frame.midY - visibleFrame.minY + 8
        )
        view.targetCenter = CGPoint(
            x: targetRect.midX - visibleFrame.minX,
            y: targetRect.midY - visibleFrame.minY
        )
        view.idlePoint = CGPoint(
            x: max(18, view.iconCenter.x - 42),
            y: min(view.bounds.maxY - 18, view.iconCenter.y + 42)
        )
        view.reduceMotion = reduceMotion
        view.isPaused = interactionModel.isPaused
        if demo.contentView !== view {
            demo.contentView = view
        }
        PermissionCompanionPanelOrdering.apply(
            interactivePanel: panel,
            demoPanel: demo,
            isRealDragActive: isRealDragActive
        )
        demoView = view
        demoPanel = demo
    }

    private func makeInteractivePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: PermissionCompanionPlacementPlanner.companionSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func makeDemoPanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private func recordUserActivity() {
        idleTimer?.invalidate()
        idleTimer = nil
        let timerID = interactionModel.recordUserActivity()
        demoView?.isPaused = true
        scheduleIdleTimer(timerID)
    }

    private func setIconHovering(_ hovering: Bool) {
        idleTimer?.invalidate()
        idleTimer = nil
        let timerID: Int?
        if hovering {
            _ = interactionModel.beginHover()
            timerID = nil
        } else {
            timerID = interactionModel.endHover()
        }
        demoView?.isPaused = interactionModel.isPaused
        scheduleIdleTimer(timerID)
    }

    private func scheduleIdleTimer(_ timerID: Int?) {
        guard let timerID else { return }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: PermissionCompanionInteractionModel.idleDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.interactionModel.fireIdleTimer(timerID)
            self.demoView?.isPaused = self.interactionModel.isPaused
        }
    }

    private func setRealDragActive(_ active: Bool) {
        guard isRealDragActive != active else { return }
        isRealDragActive = active
        let timerID: Int?
        if active {
            idleTimer?.invalidate()
            idleTimer = nil
            interactionModel.beginRealDrag()
            demoPanel?.orderOut(nil)
            timerID = nil
        } else {
            timerID = interactionModel.endRealDrag()
        }
        demoView?.isPaused = interactionModel.isPaused
        onDragStateChanged?(active)
        if !active {
            scheduleIdleTimer(timerID)
        }
    }
}

enum PermissionCompanionTileStyle {
    static let size = CGSize(width: 140, height: 142)
    static let cornerRadius: CGFloat = 16
    static let iconSize: CGFloat = 90
    static let iconFrameSize: CGFloat = 92
    static let verticalSpacing: CGFloat = 8
    static let normalBorderOpacity: Double = 0
    static let increasedContrastBorderOpacity: Double = 0.55
}

private struct PermissionCompanionCard: View {
    let fallback: PermissionCompanionFallbackPlan
    let isGranted: Bool
    let onUserInteraction: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onDragStateChanged: (Bool) -> Void
    let onReveal: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        content
        .padding(.top, 11)
        .padding(.bottom, 9)
        .frame(
            width: PermissionCompanionTileStyle.size.width,
            height: PermissionCompanionTileStyle.size.height
        )
        .background(
            RoundedRectangle(cornerRadius: PermissionCompanionTileStyle.cornerRadius, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PermissionCompanionTileStyle.cornerRadius, style: .continuous)
                .stroke(
                    Color.white.opacity(
                        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                            ? PermissionCompanionTileStyle.increasedContrastBorderOpacity
                            : PermissionCompanionTileStyle.normalBorderOpacity
                    ),
                    lineWidth: 1
                )
        )
        .contextMenu {
            Button("Reveal Relay Runner in Finder", action: onReveal)
            Button("Open \(fallback.permission.displayName) Settings", action: onOpenSettings)
        }
        .accessibilityAction(named: "Reveal Relay Runner in Finder", onReveal)
        .accessibilityAction(named: "Open \(fallback.permission.displayName) Settings", onOpenSettings)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isGranted ? grantedAccessibilityLabel : fallback.accessibilityLabel)
        .accessibilityHint(isGranted ? "Relay Runner is ready for \(fallback.permission.displayName)." : fallback.instructions)
    }

    @ViewBuilder
    private var content: some View {
        if isGranted {
            VStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppTypography.symbolFont(size: 46, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Granted")
                    .font(AppTypography.font(.cardHeading))
                    .foregroundStyle(.white)
                Text(fallback.permission.displayName)
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
        } else {
            VStack(spacing: PermissionCompanionTileStyle.verticalSpacing) {
                DraggableAppIconView(
                    bundleURL: fallback.payloadURL,
                    size: PermissionCompanionTileStyle.iconSize,
                    isEnabled: fallback.payloadEnabled,
                    onUserInteraction: onUserInteraction,
                    onHoverChanged: onHoverChanged,
                    onDragStateChanged: onDragStateChanged
                )
                .frame(
                    width: PermissionCompanionTileStyle.iconFrameSize,
                    height: PermissionCompanionTileStyle.iconFrameSize
                )
                Text("Drag me")
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
    }

    private var grantedAccessibilityLabel: String {
        "\(fallback.permission.displayName) granted for Relay Runner."
    }
}

enum PermissionCompanionCursorArtwork: Equatable {
    case openHand
    case closedHand

    static func artwork(for phase: PermissionCompanionAnimationPlanner.Phase) -> PermissionCompanionCursorArtwork {
        switch phase {
        case .press, .drag:
            return .closedHand
        case .staticHint, .approach, .release, .hold, .reset:
            return .openHand
        }
    }

    var cursor: NSCursor {
        switch self {
        case .openHand:
            return .openHand
        case .closedHand:
            return .closedHand
        }
    }

    static func drawFrame(for point: CGPoint,
                          imageSize: CGSize,
                          hotSpot: CGPoint) -> CGRect {
        CGRect(
            x: point.x - hotSpot.x,
            y: point.y - hotSpot.y,
            width: imageSize.width,
            height: imageSize.height
        )
    }
}

final class PermissionCompanionDemoView: NSView {
    var icon: NSImage?
    var iconCenter: CGPoint = .zero
    var targetCenter: CGPoint = .zero
    var idlePoint: CGPoint = .zero
    var reduceMotion = false {
        didSet {
            guard oldValue != reduceMotion else { return }
            updateDisplayLink()
            needsDisplay = true
        }
    }
    var isPaused = false {
        didSet {
            guard oldValue != isPaused else { return }
            updateDisplayLink()
            needsDisplay = true
        }
    }

    private var clock = PermissionCompanionDemoClock()
    private let displayLinkTarget = PermissionCompanionDemoDisplayLinkTarget()
    private var displayLink: PermissionCompanionDemoDisplayLinking?
    private let displayLinkFactory: (PermissionCompanionDemoView, Any, Selector) -> PermissionCompanionDemoDisplayLinking

    init(frame frameRect: NSRect,
         reduceMotion: Bool = false,
         displayLinkFactory: ((PermissionCompanionDemoView, Any, Selector) -> PermissionCompanionDemoDisplayLinking)? = nil) {
        self.reduceMotion = reduceMotion
        self.displayLinkFactory = displayLinkFactory ?? { view, target, selector in
            view.displayLink(target: target, selector: selector)
        }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        displayLinkTarget.view = self
        updateDisplayLink()
    }

    required init?(coder: NSCoder) {
        self.displayLinkFactory = { view, target, selector in
            view.displayLink(target: target, selector: selector)
        }
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        displayLinkTarget.view = self
        updateDisplayLink()
    }

    deinit {
        displayLink?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayLink()
    }

    fileprivate func displayLinkDidFire(_ link: CADisplayLink) {
        displayLinkDidFire(timestamp: link.timestamp)
    }

    func simulateDisplayLinkTickForTesting(timestamp: TimeInterval) {
        displayLinkDidFire(timestamp: timestamp)
    }

    var animationElapsedForTesting: TimeInterval {
        clock.elapsed
    }

    var hasActiveDisplayLinkForTesting: Bool {
        displayLink != nil
    }

    private func displayLinkDidFire(timestamp: TimeInterval) {
        clock.tick(timestamp: timestamp, isPaused: reduceMotion || isPaused)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let state = PermissionCompanionAnimationPlanner.state(
            elapsed: clock.elapsed,
            idlePoint: idlePoint,
            iconCenter: iconCenter,
            targetCenter: targetCenter,
            reduceMotion: reduceMotion
        )
        if let hint = state.directionalHint {
            drawDirectionalHint(hint)
        }
        if let ghostCenter = state.ghostCenter, let icon {
            icon.draw(
                in: CGRect(
                    x: ghostCenter.x - 24,
                    y: ghostCenter.y - 24,
                    width: 48,
                    height: 48
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: state.ghostOpacity
            )
        }
        drawCursor(at: state.cursor, artwork: PermissionCompanionCursorArtwork.artwork(for: state.phase))
    }

    private func updateDisplayLink() {
        let shouldRun = PermissionCompanionDemoDisplayPolicy.shouldRunDisplayLink(
            reduceMotion: reduceMotion,
            isPaused: isPaused,
            isAttachedToWindow: window != nil
        )
        guard shouldRun else {
            displayLink?.invalidate()
            displayLink = nil
            clock.freeze()
            return
        }

        guard displayLink == nil else { return }
        let link = displayLinkFactory(
            self,
            displayLinkTarget,
            #selector(PermissionCompanionDemoDisplayLinkTarget.tick(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func drawDirectionalHint(_ hint: PermissionCompanionDirectionalHint) {
        let start = pointAlongLine(from: hint.start, to: hint.end, inset: 42)
        let end = pointAlongLine(from: hint.end, to: hint.start, inset: 30)
        guard hypot(start.x - end.x, start.y - end.y) > 12 else { return }

        NSColor.white.withAlphaComponent(hint.opacity).setStroke()
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.stroke()

        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 13
        let arrowSpread = CGFloat.pi / 7
        let arrow = NSBezierPath()
        arrow.move(to: end)
        arrow.line(to: CGPoint(
            x: end.x - arrowLength * cos(angle - arrowSpread),
            y: end.y - arrowLength * sin(angle - arrowSpread)
        ))
        arrow.move(to: end)
        arrow.line(to: CGPoint(
            x: end.x - arrowLength * cos(angle + arrowSpread),
            y: end.y - arrowLength * sin(angle + arrowSpread)
        ))
        arrow.lineWidth = 3
        arrow.lineCapStyle = .round
        arrow.stroke()
    }

    private func pointAlongLine(from start: CGPoint, to end: CGPoint, inset: CGFloat) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = max(1, hypot(dx, dy))
        return CGPoint(
            x: start.x + dx / distance * inset,
            y: start.y + dy / distance * inset
        )
    }

    private func drawCursor(at point: CGPoint, artwork: PermissionCompanionCursorArtwork) {
        let cursor = artwork.cursor
        let image = cursor.image
        image.draw(
            in: PermissionCompanionCursorArtwork.drawFrame(
                for: point,
                imageSize: image.size,
                hotSpot: cursor.hotSpot
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.94
        )
    }
}

private final class PermissionCompanionDemoDisplayLinkTarget: NSObject {
    weak var view: PermissionCompanionDemoView?

    @objc func tick(_ link: CADisplayLink) {
        view?.displayLinkDidFire(link)
    }
}
