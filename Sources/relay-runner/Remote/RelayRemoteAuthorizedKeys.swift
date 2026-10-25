import CryptoKit
import Foundation

// Relay Remote's share of `~/.ssh/authorized_keys` (docs/specs/relay-remote.md,
// Pairing and trust). Relay owns only lines whose comment field is one of its
// markers; every other byte in the file is preserved.

/// The comment marker that ends every `authorized_keys` line Relay owns.
enum RelayRemoteKeyMarker: Equatable, Sendable {
    case device(String)
    case pairing(String)

    static let devicePrefix = "relay-remote:"
    static let pairingPrefix = "relay-remote-pair:"

    var comment: String {
        switch self {
        case .device(let id): return Self.devicePrefix + id
        case .pairing(let id): return Self.pairingPrefix + id
        }
    }
}

enum RelayRemoteIdentifier {
    /// The id alphabet `relay-remote-shell` accepts: 1–128 of `[A-Za-z0-9._-]`.
    static func isValid(_ value: String) -> Bool {
        guard (1...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x2D || c == 0x2E || c == 0x5F
        }
    }
}

/// An OpenSSH public key restricted to the types Relay Remote issues or accepts.
struct SSHPublicKey: Hashable, Sendable {
    static let allowedTypes: Set<String> = ["ssh-ed25519", "ecdsa-sha2-nistp256"]

    let type: String
    let blob: Data

    init(ed25519 publicKey: Curve25519.Signing.PublicKey) {
        type = "ssh-ed25519"
        var blob = Data()
        blob.appendSSHString(Data(type.utf8))
        blob.appendSSHString(publicKey.rawRepresentation)
        self.blob = blob
    }

    /// Parses `"<type> <base64>[ <comment>]"`, checking the blob's structure.
    init?(openSSH text: String) {
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count == 2 || fields.count == 3,
              Self.allowedTypes.contains(String(fields[0])),
              let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        var reader = SSHWireReader(blob)
        guard let embeddedType = reader.string(), String(decoding: embeddedType, as: UTF8.self) == fields[0] else {
            return nil
        }
        switch fields[0] {
        case "ssh-ed25519":
            guard reader.string()?.count == 32 else { return nil }
        default:
            guard reader.string() == Data("nistp256".utf8),
                  let point = reader.string(), point.count == 65, point.first == 0x04 else { return nil }
        }
        guard reader.isAtEnd else { return nil }
        self.type = String(fields[0])
        self.blob = blob
    }

    var openSSH: String { "\(type) \(blob.base64EncodedString())" }

    /// `SHA256:<unpadded base64>`, as `ssh-keygen -l` prints it.
    var fingerprint: String { Self.fingerprint(of: blob) }

    static func fingerprint(of blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }
}

/// Builds the two kinds of line Relay installs.
enum RelayRemoteKeyLine {
    enum BuildError: Error, Equatable {
        case unsupportedShimPath
        case invalidIdentifier
        case invalidNetworkRange
    }

    static func pairing(shim: URL, pairingID: String, key: SSHPublicKey, expiresAt: Date) throws -> String {
        guard RelayRemoteIdentifier.isValid(pairingID) else { throw BuildError.invalidIdentifier }
        let command = try forcedCommand(shim: shim, arguments: "--pair \(pairingID)")
        let expiry = expiryFormatter.string(from: expiresAt)
        return "command=\"\(command)\",restrict,expiry-time=\"\(expiry)\" \(key.openSSH) \(RelayRemoteKeyMarker.pairing(pairingID).comment)"
    }

    static func device(shim: URL, deviceID: String, key: SSHPublicKey, fromRanges: [String] = []) throws -> String {
        guard RelayRemoteIdentifier.isValid(deviceID) else { throw BuildError.invalidIdentifier }
        let command = try forcedCommand(shim: shim, arguments: "--device \(deviceID)")
        var options = "command=\"\(command)\",restrict"
        if !fromRanges.isEmpty {
            guard fromRanges.allSatisfy(isNetworkRange) else { throw BuildError.invalidNetworkRange }
            options += ",from=\"\(fromRanges.joined(separator: ","))\""
        }
        return "\(options) \(key.openSSH) \(RelayRemoteKeyMarker.device(deviceID).comment)"
    }

