import AppKit
import ApplicationServices
import SwiftUI

enum PermissionSetupSource: Equatable {
    case onboarding
    case settingsStatus
    case hostedTool
    case permissionRecovery

    var windowDiscoveryTimeout: TimeInterval {
        switch self {
        case .onboarding:
            return 12
        case .settingsStatus, .permissionRecovery:
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
}

final class PermissionSetupCoordinator {
    private struct ActiveSetup {
        let request: PermissionSetupRequest
        var grantPendingUntilDragEnds = false
        var completionPosted = false
    }

    private let permissions: PermissionsManager
    private let setSetupNotchState: (PermissionSetupNotchState?) -> Void
    private let postGrantReady: (PermissionKind, PermissionSetupSource) -> Void
    private let companion: PermissionSetupCompanionController
    private var active: ActiveSetup?

    init(permissions: PermissionsManager,
         setSetupNotchState: @escaping (PermissionSetupNotchState?) -> Void,
         postGrantReady: @escaping (PermissionKind, PermissionSetupSource) -> Void = { kind, _ in
             NotificationCenter.default.post(
                name: .relayPermissionSetupGrantReady,
                object: kind.rawValue
             )
         },
         companion: PermissionSetupCompanionController = PermissionSetupCompanionController()) {
        self.permissions = permissions
        self.setSetupNotchState = setSetupNotchState
        self.postGrantReady = postGrantReady
        self.companion = companion
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
                    self.cancel()
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
                self?.cancel()
            }
        )
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
        completed.completionPosted = true
        self.active = completed
        companion.cancel()
        setSetupNotchState(nil)
        postGrantReady(active.request.permission, active.request.source)
        self.active = nil
    }
}

struct PermissionCompanionInteractionModel: Equatable {
    static let idleDelay: TimeInterval = 0.85

    private(set) var isPaused = false
    private(set) var dragActive = false
    private(set) var pendingTimerID: Int?
    private var nextTimerID = 0

    mutating func recordUserActivity(now: TimeInterval = 0) -> Int {
        isPaused = true
        nextTimerID += 1
        pendingTimerID = nextTimerID
        return nextTimerID
    }

    mutating func beginRealDrag() {
        dragActive = true
        isPaused = true
        pendingTimerID = nil
    }

    mutating func endRealDrag() -> Int {
        dragActive = false
        return recordUserActivity()
    }

    mutating func fireIdleTimer(_ id: Int) {
        guard pendingTimerID == id, !dragActive else { return }
        pendingTimerID = nil
        isPaused = false
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
        let dropCueOpacity: CGFloat
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
                dropCueOpacity: 0.8
            )
        }

        let t = elapsed.truncatingRemainder(dividingBy: loopDuration)
        if t < 0.65 {
            return State(
                phase: .approach,
                cursor: lerp(idlePoint, iconCenter, CGFloat(t / 0.65)),
                ghostCenter: nil,
                ghostOpacity: 0,
                dropCueOpacity: 0
            )
        }
        if t < 0.82 {
            return State(
                phase: .press,
                cursor: iconCenter,
                ghostCenter: nil,
                ghostOpacity: 0,
                dropCueOpacity: 0
            )
        }
        if t < 1.95 {
            let progress = CGFloat((t - 0.82) / 1.13)
            let point = lerp(iconCenter, targetCenter, progress)
            return State(
                phase: .drag,
                cursor: point,
                ghostCenter: point,
                ghostOpacity: 0.88,
                dropCueOpacity: 0
            )
        }
        if t < 2.25 {
            return State(
                phase: .release,
                cursor: targetCenter,
                ghostCenter: targetCenter,
                ghostOpacity: 0.82,
                dropCueOpacity: 1
            )
        }
        if t < 2.85 {
            let opacity = CGFloat(1 - ((t - 2.25) / 0.6))
            return State(
                phase: .hold,
                cursor: targetCenter,
                ghostCenter: targetCenter,
                ghostOpacity: max(0, opacity * 0.6),
                dropCueOpacity: max(0, opacity)
            )
        }
        return State(
            phase: .reset,
            cursor: lerp(targetCenter, idlePoint, CGFloat((t - 2.85) / 0.45)),
            ghostCenter: nil,
            ghostOpacity: 0,
            dropCueOpacity: 0
        )
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(
            x: a.x + (b.x - a.x) * min(max(t, 0), 1),
            y: a.y + (b.y - a.y) * min(max(t, 0), 1)
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
        CGRect(
            x: settingsFrame.minX + settingsFrame.width * 0.42,
            y: settingsFrame.minY + max(88, settingsFrame.height * 0.16),
            width: settingsFrame.width * 0.50,
            height: min(settingsFrame.height * 0.62, settingsFrame.height - 150)
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
        if payloadEnabled {
            return "If Relay Runner is missing, reveal it in Finder, use System Settings' + button in \(pane), choose Relay Runner.app, then turn on its switch."
        }
        return "Relay Runner is not running from a reachable .app bundle. Reveal it in Finder, then use System Settings' + button in \(pane) to add Relay Runner.app manually."
    }

    var accessibilityLabel: String {
        let purposeCopy = purpose.isEmpty ? "" : "\(purpose) "
        return "\(permission.displayName) permission. \(purposeCopy)Drag Relay Runner.app, or reveal it in Finder and use System Settings' plus button."
    }

    static func make(permission: PermissionKind,
                     purpose: String,
                     bundleURL: URL?,
                     fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> PermissionCompanionFallbackPlan {
        let validPayload = bundleURL.map {
            $0.pathExtension == "app" && fileExists($0.path)
        } ?? false
        let revealURL: URL
        if let bundleURL, fileExists(bundleURL.path) {
            revealURL = bundleURL
        } else {
            revealURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        }
        return PermissionCompanionFallbackPlan(
            permission: permission,
            purpose: purpose,
            payloadURL: validPayload ? bundleURL : nil,
            revealURL: revealURL,
            payloadEnabled: validPayload
        )
    }
}

final class PermissionSetupCompanionController {
    private var interactivePanel: NSPanel?
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
        let frame = CGRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
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
        let panel = interactivePanel ?? makeInteractivePanel()
        let root = PermissionCompanionCard(
            fallback: fallback,
            onUserInteraction: { [weak self] in self?.recordUserActivity() },
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
        panel.contentView = NSHostingView(rootView: root)
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        interactivePanel = panel

        let demo = demoPanel ?? makeDemoPanel(frame: visibleFrame)
        demo.setFrame(visibleFrame, display: true)
        let view = demoView ?? PermissionCompanionDemoView(frame: CGRect(origin: .zero, size: visibleFrame.size))
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
        view.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.isPaused = interactionModel.isPaused
        if demo.contentView !== view {
            demo.contentView = view
        }
        if !demo.isVisible {
            demo.orderFrontRegardless()
        }
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
        panel.hidesOnDeactivate = false
        return panel
    }

    private func recordUserActivity() {
        let timerID = interactionModel.recordUserActivity()
        demoView?.isPaused = true
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
        if active {
            idleTimer?.invalidate()
            idleTimer = nil
            interactionModel.beginRealDrag()
        } else {
            _ = interactionModel.endRealDrag()
        }
        demoView?.isPaused = interactionModel.isPaused
        onDragStateChanged?(active)
        if !active {
            recordUserActivity()
        }
    }
}

private struct PermissionCompanionCard: View {
    let fallback: PermissionCompanionFallbackPlan
    let onUserInteraction: () -> Void
    let onDragStateChanged: (Bool) -> Void
    let onReveal: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            DraggableAppIconView(
                bundleURL: fallback.payloadURL,
                size: 90,
                isEnabled: fallback.payloadEnabled,
                onUserInteraction: onUserInteraction,
                onDragStateChanged: onDragStateChanged
            )
            .frame(width: 92, height: 92)
            Text(fallback.payloadEnabled ? "Drag me" : "Reveal")
                .font(AppTypography.font(.caption))
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 6) {
                Button(action: onReveal) {
                    Image(systemName: "folder")
                }
                .help("Reveal Relay Runner in Finder")
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .help("Open \(fallback.permission.displayName) Settings")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white)
        }
        .padding(.top, 11)
        .padding(.bottom, 9)
        .frame(width: 140, height: 142)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.55 : 0), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fallback.accessibilityLabel)
        .accessibilityHint(fallback.instructions)
        .onHover { _ in onUserInteraction() }
    }
}

