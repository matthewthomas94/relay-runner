import Foundation

/// RR-443: resolves a spoken project name against the project registry.
/// Read-only: it ranks registry records and never mutates anything. Names
/// compare without case, diacritics, spaces or punctuation, so "relay runner"
/// finds `relay-runner`.
enum ProjectNameMatcher {
    enum Tier: String {
        case exact, folder, fuzzy
    }

    enum Status: String {
        case exact, folder, fuzzy, ambiguous, none
    }

    struct Candidate: Equatable {
        let projectID: String
        let displayName: String
        let repoPath: String
        let selectedPath: String

        init(projectID: String, displayName: String, repoPath: String, selectedPath: String? = nil) {
            self.projectID = projectID
            self.displayName = displayName
            self.repoPath = repoPath
            self.selectedPath = selectedPath ?? repoPath
        }

        init(_ project: RegisteredProjectV2) {
            self.init(projectID: project.projectID, displayName: project.displayName,
                      repoPath: project.lastResolvedPath, selectedPath: project.selectedPath)
        }
    }

    struct Match: Equatable {
        let candidate: Candidate
        let tier: Tier
        let score: Double
    }

    struct Result: Equatable {
        let status: Status
        let matches: [Match]
    }

    static let fuzzyThreshold = 0.75
    /// A fuzzy winner must lead the runner-up by this much to stand alone.
    static let fuzzyMargin = 0.1
    static let maxMatches = 5

    /// Spoken filler around a name: "the relay runner project".
    private static let leadingFiller: Set<String> = ["the", "my", "a"]
    private static let trailingFiller: Set<String> = ["project", "repo", "repository", "folder"]

    static func match(_ spoken: String, in candidates: [Candidate]) -> Result {
        let query = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.hasPrefix("/") || query.hasPrefix("~") {
            let path = normalizedPath(query)
            let hits = candidates.filter { normalizedPath($0.repoPath) == path || normalizedPath($0.selectedPath) == path }
            return resolve(exact: hits, folder: [], fuzzy: [])
        }
        let variants = queryVariants(query)
        guard !variants.isEmpty else { return Result(status: .none, matches: []) }
        let compactVariants = Set(variants.map { $0.joined() })

        var exact: [Candidate] = []
        var folder: [Candidate] = []
        var fuzzy: [(Candidate, Double)] = []
        for candidate in candidates {
            let name = tokens(candidate.displayName)
            let folders = [candidate.repoPath, candidate.selectedPath].map { tokens(URL(fileURLWithPath: $0).lastPathComponent) }
            if candidate.projectID.caseInsensitiveCompare(query) == .orderedSame
                || compactVariants.contains(name.joined()) {
                exact.append(candidate)
            } else if folders.contains(where: { compactVariants.contains($0.joined()) }) {
                folder.append(candidate)
            } else {
                let score = variants.flatMap { variant in
                    ([name] + folders).map { similarity(variant, $0) }
                }.max() ?? 0
                if score >= fuzzyThreshold { fuzzy.append((candidate, score)) }
            }
        }
        return resolve(exact: exact, folder: folder, fuzzy: fuzzy)
    }

