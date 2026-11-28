import SwiftUI

/// The dock's controls, so the tutorial (RR-542) can dim the ones a step is
/// not teaching. `textBox` is the text box and its Send button; `replay` is
/// the playback control on the left (Play, Stop, Replay, or Cancel while
/// talking); `talk` is the white talk button on the right.
enum DockControl: Hashable, CaseIterable {
    case textBox, replay, talk
}

/// A file or photo picked to send with the next message (user, 2026-11-28).
/// It uploads to the Mac as soon as it is picked; `path` is where the Mac
/// saved it.
struct DockAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    /// A small thumbnail when the file is an image.
    let preview: UIImage?
    var progress: Double = 0
    var path: String?
    /// Why it could not be sent; it stays in the box until removed.
    var failure: String?

    var isUploading: Bool { path == nil && failure == nil }
}

/// Where the attach button picks from.
enum AttachSource { case photos, files }

/// The dock from screens 21–25 (Figma Final, user 2026-11-27): one glass
/// message panel holding the agent tabs, a text box whose Send button is the
/// old secondary up arrow, then a row of two buttons sharing its width. On
/// the left one playback control: Play while the selected agent has a reply
/// not played yet (RR-554),
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
    /// A replay or reply has not started playing yet: the control reads
    /// "Preparing message", as on the desktop, and stops it.
    var isPreparing = false
    var canStop = true
    /// False while the agent is starting up: the text box, Send and the talk
    /// button are disabled, so nothing is sent by text or voice until it is
    /// ready (user, 2026-11-28).
    var canMessage = true
    /// Controls drawn at 30%, as the tutorial dims controls it is not teaching.
    var dimmed: Set<DockControl> = []
    /// Controls that take no touches, so a dimmed control does nothing.
    var inert: Set<DockControl> = []
    /// False when `MainTabView` draws the dock in the tab bar's glass
    /// container, so its glass can melt into the tab bar (`HostedPanel`).
    var drawsGlass = true
    /// Files picked for the next message, shown above the text.
    var attachments: [DockAttachment] = []
    var onAttach: (AttachSource) -> Void = { _ in }
    var onRemoveAttachment: (DockAttachment.ID) -> Void = { _ in }
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
    static let sideInset = RelayMetrics.barMargin

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
                            .transition(.relayDockSwap)
                    }
                }
                .disabled(!replayEnabled)
                .buttonStyle(RelayButtonStyle(role: .secondary, fullWidth: true))
                // The same beam as the reply it will play, so the two read
                // as one (user, 2026-11-28).
                .playbackBeam(active: replayFace == .play, cornerRadius: RelayMetrics.buttonRadius)
                .animation(RelayMotion.dockSwap, value: replayFace)
                .opacity(dimmed.contains(.replay) ? 0.3 : 1)
                .allowsHitTesting(!inert.contains(.replay))
                DockTalkButton(mode: talkMode, isTalking: isTalking, onCommand: onTalk)
                    .opacity(dimmed.contains(.talk) || !canMessage ? 0.3 : 1)
                    .allowsHitTesting(!inert.contains(.talk) && canMessage)
                    .disabled(!canMessage)
                    .animation(RelayMotion.enter, value: canMessage)
            }
        }
        .padding(Self.padding)
        .background {
            if drawsGlass { RelayGlassBackground(glass: .panel, shape: shape) }
        }
        .clipShape(shape)
        .animation(RelayMotion.enter, value: dimmed)
    }

    enum ReplayFace { case cancel, preparing, stop, play, replay }

    @ViewBuilder
    private var replayLabel: some View {
        switch replayFace {
        case .cancel: Self.fitting("Cancel message", icon: .x)
        // No stop square here: only Stop message carries it (user, 2026-11-28).
        case .preparing: Self.fitting("Preparing message", icon: nil)
        case .stop: Self.fitting("Stop message", icon: .square)
        case .play:
            // As much of "Play new message" as fits half the row.
            ViewThatFits(in: .horizontal) {
                RelayButtonLabel("Play new message", icon: .play)
                RelayButtonLabel("Play message", icon: .play)
                RelayButtonLabel("Play", icon: .play)
            }
            .lineLimit(1)
        case .replay: Self.fitting("Replay message", icon: .rotateCcw)
        }
    }

    /// The full label (user, 2026-11-27), its text shrinking a little where
    /// half the row is narrow.
    private static func fitting(_ title: String, icon: LucideIcon?) -> some View {
        RelayButtonLabel(title, icon: icon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var replayEnabled: Bool {
        switch replayFace {
        case .cancel, .play: return true
        case .stop, .preparing: return canStop
        case .replay: return canReplay
        }
    }

    private func replayAction() {
        switch replayFace {
        case .cancel: onCancel()
        case .stop, .preparing: onStop()
        case .play: onPlay()
        case .replay: onReplay()
        }
    }

    /// What the playback control reads: Cancel while talking, Preparing until
    /// a replay or reply starts, Stop while one plays, Play while a reply
    /// waits to be played, otherwise Replay.
    var replayFace: ReplayFace {
        if isTalking { return .cancel }
        if isPreparing { return .preparing }
        if isPlaying { return .stop }
        return canPlay ? .play : .replay
    }

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        let hasFiles = attachments.contains { $0.path != nil }
        let uploading = attachments.contains(where: \.isUploading)
        return (hasText || hasFiles) && !uploading && !isTalking && canMessage
    }

    /// With nothing typed, said or picked, Send is the attach button; it
    /// turns back into the up arrow as soon as there is something to send
    /// (user, 2026-11-28).
    private var showsAttach: Bool {
        !hasText && attachments.isEmpty && !showsTranscript
    }

    private var textBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment, fill: Self.sendFill) {
                                onRemoveAttachment(attachment.id)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
                .transition(.opacity)
            }
            textRow
        }
        .animation(RelayMotion.dockSwap, value: attachments.map(\.id))
        .frame(minHeight: 44)
        // The box's edge is the Send button's colour (user, 2026-11-28).
        .modifier(FieldSurface(stroke: Self.sendFill))
        .opacity(dimmed.contains(.textBox) || !canMessage ? 0.3 : 1)
        .allowsHitTesting(!inert.contains(.textBox) && canMessage)
        .disabled(!canMessage)
        .animation(RelayMotion.enter, value: canMessage)
        .animation(RelayMotion.move, value: showsTranscript)
    }

    private var textRow: some View {
        // Send sits in the bottom-right corner, 4 pt in from the edges, so on
        // one line it is centred and as the box grows it stays at the bottom.
        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if showsTranscript {
                    // The newest words stay in view: the transcript keeps its
                    // last three lines.
                    Text(transcript.isEmpty ? placeholder : transcript)
                        .foregroundStyle(transcript.isEmpty ? RelayColor.neutral7 : RelayColor.neutral10)
                        .lineLimit(Self.maxLines)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // No crossfade: the words move with the box as it grows
                        // a line; crossfaded, the old lines and the new showed
                        // a line apart (user, 2026-11-28).
                        .contentTransition(.identity)
                        .animation(RelayMotion.move, value: transcript)
                } else {
                    TextField("", text: $text,
                              prompt: Text(placeholder).foregroundStyle(RelayColor.neutral7), axis: .vertical)
                    .lineLimit(1...Self.maxLines)
                    .foregroundStyle(RelayColor.neutral10)
                    .tint(RelayColor.neutral10)
                    .submitLabel(.send)
                    .onSubmit(sendIfPossible)
                    // A field that grows types Return as a new line and never
                    // submits, so the keyboard's Send key sends (user, 2026-11-28).
                    .onChange(of: text) { old, new in
                        guard new.count == old.count + 1,
                              new.filter({ $0 == "\n" }).count > old.filter({ $0 == "\n" }).count else { return }
                        text = old
                        sendIfPossible()
                    }
                }
            }
            .relayTextStyle(.body)
            .padding(.leading, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44, alignment: .leading)
            // The old secondary Send: grey until there is text to send, then
            // the selected fill with the glass's lit rim, as the selected
            // tabs (user, 2026-11-28). With nothing to send it attaches.
            ZStack {
                if showsAttach {
                    Menu {
                        Button { onAttach(.photos) } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                        Button { onAttach(.files) } label: { Label("Choose File", systemImage: "folder") }
                    } label: {
                        sendFace(.paperclip, lit: false, iconColor: RelayColor.neutral10)
                    }
                    .accessibilityLabel("Attach a photo or file")
                    .transition(.relayDockSwap)
                } else {
                    Button(action: sendIfPossible) {
                        sendFace(.arrowUp, lit: canSend, iconColor: canSend ? RelayColor.neutral10 : RelayColor.neutral7)
                    }
                    .buttonStyle(.relayPlain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                    .transition(.relayDockSwap)
                }
            }
            .animation(RelayMotion.dockSwap, value: canSend)
            .animation(RelayMotion.dockSwap, value: showsAttach)
            .padding(.trailing, 4)
            .padding(.bottom, 4)
            .padding(.top, 4)
        }
    }

    private func sendFace(_ icon: LucideIcon, lit: Bool, iconColor: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return LucideImage(icon, size: 18)
            .foregroundStyle(iconColor)
            .frame(width: 36, height: 36)
            .background {
                if lit {
                    shape.fill(RelayGlass.selected.tint)
                        .overlay(RelayGlassRim(shape: shape, light: RelayGlass.selected.rimLight))
                } else {
                    shape.fill(Self.sendFill)
                }
            }
            .contentShape(shape)
    }

    /// The transcript stays in the text box after the talk button is released
    /// until the message is sent, so the box shrinks once, as the message
    /// lands in the chat, rather than shrinking and then the chat jumping
    /// when the message arrives (user, 2026-11-28).
    private var showsTranscript: Bool { isTalking || !transcript.isEmpty }

    /// The Send button's fill and the text box's edge: #212529 at 65%, as
    /// in the Figma dock.
    static let sendFill = RelayColor.neutral4.opacity(0.65)

    private func sendIfPossible() {
        guard canSend else { return }
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
    /// What the tap just asked for, shown at once instead of waiting for the
    /// voice layer to open or close the microphone (user, 2026-11-27: the
    /// button was slow to respond). Cleared when the voice layer catches up.
    @State private var expected: Bool?

    private enum Face { case talk, send }

    private var face: Face {
        (expected ?? isTalking) || (mode == .hold && touching) ? .send : .talk
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RelayMetrics.buttonRadius, style: .continuous)
        // The label swaps in its own slot, the old one gone before the new arrives.
        ZStack {
            label
                .id(face)
                .transition(.relayDockSwap)
        }
            .animation(RelayMotion.dockSwap, value: face)
            .relayTextStyle(.control)
            .foregroundStyle(RelayColor.neutral10)
            // "Release to send" stays on one line in half the row.
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: RelayMetrics.controlHeight)
            // A secondary glass button, like Play beside it (user, 2026-11-28).
            .modifier(RelayGlassSurface(glass: touching ? .selected : .control, shape: shape))
            // An orange beam runs round it while it reads Tap (or Release) to send.
            .listeningBeam(active: face == .send, cornerRadius: RelayMetrics.buttonRadius)
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
                        let command = TalkGesture.touchUp(mode: mode, isTalking: isTalking)
                        if command != .none { expect(command == .start) }
                        onCommand(command)
                    }
            )
            .onChange(of: isTalking) { expected = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            // VoiceOver taps toggle in either mode.
            .accessibilityAction { onCommand(isTalking ? .send : .start) }
    }

    /// Shows `talking` until the voice layer agrees, or for a second and a
    /// half if it never does (the microphone refused, say).
    private func expect(_ talking: Bool) {
        expected = talking
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if expected == talking { expected = nil }
        }
    }

    @ViewBuilder
    private var label: some View {
        if face == .send {
            // The sound wave moves while the user talks.
            HStack(spacing: 8) {
                TalkingWave(size: 20)
                Text(title)
            }
            .accessibilityElement(children: .combine)
        } else {
            RelayButtonLabel(title, icon: .mic)
        }
    }

    private var title: String {
        switch face {
        case .send: return mode == .hold ? "Release to send" : "Tap to send"
        case .talk: return mode == .hold ? "Hold to talk" : "Tap to talk"
        }
    }
}

