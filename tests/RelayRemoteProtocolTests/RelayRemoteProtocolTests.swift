import Foundation
import XCTest
@testable import RelayRemoteProtocol

final class RelayRemoteProtocolTests: XCTestCase {
    private func vector(_ name: String) throws -> Any {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Vectors"))
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    private func objects(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(vector(name) as? [[String: Any]])
    }

    func testFrameVectorsRoundTripByteForByte() throws {
        let frames = try objects("frames")
        XCTAssertGreaterThanOrEqual(frames.count, 12)
        var types = Set<String>()
        for entry in frames {
            let name = entry["name"] as! String
            let line = Data((entry["line"] as! String).utf8)
            let frame = try FrameCodec.decode(line)
            types.insert(frame.typeName)
            XCTAssertEqual(frame.direction == .phoneToMac, entry["direction"] as? String == "phone_to_mac", name)
            XCTAssertEqual(try FrameCodec.encode(frame), line + Data([0x0A]), name)
            XCTAssertEqual(try FrameCodec.decode(line + Data([0x0A])), frame, name)
        }
        XCTAssertEqual(types, ["hello", "utterance", "control", "remote_mode", "ack", "ping", "welcome", "accepted",
                               "speech", "speech_audio", "speech_control", "status", "error", "pong"])
    }

    func testInvalidVectorsReportSharedErrorCodes() throws {
        for entry in try objects("invalid") {
            let name = entry["name"] as! String
            XCTAssertThrowsError(try FrameCodec.decode(Data((entry["line"] as! String).utf8)), name) { error in
                XCTAssertEqual((error as? FrameError)?.code, entry["error"] as? String, name)
            }
        }
    }

    func testLineLimitOnEncodeAndDecode() throws {
        let limits = try XCTUnwrap(vector("limits") as? [String: Any])
        let max = limits["max_line_bytes"] as! Int
        XCTAssertEqual(max, RelayRemoteProtocol.maxLineBytes)
        func utterance(textBytes: Int) -> Frame {
            .utterance(Utterance(clientId: limits["pad_client_id"] as! String,
                                 text: String(repeating: "a", count: textBytes),
                                 capturedAt: limits["captured_at"] as! String))
        }
        let overhead = try FrameCodec.encode(utterance(textBytes: 0)).count - 1
        let exact = try FrameCodec.encode(utterance(textBytes: max - overhead))
        XCTAssertEqual(exact.count - 1, max)
        XCTAssertNoThrow(try FrameCodec.decode(exact))
        XCTAssertThrowsError(try FrameCodec.encode(utterance(textBytes: max - overhead + 1))) {
            XCTAssertEqual(($0 as? FrameError)?.code, "line_too_long")
        }
        var over = exact
        over.insert(contentsOf: Data("a".utf8), at: over.index(over.endIndex, offsetBy: -2))
        XCTAssertThrowsError(try FrameCodec.decode(over)) {
            XCTAssertEqual(($0 as? FrameError)?.code, "line_too_long")
        }
    }

    func testAudioDataLimitOnEncodeAndDecode() throws {
        let limits = try XCTUnwrap(vector("limits") as? [String: Any])
        let limit = limits["max_audio_data_bytes"] as! Int
        XCTAssertEqual(limit, RelayRemoteProtocol.maxAudioDataBytes)
        func part(_ bytes: Int) -> Frame {
            .speechAudio(SpeechAudio(seq: 46, part: 0, parts: 1, format: .aac, sampleRate: 24000,
                                     data: String(repeating: "A", count: bytes), last: true))
        }
        let line = try FrameCodec.encode(part(limit))
        XCTAssertLessThan(line.count, RelayRemoteProtocol.maxLineBytes)
        XCTAssertEqual(try FrameCodec.decode(line), part(limit))
        XCTAssertThrowsError(try FrameCodec.encode(part(limit + 1))) {
            XCTAssertEqual(($0 as? FrameError)?.code, "invalid_field")
        }
        let over = Data(String(decoding: line, as: UTF8.self)
            .replacingOccurrences(of: "\"data\":\"", with: "\"data\":\"A").utf8)
        XCTAssertThrowsError(try FrameCodec.decode(over)) {
            XCTAssertEqual(($0 as? FrameError)?.code, "invalid_field")
        }
    }

    func testSeqCounterIsMonotonic() {
        var counter = SeqCounter()
        XCTAssertEqual([counter.next(), counter.next(), counter.next()], [1, 2, 3])
    }

    func testClientIDDeduplicationVectors() throws {
        let vectors = try XCTUnwrap(vector("dedup") as? [String: Any])
        var dedup = ClientIDDeduplicator(window: vectors["window"] as! Int)
        let actual = (vectors["ids"] as! [String]).map { dedup.isDuplicate($0) }
        XCTAssertEqual(actual, vectors["expected_duplicates"] as! [Bool])
    }

    func testReplayVectors() throws {
        for scenario in try objects("replay") {
            let name = scenario["name"] as! String
            var counter = SeqCounter()
            var buffer = ReplayBuffer()
            for step in scenario["steps"] as! [[String: Any]] {
                let at = (step["at"] as? NSNumber)?.doubleValue ?? 0
                switch step["op"] as! String {
                case "send":
                    for _ in 0..<(step["count"] as! Int) {
                        let seq = counter.next()
                        try buffer.record(.status(Status(seq: seq, text: "frame \(seq)")), at: at)
                    }
                case "ack":
                    buffer.ack(step["seq"] as! Int)
                default:
                    let result = buffer.resume(after: step["after"] as? Int, at: at)
                    let expect = step["expect"] as! [String: Any]
                    let seqs = result.frames.compactMap(\.seq)
                    if let first = seqs.first, let last = seqs.last { XCTAssertEqual(seqs, Array(first...last), name) }
                    let range = (expect["replayed_range"] as? [Int]).map { [$0[0], $0[1]] }
                    XCTAssertEqual(seqs.isEmpty ? nil : [seqs.first!, seqs.last!], range, name)
                    XCTAssertEqual(result.dropped, expect["dropped"] as? Bool, name)
                    XCTAssertEqual(result.serverSeq, expect["server_seq"] as? Int, name)
                }
            }
        }
    }

    func testAudioReplayVectors() throws {
        func label(_ frame: Frame) -> String {
            switch frame {
            case .speechAudio(let audio): return "audio \(audio.seq).\(audio.part)"
            default: return "\(frame.typeName) \(frame.seq ?? -1)"
            }
        }
        for scenario in try objects("audio_replay") {
            let name = scenario["name"] as! String
            var counter = SeqCounter()
            var buffer = ReplayBuffer()
            var parts: [Int: Int] = [:]
            for step in scenario["steps"] as! [[String: Any]] {
                let at = (step["at"] as? NSNumber)?.doubleValue ?? 0
                switch step["op"] as! String {
                case "speech":
                    let seq = counter.next()
                    try buffer.record(.speech(Speech(seq: seq, kind: .final, source: .orchestrator,
                                                     text: "frame \(seq)", audio: true)), at: at)
                case "status":
                    let seq = counter.next()
                    try buffer.record(.status(Status(seq: seq, text: "frame \(seq)")), at: at)
                case "audio":
                    let seq = step["seq"] as! Int
                    for _ in 0..<(step["count"] as! Int) {
                        let part = parts[seq, default: 0]
                        parts[seq] = part + 1
                        let audio = SpeechAudio(seq: seq, part: part, parts: 0, format: .aac, sampleRate: 24000,
                                                data: "AAAA")
                        XCTAssertEqual(buffer.attach(audio), step["kept"] as? Bool, name)
                        XCTAssertNil(Frame.speechAudio(audio).seq, name)
                        XCTAssertThrowsError(try buffer.record(.speechAudio(audio), at: 0), name)
                    }
                case "ack":
                    buffer.ack(step["seq"] as! Int)
                default:
                    let result = buffer.resume(after: step["after"] as? Int, at: at)
                    let expect = step["expect"] as! [String: Any]
                    XCTAssertEqual(result.frames.map(label), expect["replayed"] as? [String], name)
                    XCTAssertEqual(result.dropped, expect["dropped"] as? Bool, name)
                    XCTAssertEqual(result.serverSeq, expect["server_seq"] as? Int, name)
                }
            }
        }
    }
}