    /// An address or CIDR, optionally with an IPv6 scope (`fe80::%en0/10`)
    /// that names an interface. No wildcards, negations or separators.
    private static func isNetworkRange(_ range: String) -> Bool {
        let parts = range.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let address = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:/")
        let scope = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/")
        guard !parts[0].isEmpty, parts[0].unicodeScalars.allSatisfy(address.contains) else { return false }
        return parts.count == 1 || (!parts[1].isEmpty && parts[1].unicodeScalars.allSatisfy(scope.contains))
    }

    /// sshd runs `command=` through the login shell, so the shim path is
    /// single-quoted (it lives under "Application Support"). Paths that would
    /// need escaping inside the option are refused rather than escaped.
    private static func forcedCommand(shim: URL, arguments: String) throws -> String {
        let path = shim.path
        guard !path.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" || $0.isNewline }) else {
            throw BuildError.unsupportedShimPath
        }
        return "'\(path)' \(arguments)"
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        return formatter
    }()
}

/// A device line read back from `authorized_keys`.
struct RelayRemoteDeviceKey: Equatable, Sendable {
    let deviceID: String
    let publicKey: SSHPublicKey
    let restrictedToNetwork: Bool
}

enum AuthorizedKeysError: Error, Equatable, LocalizedError {
    case unsafeDirectory(path: String)
    case unsafeFile(path: String)
    case notADirectory(path: String)
    case notARegularFile(path: String)
    case io(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory(let path):
            return "\(path) is writable by other users. sshd ignores keys there, so Relay Remote won't write to it. Run chmod go-w on it, then try again."
        case .unsafeFile(let path):
            return "\(path) is writable by other users. sshd ignores it, so Relay Remote won't write to it. Run chmod go-w on it, then try again."
        case .notADirectory(let path):
            return "\(path) is not a folder."
        case .notARegularFile(let path):
            return "\(path) is a link or special file, so Relay Remote won't replace it."
        case .io(let operation, let code):
            return "Couldn't \(operation) authorized_keys: \(String(cString: strerror(code)))."
        }
    }
}

/// Atomic, marker-scoped access to `<home>/.ssh/authorized_keys`.
struct AuthorizedKeysFile: Sendable {
    let sshDirectory: URL

    init(home: URL) {
        sshDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
    }

    var fileURL: URL { sshDirectory.appendingPathComponent("authorized_keys") }

    /// Every paired device line, in file order.
    func deviceKeys() throws -> [RelayRemoteDeviceKey] {
        guard let data = try read() else { return [] }
        return Self.split(data).lines.compactMap { line in
            let text = String(decoding: line, as: UTF8.self)
            guard let comment = Self.markerComment(of: text),
                  comment.hasPrefix(RelayRemoteKeyMarker.devicePrefix) else { return nil }
            let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard fields.count >= 3,
                  let key = SSHPublicKey(openSSH: "\(fields[fields.count - 3]) \(fields[fields.count - 2])") else { return nil }
            return RelayRemoteDeviceKey(
                deviceID: String(comment.dropFirst(RelayRemoteKeyMarker.devicePrefix.count)),
                publicKey: key,
                restrictedToNetwork: text.contains("from=\"")
            )
        }
    }

    /// Removes the lines carrying `markers` and writes `lines` where the first
    /// of them stood (or at the end). Leaves the file untouched when the
    /// result is unchanged.
    func replace(_ markers: [RelayRemoteKeyMarker], with lines: [String]) throws {
        let comments = Set(markers.map(\.comment))
        try update(removing: { comments.contains($0) }, inserting: lines)
    }

    /// Removes every pairing line, e.g. ones left behind by a crash.
    func removeAllPairingLines() throws {
        try update(removing: { $0.hasPrefix(RelayRemoteKeyMarker.pairingPrefix) }, inserting: [])
    }

    /// Serializes read-modify-write cycles within the app.
    private static let lock = NSLock()

    private func update(removing shouldRemove: (String) -> Bool, inserting newLines: [String]) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let directoryExists = try checkDirectory()
        if !directoryExists {
            guard !newLines.isEmpty else { return }
            try createDirectory()
        }
        let existing = try read()
        if existing == nil, newLines.isEmpty { return }

        let original = existing ?? Data()
        let parsed = Self.split(original)
        var output: [(bytes: Data, terminated: Bool)] = []
        var insertAt: Int?
        for (index, line) in parsed.lines.enumerated() {
            let terminated = index < parsed.lines.count - 1 || parsed.endsWithNewline
            if let comment = Self.markerComment(of: String(decoding: line, as: UTF8.self)), shouldRemove(comment) {
                if insertAt == nil { insertAt = output.count }
                continue
            }
            output.append((line, terminated))
        }
        let inserted = newLines.map { (bytes: Data($0.utf8), terminated: true) }
        output.insert(contentsOf: inserted, at: insertAt ?? output.count)

