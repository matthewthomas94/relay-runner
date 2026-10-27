import Foundation
import os
import Security

/// Small secrets and records the app keeps on the device: the device key,
/// the paired Mac. Only the Keychain implementation ships.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(_ account: String) throws
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

/// Generic-password items in the data protection Keychain, readable after the
/// first unlock (so a reconnect works with the phone locked) and never
/// synchronised or migrated to another device.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "com.relayrunner.remote") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    public func write(_ data: Data, account: String) throws {
        try delete(account)
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let items = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    public init() {}

    public func read(_ account: String) throws -> Data? { items.withLock { $0[account] } }
    public func write(_ data: Data, account: String) throws { items.withLock { $0[account] = data } }
    public func delete(_ account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
}
