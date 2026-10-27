import Foundation

/// What the phone keeps after pairing: who it is to the Mac, where the Mac
/// may be, and the host keys it trusts. Stored in the Keychain; descriptions
/// are redacted because the record holds fingerprints.
public struct PairedMac: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var deviceID: String
    public var deviceName: String
    public var user: String
    public var hosts: [String]
    public var port: Int
    public var hostKeyFingerprints: [String]

    public init(deviceID: String, deviceName: String, user: String, hosts: [String], port: Int,
                hostKeyFingerprints: [String]) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.user = user
        self.hosts = hosts
        self.port = port
        self.hostKeyFingerprints = hostKeyFingerprints
    }

    /// The Mac's `LocalHostName.local`, used to filter Bonjour results.
    public var bonjourHostName: String? {
        hosts.first { $0.lowercased().hasSuffix(".local") }
    }

    public var description: String { "PairedMac(redacted)" }
    public var debugDescription: String { description }
}

public struct PairingStore: Sendable {
    static let account = "paired-mac"
    private let store: SecretStore

    public init(store: SecretStore) {
        self.store = store
    }

    public func load() -> PairedMac? {
        guard let data = try? store.read(Self.account) else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    public func save(_ mac: PairedMac) throws {
        try store.write(try JSONEncoder().encode(mac), account: Self.account)
    }

    public func clear() throws {
        try store.delete(Self.account)
    }
}
