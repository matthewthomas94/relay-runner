import CryptoKit
import Foundation
import NIOSSH
import Security

/// The phone's permanent SSH identity. A Secure Enclave P-256 key when
/// `SecureEnclave.isAvailable` (`ecdsa-sha2-nistp256` in `authorized_keys`),
/// otherwise an Ed25519 key kept in the Keychain. Only the public half is
/// ever exported; descriptions are redacted.
public struct DeviceKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Sendable {
        case secureEnclaveP256 = "secure-enclave-p256"
        case ed25519
    }

    public let kind: Kind
    public let privateKey: NIOSSHPrivateKey

    /// The OpenSSH public key line the Mac installs.
    public var openSSHPublicKey: String { String(openSSHPublicKey: privateKey.publicKey) }

    /// For the pairing and settings screens only; never logged.
    public var fingerprint: String { SSHFingerprint.sha256(privateKey.publicKey) }

    public var description: String { "DeviceKey(\(kind.rawValue), redacted)" }
    public var debugDescription: String { description }
}

public enum DeviceKeyStore {
    static let secureEnclaveAccount = "device-key.secure-enclave-p256"
    static let ed25519Account = "device-key.ed25519"

    /// Loads the stored key, or creates one. A Secure Enclave key is stored
    /// as its `dataRepresentation`, a blob only this device's enclave can use.
    public static func loadOrCreate(in store: SecretStore,
                                    secureEnclaveAvailable: Bool = SecureEnclave.isAvailable) throws -> DeviceKey {
        if let blob = try store.read(secureEnclaveAccount) {
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
            return DeviceKey(kind: .secureEnclaveP256, privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key))
        }
        if let raw = try store.read(ed25519Account) {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            return DeviceKey(kind: .ed25519, privateKey: NIOSSHPrivateKey(ed25519Key: key))
        }
        if secureEnclaveAvailable, let key = try? makeSecureEnclaveKey() {
            try store.write(key.dataRepresentation, account: secureEnclaveAccount)
            return DeviceKey(kind: .secureEnclaveP256, privateKey: NIOSSHPrivateKey(secureEnclaveP256Key: key))
        }
        let key = Curve25519.Signing.PrivateKey()
        try store.write(key.rawRepresentation, account: ed25519Account)
        return DeviceKey(kind: .ed25519, privateKey: NIOSSHPrivateKey(ed25519Key: key))
    }

    /// Usable after the first unlock so a locked phone can still reconnect.
    private static func makeSecureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
    }
}
