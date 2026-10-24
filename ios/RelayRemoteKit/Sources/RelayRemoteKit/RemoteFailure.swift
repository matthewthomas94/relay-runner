/// Why a connection or pairing attempt ended. Codes are safe to log; none of
/// them carries key material, fingerprints or user text.
public enum RemoteFailure: Error, Equatable, Sendable {
    /// The Mac presented a host key that is not pinned. Nothing was sent.
    case hostKeyMismatch
    /// The Mac's sshd refused the device key (unpaired or revoked).
    case authenticationRejected
    /// sshd accepted the key but refused to run the forced command.
    case execRejected
    /// No candidate address answered.
    case unreachable
    /// The SSH handshake or the `welcome` frame did not arrive in time.
    case handshakeTimeout
    /// The Mac stopped answering pings.
    case livenessTimeout
    /// Network.framework reported the path unviable or a better path.
    case networkChanged
    /// A line broke the 64 KiB frame limit.
    case protocolViolation
    /// The QR code or pasted text is not a Relay Remote pairing code.
    case invalidPairingCode
    /// The Mac answered the pairing request with an `error` frame.
    case pairingRejected(code: String, message: String)

    /// Retrying cannot fix these, so the session stops and asks the user.
    public var isTerminal: Bool {
        switch self {
        case .hostKeyMismatch, .authenticationRejected: return true
        default: return false
        }
    }

    public var code: String {
        switch self {
        case .hostKeyMismatch: return "host_key_mismatch"
        case .authenticationRejected: return "authentication_rejected"
        case .execRejected: return "exec_rejected"
        case .unreachable: return "unreachable"
        case .handshakeTimeout: return "handshake_timeout"
        case .livenessTimeout: return "liveness_timeout"
        case .networkChanged: return "network_changed"
        case .protocolViolation: return "protocol_violation"
        case .invalidPairingCode: return "invalid_pairing_code"
        case .pairingRejected(let code, _): return "pairing_rejected:\(code)"
        }
    }

    public var userMessage: String {
        switch self {
        case .hostKeyMismatch:
            return "The Mac's SSH host key does not match the one pinned at pairing. Relay Remote refused the connection and sent nothing. If the Mac was reinstalled or its keys were regenerated, pair again."
        case .authenticationRejected:
            return "The Mac no longer accepts this iPhone's key. Pair again from Relay Runner's Settings."
        case .execRejected:
            return "The Mac refused to start Relay Remote's helper."
        case .unreachable:
            return "The Mac is not reachable. Check that it is awake, Remote Login is on, and Tailscale is connected when away from home."
        case .handshakeTimeout:
            return "The Mac did not answer in time."
        case .livenessTimeout:
            return "The Mac stopped answering."
        case .networkChanged:
            return "The network changed."
        case .protocolViolation:
            return "The Mac sent a frame larger than the protocol allows."
        case .invalidPairingCode:
            return "That is not a Relay Remote pairing code."
        case .pairingRejected(_, let message):
            return message
        }
    }

    /// A loggable code for any error, without its description.
    public static func code(for error: Error) -> String {
        if let failure = error as? RemoteFailure { return failure.code }
        if error is CancellationError { return "cancelled" }
        return "transport_error"
    }
}
