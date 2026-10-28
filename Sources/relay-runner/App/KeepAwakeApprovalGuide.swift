import AppKit
import SwiftUI

/// While Keep Awake waits for its power helper's one-time approval, a tile beside System
/// Settings shows Relay Runner's switch turning on, like the permission companion does for
/// privacy permissions. Login Items takes a switch, not a dragged app, so nothing drags here.
final class KeepAwakeApprovalGuide {
    static let allowedAcknowledgementDelay: TimeInterval = 0.65

    private var panel: NSPanel?
    private var hostingView: NSHostingView<KeepAwakeApprovalTile>?
    private var frame: CGRect?
    private var pollTimer: Timer?
    private var dismissTimer: Timer?

    func show() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        setTile(allowed: false)
        if frame == nil, let screen = NSScreen.main {
            place(PermissionCompanionPlacementPlanner.clamp(
                PermissionCompanionPlacementPlanner.pendingDiscoveryFallbackFrame(visibleFrame: screen.visibleFrame),
                to: screen.visibleFrame))
        }
        RelayWindowMotion.present(panel, makeKey: false)
        startPolling()
    }

    /// Approval landed: the tile swaps to its allowed state, then leaves.
    func showAllowed() {
        guard panel != nil else { return }
        stopPolling()
        setTile(allowed: true)
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: Self.allowedAcknowledgementDelay, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    func dismiss() {
        stopPolling()
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let panel else { return }
        self.panel = nil
        hostingView = nil
        frame = nil
        RelayWindowMotion.dismiss(panel) { panel.close() }
    }

    private func setTile(allowed: Bool) {
        let tile = KeepAwakeApprovalTile(isAllowed: allowed)
        if let hostingView, panel?.contentView === hostingView {
            hostingView.rootView = tile
        } else {
            let hostingView = NSHostingView(rootView: tile)
            panel?.contentView = hostingView
            self.hostingView = hostingView
        }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        follow()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Keeps the tile beside the Settings window while it is frontmost.
    private func follow() {
        guard let observation = PermissionSettingsWindowFinder.discover() else { return }
        place(PermissionCompanionPlacementPlanner.plan(
            settingsFrame: observation.windowFrame,
            targetRect: observation.targetRect,
            visibleFrame: observation.visibleFrame
        ).frame)
    }

    private func place(_ next: CGRect) {
        guard let panel, next != frame else { return }
        defer { frame = next }
        guard panel.isVisible, frame != nil, !RelayLayerMotion.reduceMotion else {
            panel.setFrame(next, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = RelayMotion.changeDuration
            context.timingFunction = RelayMotion.changeCurve.mediaTimingFunction
            panel.animator().setFrame(next, display: true)
        }
    }

    private static func makePanel() -> NSPanel {
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
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        return panel
    }
}

struct KeepAwakeApprovalTile: View {
    static let switchInterval: Duration = .seconds(1.1)

    let isAllowed: Bool
    @State private var switchOn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RelaySwap(isAllowed) { isAllowed in
            if isAllowed {
                VStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppTypography.symbolFont(size: 46, weight: .semibold))
                        .foregroundStyle(.green)
                    Text("Allowed")
                        .font(AppTypography.font(.cardHeading))
                        .foregroundStyle(.white)
                    Text(KeepAwakeState.label)
                        .font(AppTypography.font(.caption))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
            } else {
                VStack(spacing: PermissionCompanionTileStyle.verticalSpacing) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 56, height: 56)
                    mockSwitch(on: reduceMotion || switchOn)
                    Text("Turn me on")
                        .font(AppTypography.font(.caption))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, 11)
        .padding(.bottom, 9)
        .frame(width: PermissionCompanionTileStyle.size.width, height: PermissionCompanionTileStyle.size.height)
        .background(
            RoundedRectangle(cornerRadius: PermissionCompanionTileStyle.cornerRadius, style: .continuous)
                .fill(Color.black)
        )
        .task(id: isAllowed) {
            guard !isAllowed, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.switchInterval)
                withAnimation(RelayMotion.change) { switchOn.toggle() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isAllowed
            ? "Keep Awake allowed."
            : "Turn on Relay Runner under Allow in the Background in \(KeepAwakePowerHelper.approvalPlace).")
    }

    /// The Login Items switch, sliding on and off to show what to click.
    private func mockSwitch(on: Bool) -> some View {
        Capsule()
            .fill(on ? Color.accentColor : Color.white.opacity(0.25))
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .padding(2)
            }
    }
}
