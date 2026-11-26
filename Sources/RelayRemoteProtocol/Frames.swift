import Foundation

/// Relay Remote wire protocol (docs/specs/relay-remote.md, "Wire protocol").
/// The Rust twin lives in rust/relay-rs/src/remote/protocol.rs; both must
/// agree byte for byte on tests/RelayRemoteProtocolTests/Vectors.
public enum RelayRemoteProtocol {
    public static let version = 1
    /// Maximum bytes of one JSON line, excluding the trailing newline.
    public static let maxLineBytes = 64 * 1024
    /// Maximum base64 bytes of Mac-voiced audio in one `speech_audio` frame (RR-457).
    public static let maxAudioDataBytes = 32 * 1024
    /// RR-532: the agent slugs an `agent` field names, in the Mac's table order.
    /// The codecs accept any string so a later agent does not break an older
    /// peer; the Mac refuses or ignores a slug it does not know.
    public static let agents = ["puck", "isabella", "george", "sky"]
}

/// Same values as `SPEECH_KINDS` in services/speech_coordinator.py.
public enum SpeechKind: String, Codable, Sendable {
    case handoff, progress, clarification, `final`, fallback, control
}

/// Same values as `SPEECH_SOURCES` in services/speech_coordinator.py.
public enum SpeechSource: String, Codable, Sendable {
    case messenger, orchestrator, lifecycle, completion, fallback
}

public enum ControlAction: String, Codable, Sendable {
    case stop, interrupt, cancel, play, replay
}

public enum SpeechControlAction: String, Codable, Sendable {
    case stop, skip
}

/// Which device voices a `speech` frame (RR-454). `mac`: Kokoro speaks it and
/// the phone only shows the text. Absent means `phone`, as before RR-454.
public enum SpokenBy: String, Codable, Sendable {
    case mac, phone
}

/// Codec of a `speech_audio` stream (RR-457). `aac` is AAC-LC in ADTS framing.
public enum AudioFormat: String, Codable, Sendable {
    case aac, opus
}

public struct Hello: Codable, Equatable, Sendable {
    public var `protocol`: Int
    public var deviceId: String
    public var deviceName: String
    public var appVersion: String
    public var resumeAfterSeq: Int?
    /// The phone's Remote mode switch, restored on every reconnect (RR-454).
    /// Absent means on, matching phones built before the switch existed.
    public var remoteMode: Bool?

    public init(protocol: Int = RelayRemoteProtocol.version, deviceId: String, deviceName: String,
                appVersion: String, resumeAfterSeq: Int? = nil, remoteMode: Bool? = nil) {
        self.protocol = `protocol`
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.resumeAfterSeq = resumeAfterSeq
        self.remoteMode = remoteMode
    }
}

public struct Utterance: Codable, Equatable, Sendable {
    public var clientId: String
    public var text: String
    public var capturedAt: String
    /// RR-532: the agent the request is for, by slug. Absent: the agent
    /// focused on the Mac, as before.
    public var agent: String?

    public init(clientId: String, text: String, capturedAt: String, agent: String? = nil) {
        self.clientId = clientId
        self.text = text
        self.capturedAt = capturedAt
        self.agent = agent
    }
}

public struct Control: Codable, Equatable, Sendable {
    public var clientId: String
    public var action: ControlAction
    /// RR-532: the agent the control is for, by slug. Absent: the focused agent.
    public var agent: String?

    public init(clientId: String, action: ControlAction, agent: String? = nil) {
        self.clientId = clientId
        self.action = action
        self.agent = agent
    }
}

/// The phone's Remote mode switch changed (RR-454). On: the phone owns the
/// microphone and speaker. Off: speech plays on the Mac and the phone shows text.
public struct RemoteMode: Codable, Equatable, Sendable {
    public var clientId: String
    public var enabled: Bool

    public init(clientId: String, enabled: Bool) {
        self.clientId = clientId
        self.enabled = enabled
    }
}

/// What a `session_command` asks Relay Runner on the Mac to do (RR-456).
public enum SessionAction: String, Codable, Sendable {
    case listProjects = "list_projects"
    case start, stop, state
}

/// The Mac's Relay session as `session_state` reports it (RR-456).
public enum SessionPhase: String, Codable, Sendable {
    /// Named so that `SessionPhase?` comparisons never read as `Optional.none`.
    case noSession = "none"
    case starting, ready, failed
}

