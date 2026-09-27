import CryptoKit
import Foundation

// Stable digests for pinning MCP payloads that non-Claude clients must keep
// receiving byte for byte. JSON is serialized with sorted keys so dictionary
// ordering cannot change the digest.
func mcpSHA256(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
}

func mcpCanonicalJSONSHA256(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return mcpSHA256(String(decoding: data, as: UTF8.self))
}