private final class PermissionCompanionDemoView: NSView {
    var icon: NSImage?
    var iconCenter: CGPoint = .zero
    var targetCenter: CGPoint = .zero
    var idlePoint: CGPoint = .zero
    var reduceMotion = false
    var isPaused = false {
        didSet { displayLinkActive = !isPaused }
    }

    private var startedAt = Date()
    private var animationTimer: Timer?
    private var displayLinkActive = true {
        didSet { updateTimer() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        updateTimer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        updateTimer()
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let state = PermissionCompanionAnimationPlanner.state(
            elapsed: Date().timeIntervalSince(startedAt),
            idlePoint: idlePoint,
            iconCenter: iconCenter,
            targetCenter: targetCenter,
            reduceMotion: reduceMotion
        )
        drawDropCue(opacity: state.dropCueOpacity)
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
        drawCursor(at: state.cursor, pressed: state.phase == .press || state.phase == .drag)
    }

    private func updateTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        guard displayLinkActive else { return }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    private func drawDropCue(opacity: CGFloat) {
        guard opacity > 0 else { return }
        NSColor.systemGreen.withAlphaComponent(opacity).setStroke()
        let rect = CGRect(x: targetCenter.x - 18, y: targetCenter.y - 18, width: 36, height: 36)
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 3
        path.stroke()
        let plus = NSBezierPath()
        plus.move(to: CGPoint(x: targetCenter.x - 8, y: targetCenter.y))
        plus.line(to: CGPoint(x: targetCenter.x + 8, y: targetCenter.y))
        plus.move(to: CGPoint(x: targetCenter.x, y: targetCenter.y - 8))
        plus.line(to: CGPoint(x: targetCenter.x, y: targetCenter.y + 8))
        plus.lineWidth = 2
        plus.stroke()
    }

    private func drawCursor(at point: CGPoint, pressed: Bool) {
        let path = NSBezierPath()
        path.move(to: point)
        path.line(to: CGPoint(x: point.x + 2, y: point.y - 24))
        path.line(to: CGPoint(x: point.x + 8, y: point.y - 17))
        path.line(to: CGPoint(x: point.x + 13, y: point.y - 30))
        path.line(to: CGPoint(x: point.x + 18, y: point.y - 28))
        path.line(to: CGPoint(x: point.x + 13, y: point.y - 15))
        path.line(to: CGPoint(x: point.x + 23, y: point.y - 15))
        path.close()
        NSColor.white.withAlphaComponent(pressed ? 0.95 : 0.86).setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
