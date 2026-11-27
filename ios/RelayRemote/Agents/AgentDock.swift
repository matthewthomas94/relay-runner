import SwiftUI

/// The dock's controls, so the tutorial (RR-542) can dim the ones a step is
/// not teaching. `textBox` is the text box and its Send button; `replay` is
/// the playback control on the left (Play, Stop, Replay, or Cancel while
/// talking); `talk` is the white talk button on the right.
enum DockControl: Hashable, CaseIterable {
    case textBox, replay, talk
}

/// The dock from screens 21–25 (Figma Final, user 2026-11-27): one glass
/// message panel holding the agent tabs, a text box whose Send button is the
/// old secondary up arrow, then a row of two buttons sharing its width. On
/// the left one playback control: Play while the selected agent has a reply
/// not played yet (RR-554, shimmering with the desktop's attention dots),
/// Stop while a reply plays, otherwise Replay, and Cancel while the user
/// talks. On the right the white talk button: Hold to talk, then Release to
/// send while talking (Tap to talk and Tap to send in Toggle mode). The
/// tutorial's dock has no agent tabs. It sits at the bottom of its container,
/// so as the text box fills it grows upward.
struct AgentDock: View {
    @Binding var text: String
    let placeholder: String
    /// The agent tabs, the panel's top row (Figma Final 21–25); nil in the tutorial.
    var tabs: AgentTabStrip?
    var talkMode: TalkMode = .hold
    var isTalking = false
    /// The live transcript, shown in the text box while talking.
    var transcript = ""
    var canReplay = true
    /// The selected agent has a reply not played yet: the control reads Play.
    var canPlay = false
    /// A reply is playing: the control reads Stop.
    var isPlaying = false
    var canStop = true
    /// Controls drawn at 30%, as the tutorial dims controls it is not teaching.
    var dimmed: Set<DockControl> = []
    /// Controls that take no touches, so a dimmed control does nothing.
    var inert: Set<DockControl> = []
    /// False when `MainTabView` draws the dock in the tab bar's glass
    /// container, so its glass can melt into the tab bar (`HostedPanel`).
    var drawsGlass = true
    var onSend: () -> Void = {}
    var onTalk: (TalkGesture.Command) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onReplay: () -> Void = {}
    var onPlay: () -> Void = {}
    var onStop: () -> Void = {}

