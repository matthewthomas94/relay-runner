import CryptoKit
import Foundation
import Network
import NIOSSH

/// Pairs with the Mac from a scanned QR payload (docs/specs/relay-remote.md,
/// "Pairing and trust", step 4): connect with the one-time pairing key,
/// verify the host key against the fingerprints in the payload, send `pair`
/// with the token, this device's id, name and public key, then wait while the
/// user confirms on the Mac.
public struct PairingClient: Sendable {
    /// The Mac keeps a pairing open for ten minutes.
    public static let replyTimeout: Double = 10 * 60

    private let transport: RemoteTransport
    private let log: RemoteLogger

    public init(transport: RemoteTransport, log: RemoteLogger = .system) {
        self.transport = transport
        self.log = log
    }

    public func pair(_ payload: PairingPayload, deviceKey: DeviceKey, deviceID: String,
                     deviceName: String) async throws -> PairedMac {
        let pairingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: payload.pairingKey)
        let credentials = SSHCredentials(user: payload.user, privateKey: NIOSSHPrivateKey(ed25519Key: pairingKey),
                                         pinnedHostKeys: Set(payload.hostKeys))
        let connection = try await connect(payload, credentials: credentials)
        defer { connection.close() }

        let request: [String: String] = [
            "type": "pair",
            "token": payload.token,
            "device_id": deviceID,
            "device_name": deviceName,
            "public_key": deviceKey.openSSHPublicKey,
        ]
        var line = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .withoutEscapingSlashes])
        line.append(0x0A)
        connection.send(line)
        log("pair request sent")

        let reply = try await firstLine(of: connection)
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw RemoteFailure.protocolViolation
        }
        if object["type"] as? String == "paired", object["device_id"] as? String == deviceID {
            log("paired")
            return PairedMac(deviceID: deviceID, deviceName: deviceName, user: payload.user, hosts: payload.hosts,
                             port: payload.port, hostKeyFingerprints: payload.hostKeys)
        }
        let code = object["code"] as? String ?? "unexpected_reply"
        log("pairing refused: \(code)")
        throw RemoteFailure.pairingRejected(code: code, message: object["message"] as? String
            ?? "The Mac did not accept the pairing request.")
    }

    /// Tries the payload's hosts in order. A host key mismatch on any of them
    /// stops pairing: the code came from this Mac's screen, so a different key
    /// means a different machine is answering.
    private func connect(_ payload: PairingPayload, credentials: SSHCredentials) async throws -> RemoteConnection {
        var lastFailure: Error = RemoteFailure.unreachable
        for host in payload.hosts {
            let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(integerLiteral: UInt16(payload.port)))
            do {
                return try await transport.connect(to: endpoint, credentials: credentials)
            } catch let failure as RemoteFailure where failure.isTerminal {
                throw failure
            } catch {
                lastFailure = error
            }
        }
        throw lastFailure
    }

    private func firstLine(of connection: RemoteConnection) async throws -> Data {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                for try await line in connection.lines { return line }
                return nil
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.replyTimeout * 1_000_000_000))
                throw RemoteFailure.handshakeTimeout
            }
            defer { group.cancelAll() }
            guard let line = try await group.next() ?? nil else { throw RemoteFailure.execRejected }
            return line
        }
    }
}
