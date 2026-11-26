import RelayRemoteKit
import SwiftUI

/// Tutorial (15–20): hold to talk, release to send, play and stop a reply,
/// over the real dock and a dimmed tab bar (RR-542). A port of the desktop's
/// session-controls tutorial to the phone's controls. `TutorialScreen` draws a
/// step; `LiveTutorial` drives it from the real voice layer and the Mac's
/// session; `TutorialMachine` decides when each step advances.
struct TutorialView: View {
    let model: AppModel
    let onFinished: () -> Void
    /// Debug only: a step with sample data for a screenshot (`LaunchOptions`).
    var sample: String?

    var body: some View {
        #if DEBUG
        if let sample = sample.flatMap(TutorialSample.init(rawValue:)) {
            TutorialScreen(step: sample.step, problem: nil, agentName: "George", isTalking: sample.isTalking,
                           transcript: sample.transcript, waiting: sample.waiting, onSkip: onFinished,
                           sampleGlow: sample.glow)
        } else {
            live
        }
        #else
        live
        #endif
    }

    @ViewBuilder
    private var live: some View {
        if let session = model.session, let voice = model.voice {
            LiveTutorial(model: model, session: session, voice: voice, onFinished: onFinished)
        } else {
            // Not paired: nothing to talk to, and Skip is the way on.
            TutorialScreen(step: .basics, problem: .macUnreachable, agentName: "George", onSkip: onFinished)
        }
    }
}

extension TutorialStep {
    /// The hero text, with its line breaks as in the reference images.
    var hero: HeroText {
        switch self {
        case .basics:
            return "Now let’s learn the basics"
        case .holdToTalk:
            return HeroText(lines: [[.chip(icon: .mic, label: "Hold to talk", style: .primary), .text(" & say hi")]])
        case .releaseToSend:
            return "Now release to send"
        case .playReply:
            return HeroText(lines: [[.text("Wait for a reply,")],
                                    [.text("then tap "), .chip(icon: .play, label: "Play", style: .secondary)]])
        case .stopPlayback:
            return HeroText(lines: [[.text("Tap "), .chip(icon: .square, label: nil, style: .secondary),
                                     .text(" to stop playback")]])
        case .allDone:
            return "You’re all done"
        }
    }
}

/// What the tutorial's controls do.
struct TutorialActions {
    var talk: (TalkGesture.Command) -> Void = { _ in }
    var play: (AgentsScreenState.WaitingReply) -> Void = { _ in }
    var stop: () -> Void = {}
    var skip: () -> Void = {}
}

/// One tutorial step: the hero text where every onboarding screen has it, the
/// real dock and a dimmed tab bar below. The control the step targets stays
/// lit; every other control and the tab bar are dimmed to 30% and take no
/// touches. The state glows behind the screen belong to the app root, so this
/// view draws no background.
struct TutorialScreen: View {
    let step: TutorialStep
    let problem: TutorialProblem?
    let agentName: String
    var isTalking = false
    var transcript = ""
    var waiting: AgentsScreenState.WaitingReply?
    var onSkip: (() -> Void)?
    var actions = TutorialActions()
    /// Debug only: draws a glow here, where the app root has no voice to follow.
    var sampleGlow: DotFieldStyle?

    private var subtitle: String {
        if let problem { return problem.line }
        return step == .basics ? "Getting speech ready" : ""
    }

    var body: some View {
        ZStack {
            if let sampleGlow {
                DotField(style: sampleGlow).ignoresSafeArea().allowsHitTesting(false)
            }
            OnboardingHeroLayout(hero: step.hero, onSkip: step == .allDone ? nil : onSkip,
                                 drawsBackground: false,
                                 accessory: {
                RelaySwap(subtitle) { text in
                    Text(text)
                        .relayTextStyle(.body)
                        .foregroundStyle(RelayColor.neutral7)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .frame(minHeight: 20)
                }
            }, secondary: { EmptyView() })
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                if step.showsDock {
                    if step == .playReply, let waiting {
                        WaitingReplyPanel(name: agentName, receivedAt: waiting.receivedAt) { actions.play(waiting) }
                            .padding(.horizontal, RelayMetrics.screenMargin)
                            .transition(.relaySurface)
                    }
                    dock
                        .padding(.bottom, AgentsScreen.dockBottomGap)
                        .transition(.relaySurface)
                }
            }
            .animation(RelayMotion.change, value: step.showsDock)
            .animation(RelayMotion.change, value: waiting)
        }
        .glassTabBar {
            GlassTabBar(selection: .constant(.agents), dimmed: true)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .opacity(step == .basics || step == .allDone ? 0 : 1)
        }
    }

    private var dock: some View {
        let dimmed = Set(DockControl.allCases).subtracting(step.litControls)
        return AgentDock(text: .constant(""), placeholder: "Message \(agentName)", talkMode: .hold,
                         isTalking: isTalking, transcript: transcript, dimmed: dimmed, inert: dimmed,
                         onTalk: actions.talk, onStop: actions.stop)
    }
}