    /// The text box grows to three lines, then scrolls (user, 2026-11-27).
    static let maxLines = 3
    /// The Figma dock: radius 20, 10 pt padding, 12 pt in from the screen.
    static let cornerRadius: CGFloat = 20
    static let padding: CGFloat = 10
    static let sideInset: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(spacing: 8) {
            if let tabs {
                // The strip scrolls to the panel's edges, under its padding.
                tabs
                    .contentMargins(.horizontal, Self.padding, for: .scrollContent)
                    .padding(.horizontal, -Self.padding)
            }
            textBox
            HStack(spacing: 8) {
                // One button whose label swaps: the old label leaves before
                // the new one arrives, and the button's surface stays put.
                Button(action: replayAction) {
                    ZStack {
                        replayLabel
                            .id(replayFace)
                            .transition(.relayControlSwap)
                    }
                }
                .disabled(!replayEnabled)
                .buttonStyle(RelayButtonStyle(role: .secondary, fullWidth: true))
                .background {
                    // A reply waiting to be played shimmers, as an agent
                    // wanting attention does on the Mac.
                    if replayFace == .play {
                        FluxDots()
                            .clipShape(RoundedRectangle(cornerRadius: RelayMetrics.buttonRadius, style: .continuous))
                            .transition(.opacity)
                    }
                }
                .animation(RelayMotion.enter, value: replayFace)
                .opacity(dimmed.contains(.replay) ? 0.3 : 1)
                .allowsHitTesting(!inert.contains(.replay))
                DockTalkButton(mode: talkMode, isTalking: isTalking, onCommand: onTalk)
                    .opacity(dimmed.contains(.talk) ? 0.3 : 1)
                    .allowsHitTesting(!inert.contains(.talk))
            }
        }
        .padding(Self.padding)
        .background {
            if drawsGlass { RelayGlassBackground(glass: .panel, shape: shape) }
        }
        .clipShape(shape)
        .animation(RelayMotion.enter, value: dimmed)
    }

    enum ReplayFace { case cancel, stop, play, replay }

    @ViewBuilder
    private var replayLabel: some View {
        switch replayFace {
        case .cancel: RelayButtonLabel("Cancel", icon: .x)
        case .stop: RelayButtonLabel("Stop", icon: .square)
        case .play: RelayButtonLabel("Play", icon: .play)
        case .replay: RelayButtonLabel("Replay", icon: .rotateCcw)
        }
    }

    private var replayEnabled: Bool {
        switch replayFace {
        case .cancel, .play: return true
        case .stop: return canStop
        case .replay: return canReplay
        }
    }

    private func replayAction() {
        switch replayFace {
        case .cancel: onCancel()
        case .stop: onStop()
        case .play: onPlay()
        case .replay: onReplay()
        }
    }

    /// What the playback control reads: Cancel while talking, Stop while a
    /// reply plays, Play while a reply waits to be played, otherwise Replay.
    var replayFace: ReplayFace {
        if isTalking { return .cancel }
        if isPlaying { return .stop }
        return canPlay ? .play : .replay
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool { hasText && !isTalking }

    private var textBox: some View {
        // Send sits in the bottom-right corner, 4 pt in from the edges, so on
        // one line it is centred and as the box grows it stays at the bottom.
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if isTalking {
                    // The newest words stay in view: the transcript keeps its
                    // last three lines.
                    Text(transcript.isEmpty ? placeholder : transcript)
                        .foregroundStyle(transcript.isEmpty ? RelayColor.neutral7 : RelayColor.neutral10)
                        .lineLimit(Self.maxLines)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                        .animation(RelayMotion.enter, value: transcript)
                } else {
                    TextField("", text: $text,
                              prompt: Text(placeholder).foregroundStyle(RelayColor.neutral7), axis: .vertical)
                    .lineLimit(1...Self.maxLines)
                    .foregroundStyle(RelayColor.neutral10)
                    .tint(RelayColor.neutral10)
                    .submitLabel(.send)
                    .onSubmit(sendIfPossible)
                }
            }
            .relayTextStyle(.body)
            .padding(.leading, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44, alignment: .leading)
            // The old secondary Send: grey until there is text to send.
            Button(action: sendIfPossible) {
                LucideImage(.arrowUp, size: 18)
                    .foregroundStyle(canSend ? RelayColor.neutral10 : RelayColor.neutral7)
                    .frame(width: 36, height: 36)
                    .background(RelayGlassBackground(glass: .selected,
                                                     shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
            }
            .buttonStyle(.relayPlain)
            .disabled(!canSend)
            .animation(RelayMotion.enter, value: canSend)
            .padding(.trailing, 4)
            .padding(.bottom, 4)
            .padding(.top, 4)
            .accessibilityLabel("Send")
        }
        .frame(minHeight: 44)
        .modifier(FieldSurface())
        .opacity(dimmed.contains(.textBox) ? 0.3 : 1)
        .allowsHitTesting(!inert.contains(.textBox))
        .animation(RelayMotion.move, value: isTalking)
    }

    private func sendIfPossible() {
        guard !isTalking, hasText else { return }
        onSend()
    }
}

/// The white talk button on the dock's right (Figma Final 21–25, user
/// 2026-11-27): the mic and Hold to talk, then the sound wave and Release to
/// send while talking (Tap to talk and Tap to send in Toggle mode). Hold or
/// tap follows the Talk setting. Its pressed and active state is the plain
/// pressed fill; haptics fire straight from the touch.
struct DockTalkButton: View {
    let mode: TalkMode
    let isTalking: Bool
    let onCommand: (TalkGesture.Command) -> Void
    @State private var touching = false

    private enum Face { case talk, send }

    private var face: Face {
        isTalking || (mode == .hold && touching) ? .send : .talk
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RelayMetrics.buttonRadius, style: .continuous)
        // The label swaps in its own slot, the old one gone before the new arrives.
        ZStack {
            label
                .id(face)
                .transition(.relayControlSwap)
        }
            .animation(RelayMotion.enter, value: face)
            .relayTextStyle(.control)
            .foregroundStyle(RelayColor.neutral1)
            // "Release to send" stays on one line in half the row.
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: RelayMetrics.controlHeight)
            .modifier(RelayGlassSurface(glass: touching ? .primaryPressed : .primary, shape: shape))
            .contentShape(shape)
            .scaleEffect(touching ? RelayMotion.pressedScale : 1)
            .animation(RelayMotion.press, value: touching)
            .onAppear { RelayHaptics.prepare() }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !touching else { return }
                        RelayHaptics.press()
                        touching = true
                        onCommand(TalkGesture.touchDown(mode: mode, isTalking: isTalking))
                    }
                    .onEnded { _ in
                        RelayHaptics.release()
                        touching = false
                        onCommand(TalkGesture.touchUp(mode: mode, isTalking: isTalking))
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            // VoiceOver taps toggle in either mode.
            .accessibilityAction { onCommand(isTalking ? .send : .start) }
    }

    private var label: some View {
        RelayButtonLabel(title, icon: face == .send ? .audioLines : .mic)
    }

    private var title: String {
        switch face {
        case .send: return mode == .hold ? "Release to send" : "Tap to send"
        case .talk: return mode == .hold ? "Hold to talk" : "Tap to talk"
        }
    }
}
