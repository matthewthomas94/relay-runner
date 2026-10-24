import Foundation

/// The QR code Relay Runner shows while pairing (RR-426,
/// `RelayRemotePairingPayload`). It carries a one-time pairing key and token,
/// so it is parsed in memory, never stored, and its descriptions are redacted.
public struct PairingPayload: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let user: String
    /// Bonjour name, LAN addresses, then the Tailscale address.
    public let hosts: [String]
    public let port: Int
    /// `SHA256:` fingerprints of the Mac's host keys.
    public let hostKeys: [String]
    public let pairingID: String
    /// The 32-byte Ed25519 seed of the ephemeral pairing key.
    let pairingKey: Data
    /// Base64, returned to the Mac verbatim.
    let token: String

    private struct Wire: Decodable {
        let `protocol`: Int
        let user: String
        let hosts: [String]
        let port: Int
        let host_keys: [String]
        let pairing_id: String
        let pairing_key: String
        let token: String
    }

    public static func parse(_ text: String) throws -> PairingPayload {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.protocol == 1,
              !wire.user.isEmpty,
              !wire.hosts.isEmpty,
              wire.hosts.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }),
              (1...65535).contains(wire.port),
              !wire.host_keys.isEmpty,
              wire.host_keys.allSatisfy({ $0.hasPrefix("SHA256:") && $0.count > 7 }),
              Identifier.isValid(wire.pairing_id),
              let seed = Data(base64Encoded: wire.pairing_key), seed.count == 32,
              let token = Data(base64Encoded: wire.token), !token.isEmpty else {
            throw RemoteFailure.invalidPairingCode
        }
        return PairingPayload(user: wire.user, hosts: wire.hosts, port: wire.port, hostKeys: wire.host_keys,
                              pairingID: wire.pairing_id, pairingKey: seed, token: wire.token)
    }

    public var description: String { "PairingPayload(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// The id alphabet `relay-remote-shell` and the Mac's key writer accept.
enum Identifier {
    static func isValid(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x2D || c == 0x2E || c == 0x5F
        }
    }
}