    private static func resolve(exact: [Candidate], folder: [Candidate], fuzzy: [(Candidate, Double)]) -> Result {
        if !exact.isEmpty {
            return Result(status: exact.count == 1 ? .exact : .ambiguous,
                          matches: exact.prefix(maxMatches).map { Match(candidate: $0, tier: .exact, score: 1) })
        }
        if !folder.isEmpty {
            return Result(status: folder.count == 1 ? .folder : .ambiguous,
                          matches: folder.prefix(maxMatches).map { Match(candidate: $0, tier: .folder, score: 1) })
        }
        let ranked = fuzzy.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.displayName < $1.0.displayName }
        guard let top = ranked.first else { return Result(status: .none, matches: []) }
        let close = ranked.filter { top.1 - $0.1 < fuzzyMargin }
        return Result(status: close.count == 1 ? .fuzzy : .ambiguous,
                      matches: close.prefix(maxMatches).map { Match(candidate: $0.0, tier: .fuzzy, score: $0.1) })
    }

    /// The spoken words, and the words without filler such as "the … project".
    private static func queryVariants(_ query: String) -> [[String]] {
        let words = tokens(query)
        guard !words.isEmpty else { return [] }
        var trimmed = words[...]
        if trimmed.count > 1, let first = trimmed.first, leadingFiller.contains(first) { trimmed = trimmed.dropFirst() }
        if trimmed.count > 1, let last = trimmed.last, trailingFiller.contains(last) { trimmed = trimmed.dropLast() }
        return Array(trimmed) == words ? [words] : [words, Array(trimmed)]
    }

    /// Lowercased alphanumeric words with case, width and diacritics folded.
    /// camelCase splits are not needed: comparisons use the joined form.
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Edit-distance ratio on the joined words, raised for a contained name
    /// ("runner" in "relay-runner") so a partial spoken name still surfaces.
    private static func similarity(_ query: [String], _ key: [String]) -> Double {
        let a = query.joined(), b = key.joined()
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let ratio = 1 - Double(levenshtein(Array(a), Array(b))) / Double(max(a.count, b.count))
        let contained = a.count >= 3 && (Set(query).isSubset(of: Set(key)) || (a.count >= 4 && b.contains(a)))
        return contained ? max(ratio, 0.8) : ratio
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// RR-443: registering a project the user named by voice. The folder comes
/// only from the shared picker; there is no default location. Registration
/// calls the same registry operations as Add existing project and Create new
/// project, so the records are identical.
enum VoiceProjectRegistration {
    enum Kind: String {
        case existing, new
    }

    struct Request: Equatable {
        let kind: Kind
        /// New projects only: the folder created inside the picked parent.
        let name: String?
    }

    enum RequestError: Error, CustomStringConvertible, Equatable {
        case missingUserAnswer
        case invalidKind
        case nameRequired
        case nameNotAllowed
        case invalidName

        var description: String {
            switch self {
            case .missingUserAnswer:
                return "register_project needs the user's answer from the current turn. Ask whether the project is an existing folder or a new project, end your turn, and call it with their words once they answer."
            case .invalidKind:
                return "kind must be existing or new."
            case .nameRequired:
                return "A new project needs the name the user gave it."
            case .nameNotAllowed:
                return "An existing project keeps its folder name, as Add existing project does; omit name."
            case .invalidName:
                return "The project name must be one folder name: no slashes, colons, control characters or leading dot."
            }
        }
    }

    static func request(kind rawKind: String?, name rawName: String?, userAnswer: String?) throws -> Request {
        guard let answer = userAnswer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
            throw RequestError.missingUserAnswer
        }
        guard let rawKind, let kind = Kind(rawValue: rawKind) else { throw RequestError.invalidKind }
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .existing:
            guard name?.isEmpty ?? true else { throw RequestError.nameNotAllowed }
            return Request(kind: .existing, name: nil)
        case .new:
            guard let name, !name.isEmpty else { throw RequestError.nameRequired }
            guard name.utf8.count <= 255, !name.hasPrefix("."),
                  !name.contains("/"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw RequestError.invalidName
            }
            return Request(kind: .new, name: name)
        }
    }

    /// The picker prompt. It names no folder: the user chooses every location.
    static func pickerMessage(for request: Request) -> String {
        switch request.kind {
        case .existing: return "Choose an existing project folder"
        case .new: return "Choose the folder to create “\(request.name ?? "")” in"
        }
    }

    /// Register the folder the user picked: the existing folder itself, or a
    /// new folder named `request.name` inside the picked parent.
    static func register(
        _ request: Request,
        pickedFolder: URL,
        registry: ProjectRegistryV2Service
    ) throws -> RegisteredProjectV2 {
        switch request.kind {
        case .existing:
            return try registry.registerExistingProject(at: pickedFolder)
        case .new:
            guard let name = request.name else { throw RequestError.nameRequired }
            let target = pickedFolder.standardizedFileURL.appendingPathComponent(name, isDirectory: true)
            return try registry.createProject(at: target)
        }
    }
}
