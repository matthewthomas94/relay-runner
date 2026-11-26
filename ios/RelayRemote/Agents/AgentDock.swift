import SwiftUI

/// The dock's controls, so the tutorial (RR-542) can dim the ones a step is
/// not teaching.
enum DockControl: Hashable, CaseIterable {
    case textBox, replay, talk, stop
}

/// The dock from screens 21–25: a text box with Send, then Replay, a wide
/// Talk control and Stop. It sits at the bottom of its container, so as the
/// text box fills it grows upward. While the user talks the text box shows the
/// live transcript and Replay becomes Cancel.
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
    var onSend: () -> Void = {}
    var onTalk: (TalkGesture.Command) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onReplay: () -> Void = {}
    var onStop: () -> Void = {}

    static let maxLines = 6

    var body: some View {
        VStack(spacing: 8) {
            textBox
                .opacity(dimmed.contains(.textBox) ? 0.3 : 1)
            HStack(spacing: 8) {
                Group {
                    if isTalking {
                        Button(action: onCancel) { LucideImage(.x, size: 20) }
                            .buttonStyle(DockSquareButtonStyle())
                            .accessibilityLabel("Cancel")
                    } else {
                        Button(action: onReplay) { LucideImage(.rotateCcw, size: 20) }
                            .buttonStyle(DockSquareButtonStyle())
                            .disabled(!canReplay)
                            .accessibilityLabel("Replay")
                    }
                }
                .opacity(dimmed.contains(.replay) ? 0.3 : 1)
                TalkButton(mode: talkMode, isTalking: isTalking, onCommand: onTalk)
                    .opacity(dimmed.contains(.talk) ? 0.3 : 1)
                Button(action: onStop) { LucideImage(.square, size: 20) }
                    .buttonStyle(DockSquareButtonStyle())
                    .disabled(!canStop)
                    .opacity(dimmed.contains(.stop) ? 0.3 : 1)
                    .accessibilityLabel("Stop")
            }
        }
        .padding(10)
        .background(RelayGlassBackground(glass: .panel,
                                         shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
        .padding(.horizontal, 12)
    }

    private var canSend: Bool {
        !isTalking && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var textBox: some View {
        HStack(alignment: .center, spacing: 8) {
            Group {
                if isTalking {
                    Text(transcript.isEmpty ? placeholder : transcript)
                        .foregroundStyle(transcript.isEmpty ? RelayColor.neutral7 : RelayColor.neutral10)
                        .lineLimit(Self.maxLines)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.vertical, 8)
            Button(action: sendIfPossible) {
                LucideImage(.arrowUp, size: 18)
                    .foregroundStyle(canSend ? RelayColor.neutral10 : RelayColor.neutral7)
                    .frame(width: 36, height: 36)
                    .background(RelayGlassBackground(glass: .selected,
                                                     shape: RoundedRectangle(cornerRadius: 10, style: .continuous)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.trailing, 4)
            .accessibilityLabel("Send")
        }
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RelayColor.neutral1))
    }

    private func sendIfPossible() {
        guard canSend else { return }
        onSend()
    }
}

/// Replay, Cancel and Stop: slim 44 pt glass squares with an outline icon.
struct DockSquareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DockSquareButton(configuration: configuration)
    }
}

private struct DockSquareButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RelayMetrics.buttonRadius, style: .continuous)
        configuration.label
            .foregroundStyle(RelayColor.neutral10)
            .frame(width: RelayMetrics.controlHeight, height: RelayMetrics.controlHeight)
            .background(RelayGlassBackground(glass: configuration.isPressed ? .selected : .control, shape: shape))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The wide Talk control, the screen's one primary button. Hold: pressed while
/// the finger is down. Toggle: one tap starts, it reads as active, and a
/// second tap sends. Its pressed and active state is the plain pressed fill.
struct TalkButton: View {
    let mode: TalkMode
    let isTalking: Bool
    let onCommand: (TalkGesture.Command) -> Void
    @State private var touching = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RelayMetrics.buttonRadius, style: .continuous)
        let active = isTalking || (mode == .hold && touching)
        HStack(spacing: 8) {
            LucideImage(active ? .audioLines : .mic, size: 20)
            Text(label(active: active))
        }
        .relayTextStyle(.control)
        .foregroundStyle(RelayColor.neutral1)
        .frame(maxWidth: .infinity, minHeight: RelayMetrics.controlHeight)
        .background(shape.fill(active ? RelayColor.primaryPressed : RelayColor.neutral10))
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !touching else { return }
                    touching = true
                    onCommand(TalkGesture.touchDown(mode: mode, isTalking: isTalking))
                }
                .onEnded { _ in
                    touching = false
                    onCommand(TalkGesture.touchUp(mode: mode, isTalking: isTalking))
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(active: active))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            // VoiceOver taps toggle in either mode.
            onCommand(isTalking ? .send : .start)
        }
    }

    private func label(active: Bool) -> String {
        guard active else { return mode == .hold ? "Hold to talk" : "Tap to talk" }
        return mode == .hold ? "Release to send" : "Tap to send"
    }
}
