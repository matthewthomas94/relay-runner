import CryptoKit
import Foundation
import NIOCore
import NIOSSH

public enum SSHFingerprint {
    /// `SHA256:<unpadded base64>` of the key blob, the form `ssh-keygen -l`
    /// prints and the Mac's pairing code carries. Shown in the UI only.
    public static func sha256(_ key: NIOSSHPublicKey) -> String {
        let fields = String(openSSHPublicKey: key).split(separator: " ")
        let blob = fields.count >= 2 ? Data(base64Encoded: String(fields[1])) ?? Data() : Data()
        return "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Accepts only host keys whose fingerprint was pinned at pairing. swift-nio-ssh
/// calls this after verifying the server's key-exchange signature and before
/// user authentication, so a refusal means nothing was sent.
final class PinnedHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let pins: Set<String>
    private let failures: FailureRecorder

    init(pins: Set<String>, failures: FailureRecorder) {
        self.pins = pins
        self.failures = failures
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if pins.contains(SSHFingerprint.sha256(hostKey)) {
            validationCompletePromise.succeed(())
        } else {
            failures.record(.hostKeyMismatch)
            validationCompletePromise.fail(RemoteFailure.hostKeyMismatch)
        }
    }
}

/// Offers the one private key once. A second request means sshd refused it.
final class PrivateKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let user: String
    private let key: NIOSSHPrivateKey
    private let failures: FailureRecorder
    private var offered = false

    init(user: String, key: NIOSSHPrivateKey, failures: FailureRecorder) {
        self.user = user
        self.key = key
        self.failures = failures
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, availableMethods.contains(.publicKey) else {
            failures.record(.authenticationRejected)
            nextChallengePromise.fail(RemoteFailure.authenticationRejected)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}
