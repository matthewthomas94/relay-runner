import SwiftUI

enum OnboardingTutorialScreen: String, Equatable {
    case intro
    case recording
    case playback
    case workspace
    case sessionRetry
}

struct OnboardingTutorialPresentation: Equatable {
    let screen: OnboardingTutorialScreen
    let reduceMotion: Bool
    let message: String?
}

enum OnboardingSessionControlsTutorial {
    enum Event: Equatable {
        case recordingStarted
        case speechDetected
        case recordingSent
        case playbackRequested
        case cancelRequested
        case workspaceToggled
    }

    enum RecordingGate: Equatable {
        case waitingForStart
        case waitingForSpeech
        case waitingForSend
        case complete
    }

    enum PlaybackGate: Equatable {
        case waitingForPlayback
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
            return .complete
        default:
            return gate
        }
    }

    static func nextPlaybackGate(_ gate: PlaybackGate, event: Event) -> PlaybackGate {
        switch (gate, event) {
        case (.waitingForPlayback, .playbackRequested):
            return .waitingForCancel
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
        case .playback:
            return .tutorialPlayback
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
        case .tutorialPlayback:
            return .playback
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
            OnboardingBlinkingTitle("Great, now lets learn the basics /")
        case .recording:
            HStack(alignment: .center, spacing: 30) {
                tutorialText("turn")
                OnboardingTutorialKeycap(
                    kind: .capsLock,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("on & say hi, turn it off to send /")
            }
        case .playback:
            HStack(alignment: .center, spacing: 26) {
                tutorialText("Double tap")
                OnboardingTutorialKeycap(
                    kind: .option,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("to play/ replay, double tap")
                OnboardingTutorialKeycap(
                    kind: .control,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("to cancel /")
            }
        case .workspace:
            HStack(alignment: .center, spacing: 30) {
                tutorialText("You're all set, double tap")
                OnboardingTutorialKeycap(
                    kind: .shift,
                    reduceMotion: presentation.reduceMotion
                )
                tutorialText("to enter/ exit your workspace /")
            }
        case .sessionRetry:
            VStack(spacing: 32) {
                OnboardingBlinkingTitle("Session setup needs attention /")
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
        Text(text)
            .font(AppTypography.font(.onboardingHero))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.60)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityLabel: String {
        switch presentation.screen {
        case .intro:
            return "Great, now lets learn the basics"
        case .recording:
            return "Turn Caps Lock on and say hi, turn it off to send"
        case .playback:
            return "Double tap Option to play or replay, double tap Control to cancel"
        case .workspace:
            return "You're all set, double tap Shift to enter or exit your workspace"
        case .sessionRetry:
            return "Session setup needs attention"
        }
    }
}

private enum OnboardingTutorialKeycapKind {
    case capsLock
    case option
    case control
    case shift

    var width: CGFloat {
        switch self {
        case .capsLock, .option, .control:
            return 120
        case .shift:
            return 120
        }
    }

    var height: CGFloat {
        switch self {
        case .shift:
            return 52
        default:
            return 84
        }
    }

    var primaryLabel: String {
        switch self {
        case .capsLock:
            return "caps lock"
        case .option:
            return "Alt"
        case .control:
            return "Control"
        case .shift:
            return "shift"
        }
    }

    var secondaryLabel: String? {
        switch self {
        case .option:
            return "Option"
        default:
            return nil
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

private struct OnboardingTutorialKeycap: View {
    let kind: OnboardingTutorialKeycapKind
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let phase = reduceMotion
                ? OnboardingTutorialKeycapPhase(scale: 0.97, capsLightOn: kind == .capsLock)
                : Self.phase(for: kind, at: context.date.timeIntervalSinceReferenceDate)
            keycap(phase: phase)
        }
        .frame(width: kind.width, height: kind.height)
        .accessibilityLabel(kind.accessibilityLabel)
    }

    private func keycap(phase: OnboardingTutorialKeycapPhase) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.075))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )

            if kind == .capsLock {
                Circle()
                    .fill(phase.capsLightOn ? Self.capsLockGreen : Self.capsLockOff)
                    .frame(width: 8, height: 8)
                    .padding(.leading, 14)
                    .padding(.top, 13)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.primaryLabel)
                if let secondary = kind.secondaryLabel {
                    Spacer(minLength: 20)
                    Text(secondary)
                        .font(AppTypography.font(.permissionButton, size: 21))
                }
            }
            .font(AppTypography.font(.permissionButton, size: kind == .control ? 20 : 13))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.leading, 13)
            .padding(.top, kind == .shift ? 18 : 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .scaleEffect(phase.scale)
        .animation(nil, value: phase.scale)
    }

    private static let capsLockGreen = Color(red: 0.45, green: 0.95, blue: 0.02)
    private static let capsLockOff = Color(red: 0.07, green: 0.075, blue: 0.08)

    private static func phase(for kind: OnboardingTutorialKeycapKind,
                              at time: TimeInterval) -> OnboardingTutorialKeycapPhase {
        if kind == .capsLock {
            let cycle = time.truncatingRemainder(dividingBy: 1.0)
            return OnboardingTutorialKeycapPhase(
                scale: cycle < 0.14 ? 0.94 : 1.0,
                capsLightOn: cycle < 0.5
            )
        }
        let cycle = time.truncatingRemainder(dividingBy: 1.15)
        let pressed = (cycle < 0.11) || (cycle >= 0.22 && cycle < 0.33)
        return OnboardingTutorialKeycapPhase(scale: pressed ? 0.94 : 1.0, capsLightOn: false)
    }
}

private struct OnboardingTutorialKeycapPhase: Equatable {
    let scale: CGFloat
    let capsLightOn: Bool
}