/// Lists projects, or starts, stops or inspects the Mac's Relay session
/// (RR-456). The Mac's provider, model and effort defaults apply. RR-523:
/// `agent` names the agent to start by slug (`puck`, `isabella`, `george`,
/// `sky`); a start without it, from an older phone build, starts the most
/// recently active agent, or Puck if none has run. RR-532: a start without
/// `project_id` starts in the built-in general-tasks project, as the Mac's
/// own Start Session does.
public struct SessionCommand: Codable, Equatable, Sendable {
    public var clientId: String
    public var action: SessionAction
    public var projectId: String?
    public var agent: String?

    public init(clientId: String, action: SessionAction, projectId: String? = nil, agent: String? = nil) {
        self.clientId = clientId
        self.action = action
        self.projectId = projectId
        self.agent = agent
    }
}

/// A registered project as `session_state` lists it. `availability` is the
/// Mac registry's value (`available`, `missing`, ...); only `available`
/// projects can start.
public struct ProjectSummary: Codable, Equatable, Sendable {
    public var projectId: String
    public var displayName: String
    public var availability: String

    public init(projectId: String, displayName: String, availability: String) {
        self.projectId = projectId
        self.displayName = displayName
        self.availability = availability
    }

    public var isAvailable: Bool { availability == "available" }
}

public struct Ack: Codable, Equatable, Sendable {
    public var seq: Int
    public var played: Bool

    public init(seq: Int, played: Bool) {
        self.seq = seq
        self.played = played
    }
}

public struct Ping: Codable, Equatable, Sendable {
    public var t: Int

    public init(t: Int) { self.t = t }
}

public struct Welcome: Codable, Equatable, Sendable {
    public var `protocol`: Int
    public var sessionState: String
    public var serverSeq: Int
    public var resumedFrom: Int?
    public var dropped: Bool

    public init(protocol: Int = RelayRemoteProtocol.version, sessionState: String, serverSeq: Int,
                resumedFrom: Int? = nil, dropped: Bool) {
        self.protocol = `protocol`
        self.sessionState = sessionState
        self.serverSeq = serverSeq
        self.resumedFrom = resumedFrom
        self.dropped = dropped
    }
}

public struct Accepted: Codable, Equatable, Sendable {
    public var clientId: String
    public var relayCommandSeq: Int
    public var relayCommandId: String
    /// RR-532: the agent whose inbox took the utterance. Absent from a Mac
    /// that does not route by agent.
    public var agent: String?

    public init(clientId: String, relayCommandSeq: Int, relayCommandId: String, agent: String? = nil) {
        self.clientId = clientId
        self.relayCommandSeq = relayCommandSeq
        self.relayCommandId = relayCommandId
        self.agent = agent
    }
}

public struct Speech: Codable, Equatable, Sendable {
    public var seq: Int
    public var kind: SpeechKind
    public var source: SpeechSource
    public var text: String
    public var relayCommandSeq: Int?
    public var spokenBy: SpokenBy?
    /// True when `speech_audio` parts in the Mac's voice follow (RR-457).
    public var audio: Bool?
    /// RR-532: the agent speaking. Absent: the focused agent, as before.
    public var agent: String?

    public init(seq: Int, kind: SpeechKind, source: SpeechSource, text: String, relayCommandSeq: Int? = nil,
                spokenBy: SpokenBy? = nil, audio: Bool? = nil, agent: String? = nil) {
        self.seq = seq
        self.kind = kind
        self.source = source
        self.text = text
        self.relayCommandSeq = relayCommandSeq
        self.spokenBy = spokenBy
        self.audio = audio
        self.agent = agent
    }
}

/// One slice of the Mac's voice for the `speech` frame `seq` (RR-457). The parts
/// of one seq are consecutive slices of one encoded stream. `parts` is the total
/// once known, otherwise 0; the final part carries `last: true`. It takes no seq
/// of its own and is replayed with the frame it voices.
public struct SpeechAudio: Codable, Equatable, Sendable {
    public var seq: Int
    public var part: Int
    public var parts: Int
    public var format: AudioFormat
    public var sampleRate: Int
    /// Base64, at most `RelayRemoteProtocol.maxAudioDataBytes`.
    public var data: String
    public var last: Bool?
    /// RR-532: the agent of the `speech` frame this voices.
    public var agent: String?

    public init(seq: Int, part: Int, parts: Int, format: AudioFormat, sampleRate: Int, data: String,
                last: Bool? = nil, agent: String? = nil) {
        self.seq = seq
        self.part = part
        self.parts = parts
        self.format = format
        self.sampleRate = sampleRate
        self.data = data
        self.last = last
        self.agent = agent
    }
}

