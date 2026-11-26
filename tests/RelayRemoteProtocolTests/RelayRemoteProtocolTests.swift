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
        XCTAssertEqual(types, ["hello", "utterance", "control", "remote_mode", "session_command", "ack", "ping",
                               "welcome", "accepted", "speech", "speech_audio", "speech_control", "status",
                               "error", "pong", "session_state"])
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

    func testSessionFramesCarryNoSeqAndDecodeTheirProjects() throws {
        let frames = try objects("frames")
        let line = try XCTUnwrap(frames.first { $0["name"] as? String == "session_state_no_session_with_projects" }?["line"] as? String)
        guard case .sessionState(let state) = try FrameCodec.decode(Data(line.utf8)) else {
            return XCTFail("expected session_state")
        }
        XCTAssertNil(Frame.sessionState(state).seq, "session_state is not replayed")
        XCTAssertTrue(state.appRunning)
        XCTAssertEqual(state.session, .noSession)
        XCTAssertEqual(state.projects?.map(\.displayName), ["relay-runner", "café notes"])
        XCTAssertEqual(state.projects?.map(\.isAvailable), [true, false])
        let command = Frame.sessionCommand(SessionCommand(clientId: UUID().uuidString, action: .start, projectId: "p"))
        XCTAssertNil(command.seq)
        XCTAssertEqual(command.direction, .phoneToMac)
    }

    /// RR-523: a start names its agent; one without it, from an older phone
    /// build, still decodes, and the state reports the active and running agents.
    func testSessionCommandAgentRoundTripsAndStateCarriesAgents() throws {
        let id = "3f2b8a52-6c1e-4f0a-9d57-0b7a1c2e4d10"
        for agent in ["george", nil] {
            let frame = Frame.sessionCommand(SessionCommand(clientId: id, action: .start, projectId: "p", agent: agent))
            let line = try FrameCodec.encode(frame)
            XCTAssertEqual(String(decoding: line, as: UTF8.self).contains("\"agent\""), agent != nil)
            XCTAssertEqual(try FrameCodec.decode(line), frame)
        }
        let frames = try objects("frames")
        func line(_ name: String) throws -> Data {
            Data(try XCTUnwrap(frames.first { $0["name"] as? String == name }?["line"] as? String).utf8)
        }
        guard case .sessionCommand(let older) = try FrameCodec.decode(line("session_command_start")) else {
            return XCTFail("expected session_command")
        }
        XCTAssertNil(older.agent)
        XCTAssertEqual(older.projectId, "6d23b5b1-6da7-4056-b328-7ea8167388c0")
        guard case .sessionCommand(let named) = try FrameCodec.decode(line("session_command_start_agent")) else {
            return XCTFail("expected session_command")
        }
        XCTAssertEqual(named.agent, "george")
        guard case .sessionState(let state) = try FrameCodec.decode(line("session_state_ready_agents")) else {
            return XCTFail("expected session_state")
        }
        XCTAssertEqual(state.activeAgent, "george")
        XCTAssertEqual(state.runningAgents, ["puck", "george"])
        guard case .sessionState(let plain) = try FrameCodec.decode(line("session_state_ready")) else {
            return XCTFail("expected session_state")
        }
        XCTAssertNil(plain.activeAgent)
        XCTAssertNil(plain.runningAgents)
    }

    /// RR-532: agent addressing, per-agent state, the Workspace feed and
    /// settings round-trip byte for byte, as the Rust twin reads them.
    func testExtendedFrameVectorsRoundTripByteForByte() throws {
        var types = Set<String>()
        for entry in try objects("frames_extended") {
            let name = entry["name"] as! String
            let line = Data((entry["line"] as! String).utf8)
            let frame = try FrameCodec.decode(line)
            types.insert(frame.typeName)
            XCTAssertEqual(frame.direction == .phoneToMac, entry["direction"] as? String == "phone_to_mac", name)
            XCTAssertEqual(try FrameCodec.encode(frame), line + Data([0x0A]), name)
            XCTAssertEqual(try FrameCodec.decode(line + Data([0x0A])), frame, name)
        }
        XCTAssertTrue(types.isSuperset(of: ["workspace_command", "workspace_state", "settings_command",
                                            "settings_state"]))
    }

    /// RR-532: the new fields decode as the Mac and phone read them, and the
    /// RR-456 vectors that carry none of them still decode as before.
    func testAgentWorkspaceAndSettingsFieldsDecode() throws {
        let extended = try objects("frames_extended")
        let plain = try objects("frames")
        func frame(_ name: String, in entries: [[String: Any]]) throws -> Frame {
            try FrameCodec.decode(Data(try XCTUnwrap(entries.first { $0["name"] as? String == name }?["line"] as? String).utf8))
        }
        for name in ["utterance_agent", "control_agent", "accepted_agent", "speech_agent", "speech_audio_agent",
                     "speech_control_agent", "status_agent"] {
            XCTAssertNotNil(try frame(name, in: extended).agent, name)
        }
        XCTAssertEqual(try frame("utterance_agent", in: extended).agent, "george")
        for name in ["utterance", "control_stop", "accepted", "speech_final", "speech_audio_first_part",
                     "speech_control", "status", "session_command_start"] {
            XCTAssertNil(try frame(name, in: plain).agent, name)
        }
        guard case .sessionState(let older) = try frame("session_state_ready_agents", in: plain) else {
            return XCTFail("expected session_state")
        }
        XCTAssertNil(older.agents)

        guard case .sessionCommand(let general) = try frame("session_command_start_general", in: extended) else {
            return XCTFail("expected session_command")
        }
        XCTAssertEqual(general.action, .start)
        XCTAssertNil(general.projectId, "no project means general-tasks")
        XCTAssertEqual(general.agent, "sky")

        guard case .sessionState(let state) = try frame("session_state_agents", in: extended) else {
            return XCTFail("expected session_state")
        }
        XCTAssertEqual(state.agents?.map(\.agent), RelayRemoteProtocol.agents)
        XCTAssertEqual(state.agents?.map(\.state), [.working, .off, .playing, .listening])
        XCTAssertEqual(state.agents?.first?.workingOn, "RR-120 review")
        XCTAssertNil(state.agents?[1].workingOn)

        guard case .workspaceState(let workspace) = try frame("workspace_state", in: extended) else {
            return XCTFail("expected workspace_state")
        }
        XCTAssertEqual(workspace.projects.map(\.name), ["relay-runner", "general-tasks"])
        XCTAssertEqual(workspace.tickets.map(\.status), [.inProgress, .queued, .backlog])
        XCTAssertEqual(workspace.tickets.map(\.agent), ["puck", nil, "sky"])
        XCTAssertNil(workspace.error)
        XCTAssertNil(Frame.workspaceState(workspace).seq, "workspace_state is not replayed")

        guard case .settingsCommand(let set) = try frame("settings_command_set", in: extended) else {
            return XCTFail("expected settings_command")
        }
        XCTAssertEqual(set, SettingsCommand(clientId: "3f2b8a52-6c1e-4f0a-9d57-0b7a1c2e4d10", action: .set,
                                            speechSpeedPercent: 150, model: "sonnet"))
        guard case .settingsState(let settings) = try frame("settings_state", in: extended) else {
            return XCTFail("expected settings_state")
        }
        XCTAssertEqual(settings.speechSpeedPercent, 130)
        XCTAssertEqual(settings.modelOptions?.map(\.value), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(settings.sizingOptions?.last, SettingOption(value: "user_default", label: "Use my defaults"))
        guard case .settingsState(let unsupported) = try frame("settings_state_unsupported", in: extended) else {
            return XCTFail("expected settings_state")
        }
        XCTAssertEqual(unsupported, SettingsState(error: "Settings cannot be changed from the phone on this Mac yet."))
        XCTAssertEqual(Frame.settingsCommand(set).direction, .phoneToMac)
        XCTAssertEqual(Frame.workspaceCommand(WorkspaceCommand(clientId: set.clientId)).direction, .phoneToMac)
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
