import RelayRemoteKit
import SwiftUI

/// Agents (21–25): the selected agent's chat, the agent tabs and the dock,
/// over the paired Mac's session (RR-540). The screen itself is
/// `AgentsScreen`; this view feeds it from the app model and routes its
/// controls to the session and the voice layer.
struct AgentsTabView: View {
    let model: AppModel
    var launch = LaunchOptions.current

    var body: some View {
        #if DEBUG
        if launch.agentsSample == "play-demo" {
            AgentsPlayDemo()
        } else if launch.agentsSample == "talk-demo" {
            AgentsTalkDemo(state: AgentsSample.ready.state)
        } else if let sample = launch.agentsSample.flatMap(AgentsSample.init(rawValue:)) {
            if let every = launch.cycleAgentsEvery {
                AgentsCycleDemo(state: sample.state, every: every)
            } else {
                AgentsScreen(state: sample.state, draft: sample.draft)
            }
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
            LiveAgentsScreen(agents: model.agents, session: session, voice: voice)
        } else {
            TabPlaceholder(title: "Agents", detail: "Pair with your Mac to talk to its agents.")
        }
    }
}

private struct LiveAgentsScreen: View {
    let agents: AgentsModel
    let session: RemoteSession
    let voice: VoiceController

    var body: some View {
        let talkMode = TalkModePreference().mode
        let snapshot = VoiceSnapshot(isTalking: voice.isListening, transcript: voice.transcript,
                                     playingSeq: voice.isSpeaking ? voice.currentSeq : nil,
                                     waitingSeqs: voice.waitingSeqs, isPreparing: voice.isPreparing)
        AgentsScreen(state: AgentsScreenState(agents: agents, voice: snapshot, talkMode: talkMode),
                     actions: actions(playing: agents.agent(ofSeq: snapshot.playingSeq)
                                        ?? agents.activities.first { $0.value == .playing }?.key))
            .onChange(of: MacSessionStatus(session), initial: true) { _, status in agents.update(status) }
    }

    private func actions(playing: String?) -> AgentsScreenActions {
        AgentsScreenActions(
            select: { agents.select($0) },
            setWorkStyle: { agents.setWorkStyle($0, for: agents.selected) },
            send: { agents.send($0) },
            talk: { command in
                switch command {
                case .start: voice.pressToTalkBegan(agent: agents.selected)
                case .send: voice.pressToTalkEnded()
                case .none: break
                }
            },
            cancelTalk: { voice.cancelTalking() },
            play: { voice.play(seq: $0.seq, skipping: $0.skipping) },
            stop: {
                // Silence the phone, and stop the selected agent and the one playing.
                var targets = [agents.selected]
                if let playing, playing != agents.selected { targets.append(playing) }
                voice.stop(agents: targets)
            },
            replay: {
                agents.replayRequested(for: agents.selected)
                voice.replay(agent: agents.selected)
            },
            start: { agents.start(agents.selected) },
            retry: {
                if case .waiting = session.state { session.retryNow() } else { session.start() }
            }
        )
    }
}

/// A tab's placeholder body: its name and one line under it.
struct TabPlaceholder: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(title).relayTextStyle(.titleL).foregroundStyle(RelayColor.neutral10)
            if let detail {
                Text(detail).relayTextStyle(.body).foregroundStyle(RelayColor.neutral7)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
/// Debug (`--agents-sample=talk-demo`): talks a message, releases and sends
/// it as the live voice layer does, on a loop, so the dock can be recorded.
private struct AgentsTalkDemo: View {
    @State var state: AgentsScreenState

    var body: some View {
        AgentsScreen(state: state)
            .task {
                let words = "Could you put the latest build in my Applications as well and then check the tabs".split(separator: " ")
                let base = state.feed
                while !Task.isCancelled {
                    state.feed = base
                    try? await Task.sleep(for: .seconds(1))
                    state.isTalking = true
                    for count in 1...words.count {
                        try? await Task.sleep(for: .seconds(0.08))
                        state.transcript = words.prefix(count).joined(separator: " ")
                    }
                    try? await Task.sleep(for: .seconds(0.4))
                    // Released: listening ends at once; the transcript clears
                    // and the message files once the recogniser finishes.
                    state.isTalking = false
                    try? await Task.sleep(for: .seconds(0.5))
                    state.feed.append(ChatMessage(role: .user, text: state.transcript, date: .now))
                    state.transcript = ""
                    state.isPreparing = true
                    try? await Task.sleep(for: .seconds(1.5))
                    state.isPreparing = false
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

/// Debug: the sample screen switching agents on a timer (`--cycle-agents`).
private struct AgentsCycleDemo: View {
    @State var state: AgentsScreenState
    let every: Double

    var body: some View {
        AgentsScreen(state: state)
            .task {
                let order = ["puck", "sky", "isabella", "george"]
                while !Task.isCancelled {
                    for slug in order {
                        try? await Task.sleep(for: .seconds(every))
                        withAnimation(RelayMotion.move) {
                            state.selected = slug
                            state.name = state.tabs.first { $0.slug == slug }?.name ?? slug
                        }
                    }
                }
            }
    }
}
#endif