/// Lucide's `audio-lines`, its six bars moving with the user's voice
/// (`MicLevelMeter`), as libraries.dev's Voice maps its bands: the middle
/// pair follows the lows, the next pair the mids and the outer pair the
/// highs. A slight shimmer keeps the bars apart; silence leaves them low.
/// Reduce Motion, or no microphone, holds the icon still.
struct TalkingWave: View {
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.micLevel) private var meter
    /// Quick to rise and fall, so the bars keep up with syllables.
    @State private var envelope = VoiceEnvelope(attack: 0.05, release: 0.18)

    /// Each bar's resting height in Lucide's 24 pt grid, centred on y = 12.
    private static let bars: [CGFloat] = [3, 11, 18, 7, 13, 3]
    /// Which band each bar follows: highs, mids, lows, lows, mids, highs.
    private static let bandOfBar = [2, 1, 0, 0, 1, 2]

    var body: some View {
        let still = reduceMotion || meter == nil
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: still)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let voice = still ? nil : envelope.follow(meter?.current ?? .silent, at: time)
            Canvas { context, canvas in
                let scale = canvas.width / 24
                for (index, rest) in Self.bars.enumerated() {
                    var height = rest
                    if let voice {
                        let band = CGFloat(voice.bands[Self.bandOfBar[index]])
                        let shimmer = 0.85 + 0.15 * CGFloat(sin(time * 9 + Double(index) * 1.7))
                        height = 3 + 17 * band * shimmer
                    }
                    let x = (2 + CGFloat(index) * 4) * scale
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: (12 - height / 2) * scale))
                    path.addLine(to: CGPoint(x: x, y: (12 + height / 2) * scale))
                    context.stroke(path, with: .foreground,
                                   style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A picked file in the text box: its thumbnail or a file icon, its name,
/// a ring while it uploads or a warning if it could not, and a remove button.
private struct AttachmentChip: View {
    let attachment: DockAttachment
    let fill: Color
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let preview = attachment.preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    LucideImage(.file, size: 16).foregroundStyle(RelayColor.neutral7)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(attachment.name)
                .relayTextStyle(.caption)
                .foregroundStyle(attachment.failure == nil ? RelayColor.neutral10 : RelayColor.neutral7)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
            if attachment.isUploading {
                Circle()
                    .trim(from: 0, to: max(0.05, attachment.progress))
                    .stroke(RelayColor.neutral10, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .background(Circle().stroke(RelayColor.neutral7.opacity(0.4), lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .animation(RelayMotion.move, value: attachment.progress)
            } else if attachment.failure != nil {
                LucideImage(.triangleExclamationPoint, size: 14).foregroundStyle(RelayColor.neutral7)
            }
            Button(action: remove) {
                LucideImage(.x, size: 14)
                    .foregroundStyle(RelayColor.neutral7)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.relayPlain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
        .accessibilityElement(children: .combine)
        .accessibilityValue(attachment.failure ?? (attachment.isUploading ? "Uploading" : "Ready"))
    }
}
