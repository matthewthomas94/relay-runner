import AppKit
import SwiftUI

/// One button in a Graphical dialog.
struct GraphicalDialogAction {
    enum Role { case `default`, cancel, destructive }

    let title: String
    var role: Role = .default
    let action: () -> Void

    init(_ title: String, role: Role = .default, action: @escaping () -> Void = {}) {
        self.title = title
        self.role = role
        self.action = action
    }
}

/// The kit's alert dialog: a neutral-2 card with radius 24 and 24 points of
/// padding over a 20% black backdrop. The title is text-m, the description is
/// text-s in neutral-7. Cancel is a secondary button; the confirming action is
/// the white primary button, or the danger button when it destroys something.
struct GraphicalDialogView: View {
    static let width: CGFloat = 400

    let title: String
    let message: String?
    let actions: [GraphicalDialogAction]
    let dismiss: () -> Void

    private var cancel: GraphicalDialogAction? { actions.first { $0.role == .cancel } }
    private var confirming: [GraphicalDialogAction] { actions.filter { $0.role != .cancel } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .contentShape(Rectangle())
                .onTapGesture { perform(cancel) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: GraphicalTheme.spaceS) {
                Text(title)
                    .font(AppTypography.font(.screenTitle))
                    .foregroundStyle(GraphicalTheme.neutral10)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message)
                        .font(AppTypography.font(.body))
                        .foregroundStyle(GraphicalTheme.neutral7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: GraphicalTheme.spaceXS) {
                    Spacer(minLength: 0)
                    SettingsActionButton(title: cancel?.title ?? "Cancel", systemImage: nil) { perform(cancel) }
                        .keyboardShortcut(.cancelAction)
                    ForEach(confirming.indices, id: \.self) { index in
                        let action = confirming[index]
                        SettingsActionButton(
                            title: action.title,
                            systemImage: nil,
                            prominence: action.role == .destructive ? .danger : .primary
                        ) { perform(action) }
                        .keyboardShortcut(index == confirming.count - 1 ? .defaultAction : nil)
                    }
                }
                .padding(.top, GraphicalTheme.spaceXS)
            }
            .padding(GraphicalTheme.spaceL)
            .frame(width: Self.width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: GraphicalTheme.radiusM, style: .continuous)
                    .fill(GraphicalTheme.neutral2)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isModal)
        }
        .onExitCommand { perform(cancel) }
        .environment(\.colorScheme, .dark)
    }

    private func perform(_ action: GraphicalDialogAction?) {
        dismiss()
        action?.action()
    }
}

/// Presents a Graphical dialog in a child panel that covers its window, so it
/// sits above scrolling content the way a system alert would.
private struct GraphicalDialogPresenter: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let message: String?
    let actions: [GraphicalDialogAction]

    func makeNSView(context: Context) -> GraphicalDialogAnchorView { GraphicalDialogAnchorView() }

    func updateNSView(_ view: GraphicalDialogAnchorView, context: Context) {
        if isPresented {
            let binding = $isPresented
            view.present(AnyView(GraphicalDialogView(
                title: title, message: message, actions: actions,
                dismiss: { binding.wrappedValue = false }
            )))
        } else {
            view.hide()
        }
    }

    static func dismantleNSView(_ view: GraphicalDialogAnchorView, coordinator: ()) {
        view.hide()
    }
}

final class GraphicalDialogAnchorView: NSView {
    private var panel: GraphicalDialogPanel?
    private var pendingContent: AnyView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hide(animated: false)
        } else if let pendingContent {
            present(pendingContent)
        }
    }

    func present(_ content: AnyView) {
        if let hosting = panel?.contentView as? NSHostingView<AnyView> {
            hosting.rootView = content
            return
        }
        guard let window else {
            pendingContent = content
            return
        }
        pendingContent = nil
        let hosting = NSHostingView(rootView: content)
        let panel = GraphicalDialogPanel(
            contentRect: window.frame,
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = window.level
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = hosting
        self.panel = panel
        panel.setFrame(window.frame, display: true)
        window.addChildWindow(panel, ordered: .above)
        RelayWindowMotion.present(panel)
    }

    func hide(animated: Bool = true) {
        guard let panel else { return }
        self.panel = nil
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { window?.makeKey() }
        let close = {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        if animated { RelayWindowMotion.dismiss(panel, completion: close) } else { close() }
    }
}

private final class GraphicalDialogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension View {
    /// A Graphical alert dialog in place of the system `.alert`. A Cancel button
    /// is added when no action has the cancel role.
    func graphicalAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        actions: [GraphicalDialogAction]
    ) -> some View {
        // Mounted only while presented, so the anchor costs nothing at rest.
        background {
            if isPresented.wrappedValue {
                GraphicalDialogPresenter(
                    isPresented: isPresented,
                    title: title,
                    message: message,
                    actions: actions.contains { $0.role == .cancel } ? actions
                        : [GraphicalDialogAction("Cancel", role: .cancel)] + actions
                )
            }
        }
    }
}
