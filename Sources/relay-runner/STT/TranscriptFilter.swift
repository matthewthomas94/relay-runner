import Foundation

/// Silence/hallucination filter shared by both command capture loops. Pure,
/// so the Phonon dictation harness replays exactly the production decision.
enum TranscriptFilter {
    static let hallucinations: Set<String> = [
        "", "you", "thank you", "thanks for watching",
        "bye", "the end", "thanks", "thank you for watching",
    ]

    /// Returns the trimmed recognizer text, or nil for empty output and the
    /// known phantom phrases recognizers emit for silence or noise.
    static func meaningfulText(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        guard !hallucinations.contains(lower) else { return nil }
        return text
    }
}
