import AppKit

/// Bottom-center pill showing live transcription or message preview.
/// Uses NSVisualEffectView for blur backdrop, overlaid with a text label.
final class TranscriptionPill: NSView {

    private let blurView: NSVisualEffectView
    private let label: NSTextField
    private let maxWidth: CGFloat = 600
    private let padding = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

    override init(frame: NSRect) {
        blurView = NSVisualEffectView()
        label = NSTextField(labelWithString: "")

        super.init(frame: frame)

        wantsLayer = true
        alphaValue = 0

        // Blur backdrop
        blurView.material = .hudWindow
        blurView.state = .active
        blurView.blendingMode = .behindWindow
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 16
        blurView.layer?.masksToBounds = true
        addSubview(blurView)

        // Text label
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Update the displayed text. Pass nil or empty to hide.
    func update(text: String?, animated: Bool = true) {
        guard let text, !text.isEmpty else {
            hide(animated: animated)
            return
        }

        label.stringValue = text

        // Size to fit
        let labelSize = label.sizeThatFits(NSSize(width: maxWidth - padding.left - padding.right, height: 60))
        let pillWidth = min(maxWidth, labelSize.width + padding.left + padding.right)
        let pillHeight = labelSize.height + padding.top + padding.bottom

        // Position at bottom-center of superview
        guard let superview else { return }
        let x = (superview.bounds.width - pillWidth) / 2
        let y: CGFloat = 40  // offset from bottom

        frame = NSRect(x: x, y: y, width: pillWidth, height: pillHeight)
        blurView.frame = bounds
        label.frame = NSRect(
            x: padding.left,
            y: padding.bottom,
            width: bounds.width - padding.left - padding.right,
            height: bounds.height - padding.top - padding.bottom
        )

        show(animated: animated)
    }

    private func show(animated: Bool) {
        guard alphaValue < 1 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
        }
    }

    func hide(animated: Bool = true) {
        guard alphaValue > 0 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                animator().alphaValue = 0
            }
        } else {
            alphaValue = 0
        }
    }
}
