import AppKit
import SwiftUI

struct NotchStatusDisplayGeometry: Equatable {
    let frame: CGRect
    let auxiliaryTopRightArea: CGRect

    init(frame: CGRect, auxiliaryTopRightArea: CGRect) {
        self.frame = frame
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }

    init(screen: NSScreen) {
        self.frame = screen.frame
        self.auxiliaryTopRightArea = screen.auxiliaryTopRightArea ?? .zero
    }
}

struct NotchStatusPlacement: Equatable {
    let visibleFrame: CGRect
    let retractedFrame: CGRect
}

enum NotchStatusPlacementPlanner {
    static let surfaceSize = CGSize(width: 30, height: 30)

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

        return NotchStatusPlacement(
            visibleFrame: visibleFrame,
            retractedFrame: retractedFrame
        )
    }
}

final class NotchStatusController {
    private var panel: NotchStatusPanel?
    private var active = false
    private var screenParametersObserver: NSObjectProtocol?
    private var lastPlacement: NotchStatusPlacement?
    private var loggedMissingNotch = false

    deinit {
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
        } else {
            hide()
        }
    }

    private func show() {
        installScreenParametersObserver()

        guard let placement = currentPlacement() else {
            if !loggedMissingNotch {
                NSLog("[RelayRunner] Notch status surface hidden: no display exposes an auxiliary top-right notch area.")
                loggedMissingNotch = true
            }
            panel?.orderOut(nil)
            return
        }

        loggedMissingNotch = false
        lastPlacement = placement

        let panel = panel ?? NotchStatusPanel()
        if self.panel == nil {
            panel.contentView = NSHostingView(rootView: NotchStatusIconView())
            self.panel = panel
        }

        panel.setFrame(placement.retractedFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().setFrame(placement.visibleFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        removeScreenParametersObserver()

        guard let panel else { return }
        let targetFrame = currentPlacement()?.retractedFrame
            ?? lastPlacement?.retractedFrame
            ?? panel.frame.offsetBy(dx: -10, dy: 2)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func updatePlacement(animated: Bool) {
        guard let placement = currentPlacement() else {
            panel?.orderOut(nil)
            return
        }
        lastPlacement = placement

        guard let panel else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().setFrame(placement.visibleFrame, display: true)
            }
        } else {
            panel.setFrame(placement.visibleFrame, display: true)
        }
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
    private let orange = Color(red: 1.0, green: 0.42, blue: 0.0)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(orange.opacity(0.88), lineWidth: 1)
                }
                .shadow(color: orange.opacity(0.32), radius: 5, y: 1)

            Image("TrayIconActive", bundle: RelayRunnerResources.bundle)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
        }
        .frame(
            width: NotchStatusPlacementPlanner.surfaceSize.width,
            height: NotchStatusPlacementPlanner.surfaceSize.height
        )
    }
}
