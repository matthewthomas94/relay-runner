import Foundation
import RelayRemoteProtocol

/// Splits the exec channel's byte stream into newline-delimited lines and
/// enforces the protocol's 64 KiB line limit, matching `relay-remote-shell`.
public struct LineFramer: Sendable {
    public struct LineTooLong: Error, Equatable {}

    private var buffer = Data()

    public init() {}

    /// Returns every complete line (without its newline); empty lines are skipped.
    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) throws -> [Data] where Bytes.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[buffer.index(after: newline)...])
            guard line.count <= RelayRemoteProtocol.maxLineBytes else { throw LineTooLong() }
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= RelayRemoteProtocol.maxLineBytes else { throw LineTooLong() }
        return lines
    }
}
