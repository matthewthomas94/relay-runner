#if DEBUG
import Foundation
import Network
import RelayRemoteKit
import RelayRemoteProtocol

/// Debug only (RR-545): a scripted Mac inside the app, for checking reply
/// notifications on the simulator without a paired Mac. `--scripted-mac=<s>`
/// connects to it instead of the paired Mac; it welcomes the phone, answers
/// pings, and every `s` seconds George sends a reply of two `speech` frames,
/// voiced by the Mac, so the phone shows them without playing them.
/// `--scripted-mac-drop=<s>` drops the connection after `s` seconds and then
/// refuses every reconnect, as an unreachable Mac does.
final class ScriptedMac: RemoteTransport, @unchecked Sendable {
    static let mac = PairedMac(deviceID: "scripted-mac", deviceName: "Simulator", user: "me", hosts: ["Mac.local"],
                               port: 22, hostKeyFingerprints: ["SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"])
    static let endpoints = StaticEndpoints([.hostPort(host: "192.0.2.1", port: 22)])

    private let replyEvery: Double
    private let dropAfter: Double?
    private let lock = NSLock()
    private var seq = 0
    private var command = 0
    private var dropped = false

    init(replyEvery: Double, dropAfter: Double?) {
        self.replyEvery = replyEvery
        self.dropAfter = dropAfter
    }

    func connect(to endpoint: NWEndpoint, credentials: SSHCredentials) async throws -> RemoteConnection {
        if lock.withLock({ dropped }) { throw RemoteFailure.unreachable }
        return Connection(mac: self)
    }

    fileprivate func nextReply() -> [Frame] {
        lock.withLock {
            command += 1
            seq += 2
            return [
                .speech(Speech(seq: seq - 1, kind: .handoff, source: .messenger, text: "Checking the release build now.",
                               relayCommandSeq: command, spokenBy: .mac, agent: "george")),
                .speech(Speech(seq: seq, kind: .final, source: .orchestrator,
                               text: "Reply \(command): the build passed and every test is green.",
                               relayCommandSeq: command, spokenBy: .mac, agent: "george")),
            ]
        }
    }

    fileprivate var serverSeq: Int { lock.withLock { seq } }
    fileprivate func drop() { lock.withLock { dropped = true } }

    private final class Connection: RemoteConnection, @unchecked Sendable {
        let lines: AsyncThrowingStream<Data, Error>
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private let mac: ScriptedMac
        private let lock = NSLock()
        private var tasks: [Task<Void, Never>] = []

        init(mac: ScriptedMac) {
            self.mac = mac
            (lines, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        }

        func send(_ line: Data) {
            guard let frame = try? FrameCodec.decode(line) else { return }
            switch frame {
            case .hello:
                deliver(.welcome(Welcome(sessionState: "running", serverSeq: mac.serverSeq, dropped: false)))
                deliver(.sessionState(SessionState(appRunning: true, session: .ready, projectName: "relay-runner",
                                                   activeAgent: "george", runningAgents: ["george"])))
                start()
            case .ping(let ping):
                deliver(.pong(Pong(t: ping.t)))
            default:
                break
            }
        }

        func close() {
            lock.withLock { tasks }.forEach { $0.cancel() }
            continuation.finish()
        }

        private func start() {
            let every = mac.replyEvery
            let replies = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(every))
                    guard !Task.isCancelled, let self else { return }
                    for frame in mac.nextReply() { deliver(frame) }
                }
            }
            var started = [replies]
            if let dropAfter = mac.dropAfter {
                started.append(Task { [weak self] in
                    try? await Task.sleep(for: .seconds(dropAfter))
                    guard !Task.isCancelled, let self else { return }
                    mac.drop()
                    continuation.finish(throwing: RemoteFailure.unreachable)
                })
            }
            lock.withLock { tasks += started }
        }

        private func deliver(_ frame: Frame) {
            guard let line = try? FrameCodec.encode(frame) else { return }
            continuation.yield(line.dropLast())
        }
    }
}
#endif