public struct SpeechControl: Codable, Equatable, Sendable {
    public var seq: Int
    public var action: SpeechControlAction
    public var reason: String?
    /// RR-532: the agent whose speech stops or skips. Absent: every agent's,
    /// as before.
    public var agent: String?

    public init(seq: Int, action: SpeechControlAction, reason: String? = nil, agent: String? = nil) {
        self.seq = seq
        self.action = action
        self.reason = reason
        self.agent = agent
    }
}

public struct Status: Codable, Equatable, Sendable {
    public var seq: Int
    public var text: String
    /// RR-532: the agent the status is about, when it is about one.
    public var agent: String?

    public init(seq: Int, text: String, agent: String? = nil) {
        self.seq = seq
        self.text = text
        self.agent = agent
    }
}

public struct ErrorFrame: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct Pong: Codable, Equatable, Sendable {
    public var t: Int

    public init(t: Int) { self.t = t }
}

/// Relay Runner's session as the Mac app reports it (RR-456). The app sends
/// it over the session-control socket when no voice bridge is running, and
/// in answer to a `session_command`. `app_running: false` comes from the
/// forced-command helper when neither socket is listening. `projects` is
/// present on `list_projects` and on first contact; `error` explains a
/// refused or failed command. RR-523: `active_agent` is the active agent's
/// slug and `running_agents` every running agent's, in table order. RR-532:
/// `agents` is one entry per agent in table order, running or not, from a Mac
/// that reports per-agent state; absent from an older one.
public struct SessionState: Codable, Equatable, Sendable {
    public var appRunning: Bool
    public var session: SessionPhase
    public var projectId: String?
    public var projectName: String?
    public var projects: [ProjectSummary]?
    public var error: String?
    public var activeAgent: String?
    public var runningAgents: [String]?
    public var agents: [AgentStatus]?

    public init(appRunning: Bool, session: SessionPhase, projectId: String? = nil, projectName: String? = nil,
                projects: [ProjectSummary]? = nil, error: String? = nil,
                activeAgent: String? = nil, runningAgents: [String]? = nil, agents: [AgentStatus]? = nil) {
        self.appRunning = appRunning
        self.session = session
        self.projectId = projectId
        self.projectName = projectName
        self.projects = projects
        self.error = error
        self.activeAgent = activeAgent
        self.runningAgents = runningAgents
        self.agents = agents
    }
}

/// What one agent is doing, as `session_state.agents` reports it (RR-532).
public enum AgentActivity: String, Codable, Sendable {
    /// Not running.
    case off
    case starting
    /// Running and idle.
    case ready
    /// Running a turn.
    case working
    /// Taking the user's speech.
    case listening
    /// Its reply is playing.
    case playing
}

/// One agent inside `session_state.agents` (RR-532; not a frame).
public struct AgentStatus: Codable, Equatable, Sendable {
    /// The slug, one of `RelayRemoteProtocol.agents`.
    public var agent: String
    public var running: Bool
    public var state: AgentActivity
    /// A short line about the agent's current work, when it has one.
    public var workingOn: String?

    public init(agent: String, running: Bool, state: AgentActivity, workingOn: String? = nil) {
        self.agent = agent
        self.running = running
        self.state = state
        self.workingOn = workingOn
    }
}

// MARK: - Workspace feed (RR-532)

public enum WorkspaceAction: String, Codable, Sendable {
    case list
}

/// Asks the Mac for its Workspace: the registered projects and their open
/// tickets. Answered with `workspace_state`.
public struct WorkspaceCommand: Codable, Equatable, Sendable {
    public var clientId: String
    public var action: WorkspaceAction

    public init(clientId: String, action: WorkspaceAction = .list) {
        self.clientId = clientId
        self.action = action
    }
}

/// The Workspace lanes the phone shows, in the order it groups them.
public enum TicketStatus: String, Codable, Sendable {
    case inProgress = "in_progress"
    case queued, backlog
}

/// A project inside `workspace_state.projects` (not a frame).
public struct WorkspaceProject: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A ticket inside `workspace_state.tickets` (not a frame).
public struct WorkspaceTicket: Codable, Equatable, Sendable {
    /// The ticket id, for example `RR-120`.
    public var id: String
    public var title: String
    public var status: TicketStatus
    /// The `id` of its entry in `workspace_state.projects`.
    public var projectId: String
    /// The agent that owns it, by slug, when one does.
    public var agent: String?

