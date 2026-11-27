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

    /// Opening: the panel grows out of the tapped card from 90% and a blur,
    /// settling on a soft spring (the Mac's large-surface entrance, its
    /// bounce lowered for a panel this size).
    static let open = Animation.spring(duration: 0.42, bounce: 0.16)
    /// Closing is quicker than opening: the user is done with it.
    static let close = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
    /// How small and blurred the panel is when it is not open.
    static let hiddenScale: CGFloat = 0.9
    static let hiddenBlur: CGFloat = 8
    /// While dragged down the panel shrinks towards this, so it reads as
    /// being lifted away rather than slid.
    static let draggedScale: CGFloat = 0.92
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
/// escape gesture. Opening, the panel grows out of the card it opened from,
/// from 90% and a blur, on a soft spring; closing, it shrinks back into it,
/// quicker. Dragged down it shrinks a little as it goes, and let go past the
/// threshold it carries on down at the finger's speed and fades. With Reduce
/// Motion, fades only.
///
/// Apply `.accessibilityHidden` and `.disabled` to what sits behind it.
struct RelayModal<Header: View, Content: View>: View {
    let isPresented: Bool
    /// What it opened from (global coordinates): it grows out of there and
    /// shrinks back into it. Nil: the middle of the screen.
    var origin: CGRect?
    let onClose: () -> Void
    /// Pull to refresh on the body, when the modal has something to refresh.
    var refresh: (() async -> Void)?
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    @State private var drag: CGFloat = 0
    @State private var dragArmed = false
    @State private var panelHeight: CGFloat = 1
    @State private var fade = EdgeFade.none
    /// Let go past the threshold: it carries on down and fades.
    @State private var flung = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headerFocused: Bool

    var body: some View {
        GeometryReader { screen in
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
                .transition(reduceMotion ? .opacity
                            : flung ? .opacity.animation(.easeOut(duration: 0.22))
                            : .modifier(active: ModalPresence(hidden: true, anchor: anchor(in: screen)),
                                        identity: ModalPresence(hidden: false, anchor: anchor(in: screen))))
            }
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
                flung = false
                fade = .none
            }
        }
    }

    /// The scrim's opacity: full while the panel rests, fading as it is dragged away.
    private var scrimOpacity: Double {
        RelayModalMetrics.scrimOpacity * Double(1 - dragProgress)
    }

    /// How far the panel has been dragged towards closing, 0 to 1.
    private var dragProgress: CGFloat { min(1, drag / max(panelHeight, 1)) }

    /// The point the panel grows from and shrinks into: the tapped card's
    /// middle, or the screen's.
    private func anchor(in screen: GeometryProxy) -> UnitPoint {
        guard let origin else { return .center }
        let frame = screen.frame(in: .global)
        guard frame.width > 0, frame.height > 0 else { return .center }
        return UnitPoint(x: min(max((origin.midX - frame.minX) / frame.width, 0), 1),
                         y: min(max((origin.midY - frame.minY) / frame.height, 0), 1))
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
        .scaleEffect(reduceMotion ? 1 : 1 - (1 - RelayModalMetrics.draggedScale) * dragProgress, anchor: .top)
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
                    // Carry on down with the finger's speed and fade, rather
                    // than stopping and shrinking away (user, 2026-11-28).
                    flung = true
                    let distance = max(panelHeight * 1.2 - drag, 1)
                    let speed = max(value.velocity.height, 0) / distance
                    withAnimation(.interpolatingSpring(duration: 0.4, bounce: 0, initialVelocity: speed)) {
                        drag = panelHeight * 1.2
                    }
                    // A frame later, so the panel leaves with the fade
                    // set above rather than its opening transition.
                    DispatchQueue.main.async { onClose() }
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { drag = 0 }
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

/// The modal's panel when it is not open: smaller, blurred and faded,
/// scaled about the card it opened from.
private struct ModalPresence: ViewModifier {
    let hidden: Bool
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? RelayModalMetrics.hiddenBlur : 0)
            .scaleEffect(hidden ? RelayModalMetrics.hiddenScale : 1, anchor: anchor)
    }
}
