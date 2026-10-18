import Foundation

struct TranscriptAccumulator: Equatable {
    private var committed = ""
    private var live = ""

    var transcript: String {
        Self.join(committed, live)
    }

    var hasTranscript: Bool {
        !transcript.isEmpty
    }

    mutating func reset() {
        committed = ""
        live = ""
    }

    mutating func refine(_ text: String) {
        live = Self.clean(text)
    }

    mutating func commitLiveSegment() {
        committed = Self.join(committed, live)
        live = ""
    }

    static func join(_ previous: String, _ next: String) -> String {
        let previous = clean(previous)
        let next = clean(next)

        guard !previous.isEmpty else { return next }
        guard !next.isEmpty else { return previous }

        let previousWords = words(in: previous)
        let nextWords = words(in: next)
        let previousComparable = previousWords.map { $0.normalized }
        let nextComparable = nextWords.map { $0.normalized }

        // A rollover keeps only 1 s of shared audio, so only a short
        // suffix/prefix can be a re-transcription. Longer matches (or one
        // segment containing the other) are genuinely repeated speech.
        let maxOverlap = min(previousComparable.count, nextComparable.count, maxOverlapWords)
        if maxOverlap > 0 {
            for size in stride(from: maxOverlap, through: 1, by: -1) {
                if Array(previousComparable.suffix(size)) == Array(nextComparable.prefix(size)) {
                    // The earlier segment heard these words with more
                    // context; the later one heard how the sentence ended.
                    let shared = zip(previousWords.suffix(size), nextWords.prefix(size)).map { earlier, later in
                        stripTrailingPunctuation(earlier.raw) + trailingPunctuation(later.raw)
                    }
                    let combinedWords = previousWords.dropLast(size).map { $0.raw } + shared
                        + nextWords.dropFirst(size).map { $0.raw }
                    return combinedWords.joined(separator: " ")
                }
            }
        }

        return previous + " " + next
    }

    private static let maxOverlapWords = 5

    private static func stripTrailingPunctuation(_ word: String) -> String {
        String(word.prefix(word.count - trailingPunctuation(word).count))
    }

    private static func trailingPunctuation(_ word: String) -> String {
        String(word.reversed().prefix { $0.isPunctuation }.reversed())
    }

    private static func clean(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func words(in text: String) -> [(raw: String, normalized: String)] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .map { word in
                (
                    raw: word,
                    normalized: word
                        .lowercased()
                        .trimmingCharacters(in: .punctuationCharacters)
                )
            }
            .filter { !$0.normalized.isEmpty }
    }
}
