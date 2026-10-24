import Foundation

/// Errors shared with the Python twin; `code` strings are identical on both sides.
public enum FrameError: Error, Equatable, Sendable {
    case invalidJSON
    case unknownType(String)
    case missingField(String)
    case invalidField(String)
    case lineTooLong(Int)

    public var code: String {
        switch self {
        case .invalidJSON: return "invalid_json"
        case .unknownType: return "unknown_type"
        case .missingField: return "missing_field"
        case .invalidField: return "invalid_field"
        case .lineTooLong: return "line_too_long"
        }
    }
}

/// Newline-delimited JSON codec. Keys are sorted and output is compact so the
/// bytes are canonical and identical to the Python encoder.
public enum FrameCodec {
    /// Returns the frame as one line including the trailing newline.
    public static func encode(_ frame: Frame) throws -> Data {
        try validate(frame)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var line = try encoder.encode(frame)
        guard line.count <= RelayRemoteProtocol.maxLineBytes else {
            throw FrameError.lineTooLong(line.count)
        }
        line.append(0x0A)
        return line
    }

    /// Decodes one line; a single trailing newline is accepted.
    public static func decode(_ line: Data) throws -> Frame {
        var body = line
        if body.last == 0x0A { body.removeLast() }
        guard body.count <= RelayRemoteProtocol.maxLineBytes else {
            throw FrameError.lineTooLong(body.count)
        }
        guard (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else {
            throw FrameError.invalidJSON
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let frame: Frame
        do {
            frame = try decoder.decode(Frame.self, from: body)
        } catch let error as FrameError {
            throw error
        } catch DecodingError.keyNotFound(let key, _) {
            throw FrameError.missingField(key.stringValue)
        } catch DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context),
                DecodingError.dataCorrupted(let context) {
            throw FrameError.invalidField(context.codingPath.last?.stringValue ?? "")
        }
        try validate(frame)
        return frame
    }

    private static func validate(_ frame: Frame) throws {
        switch frame {
        case .utterance(let f): try requireUUID(f.clientId)
        case .control(let f): try requireUUID(f.clientId)
        case .accepted(let f): try requireUUID(f.clientId)
        default: break
        }
    }

    private static func requireUUID(_ value: String) throws {
        guard UUID(uuidString: value) != nil else { throw FrameError.invalidField("client_id") }
    }
}