/// `TutorialScreen` over the real session: the agent the Mac reports running
/// (George if none is), the phone's voice layer, and the step machine.
private struct LiveTutorial: View {
    let model: AppModel
    let session: RemoteSession
    let voice: VoiceController
    let onFinished: () -> Void

    @State private var tutorial: TutorialModel
    @State private var speech = TutorialSignals.Speech.preparing
    @State private var agent: String?

    init(model: AppModel, session: RemoteSession, voice: VoiceController, onFinished: @escaping () -> Void) {
        self.model = model
        self.session = session
        self.voice = voice
        self.onFinished = onFinished
        // Skipping and finishing both end here: the user's playback setting comes back.
        _tutorial = State(initialValue: TutorialModel(onFinished: {
            voice.playbackMode = model.playbackMode
            onFinished()
        }))
    }

    var body: some View {
        let agents = model.agents
        let state = AgentsScreenState(
            agents: agents,
            voice: VoiceSnapshot(isTalking: voice.isListening, transcript: voice.transcript,
                                 playingSeq: voice.isSpeaking ? voice.currentSeq : nil,
                                 waitingSeqs: voice.waitingSeqs),
            talkMode: .hold)
        let signals = TutorialSignals(
            speech: speech,
            agentAvailable: TutorialAgent.isAvailable(agent.flatMap { agents.activities[$0] }),
            reachable: agents.reachability == .reachable,
            isListening: voice.isListening,
            voiceIdle: voice.activity == .idle,
            userMessages: agent.map { agents.chat($0).filter { $0.role == .user }.count } ?? 0,
            replyWaiting: state.waiting != nil,
            isPlaying: voice.isSpeaking)
        TutorialScreen(step: tutorial.machine.step, problem: tutorial.machine.problem, agentName: state.name,
                       isTalking: state.isTalking, transcript: state.transcript, waiting: state.waiting,
                       onSkip: { tutorial.skip() },
                       actions: actions(agents: agents))
            .onChange(of: MacSessionStatus(session), initial: true) { _, status in
                agents.update(status)
                chooseAgent()
            }
            .onChange(of: signals, initial: true) { _, new in tutorial.observe(new) }
            .task {
                // Replies queue for the tutorial whatever the user's setting; the
                // setting itself is untouched and returns when the tutorial ends.
                voice.playbackMode = .onDemand
                speech = await voice.prepareSpeech() ? .ready : .unavailable
            }
            .onDisappear {
                tutorial.cancel()
                voice.playbackMode = model.playbackMode
            }
    }

    /// Picks the agent once the Mac has reported its agents, and starts George
    /// with no project when none is running.
    private func chooseAgent() {
        let agents = model.agents
        guard agent == nil,
              let slug = TutorialAgent.choose(activities: agents.activities, active: agents.activeAgent) else { return }
        agent = slug
        agents.select(slug)
        if agents.isStopped(slug) { agents.start(slug) }
    }

    private func actions(agents: AgentsModel) -> TutorialActions {
        TutorialActions(
            talk: { command in
                switch command {
                case .start:
                    voice.pressToTalkBegan(agent: agent)
                    tutorial.holdBegan()
                case .send:
                    voice.pressToTalkEnded()
                    tutorial.released()
                case .none:
                    break
                }
            },
            play: { waiting in
                voice.play(seq: waiting.seq, skipping: waiting.skipping)
                tutorial.playTapped()
            },
            stop: {
                voice.stop(agents: agent.map { [$0] } ?? [])
                tutorial.stopTapped()
            })
    }
}

#if DEBUG
/// Debug-only sample steps for `--tutorial-step=<name>`: the reference
/// images' states, 15 to 20.
enum TutorialSample: String, CaseIterable {
    case basics, hold, release, play, stop, done

    var step: TutorialStep {
        switch self {
        case .basics: return .basics
        case .hold: return .holdToTalk
        case .release: return .releaseToSend
        case .play: return .playReply
        case .stop: return .stopPlayback
        case .done: return .allDone
        }
    }

    var isTalking: Bool { self == .release }
    var transcript: String { self == .release ? "Hi" : "" }

    var waiting: AgentsScreenState.WaitingReply? {
        self == .play ? .init(seq: 1, skipping: [], receivedAt: .now.addingTimeInterval(-2)) : nil
    }

    var glow: DotFieldStyle? {
        switch self {
        case .release: return .listening
        case .stop: return .playback
        default: return nil
        }
    }
}
#endif
