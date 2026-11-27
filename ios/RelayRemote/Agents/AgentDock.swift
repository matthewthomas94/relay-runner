import SwiftUI

/// The dock's controls, so the tutorial (RR-542) can dim the ones a step is
/// not teaching. `talk` is the white button inside the text box.
enum DockControl: Hashable, CaseIterable {
    case textBox, replay, talk, stop
}

/// The dock from screens 21–25 (RR-552): a text box whose white button is
/// both the talk button and Send, then labelled Replay and Stop sharing a row.
/// It sits at the bottom of its container, so as the text box fills it grows
/// upward. While the user talks the text box shows the live transcript and
/// Replay becomes Cancel.
struct AgentDock: View {
    @Binding var text: String
    let placeholder: String
    var talkMode: TalkMode = .hold
    var isTalking = false
    /// The live transcript, shown in the text box while talking.
    var transcript = ""
    var canReplay = true
    var canStop = true
    /// Controls drawn at 30%, as the tutorial dims controls it is not teaching.
    var dimmed: Set<DockControl> = []
    /// Controls that take no touches, so a dimmed control does nothing.
    var inert: Set<DockControl> = []
    /// False when `MainTabView` draws the dock in the tab bar's glass
    /// container, so its glass can melt into the tab bar (`HostedDock`).
    var drawsGlass = true
    var onSend: () -> Void = {}
    var onTalk: (TalkGesture.Command) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onReplay: () -> Void = {}
    var onStop: () -> Void = {}

    /// The text box grows to three lines, then scrolls (user, 2026-11-27).
    static let maxLines = 3
    /// The Figma dock: radius 20, 10 pt padding, 12 pt in from the screen.
    static let cornerRadius: CGFloat = 20
    static let sideInset: CGFloat = 12

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        VStack(spacing: 8) {
            textBox
            HStack(spacing: 8) {
                Group {
                    if isTalking {
                        Button(action: onCancel) { RelayButtonLabel("Cancel", icon: .x) }
                            .transition(.relayControlSwap)
                    } else {
                        Button(action: onReplay) { RelayButtonLabel("Replay", icon: .rotateCcw) }
                            .disabled(!canReplay)
                            .transition(.relayControlSwap)
                    }
                }
                .buttonStyle(RelayButtonStyle(role: .secondary, fullWidth: true))
                .animation(RelayMotion.enter, value: isTalking)
                .opacity(dimmed.contains(.replay) ? 0.3 : 1)
                .allowsHitTesting(!inert.contains(.replay))
                Button(action: onStop) { RelayButtonLabel("Stop", icon: .square) }
                    .buttonStyle(RelayButtonStyle(role: .secondary, fullWidth: true))
                    .disabled(!canStop)
                    .opacity(dimmed.contains(.stop) ? 0.3 : 1)
                    .allowsHitTesting(!inert.contains(.stop))
            }
        }
        .padding(10)
        .background {
            if drawsGlass { RelayGlassBackground(glass: .panel, shape: shape) }
        }
        .animation(RelayMotion.enter, value: dimmed)
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var textBox: some View {
        // The talk button sits in the bottom-right corner, 4 pt in from the
        // edges, so on one line it is centred and as the box grows it stays at
        // the bottom.
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
            .opacity(dimmed.contains(.textBox) ? 0.3 : 1)
            .allowsHitTesting(!inert.contains(.textBox))
            DockTalkButton(mode: talkMode, isTalking: isTalking, hasText: hasText,
                           onCommand: onTalk, onSend: sendIfPossible)
                .opacity(dimmed.contains(.talk) ? 0.3 : 1)
                .allowsHitTesting(!inert.contains(.talk))
                .padding(.trailing, 4)
                .padding(.bottom, 4)
                .padding(.top, 4)
        }
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RelayColor.neutral1))
        .animation(RelayMotion.move, value: isTalking)
    }

    private func sendIfPossible() {
        guard !isTalking, hasText else { return }
        onSend()
    }
}

/// The Agents dock handed up to `MainTabView` (RR-552): the Agents screen
/// keeps its place, and the tab view draws it there in the same
/// `GlassEffectContainer` as the tab bar, so between tabs the dock's glass
/// melts into the tab bar and rises back out of it.
struct HostedDock {
    /// The place the dock takes in the Agents screen.
    let anchor: Anchor<CGRect>
    /// The dock, without its glass.
    let content: AnyView
    /// Talking or not: the one change that resizes the dock in place.
    var isTalking = false
}

struct HostedDockKey: PreferenceKey {
    static let defaultValue: HostedDock? = nil

    static func reduce(value: inout HostedDock?, nextValue: () -> HostedDock?) {
        value = value ?? nextValue()
    }
}

extension EnvironmentValues {
    /// True under `MainTabView`, which draws the Agents dock (`HostedDock`).
    @Entry var hostsDock = false
}

/// The white button in the text box: the talk button and Send in one
/// (RR-552). Empty box: the mic, and hold or tap to talk as the Talk setting
/// says. Talking: the sound wave; release (Hold) or tap (Toggle) sends. With
/// typed text: the arrow, and a tap sends the text. Its pressed and active
/// state is the plain pressed fill; haptics fire straight from the touch.
struct DockTalkButton: View {
    let mode: TalkMode
    let isTalking: Bool
    let hasText: Bool
    let onCommand: (TalkGesture.Command) -> Void
    let onSend: () -> Void
    @State private var touching = false
    /// Whether the press that is down sends typed text rather than talking,
    /// decided when the finger lands so typing mid-press changes nothing.
    @State private var pressSends = false

    static let size: CGFloat = 36

    private enum Face { case mic, wave, send }

    private var face: Face {
        if isTalking || (mode == .hold && touching && !pressSends) { return .wave }
        return hasText ? .send : .mic
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let active = face == .wave
        icon
            .id(face)
            .transition(.relayControlSwap)
            .animation(RelayMotion.enter, value: face)
            .foregroundStyle(RelayColor.neutral1)
            .frame(width: Self.size, height: Self.size)
            .modifier(RelayGlassSurface(glass: active || touching ? .primaryPressed : .primary, shape: shape))
            .contentShape(shape)
            .scaleEffect(touching ? RelayMotion.pressedScale : 1)
            .animation(RelayMotion.press, value: touching)
            .onAppear { RelayHaptics.prepare() }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !touching else { return }
                        RelayHaptics.press()
                        pressSends = hasText && !isTalking
                        touching = true
                        if !pressSends { onCommand(TalkGesture.touchDown(mode: mode, isTalking: isTalking)) }
                    }
                    .onEnded { _ in
                        RelayHaptics.release()
                        touching = false
                        if pressSends {
                            onSend()
                        } else {
                            onCommand(TalkGesture.touchUp(mode: mode, isTalking: isTalking))
                        }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                // VoiceOver taps toggle in either mode, or send typed text.
                if hasText && !isTalking { onSend() } else { onCommand(isTalking ? .send : .start) }
            }
    }

    @ViewBuilder
    private var icon: some View {
        switch face {
        case .mic: LucideImage(.mic, size: 18)
        case .wave: LucideImage(.audioLines, size: 18)
        case .send: LucideImage(.arrowUp, size: 18)
        }
    }

    private var label: String {
        switch face {
        case .send: return "Send"
        case .wave: return mode == .hold ? "Release to send" : "Tap to send"
        case .mic: return mode == .hold ? "Hold to talk" : "Tap to talk"
        }
    }
}