    public init(id: String, title: String, status: TicketStatus, projectId: String, agent: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.projectId = projectId
        self.agent = agent
    }
}

/// The Mac's answer to `workspace_command`. `error` says why the list is
/// empty when the Mac could not read it.
public struct WorkspaceState: Codable, Equatable, Sendable {
    public var projects: [WorkspaceProject]
    public var tickets: [WorkspaceTicket]
    public var error: String?
    /// RR-535: true when the Mac held more open tickets than it sends. Absent
    /// otherwise, so an older Mac's frames decode unchanged.
    public var truncated: Bool?

    public init(projects: [WorkspaceProject], tickets: [WorkspaceTicket], error: String? = nil,
                truncated: Bool? = nil) {
        self.projects = projects
        self.tickets = tickets
        self.error = error
        self.truncated = truncated
    }
}

// MARK: - Settings (RR-532)

public enum SettingsAction: String, Codable, Sendable {
    case get, set
}

/// Reads the Mac's settings, or changes the keys a `set` carries; absent keys
/// are left alone. Answered with `settings_state`. The orchestrator provider
/// is reported but cannot be changed from the phone.
public struct SettingsCommand: Codable, Equatable, Sendable {
    public var clientId: String
    public var action: SettingsAction
    /// Speech speed in hundredths: 130 is 1.3x, the desktop's TTS rate.
    public var speechSpeedPercent: Int?
    /// One of `settings_state.model_options`.
    public var model: String?
    /// One of `settings_state.effort_options`.
    public var effort: String?
    /// One of `settings_state.sizing_options`.
    public var sizing: String?

    public init(clientId: String, action: SettingsAction, speechSpeedPercent: Int? = nil, model: String? = nil,
                effort: String? = nil, sizing: String? = nil) {
        self.clientId = clientId
        self.action = action
        self.speechSpeedPercent = speechSpeedPercent
        self.model = model
        self.effort = effort
        self.sizing = sizing
    }
}

/// One choice the Mac offers for a setting (not a frame). `value` is what a
/// `set` sends; `label` is what the phone shows.
public struct SettingOption: Codable, Equatable, Sendable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// The Mac's settings, in answer to every `settings_command`. The options are
/// the Mac's own catalogue for the current provider and model, so the phone
/// never hard-codes one. `error` says why a `set` was refused; the values are
/// then the unchanged ones. A Mac that cannot serve settings answers with
/// only `error`.
public struct SettingsState: Codable, Equatable, Sendable {
    public var speechSpeedPercent: Int?
    /// `codex` or `claude`; read-only from the phone.
    public var provider: String?
    public var model: String?
    public var effort: String?
    public var sizing: String?
    public var modelOptions: [SettingOption]?
    public var effortOptions: [SettingOption]?
    public var sizingOptions: [SettingOption]?
    public var error: String?

    public init(speechSpeedPercent: Int? = nil, provider: String? = nil, model: String? = nil, effort: String? = nil,
                sizing: String? = nil, modelOptions: [SettingOption]? = nil, effortOptions: [SettingOption]? = nil,
                sizingOptions: [SettingOption]? = nil, error: String? = nil) {
        self.speechSpeedPercent = speechSpeedPercent
        self.provider = provider
        self.model = model
        self.effort = effort
        self.sizing = sizing
        self.modelOptions = modelOptions
        self.effortOptions = effortOptions
        self.sizingOptions = sizingOptions
        self.error = error
    }
}

public enum FrameDirection: Sendable {
    case phoneToMac, macToPhone
}

