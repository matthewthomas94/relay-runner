import Foundation

/// Relay Remote wire protocol (docs/specs/relay-remote.md, "Wire protocol").
/// The Python twin lives in services/relay_remote_protocol.py; both must
/// agree byte for byte on tests/RelayRemoteProtocolTests/Vectors.
public enum RelayRemoteProtocol {
    public static let version = 1
    /// Maximum bytes of one JSON line, excluding the trailing newline.
    public static let maxLineBytes = 64 * 1024
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

public struct Hello: Codable, Equatable, Sendable {
    public var `protocol`: Int
    public var deviceId: String
    public var deviceName: String
    public var appVersion: String
    public var resumeAfterSeq: Int?

    public init(protocol: Int = RelayRemoteProtocol.version, deviceId: String, deviceName: String,
                appVersion: String, resumeAfterSeq: Int? = nil) {
        self.protocol = `protocol`
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.resumeAfterSeq = resumeAfterSeq
    }
}

public struct Utterance: Codable, Equatable, Sendable {
    public var clientId: String
    public var text: String
    public var capturedAt: String

    public init(clientId: String, text: String, capturedAt: String) {
        self.clientId = clientId
        self.text = text
        self.capturedAt = capturedAt
    }
}

public struct Control: Codable, Equatable, Sendable {
    public var clientId: String
    public var action: ControlAction

    public init(clientId: String, action: ControlAction) {
        self.clientId = clientId
        self.action = action
    }
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

    public init(clientId: String, relayCommandSeq: Int, relayCommandId: String) {
        self.clientId = clientId
        self.relayCommandSeq = relayCommandSeq
        self.relayCommandId = relayCommandId
    }
}

public struct Speech: Codable, Equatable, Sendable {
    public var seq: Int
    public var kind: SpeechKind
    public var source: SpeechSource
    public var text: String
    public var relayCommandSeq: Int?

    public init(seq: Int, kind: SpeechKind, source: SpeechSource, text: String, relayCommandSeq: Int? = nil) {
        self.seq = seq
        self.kind = kind
        self.source = source
        self.text = text
        self.relayCommandSeq = relayCommandSeq
    }
}

public struct SpeechControl: Codable, Equatable, Sendable {
    public var seq: Int
    public var action: SpeechControlAction
    public var reason: String?

    public init(seq: Int, action: SpeechControlAction, reason: String? = nil) {
        self.seq = seq
        self.action = action
        self.reason = reason
    }
}

public struct Status: Codable, Equatable, Sendable {
    public var seq: Int
    public var text: String

    public init(seq: Int, text: String) {
        self.seq = seq
        self.text = text
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

public enum FrameDirection: Sendable {
    case phoneToMac, macToPhone
}

public enum Frame: Equatable, Sendable {
    case hello(Hello)
    case utterance(Utterance)
    case control(Control)
    case ack(Ack)
    case ping(Ping)
    case welcome(Welcome)
    case accepted(Accepted)
    case speech(Speech)
    case speechControl(SpeechControl)
    case status(Status)
    case error(ErrorFrame)
    case pong(Pong)

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .utterance: return "utterance"
        case .control: return "control"
        case .ack: return "ack"
        case .ping: return "ping"
        case .welcome: return "welcome"
        case .accepted: return "accepted"
        case .speech: return "speech"
        case .speechControl: return "speech_control"
        case .status: return "status"
        case .error: return "error"
        case .pong: return "pong"
        }
    }

    public var direction: FrameDirection {
        switch self {
        case .hello, .utterance, .control, .ack, .ping: return .phoneToMac
        default: return .macToPhone
        }
    }

    /// The per-device sequence number carried by replayable Mac-to-phone frames.
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
        case .ack(let f): try f.encode(to: encoder)
        case .ping(let f): try f.encode(to: encoder)
        case .welcome(let f): try f.encode(to: encoder)
        case .accepted(let f): try f.encode(to: encoder)
        case .speech(let f): try f.encode(to: encoder)
        case .speechControl(let f): try f.encode(to: encoder)
        case .status(let f): try f.encode(to: encoder)
        case .error(let f): try f.encode(to: encoder)
        case .pong(let f): try f.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKey.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "utterance": self = .utterance(try Utterance(from: decoder))
        case "control": self = .control(try Control(from: decoder))
        case "ack": self = .ack(try Ack(from: decoder))
        case "ping": self = .ping(try Ping(from: decoder))
        case "welcome": self = .welcome(try Welcome(from: decoder))
        case "accepted": self = .accepted(try Accepted(from: decoder))
        case "speech": self = .speech(try Speech(from: decoder))
        case "speech_control": self = .speechControl(try SpeechControl(from: decoder))
        case "status": self = .status(try Status(from: decoder))
        case "error": self = .error(try ErrorFrame(from: decoder))
        case "pong": self = .pong(try Pong(from: decoder))
        default: throw FrameError.unknownType(type)
        }
    }
}
