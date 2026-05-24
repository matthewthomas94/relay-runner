import AppKit
import SwiftUI

/// Transient overlay shown when the user toggles the board hotkey without an
/// active `/relay-bridge` session. The board needs a session to know which
/// repo's `.orchestrator/` to render; without one we can't pick a project,
/// so we surface a brief teachable cue instead of silently no-op'ing.
///
/// Self-contained: one static `show()` builds an NSPanel, fades the message
/// in, and auto-dismisses after a short window. Repeated calls collapse onto
/// the same panel rather than stacking — the message is the same regardless
/// of how often it fires.
enum NoSessionToast {

    private static var panel: NSPanel?
    private static var dismissTimer: Timer?
    private static let displayDuration: TimeInterval = 2.5

    static func show() {
        // Coalesce: if the toast is already up, just refresh the dismiss timer.
        if let panel, panel.isVisible {
            armDismissTimer()
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? .zero
        let width: CGFloat = 420
        let height: CGFloat = 56
        let origin = CGPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2
        )

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .none

        let view = NoSessionToastView()
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        p.contentView = hosting
        p.orderFrontRegardless()
        panel = p

        armDismissTimer()
    }

    private static func armDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: displayDuration, repeats: false) { _ in
            dismiss()
        }
    }

    private static func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private struct NoSessionToastView: View {
    var body: some View {
        Text("Start a /relay-bridge session in your project to open the board.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 8)
            .padding(8)
    }
}
