import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices
import os

/// The first known cause of a connection's end, shared by its handlers.
final class FailureRecorder: Sendable {
    private let state = OSAllocatedUnfairLock<RemoteFailure?>(initialState: nil)

    func record(_ failure: RemoteFailure) {
        state.withLock { current in
            if current == nil { current = failure }
        }
    }

    var failure: RemoteFailure? { state.withLock { $0 } }
}

/// swift-nio-ssh over swift-nio-transport-services (Network.framework), one
/// `session` channel per connection running the Mac's forced command through
/// an `exec` request with no PTY, as RR-420 recommends.
public struct SSHTransport: RemoteTransport {
    public var connectTimeout: TimeAmount = .seconds(8)
    /// TCP connect, key exchange, authentication and the exec reply.
    public var handshakeTimeout: TimeAmount = .seconds(15)
    private let group: NIOTSEventLoopGroup
    private let log: RemoteLogger

    public init(group: NIOTSEventLoopGroup = .singleton, log: RemoteLogger = .system) {
        self.group = group
        self.log = log
    }

    public func connect(to endpoint: NWEndpoint, credentials: SSHCredentials) async throws -> RemoteConnection {
        let failures = FailureRecorder()
        let user = credentials.user
        let key = credentials.privateKey
        let pins = credentials.pinnedHostKeys

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3

        let parent: Channel
        do {
            parent = try await NIOTSConnectionBootstrap(group: group)
                .connectTimeout(connectTimeout)
                .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
                .tcpOptions(tcp)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let configuration = SSHClientConfiguration(
                            userAuthDelegate: PrivateKeyAuthDelegate(user: user, key: key, failures: failures),
                            serverAuthDelegate: PinnedHostKeyValidator(pins: pins, failures: failures)
                        )
                        try channel.pipeline.syncOperations.addHandlers([
                            NIOSSHHandler(role: .client(configuration), allocator: channel.allocator,
                                          inboundChildChannelInitializer: nil),
                            ParentChannelHandler(failures: failures),
                        ])
                    }
                }
                .connect(endpoint: endpoint)
                .get()
        } catch {
            log("tcp connect failed")
            throw RemoteFailure.unreachable
        }

        let timeout = parent.eventLoop.scheduleTask(in: handshakeTimeout) {
            failures.record(.handshakeTimeout)
            parent.close(promise: nil)
        }
        let (lines, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let exec = parent.eventLoop.makePromise(of: Void.self)
        do {
            let child = try await parent.eventLoop.flatSubmit { () -> EventLoopFuture<Channel> in
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                do {
                    let ssh = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(promise, channelType: .session) { child, type in
                        guard type == .session else {
                            return child.eventLoop.makeFailedFuture(RemoteFailure.execRejected)
                        }
                        return child.eventLoop.makeCompletedFuture {
                            // Remote EOF means the forced command exited: close fully.
                            try child.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: false)
                            try child.pipeline.syncOperations.addHandler(
                                ExecChannelHandler(exec: exec, lines: continuation, failures: failures))
                        }
                    }
                } catch {
                    promise.fail(error)
                }
                return promise.futureResult
            }.get()
            // No command: the authorized_keys `command=` runs the helper, which
            // refuses anything but an empty SSH_ORIGINAL_COMMAND or `status`.
            try await child.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ExecRequest(command: "", wantReply: true)).get()
            try await exec.futureResult.get()
            timeout.cancel()
            log("exec channel ready")
            return SSHConnection(parent: parent, child: child, lines: lines)
        } catch {
            timeout.cancel()
            parent.close(promise: nil)
            continuation.finish()
            let failure = failures.failure ?? (error as? RemoteFailure) ?? .unreachable
            // The child channel may never have existed; a completed promise ignores this.
            exec.fail(failure)
            log("ssh setup failed: \(failure.code)")
            throw failure
        }
    }
}

final class SSHConnection: RemoteConnection {
    let lines: AsyncThrowingStream<Data, Error>
    private let parent: Channel
    private let child: Channel

    init(parent: Channel, child: Channel, lines: AsyncThrowingStream<Data, Error>) {
        self.parent = parent
        self.child = child
        self.lines = lines
    }

    func send(_ line: Data) {
        child.writeAndFlush(ByteBuffer(bytes: line), promise: nil)
    }

    func close() {
        parent.close(promise: nil)
    }
}

/// Bridges the exec channel to `lines` and turns outbound buffers into
/// channel data. Standard error is dropped unread: the helper reports
/// failures as `error` frames on standard output.
final class ExecChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private var exec: EventLoopPromise<Void>?
    private let lines: AsyncThrowingStream<Data, Error>.Continuation
    private let failures: FailureRecorder
    private var framer = LineFramer()

    init(exec: EventLoopPromise<Void>, lines: AsyncThrowingStream<Data, Error>.Continuation, failures: FailureRecorder) {
        self.exec = exec
        self.lines = lines
        self.failures = failures
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else { return }
        do {
            for line in try framer.feed(buffer.readableBytesView) {
                lines.yield(line)
            }
        } catch {
            failures.record(.protocolViolation)
            context.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            exec?.succeed(())
            exec = nil
        case is ChannelFailureEvent:
            failures.record(.execRejected)
            exec?.fail(RemoteFailure.execRejected)
            exec = nil
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        exec?.fail(failures.failure ?? RemoteFailure.execRejected)
        exec = nil
        if let failure = failures.failure {
            lines.finish(throwing: failure)
        } else {
            lines.finish()
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(buffer))), promise: promise)
    }
}

/// Closes the connection on SSH errors and on Network.framework path events:
/// an unviable path or a better one (Wi-Fi back from cellular) means a new
/// TCP connection is needed (Apple DTS, forum thread 746449).
final class ParentChannelHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let failures: FailureRecorder

    init(failures: FailureRecorder) {
        self.failures = failures
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let viability = event as? NIOTSNetworkEvents.ViabilityUpdate, !viability.isViable {
            failures.record(.networkChanged)
            context.close(promise: nil)
        } else if event is NIOTSNetworkEvents.BetterPathAvailable {
            failures.record(.networkChanged)
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let failure = error as? RemoteFailure { failures.record(failure) }
        context.close(promise: nil)
    }
}
