import dnssd
import Foundation
import Network

/// Finds the paired Mac (docs/specs/relay-remote.md, "Reachability"): first a
/// Bonjour `_ssh._tcp` service on the LAN whose host is the paired Mac's
/// `LocalHostName.local` (macOS Remote Login advertises it, so Relay needs no
/// advertiser), then the stored addresses.
public struct MacEndpointResolver: EndpointProvider {
    public let mac: PairedMac
    public var browseTimeout: Double = 1.5

    public init(mac: PairedMac) {
        self.mac = mac
    }

    public func candidates() async -> [NWEndpoint] {
        var result: [NWEndpoint] = []
        if let host = mac.bonjourHostName,
           let service = await BonjourSSHBrowser.find(hostName: host, timeout: browseTimeout) {
            result.append(service)
        }
        return result + Self.addressEndpoints(for: mac)
    }

    /// When Bonjour did not find the Mac the phone is probably away from home,
    /// so Tailscale addresses come first, then LAN addresses, then `.local`
    /// names (resolved over mDNS, a last resort if browsing was blocked).
    public static func addressEndpoints(for mac: PairedMac) -> [NWEndpoint] {
        let tailscale = mac.hosts.filter(isTailscale)
        let local = mac.hosts.filter { $0.lowercased().hasSuffix(".local") }
        let lan = mac.hosts.filter { !isTailscale($0) && !$0.lowercased().hasSuffix(".local") }
        let port = NWEndpoint.Port(integerLiteral: UInt16(clamping: mac.port))
        return (tailscale + lan + local).map { .hostPort(host: .init($0), port: port) }
    }

    /// Tailscale's CGNAT range 100.64.0.0/10, its IPv6 prefix, or MagicDNS.
    static func isTailscale(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".ts.net") || lower.hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}

/// Browses `_ssh._tcp` and resolves each service's host target, returning the
/// first service whose host is the paired Mac. Everything runs on one queue.
final class BonjourSSHBrowser: @unchecked Sendable {
    private let hostName: String
    private let queue = DispatchQueue(label: "relay-remote.bonjour")
    private var browser: NWBrowser?
    private var resolvers: [HostTargetResolver] = []
    private var resolving: Set<NWEndpoint> = []
    private var continuation: CheckedContinuation<NWEndpoint?, Never>?

    private init(hostName: String) {
        self.hostName = hostName
    }

    static func find(hostName: String, timeout: Double) async -> NWEndpoint? {
        let search = BonjourSSHBrowser(hostName: hostName)
        return await withCheckedContinuation { continuation in
            search.queue.async { search.start(continuation, timeout: timeout) }
        }
    }

    static func matches(hostTarget: String, pairedHost: String) -> Bool {
        func normalized(_ name: String) -> String {
            var lower = name.lowercased()
            while lower.hasSuffix(".") { lower.removeLast() }
            return lower
        }
        return !pairedHost.isEmpty && normalized(hostTarget) == normalized(pairedHost)
    }

    private func start(_ continuation: CheckedContinuation<NWEndpoint?, Never>, timeout: Double) {
        self.continuation = continuation
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [self] state in
            if case .failed = state { finish(nil) }
        }
        browser.browseResultsChangedHandler = { [self] results, _ in
            // Each change reports the full result set; resolve each service once.
            for result in results where resolving.insert(result.endpoint).inserted {
                guard case let .service(name, type, domain, interface) = result.endpoint else { continue }
                let resolver = HostTargetResolver(name: name, type: type, domain: domain,
                                                  interfaceIndex: UInt32(interface?.index ?? 0), queue: queue) { [self] target in
                    if let target, Self.matches(hostTarget: target, pairedHost: hostName) { finish(result.endpoint) }
                }
                resolvers.append(resolver)
                resolver.start()
            }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(nil) }
    }

    private func finish(_ endpoint: NWEndpoint?) {
        guard let continuation else { return }
        self.continuation = nil
        browser?.cancel()
        browser = nil
        resolvers.forEach { $0.cancel() }
        resolvers = []
        continuation.resume(returning: endpoint)
    }
}

/// `DNSServiceResolve` for one service: Network.framework does not expose a
/// Bonjour service's host target, which is what the pairing code records.
final class HostTargetResolver {
    private let name: String
    private let type: String
    private let domain: String
    private let interfaceIndex: UInt32
    private let queue: DispatchQueue
    private let completion: (String?) -> Void
    private var ref: DNSServiceRef?

    init(name: String, type: String, domain: String, interfaceIndex: UInt32, queue: DispatchQueue,
         completion: @escaping (String?) -> Void) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceIndex = interfaceIndex
        self.queue = queue
        self.completion = completion
    }

    /// Call on `queue`; the owner keeps this object alive until `cancel()`.
    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = DNSServiceResolve(&ref, 0, interfaceIndex, name, type, domain, { _, _, _, error, _, target, _, _, _, context in
            guard let context else { return }
            let resolver = Unmanaged<HostTargetResolver>.fromOpaque(context).takeUnretainedValue()
            let host = error == kDNSServiceErr_NoError ? target.map { String(cString: $0) } : nil
            resolver.cancel()
            resolver.completion(host)
        }, context)
        guard status == kDNSServiceErr_NoError, let ref else {
            ref = nil
            completion(nil)
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
    }

    func cancel() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }
}
