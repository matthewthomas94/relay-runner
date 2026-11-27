import SwiftUI

/// Sizes and timings of the modal (RR-551). There is no Figma screen for it:
/// it is built from the panel surface, the secondary button and the standard
/// swap, and described in docs/design/relay-remote-ios/README.md.
enum RelayModalMetrics {
    /// The panel starts this far below the status bar.
    static let topGap: CGFloat = 16
    /// The panel ends this far above the bottom of the screen, the gap the
    /// full-width buttons keep.
    static let bottomGap: CGFloat = 40
    /// The black behind the panel, over the whole app.
    static let scrimOpacity: Double = 0.6
    /// How far the body fades at an edge it has scrolled under.
    static let edgeFade: CGFloat = 32
    /// The panel closes when dragged down past this share of its height.
    static let dismissFraction: CGFloat = 1.0 / 3
    /// Or when let go faster than this, in points per second.
    static let flickVelocity: CGFloat = 700

    /// Opening: the panel fades in from a light blur and 96% on the strong
    /// ease-out, unhurried enough to read as one smooth arrival.
    static let open = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.34)
    /// Closing is quicker than opening: the user is done with it.
    static let close = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.2)
}

/// The app's modal: one glass panel over a black scrim that covers the whole
/// app except the status bar, including the tab bar.
///
/// The panel always fills the space (user, 2026-11-28: a panel that resized
/// to its content jumped as the text arrived); the body scrolls under the
/// fixed header, fading at its top and bottom edges.
/// The 44 pt close button is pinned at the panel's top right. It closes from
/// the button, a tap on the scrim, a drag down (past a third of the panel's
/// height, or a fast flick, while the body is at its top) and VoiceOver's
/// escape gesture. Opening, the panel fades in from a light blur and 96%
/// (`RelayModalMetrics.open`) and the scrim fades; closing is the same,
/// quicker. With Reduce Motion, fades only. It is a modal for VoiceOver, and focus moves to the header.
///
/// Apply `.accessibilityHidden` and `.disabled` to what sits behind it.
struct RelayModal<Header: View, Content: View>: View {
    let isPresented: Bool
    let onClose: () -> Void
    /// Pull to refresh on the body, when the modal has something to refresh.
    var refresh: (() async -> Void)?
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    @State private var drag: CGFloat = 0
    @State private var dragArmed = false
    @State private var panelHeight: CGFloat = 1
    @State private var fade = EdgeFade.none
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headerFocused: Bool

    var body: some View {
        ZStack {
            if isPresented {
                scrim.transition(.opacity)
                GeometryReader { proxy in
                    let gaps: CGFloat = RelayModalMetrics.topGap + RelayModalMetrics.bottomGap
                    let room: CGFloat = max(0, proxy.size.height - gaps)
                    panel
                        .frame(maxHeight: room)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.top, RelayModalMetrics.topGap)
                        .padding(.bottom, RelayModalMetrics.bottomGap)
                        .padding(.horizontal, RelayMetrics.screenMargin)
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .transition(reduceMotion ? .opacity : .relaySurface)
            }
        }
        .animation(isPresented ? RelayModalMetrics.open : RelayModalMetrics.close, value: isPresented)
        .onChange(of: isPresented) { _, presented in
            guard presented else { return }
            // The next open starts at rest, not where the last drag left the panel.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                drag = 0
                dragArmed = false
                fade = .none
            }
        }
    }

    /// The scrim's opacity: full while the panel rests, fading as it is dragged away.
    private var scrimOpacity: Double {
        let progress: CGFloat = min(1, drag / max(panelHeight, 1))
        return RelayModalMetrics.scrimOpacity * Double(1 - progress)
    }

    private var scrim: some View {
        Color.black
            .opacity(scrimOpacity)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onClose)
            .accessibilityHidden(true)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.trailing, RelayMetrics.controlHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headerFocused)
            scroller
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) { LucideImage(.x, size: 20) }
                .buttonStyle(.relaySecondary)
                .accessibilityLabel("Close")
                .padding(8)
        }
        .relayGlass(.panel)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        .offset(y: drag)
        .simultaneousGesture(dismissDrag)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
        .onAppear { headerFocused = true }
    }

    private var scroller: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(dragArmed)
        .modifier(OptionalRefresh(refresh: refresh))
        .frame(maxHeight: .infinity)
        .onScrollGeometryChange(for: EdgeFade.self) { geometry in
            let overflow = geometry.contentSize.height - geometry.containerSize.height
            guard overflow > 1 else { return .none }
            let offset = min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0), overflow)
            return EdgeFade(top: min(RelayModalMetrics.edgeFade, offset),
                            bottom: min(RelayModalMetrics.edgeFade, overflow - offset))
        } action: { _, new in
            fade = new
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: fade.top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: fade.bottom)
            }
        }
    }

    /// Drags the panel down from the top of the body. A drag that starts
    /// anywhere else, or upward, is left to the scroll view.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !dragArmed, drag == 0 {
                    dragArmed = fade.top < 0.5 && value.translation.height > 0
                        && abs(value.translation.height) > abs(value.translation.width)
                }
                if dragArmed { drag = max(0, value.translation.height) }
            }
            .onEnded { value in
                guard dragArmed else { return }
                dragArmed = false
                let flicked = value.velocity.height > RelayModalMetrics.flickVelocity
                if drag > panelHeight * RelayModalMetrics.dismissFraction || flicked {
                    onClose()
                } else {
                    withAnimation(RelayMotion.swap) { drag = 0 }
                }
            }
    }
}

/// How much of each edge of the modal's body is faded out.
private struct EdgeFade: Equatable {
    var top: CGFloat
    var bottom: CGFloat
    static let none = EdgeFade(top: 0, bottom: 0)
}

/// `.refreshable` only when there is something to refresh.
private struct OptionalRefresh: ViewModifier {
    let refresh: (() async -> Void)?

    func body(content: Content) -> some View {
        if let refresh {
            content.refreshable { await refresh() }
        } else {
            content
        }
    }
}
