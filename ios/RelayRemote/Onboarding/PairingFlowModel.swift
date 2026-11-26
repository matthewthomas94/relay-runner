import Foundation
import Observation
import RelayRemoteKit

/// What the Check step shows about the Mac, read from the pairing code.
struct PairingCheckInfo: Equatable {
    let macName: String
    let detail: String
    /// The first twelve characters of the host key fingerprint, in three groups of four.
    let fingerprintGroups: [String]
    /// `SHA256:` plus the start and the last four characters of the host key.
    let abbreviatedHostKey: String

    init(code: String) throws {
        self.init(payload: try PairingPayload.parse(code))
    }

    init(payload: PairingPayload) {
        let host = payload.hosts.first { $0.lowercased().hasSuffix(".local") } ?? payload.hosts[0]
        let bare = host.lowercased().hasSuffix(".local") ? String(host.dropLast(6)) : host
        self.init(macName: bare.replacingOccurrences(of: "-", with: " "), detail: "\(payload.user) · \(host)",
                  hostKey: payload.hostKeys[0])
    }

    init(macName: String, detail: String, hostKey: String) {
        let body = hostKey.hasPrefix("SHA256:") ? String(hostKey.dropFirst(7)) : hostKey
        let head = Array(body.prefix(12))
        self.macName = macName
        self.detail = detail
        fingerprintGroups = stride(from: 0, to: head.count, by: 4).map { String(head[$0..<min($0 + 4, head.count)]) }
        abbreviatedHostKey = body.count > 16 ? "SHA256:\(body.prefix(12))…\(body.suffix(4))" : "SHA256:\(body)"
    }
}

/// The pairing steps (12–14) as a state machine. Pairing itself is injected:
/// `pairer` gets the code and returns nil once the Mac approved, or a short
/// message saying why it did not. It runs while the Check step waits, so the
/// code's lifetime and Cancel are handled here.
@MainActor
@Observable
final class PairingFlowModel {
    enum Step: Equatable {
        case start
        case scan
        case check(PairingCheckInfo)
    }

    typealias Pairer = @MainActor (String) async -> String?

    static let invalidCodeMessage = "That isn't a Relay Remote pairing code."
    static let expiredMessage = "The pairing code expired. Scan a new one."

    private(set) var step = Step.start
    /// One short line on the Start step: why the last attempt ended.
    private(set) var notice: String?
    /// One short line on the Scan step: why the code was not accepted.
    private(set) var scanError: String?
    private(set) var expiresAt: Date?
    /// Bumped when a code is rejected, so the camera view starts scanning again.
    private(set) var scanAttempt = 0

    @ObservationIgnored private let lifetime: TimeInterval
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pairer: Pairer
    @ObservationIgnored private let onFinished: () -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init(lifetime: TimeInterval = PairingClient.replyTimeout, now: @escaping () -> Date = Date.init,
         pairer: @escaping Pairer, onFinished: @escaping () -> Void) {
        self.lifetime = lifetime
        self.now = now
        self.pairer = pairer
        self.onFinished = onFinished
    }

    func beginScan() {
        notice = nil
        scanError = nil
        step = .scan
    }

    /// A scanned or pasted code. A valid one moves to Check and starts pairing.
    func submit(_ code: String) {
        guard step == .scan else { return }
        let info: PairingCheckInfo
        do {
            info = try PairingCheckInfo(code: code)
        } catch {
            scanError = Self.invalidCodeMessage
            scanAttempt += 1
            return
        }
        scanError = nil
        generation += 1
        let attempt = generation
        expiresAt = now().addingTimeInterval(lifetime)
        step = .check(info)
        let pairing = Task { [weak self, pairer] in
            let failure = await pairer(code)
            self?.pairingEnded(attempt, failure: failure)
        }
        let expiry = Task { [weak self, lifetime] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expired(attempt)
        }
        tasks = [pairing, expiry]
    }

    /// Abandons the attempt and returns to Start.
    func cancel() {
        guard case .check = step else { return }
        invalidate()
        notice = nil
        step = .start
    }

    /// The code's lifetime ran out on screen.
    func expired(_ attempt: Int? = nil) {
        guard case .check = step, attempt == nil || attempt == generation else { return }
        fail(Self.expiredMessage)
    }

    private func pairingEnded(_ attempt: Int, failure: String?) {
        guard attempt == generation, case .check = step else { return }
        if let failure {
            fail(failure)
        } else {
            invalidate()
            onFinished()
        }
    }

    private func fail(_ message: String) {
        invalidate()
        notice = message
        step = .start
    }

    #if DEBUG
    func debugShow(_ step: Step, expiresAt: Date?) {
        self.step = step
        self.expiresAt = expiresAt
    }
    #endif

    private func invalidate() {
        generation += 1
        tasks.forEach { $0.cancel() }
        tasks = []
        expiresAt = nil
    }
}
