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
        } else if let sample = launch.agentsSample.flatMap(AgentsSample.init(rawValue:)) {
            AgentsScreen(state: sample.state, draft: sample.draft)
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
                                     waitingSeqs: voice.waitingSeqs)
        AgentsScreen(state: AgentsScreenState(agents: agents, voice: snapshot, talkMode: talkMode),
                     actions: actions(playing: agents.agent(ofSeq: snapshot.playingSeq)))
            .onChange(of: MacSessionStatus(session), initial: true) { _, status in agents.update(status) }
    }

    private func actions(playing: String?) -> AgentsScreenActions {
        AgentsScreenActions(
            select: { agents.select($0) },
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
