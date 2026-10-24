import Foundation
import SystemConfiguration

/// Where Relay Remote keeps its per-user files and sockets.
struct RelayRemoteEnvironment: Sendable {
    var home: URL
    /// `~/Library/Application Support/relay-runner`
    var supportDirectory: URL
    var pairSocketPath: String
    var hostKeyDirectory: URL
    var sshPort: Int
    var userName: String
    var log: @Sendable (String) -> Void

    static let defaultPairSocketPath = "/tmp/relay_remote_pair.sock"

    static var live: RelayRemoteEnvironment {
        RelayRemoteEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            supportDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("relay-runner", isDirectory: true),
            pairSocketPath: defaultPairSocketPath,
            hostKeyDirectory: URL(fileURLWithPath: "/etc/ssh", isDirectory: true),
            sshPort: 22,
            userName: NSUserName(),
            log: { NSLog("[RelayRemote] %@", $0) }
        )
    }

    var authorizedKeys: AuthorizedKeysFile { AuthorizedKeysFile(home: home) }
    var shimURL: URL { RelayRemoteShim.url(supportDirectory: supportDirectory) }
    var deviceNamesURL: URL { supportDirectory.appendingPathComponent("relay-remote-devices.json") }
}

/// The stable per-user script `authorized_keys` lines point at. It is
/// rewritten at every launch to exec the helper inside the current bundle, so
/// moving or updating the app never changes `authorized_keys`.
enum RelayRemoteShim {
    static func url(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("bin", isDirectory: true).appendingPathComponent("relay-remote-shell")
    }

    static func script(helper: URL) -> String {
        let quoted = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # Written by Relay Runner at launch. Paired Relay Remote devices run this
        # through authorized_keys; it forwards to the helper in the current app.
        exec \(quoted) "$@"

        """
    }

    /// Writes the shim atomically with mode 755, skipping an identical file.
    static func install(helper: URL, at shim: URL) throws {
        let contents = Data(script(helper: helper).utf8)
        if FileManager.default.contents(atPath: shim.path) == contents { return }
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: shim, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    }

    /// The helper built next to the running executable (`Contents/MacOS` in
    /// the bundle, the products directory in development builds).
    static var bundledHelper: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("relay-remote-shell")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }
}

enum RelayRemoteLaunch {
    /// Rewrites the shim and clears pairing lines a crash may have left.
    static func prepare(environment: RelayRemoteEnvironment = .live) {
        if let helper = RelayRemoteShim.bundledHelper {
            do {
                try RelayRemoteShim.install(helper: helper, at: environment.shimURL)
            } catch {
                environment.log("shim install failed: \(error.localizedDescription)")
            }
        }
        do {
            try environment.authorizedKeys.removeAllPairingLines()
        } catch {
            environment.log("stale pairing cleanup skipped: \(error.localizedDescription)")
        }
    }
}

/// Detects Remote Login by reading the SSH banner on loopback.
enum RemoteLoginProbe {
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension")!

    static func hasSSHBanner(port: Int = 22, timeout: TimeInterval = 1.5) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 || errno == EINPROGRESS else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        var connected = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&connected, 1, Int32(timeout * 1000)) > 0,
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
              socketError == 0 else { return false }

        var banner = Data()
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, remaining) > 0 else { return false }
            var chunk = [UInt8](repeating: 0, count: 256)
            let n = recv(fd, &chunk, chunk.count, 0)
            if n < 0, errno == EAGAIN || errno == EINTR { continue }
            guard n > 0 else { return false }
            banner.append(contentsOf: chunk[0..<n])
            if banner.count >= 8 || banner.contains(0x0A) { break }
        }
        return banner.starts(with: Data("SSH-2.0-".utf8))
    }
}

/// Facts about this Mac that go into the pairing code.
enum RelayRemoteHostInfo {
    static let tailscaleRanges = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]

    /// `SHA256:` fingerprints of the Mac's SSH host keys.
    static func hostKeyFingerprints(directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("ssh_host_") && $0.hasSuffix("_key.pub") }
            .sorted()
            .compactMap { name in
                guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { return nil }
                let fields = text.split(whereSeparator: \.isWhitespace)
                guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
                return SSHPublicKey.fingerprint(of: blob)
            }
    }

    /// Bonjour name, then LAN addresses, then the Tailscale address.
    static func hostCandidates() -> [String] {
        var candidates: [String] = []
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            candidates.append("\(local).local")
        }
        let interfaces = ipv4Interfaces()
        candidates += interfaces.filter { !$0.isTailscale }.map(\.address)
        candidates += interfaces.filter(\.isTailscale).map(\.address)
        return candidates
    }

    /// The `from=` ranges for a device restricted to home and Tailscale.
    static func networkRanges() -> [String] {
        var ranges = ipv4Interfaces().filter { !$0.isTailscale }.map(\.cidr)
        ranges += tailscaleRanges
        var seen = Set<String>()
        return ranges.filter { seen.insert($0).inserted }
    }

    struct Interface {
        let address: String
        let cidr: String
        let isTailscale: Bool
    }

    static func ipv4Interfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.ifa_netmask else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let isTailscale = ip & 0xFFC0_0000 == 0x6440_0000
            let isPrivate = ip & 0xFF00_0000 == 0x0A00_0000 || ip & 0xFFF0_0000 == 0xAC10_0000 || ip & 0xFFFF_0000 == 0xC0A8_0000
            guard isTailscale || isPrivate else { continue }
            result.append(Interface(
                address: dotted(ip),
                cidr: "\(dotted(ip & netmask))/\(netmask.nonzeroBitCount)",
                isTailscale: isTailscale
            ))
        }
        return result
    }

    private static func dotted(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }
}