public enum Frame: Equatable, Sendable {
    case hello(Hello)
    case utterance(Utterance)
    case control(Control)
    case remoteMode(RemoteMode)
    case sessionCommand(SessionCommand)
    case ack(Ack)
    case ping(Ping)
    case welcome(Welcome)
    case accepted(Accepted)
    case speech(Speech)
    case speechAudio(SpeechAudio)
    case speechControl(SpeechControl)
    case status(Status)
    case error(ErrorFrame)
    case pong(Pong)
    case sessionState(SessionState)
    case workspaceCommand(WorkspaceCommand)
    case workspaceState(WorkspaceState)
    case settingsCommand(SettingsCommand)
    case settingsState(SettingsState)

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .utterance: return "utterance"
        case .control: return "control"
        case .remoteMode: return "remote_mode"
        case .sessionCommand: return "session_command"
        case .ack: return "ack"
        case .ping: return "ping"
        case .welcome: return "welcome"
        case .accepted: return "accepted"
        case .speech: return "speech"
        case .speechAudio: return "speech_audio"
        case .speechControl: return "speech_control"
        case .status: return "status"
        case .error: return "error"
        case .pong: return "pong"
        case .sessionState: return "session_state"
        case .workspaceCommand: return "workspace_command"
        case .workspaceState: return "workspace_state"
        case .settingsCommand: return "settings_command"
        case .settingsState: return "settings_state"
        }
    }

    public var direction: FrameDirection {
        switch self {
        case .hello, .utterance, .control, .remoteMode, .sessionCommand, .ack, .ping, .workspaceCommand,
             .settingsCommand: return .phoneToMac
        default: return .macToPhone
        }
    }

    /// RR-532: the agent an agent-addressed frame names (`utterance`,
    /// `control`, `accepted`, `speech`, `speech_audio`, `speech_control`,
    /// `status`). Nil when it names none, which means the focused agent.
    public var agent: String? {
        switch self {
        case .utterance(let f): return f.agent
        case .control(let f): return f.agent
        case .accepted(let f): return f.agent
        case .speech(let f): return f.agent
        case .speechAudio(let f): return f.agent
        case .speechControl(let f): return f.agent
        case .status(let f): return f.agent
        default: return nil
        }
    }

    /// The per-device sequence number carried by replayable Mac-to-phone frames.
    /// `speech_audio` takes none: its `seq` names the `speech` frame it voices.
    public var seq: Int? {
        switch self {
        case .speech(let f): return f.seq
        case .speechControl(let f): return f.seq
        case .status(let f): return f.seq
        default: return nil
        }
    }
}

extension Frame: Codable {
    private enum TypeKey: String, CodingKey { case type }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .hello(let f): try f.encode(to: encoder)
        case .utterance(let f): try f.encode(to: encoder)
        case .control(let f): try f.encode(to: encoder)
        case .remoteMode(let f): try f.encode(to: encoder)
        case .sessionCommand(let f): try f.encode(to: encoder)
        case .ack(let f): try f.encode(to: encoder)
        case .ping(let f): try f.encode(to: encoder)
        case .welcome(let f): try f.encode(to: encoder)
        case .accepted(let f): try f.encode(to: encoder)
        case .speech(let f): try f.encode(to: encoder)
        case .speechAudio(let f): try f.encode(to: encoder)
        case .speechControl(let f): try f.encode(to: encoder)
        case .status(let f): try f.encode(to: encoder)
        case .error(let f): try f.encode(to: encoder)
        case .pong(let f): try f.encode(to: encoder)
        case .sessionState(let f): try f.encode(to: encoder)
        case .workspaceCommand(let f): try f.encode(to: encoder)
        case .workspaceState(let f): try f.encode(to: encoder)
        case .settingsCommand(let f): try f.encode(to: encoder)
        case .settingsState(let f): try f.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "utterance": self = .utterance(try Utterance(from: decoder))
        case "control": self = .control(try Control(from: decoder))
        case "remote_mode": self = .remoteMode(try RemoteMode(from: decoder))
        case "session_command": self = .sessionCommand(try SessionCommand(from: decoder))
        case "ack": self = .ack(try Ack(from: decoder))
        case "ping": self = .ping(try Ping(from: decoder))
        case "welcome": self = .welcome(try Welcome(from: decoder))
        case "accepted": self = .accepted(try Accepted(from: decoder))
        case "speech": self = .speech(try Speech(from: decoder))
        case "speech_audio": self = .speechAudio(try SpeechAudio(from: decoder))
        case "speech_control": self = .speechControl(try SpeechControl(from: decoder))
        case "status": self = .status(try Status(from: decoder))
        case "error": self = .error(try ErrorFrame(from: decoder))
        case "pong": self = .pong(try Pong(from: decoder))
        case "session_state": self = .sessionState(try SessionState(from: decoder))
        case "workspace_command": self = .workspaceCommand(try WorkspaceCommand(from: decoder))
        case "workspace_state": self = .workspaceState(try WorkspaceState(from: decoder))
        case "settings_command": self = .settingsCommand(try SettingsCommand(from: decoder))
        case "settings_state": self = .settingsState(try SettingsState(from: decoder))
        default: throw FrameError.unknownType(type)
        }
    }
}
