import Foundation
import Network
import NIOSSH

/// What a connection needs to authenticate: the SSH user, the device (or
/// pairing) key, and the host key fingerprints pinned at pairing. There is no
/// trust-on-first-use path: an empty pin set refuses every host.
public struct SSHCredentials: Sendable, CustomStringConvertible {
    public var user: String
    public var privateKey: NIOSSHPrivateKey
    public var pinnedHostKeys: Set<String>

    public init(user: String, privateKey: NIOSSHPrivateKey, pinnedHostKeys: Set<String>) {
        self.user = user
        self.privateKey = privateKey
        self.pinnedHostKeys = pinnedHostKeys
    }

    public var description: String { "SSHCredentials(redacted)" }
}

/// One exec channel to the Mac's forced command, carrying NDJSON lines.
public protocol RemoteConnection: AnyObject, Sendable {
    /// Lines from the channel without their newline. The stream finishes when
    /// the channel closes, throwing a `RemoteFailure` when the cause is known.
    var lines: AsyncThrowingStream<Data, Error> { get }
    /// Queues one line (including its newline). Writes keep call order;
    /// a failed write surfaces as the end of `lines`.
    func send(_ line: Data)
    func close()
}

public protocol RemoteTransport: Sendable {
    /// Connects, authenticates and opens the exec channel. Throws
    /// `RemoteFailure.hostKeyMismatch` before anything is sent when the host
    /// key is not pinned.
    func connect(to endpoint: NWEndpoint, credentials: SSHCredentials) async throws -> RemoteConnection
}

/// Where to look for the Mac, best candidate first.
public protocol EndpointProvider: Sendable {
    func candidates() async -> [NWEndpoint]
}

public struct StaticEndpoints: EndpointProvider {
    public var endpoints: [NWEndpoint]

    public init(_ endpoints: [NWEndpoint]) {
        self.endpoints = endpoints
    }

    public func candidates() async -> [NWEndpoint] { endpoints }
}