        var data = Data()
        for (index, line) in output.enumerated() {
            data.append(line.bytes)
            if line.terminated || index < output.count - 1 { data.append(0x0A) }
        }
        guard existing == nil || data != original else { return }
        try writeAtomically(data, mode: existing == nil ? 0o600 : currentFileMode())
    }

    // MARK: Lines

    /// The file's lines without their newlines, and whether the last one had one.
    private static func split(_ data: Data) -> (lines: [Data], endsWithNewline: Bool) {
        guard !data.isEmpty else { return ([], true) }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
        let endsWithNewline = data.last == 0x0A
        if endsWithNewline { lines.removeLast() }
        return (lines, endsWithNewline)
    }

    /// The final field of a key line when it is a Relay marker.
    private static func markerComment(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("#"),
              let last = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).last else { return nil }
        let comment = String(last)
        guard comment.hasPrefix(RelayRemoteKeyMarker.devicePrefix) || comment.hasPrefix(RelayRemoteKeyMarker.pairingPrefix) else {
            return nil
        }
        return comment
    }

    // MARK: File system

    /// Whether `~/.ssh` exists; throws when it is unsafe or not a directory.
    private func checkDirectory() throws -> Bool {
        var info = stat()
        guard stat(sshDirectory.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw AuthorizedKeysError.io(operation: "inspect the folder of", code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw AuthorizedKeysError.notADirectory(path: sshDirectory.path) }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw AuthorizedKeysError.unsafeDirectory(path: sshDirectory.path) }
        return true
    }

    private func createDirectory() throws {
        guard mkdir(sshDirectory.path, 0o700) == 0 || errno == EEXIST else {
            throw AuthorizedKeysError.io(operation: "create the folder for", code: errno)
        }
        // mkdir applies the umask; set the mode sshd expects explicitly.
        guard chmod(sshDirectory.path, 0o700) == 0 else {
            throw AuthorizedKeysError.io(operation: "set the folder mode for", code: errno)
        }
    }

    /// The file's bytes, or nil when it does not exist. Throws when unsafe.
    private func read() throws -> Data? {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw AuthorizedKeysError.io(operation: "inspect", code: errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw AuthorizedKeysError.notARegularFile(path: fileURL.path) }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw AuthorizedKeysError.unsafeFile(path: fileURL.path) }
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            throw AuthorizedKeysError.io(operation: "read", code: errno)
        }
        return data
    }

    private func currentFileMode() -> mode_t {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { return 0o600 }
        return info.st_mode & 0o777
    }

    /// Temporary file in `~/.ssh`, fsync, then rename over the original.
    private func writeAtomically(_ data: Data, mode: mode_t) throws {
        var template = Array(sshDirectory.appendingPathComponent(".authorized_keys.relay-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw AuthorizedKeysError.io(operation: "create a temporary copy of", code: errno) }
        let tempPath = String(cString: template)
        var failure: AuthorizedKeysError?
        let written = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
        if !written {
            failure = .io(operation: "write", code: errno)
        } else if fchmod(fd, mode) != 0 {
            failure = .io(operation: "set the mode of", code: errno)
        } else if fsync(fd) != 0 {
            failure = .io(operation: "flush", code: errno)
        }
        close(fd)
        if failure == nil, rename(tempPath, fileURL.path) != 0 {
            failure = .io(operation: "replace", code: errno)
        }
        if let failure {
            unlink(tempPath)
            throw failure
        }
        let directoryFD = open(sshDirectory.path, O_RDONLY)
        if directoryFD >= 0 {
            fsync(directoryFD)
            close(directoryFD)
        }
    }
}

// MARK: - SSH wire helpers

extension Data {
    mutating func appendSSHString(_ value: Data) {
        var length = UInt32(value.count).bigEndian
        Swift.withUnsafeBytes(of: &length) { append(contentsOf: $0) }
        append(value)
    }
}

struct SSHWireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func string() -> Data? {
        guard data.endIndex - offset >= 4 else { return nil }
        let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        offset += 4
        guard data.endIndex - offset >= length else { return nil }
        defer { offset += length }
        return Data(data[offset..<offset + length])
    }
}
