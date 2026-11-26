#if DEBUG
import Foundation
import RelayRemoteProtocol

/// Debug-only sample screens for the Agents tab, opened with
/// `--stage=app --agents-sample=<name>` for simulator screenshots. Each one is
/// a reference image's state: 21 ready, 22 holding, 23 playing, 24 not-running,
/// 25 unreachable, and long-draft for the dock at five lines.
enum AgentsSample: String, CaseIterable {
    case ready, holding, playing
    case notRunning = "not-running"
    case unreachable
    case longDraft = "long-draft"

    @MainActor
    var state: AgentsScreenState {
        let defaults = UserDefaults(suiteName: "relay-remote.samples") ?? .standard
        let agents = AgentsModel(store: ChatStore(directory: nil), defaults: defaults)
        agents.select(self == .notRunning ? "puck" : "george")
        let today = Calendar.current.startOfDay(for: .now)
        func at(_ hour: Int, _ minute: Int) -> Date { today.addingTimeInterval(Double(hour * 3600 + minute * 60)) }
        var george = [
            ChatMessage(role: .user, text: "Line up the Registered projects buttons with Locate folder and Remove.",
                        date: at(9, 31)),
            ChatMessage(role: .agent, text: "Done. Add project and Create now match the widths of the buttons below them, and both rows use the same 8 pt gap.",
                        date: at(9, 33), seq: 11),
            ChatMessage(role: .status, text: "Created RR-531 in relay-runner", date: at(9, 33), seq: 12),
            ChatMessage(role: .user, text: "Great. Cut a new release once both are done.", date: at(9, 35)),
        ]
        if self == .ready || self == .playing {
            george.append(ChatMessage(role: .agent,
                                      text: "Both are merged. 0.8.1 is building now and I’ll put it in Applications when it’s done.",
                                      date: Date.now.addingTimeInterval(-18), seq: 13))
        }
        agents.setSample(activities: ["puck": .off, "isabella": .off, "george": .ready, "sky": .working],
                         marked: [], reachability: self == .unreachable ? .unreachable : .reachable,
                         chats: ["george": george])
        var voice = VoiceSnapshot()
        switch self {
        case .ready: voice.waitingSeqs = [13]
        case .holding:
            voice.isTalking = true
            voice.transcript = "Could you put the latest build in my Applications as well"
        case .playing: voice.playingSeq = 13
        case .notRunning, .unreachable, .longDraft: break
        }
        return AgentsScreenState(agents: agents, voice: voice, talkMode: .hold)
    }

    var draft: String {
        guard self == .longDraft else { return "" }
        return "Could you put the latest build in my Applications as well, then open it and check that the agent tabs, the dock and the Workspace all line up with the designs before you cut the next release for the team"
    }
}
#endif
