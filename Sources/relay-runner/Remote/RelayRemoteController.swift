import CoreImage
import Foundation
import Observation

/// Settings-facing state for Relay Remote: Remote Login detection, the
/// active pairing attempt, and the paired devices read from `authorized_keys`.
@MainActor
@Observable
final class RelayRemoteController {
    static let shared = RelayRemoteController()

    enum RemoteLoginState: Hashable {
        case checking
        case available
        case unavailable
    }

    /// The QR image only; the payload it encodes is never kept.
    struct PairingCode: Hashable {
        let pairingID: UUID
        let image: CGImage
        let expiresAt: Date

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.pairingID == rhs.pairingID }
        func hash(into hasher: inout Hasher) { hasher.combine(pairingID) }
    }

    enum Phase: Hashable {
        case idle
        case starting
        case showingCode(PairingCode)
        case confirming(RelayRemotePairingRequest)
        case finished(RelayRemotePairingOutcome)
    }

    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let fingerprint: String
        let restrictedToNetwork: Bool
    }

    private(set) var remoteLogin = RemoteLoginState.checking
    private(set) var phase = Phase.idle
    private(set) var devices: [Device] = []
    private(set) var errorMessage: String?
    var restrictToNetwork = false

    @ObservationIgnored private let environment: RelayRemoteEnvironment
    @ObservationIgnored private var session: RelayRemotePairingSession?
    @ObservationIgnored private var attempt: UUID?
    @ObservationIgnored private var pendingDecision: CheckedContinuation<RelayRemotePairingDecision, Never>?

    init(environment: RelayRemoteEnvironment = .live) {
        self.environment = environment
    }

    func refresh() async {
        let port = environment.sshPort
        let available = await Task.detached { RemoteLoginProbe.hasSSHBanner(port: port) }.value
        remoteLogin = available ? .available : .unavailable
        reloadDevices()
    }

    func reloadDevices() {
        do {
            let names = RelayRemoteDeviceNames.load(environment: environment)
            devices = try environment.authorizedKeys.deviceKeys().map { key in
                Device(
                    id: key.deviceID,
                    name: names[key.deviceID] ?? key.deviceID,
                    fingerprint: key.publicKey.fingerprint,
                    restrictedToNetwork: key.restrictedToNetwork
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginPairing() {
        guard session == nil else { return }
        let attempt = UUID()
        let session = RelayRemotePairingSession(
            environment: environment,
            confirm: { [weak self] request in
                await self?.requestDecision(request, attempt: attempt) ?? .deny
            },
            onFinish: { [weak self] outcome in
                await self?.pairingFinished(outcome, attempt: attempt)
            }
        )
        self.session = session
        self.attempt = attempt
        errorMessage = nil
        restrictToNetwork = false
        phase = .starting

        Task {
            do {
                let payload = try await session.start()
                let image = RelayRemoteQRCode.image(for: payload.encoded())
                guard self.attempt == attempt else { return }
                guard let image else {
                    await session.cancel()
                    errorMessage = "Couldn't draw the pairing code."
                    return
                }
                phase = .showingCode(PairingCode(
                    pairingID: attempt,
                    image: image,
                    expiresAt: Date().addingTimeInterval(RelayRemotePairingSession.lifetime)
                ))
            } catch {
                guard self.attempt == attempt else { return }
                self.session = nil
                self.attempt = nil
                phase = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelPairing() {
        let session = self.session
        self.session = nil
        attempt = nil
        phase = .idle
        pendingDecision?.resume(returning: .deny)
        pendingDecision = nil
        Task { await session?.cancel() }
    }

    func decide(allow: Bool) {
        pendingDecision?.resume(returning: allow ? .allow(restrictToNetwork: restrictToNetwork) : .deny)
        pendingDecision = nil
    }

    func dismissOutcome() {
        if case .finished = phase { phase = .idle }
    }

    func unpair(_ device: Device) {
        do {
            try RelayRemoteDevices.unpair(deviceID: device.id, environment: environment)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        reloadDevices()
    }

    private func requestDecision(_ request: RelayRemotePairingRequest, attempt: UUID) async -> RelayRemotePairingDecision {
        guard self.attempt == attempt else { return .deny }
        phase = .confirming(request)
        return await withCheckedContinuation { pendingDecision = $0 }
    }

    private func pairingFinished(_ outcome: RelayRemotePairingOutcome, attempt: UUID) {
        guard self.attempt == attempt else { return }
        session = nil
        self.attempt = nil
        pendingDecision?.resume(returning: .deny)
        pendingDecision = nil
        phase = .finished(outcome)
        reloadDevices()
    }
}

enum RelayRemoteQRCode {
    /// Renders `message` as a crisp QR image. The bytes are not retained.
    static func image(for message: Data, scale: CGFloat = 8) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(message, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: output.extent)
    }
}
