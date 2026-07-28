import SwiftUI

enum OnboardingTutorialScreen: String, Equatable {
    case intro
    case recording
    case recordingActive
    case playback
    case cancellation
    case workspace
    case sessionRetry

    var showsLoadingIndicator: Bool {
        self == .intro
    }
}

struct OnboardingTutorialPresentation: Equatable {
    let screen: OnboardingTutorialScreen
    let reduceMotion: Bool
    let message: String?
}

enum OnboardingSessionControlsTutorial {
    static let deterministicReply = "Hello, how are you?"

    enum PlaybackCommand: Equatable {
        case play
        case replay
    }

    enum Event: Equatable {
        case recordingStarted
        case speechDetected
        case recordingSent
        case responseReady
        case playbackRequested
        case playbackStarted
        case playbackFinished
        case cancelRequested
        case workspaceToggled
    }

    enum RecordingGate: Equatable {
        case waitingForStart
        case waitingForSpeech
        case waitingForSend
        case waitingForResponse
        case complete
    }

    enum PlaybackGate: Equatable {
        case waitingForPlayback
        case waitingForInitialPlaybackStart
        case waitingForInitialPlaybackEnd
        case waitingForReplayStart
        case waitingForCancel
        case complete
    }

    static func nextRecordingGate(_ gate: RecordingGate, event: Event) -> RecordingGate {
        switch (gate, event) {
        case (.waitingForStart, .recordingStarted):
            return .waitingForSpeech
        case (.waitingForSpeech, .speechDetected):
            return .waitingForSend
        case (.waitingForSend, .recordingSent):
            return .waitingForResponse
        case (.waitingForResponse, .responseReady):
            return .complete
        default:
            return gate
        }
    }

    static func nextPlaybackGate(_ gate: PlaybackGate,
                                 event: Event) -> PlaybackGate {
        switch (gate, event) {
        case (.waitingForPlayback, .playbackRequested):
            return .waitingForInitialPlaybackStart
        case (.waitingForInitialPlaybackStart, .playbackStarted):
            return .waitingForInitialPlaybackEnd
        case (.waitingForInitialPlaybackEnd, .playbackFinished):
            return .waitingForReplayStart
        case (.waitingForReplayStart, .playbackRequested),
             (.waitingForReplayStart, .playbackStarted):
            return .waitingForCancel
        case (.waitingForReplayStart, .cancelRequested):
            return .complete
        case (.waitingForCancel, .cancelRequested):
            return .complete
        default:
            return gate
        }
    }

    static func resumeID(for screen: OnboardingTutorialScreen) -> OnboardingStepID {
        switch screen {
        case .intro:
            return .tutorialIntro
        case .recording:
            return .tutorialRecording
        case .recordingActive:
            return .tutorialRecordingActive
        case .playback:
            return .tutorialPlayback
        case .cancellation:
            return .tutorialCancellation
        case .workspace:
            return .tutorialWorkspace
        case .sessionRetry:
            return .tutorialSessionRetry
        }
    }

    static func screen(for resumeID: OnboardingStepID) -> OnboardingTutorialScreen? {
        switch resumeID {
        case .tutorialIntro:
            return .intro
        case .tutorialRecording:
            return .recording
        case .tutorialRecordingActive:
            return .recordingActive
        case .tutorialPlayback:
            return .playback
        case .tutorialCancellation:
            return .cancellation
        case .tutorialWorkspace:
            return .workspace
        case .tutorialSessionRetry:
            return .sessionRetry
        default:
            return nil
        }
    }
}

