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

        if contains(previousComparable, nextComparable) {
            return previous
        }
        if contains(nextComparable, previousComparable) {
            return next
        }

        let maxOverlap = min(previousComparable.count, nextComparable.count)
        if maxOverlap > 0 {
            for size in stride(from: maxOverlap, through: 1, by: -1) {
                if Array(previousComparable.suffix(size)) == Array(nextComparable.prefix(size)) {
                    let combinedWords = previousWords.map { $0.raw } + nextWords.dropFirst(size).map { $0.raw }
                    return combinedWords.joined(separator: " ")
                }
            }
        }

        return previous + " " + next
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

    private static func contains(_ words: [String], _ candidate: [String]) -> Bool {
        guard !candidate.isEmpty else { return true }
        guard candidate.count <= words.count else { return false }

        for start in 0...(words.count - candidate.count) {
            if Array(words[start..<(start + candidate.count)]) == candidate {
                return true
            }
        }
        return false
    }
}
