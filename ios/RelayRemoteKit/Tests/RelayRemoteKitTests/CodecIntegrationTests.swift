import Foundation
import RelayRemoteProtocol
import XCTest
@testable import RelayRemoteKit

/// The exec channel delivers arbitrary chunks; the framer plus the shared
/// codec must recover exactly the golden frames both protocol suites use.
final class CodecIntegrationTests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let line: String
    }

    private func goldenVectors() throws -> [Vector] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/RelayRemoteProtocolTests/Vectors/frames.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("golden vectors not readable at \(url.path)")
        }
        return try JSONDecoder().decode([Vector].self, from: data)
    }

    func testGoldenFramesSurviveArbitraryChunking() throws {
        let vectors = try goldenVectors()
        XCTAssertGreaterThan(vectors.count, 10)
        var stream = Data()
        for vector in vectors {
            stream.append(Data(vector.line.utf8))
            stream.append(0x0A)
        }
        var generator = SystemRandomNumberGenerator()
        for chunkLimit in [1, 2, 7, 64, 4096] {
            var framer = LineFramer()
            var lines: [Data] = []
            var offset = 0
            while offset < stream.count {
                let size = Int.random(in: 1...chunkLimit, using: &generator)
                let end = min(stream.count, offset + size)
                lines += try framer.feed(stream[offset..<end])
                offset = end
            }
            XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, vectors.map(\.line))
            for (line, vector) in zip(lines, vectors) {
                let frame = try FrameCodec.decode(line)
                XCTAssertEqual(String(decoding: try FrameCodec.encode(frame).dropLast(), as: UTF8.self), vector.line,
                               vector.name)
            }
        }
    }

    func testOversizedLineIsRejectedEvenWithoutANewline() throws {
        var framer = LineFramer()
        XCTAssertThrowsError(try framer.feed([UInt8](repeating: 0x61, count: RelayRemoteProtocol.maxLineBytes + 1)))

        var exact = LineFramer()
        var line = [UInt8](repeating: 0x61, count: RelayRemoteProtocol.maxLineBytes)
        line.append(0x0A)
        XCTAssertEqual(try exact.feed(line).first?.count, RelayRemoteProtocol.maxLineBytes)
    }

    func testEmptyLinesAreSkipped() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.feed(Data("\n\n{\"a\":1}\n\n".utf8)), [Data("{\"a\":1}".utf8)])
    }

    func testFramesTheSessionWritesAreCanonicalLines() throws {
        let hello = Hello(deviceId: "dev", deviceName: "iPhone", appVersion: "0.1", resumeAfterSeq: 41)
        let line = try FrameCodec.encode(.hello(hello))
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(String(decoding: line, as: UTF8.self),
                       #"{"app_version":"0.1","device_id":"dev","device_name":"iPhone","protocol":1,"resume_after_seq":41,"type":"hello"}"# + "\n")
    }
}