struct OnboardingTutorialView: View {
    let presentation: OnboardingTutorialPresentation
    let retryAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: OnboardingPermissionTreatment.promptMinHeight)
        .padding(.horizontal, 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.screen {
        case .intro:
            ZStack {
                OnboardingBlinkingTitle(
                    "Great, now lets learn the basics /",
                    reduceMotion: presentation.reduceMotion
                )
                if presentation.screen.showsLoadingIndicator {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                        .offset(y: 72)
                        .accessibilityLabel("Preparing voice session")
                }
            }
        case .recording:
            HStack(alignment: .center, spacing: 30) {
                tutorialText("Turn")
                OnboardingTutorialKeycap(
                    animation: .capsLock,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("on & say hi /")
            }
        case .recordingActive:
            HStack(alignment: .center, spacing: 30) {
                tutorialText("Now turn")
                OnboardingTutorialKeycap(
                    animation: .capsLock,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("off to send the message /")
            }
        case .playback:
            HStack(alignment: .center, spacing: 26) {
                tutorialText("Wait for a reply then double tap")
                OnboardingTutorialKeycap(
                    animation: .playbackOption,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("to play or replay /")
            }
        case .cancellation:
            HStack(alignment: .center, spacing: 26) {
                tutorialText("Double tap")
                OnboardingTutorialKeycap(
                    animation: .playbackControl,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("to cancel playback /")
            }
        case .workspace:
            HStack(alignment: .center, spacing: 30) {
                tutorialText("Finally, double tap")
                OnboardingTutorialKeycap(
                    animation: .shift,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("to enter & exit your workspace /")
            }
        case .sessionRetry:
            VStack(spacing: 32) {
                OnboardingBlinkingTitle(
                    "Session setup needs attention /",
                    reduceMotion: presentation.reduceMotion
                )
                Text(presentation.message ?? "Relay Runner could not start the configured voice session.")
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: OnboardingPermissionTreatment.supportingMaxWidth)
                OnboardingIntroWhiteActionButton(
                    title: "Retry",
                    accessibilityLabel: "Retry voice session setup",
                    action: retryAction
                )
            }
        }
    }

    private func tutorialText(_ text: String) -> some View {
        OnboardingTutorialInstructionText(
            text: text,
            reduceMotion: presentation.reduceMotion
        )
    }

    private var accessibilityLabel: String {
        switch presentation.screen {
        case .intro:
            return "Great, now lets learn the basics"
        case .recording:
            return "Turn Caps Lock on and say hi"
        case .recordingActive:
            return "Now turn Caps Lock off to send the message"
        case .playback:
            return "Wait for a reply then double tap Option to play or replay"
        case .cancellation:
            return "Double tap Control to cancel playback"
        case .workspace:
            return "Finally, double tap Shift to enter and exit your workspace"
        case .sessionRetry:
            return "Session setup needs attention"
        }
    }
}

enum OnboardingTutorialKeycapKind {
    case capsLock
    case option
    case control
    case shift

    func assetName(capsLightOn: Bool = true) -> String {
        switch self {
        case .capsLock:
            return capsLightOn ? "OnboardingTutorialCapsLockKey" : "OnboardingTutorialCapsLockKeyOff"
        case .option:
            return "OnboardingTutorialOptionKey"
        case .control:
            return "OnboardingTutorialControlKey"
        case .shift:
            return "OnboardingTutorialShiftKey"
        }
    }

    var width: CGFloat {
        switch self {
        case .control:
            return 120
        case .capsLock, .option, .shift:
            return 120
        }
    }

    var height: CGFloat {
        switch self {
        case .capsLock:
            return 82
        case .option:
            return 114
        case .control:
            return 114
        case .shift:
            return 51
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .capsLock:
            return "Caps Lock key"
        case .option:
            return "Option key"
        case .control:
            return "Control key"
        case .shift:
            return "Shift key"
        }
    }

    var isDoubleTap: Bool {
        self != .capsLock
    }
}

enum OnboardingTutorialKeycapAnimation: Equatable {
    case capsLock
    case playbackOption
    case playbackControl
    case shift

    var kind: OnboardingTutorialKeycapKind {
        switch self {
        case .capsLock:
            return .capsLock
        case .playbackOption:
            return .option
        case .playbackControl:
            return .control
        case .shift:
            return .shift
        }
    }

    var cycleDuration: TimeInterval {
        switch self {
        case .capsLock:
            return 1.6
        case .playbackOption, .playbackControl:
            return 2.92
        case .shift:
            return 1.56
        }
    }
}

private struct OnboardingTutorialInstructionText: View {
    let text: String
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            styledText(at: context.date.timeIntervalSinceReferenceDate)
        }
        .font(AppTypography.font(.onboardingHero))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.60)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func styledText(at elapsed: TimeInterval) -> Text {
        guard text.last == "/" else {
            return Text(text).foregroundColor(.white)
        }

        let prefix = String(text.dropLast())
        return Text(prefix).foregroundColor(.white)
            + Text("/").foregroundColor(
                .white.opacity(OnboardingCursorBlink.opacity(at: elapsed, reduceMotion: reduceMotion))
            )
    }
}

struct OnboardingTutorialKeycap: View {
    let animation: OnboardingTutorialKeycapAnimation
    let reduceMotion: Bool
    var maximumSize: CGSize?
    var isDecorative = false

    private var kind: OnboardingTutorialKeycapKind {
        animation.kind
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            keycap(
                phase: OnboardingSessionControlsTutorial.keycapPhase(
                    for: animation,
                    at: context.date.timeIntervalSinceReferenceDate,
                    reduceMotion: reduceMotion
                )
            )
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .accessibilityHidden(isDecorative)
        .accessibilityLabel(kind.accessibilityLabel)
    }

    private func keycap(phase: OnboardingTutorialKeycapPhase) -> some View {
        Image(kind.assetName(capsLightOn: phase.capsLightOn), bundle: RelayRunnerResources.bundle)
                .resizable()
                .renderingMode(.original)
                .frame(width: displaySize.width, height: displaySize.height)
                .accessibilityHidden(true)
        .scaleEffect(phase.scale)
        .animation(nil, value: phase.scale)
    }

    private var displaySize: CGSize {
        guard let maximumSize else {
            return CGSize(width: kind.width, height: kind.height)
        }

        let scale = min(maximumSize.width / kind.width, maximumSize.height / kind.height)
        return CGSize(width: kind.width * scale, height: kind.height * scale)
    }
}

struct OnboardingTutorialKeycapPhase: Equatable {
    let scale: CGFloat
    let capsLightOn: Bool
}

extension OnboardingSessionControlsTutorial {
    static func keycapPhase(for animation: OnboardingTutorialKeycapAnimation,
                            at time: TimeInterval,
                            reduceMotion: Bool = false) -> OnboardingTutorialKeycapPhase {
        if reduceMotion {
            return OnboardingTutorialKeycapPhase(
                scale: 0.97,
                capsLightOn: animation.kind == .capsLock
            )
        }

        switch animation {
        case .capsLock:
            return capsLockPhase(at: time, cycleDuration: animation.cycleDuration)
        case .playbackOption:
            return doubleTapPhase(
                at: time,
                cycleDuration: animation.cycleDuration,
                tapStarts: [0.0, 0.22]
            )
        case .playbackControl:
            return doubleTapPhase(
                at: time,
                cycleDuration: animation.cycleDuration,
                tapStarts: [0.0, 0.22]
            )
        case .shift:
            return doubleTapPhase(
                at: time,
                cycleDuration: animation.cycleDuration,
                tapStarts: [0.0, 0.22]
            )
        }
    }

    static func tutorialCursorOpacity(at elapsed: TimeInterval,
                                      reduceMotion: Bool = false) -> CGFloat {
        OnboardingCursorBlink.opacity(at: elapsed, reduceMotion: reduceMotion)
    }

    private static func capsLockPhase(at time: TimeInterval,
                                      cycleDuration: TimeInterval) -> OnboardingTutorialKeycapPhase {
        let clampedTime = max(0, time)
        let cycle = clampedTime.truncatingRemainder(dividingBy: cycleDuration)
        let completedCycles = Int(floor(clampedTime / cycleDuration))
        let lightStartsOn = !completedCycles.isMultiple(of: 2)
        let scale = easedScale(at: cycle, tapStarts: [0.0])
        let capsLightOn = cycle >= 0.14 ? !lightStartsOn : lightStartsOn
        return OnboardingTutorialKeycapPhase(scale: scale, capsLightOn: capsLightOn)
    }

    private static func doubleTapPhase(at time: TimeInterval,
                                       cycleDuration: TimeInterval,
                                       tapStarts: [TimeInterval]) -> OnboardingTutorialKeycapPhase {
        let cycle = max(0, time).truncatingRemainder(dividingBy: cycleDuration)
        return OnboardingTutorialKeycapPhase(
            scale: easedScale(at: cycle, tapStarts: tapStarts),
            capsLightOn: false
        )
    }

    private static func easedScale(at cycle: TimeInterval,
                                   tapStarts: [TimeInterval]) -> CGFloat {
        for tapStart in tapStarts {
            let pressEnd = tapStart + 0.14
            let releaseEnd = pressEnd + 0.18
            guard cycle >= tapStart, cycle < releaseEnd else { continue }

            if cycle < pressEnd {
                let progress = (cycle - tapStart) / 0.14
                return scale(from: 1.0, to: 0.94, progress: progress)
            }

            let progress = (cycle - pressEnd) / 0.18
            return scale(from: 0.94, to: 1.0, progress: progress)
        }

        return 1.0
    }

    private static func scale(from start: CGFloat,
                              to end: CGFloat,
                              progress: TimeInterval) -> CGFloat {
        let eased = CGFloat(OnboardingIntroTimeline.easeInOut(progress))
        return start + (end - start) * eased
    }
}
