import Foundation

private struct ProgramDashboardResponse: Decodable {
    let summary: ProgramStatusResponse
    let backlog: ProgramStatusResponse
    let ready: ProgramStatusResponse
    let inProgress: ProgramStatusResponse
    let done: ProgramStatusResponse
    let awaitingMerge: ProgramStatusResponse

    var snapshot: ProgramDashboardSnapshot {
        ProgramDashboardSnapshot(
            summary: summary,
            backlogWork: backlog,
            readyWork: ready,
            inProgressWork: inProgress,
            doneWork: done,
            awaitingMerge: awaitingMerge
        )
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case backlog
        case ready
        case inProgress = "in_progress"
        case done
        case awaitingMerge = "awaiting_merge"
    }
}

private struct SpikeFollowupBatchResponse: Decodable {
    let batch: SpikeFollowupBatch
}

private struct ArtifactBoardClaimResponse: Decodable {
    let prefix: String
    let id: Int
}

private struct ArtifactBoardTicketResponse: Decodable {
    let markdownBase64: String

    private enum CodingKeys: String, CodingKey {
        case markdownBase64 = "markdown_base64"
    }
}

private final class BlockingHTTPResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<(Data, URLResponse), Error>?

    func set(_ value: Result<(Data, URLResponse), Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Result<(Data, URLResponse), Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct SpikeFollowupBatch: Decodable, Equatable, Identifiable {
    let id: String
    let originRepoPath: String
    let originTicketID: String
    let originRunID: Int
    let proposals: [SpikeFollowupProposal]

    private enum CodingKeys: String, CodingKey {
        case id
        case originRepoPath = "origin_repo_path"
        case originTicketID = "origin_ticket_id"
        case originRunID = "origin_run_id"
        case proposals
    }
}

struct SpikeFollowupProposal: Decodable, Equatable, Identifiable {
    let id: String
    let state: String
    let draft: SpikeFollowupDraft
    let ticketID: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case id, state, draft, error
        case ticketID = "ticket_id"
    }
}

struct SpikeFollowupDraft: Decodable, Equatable {
    let title: String
    let description: String
    let acceptanceCriteria: [String]
    let priority: String
    let dependsOn: [String]
    let workerModel: String
    let workerEffort: String
    let workerSizingRationale: String
    let workerProviderNotes: String
    let targetRepoPath: String

    private enum CodingKeys: String, CodingKey {
        case title, description, priority
        case acceptanceCriteria = "acceptance_criteria"
        case dependsOn = "depends_on"
        case workerModel = "worker_model"
        case workerEffort = "worker_effort"
        case workerSizingRationale = "worker_sizing_rationale"
        case workerProviderNotes = "worker_provider_notes"
        case targetRepoPath = "target_repo_path"
    }
}

/// Fire-and-forget HTTP client for triggering orchestrator dispatches from
/// the menu-bar app. Mirrors the port-discovery logic in the relay-orchestrator-mcp
/// target's HTTPClient — they live in separate Swift modules and can't share
/// code without restructuring the package.
///
/// The daemon writes its bound port to `/tmp/relay_orchestrator.port` at startup.
/// We re-read on every request so a daemon restart on a different port doesn't
/// strand us. Failures are logged via NSLog; the board never blocks on them.
enum OrchestratorClient {

    private static let portFile = "/tmp/relay_orchestrator.port"
    private static let defaultPort = 7634
    private static let artifactReadTimeout: TimeInterval = 120
    private static let artifactMutationTimeout: TimeInterval = 600
    static let programDashboardConnectionRetryDelaysNanoseconds: [UInt64] = [
        150_000_000,
        300_000_000,
        600_000_000,
        1_000_000_000,
        1_500_000_000,
        2_000_000_000,
        2_000_000_000,
        2_000_000_000,
        3_000_000_000,
        3_000_000_000,
        5_000_000_000,
    ]

    /// Dispatch a ticket. Returns immediately; the request runs on URLSession's
    /// own queue. The daemon's `find_active` makes this idempotent — re-dispatching
    /// a ticket that's already running just returns `already_active: true`.
    static func dispatchTicket(
        ticketId: String,
        repoPath: String,
        source: String = "board-ready-transition",
        projectScopeToken: String? = nil
    ) {
        guard let req = dispatchRequest(
            ticketId: ticketId,
            repoPath: repoPath,
            source: source,
            port: readPort(),
            projectScopeToken: projectScopeToken
        ) else {
            NSLog("[orchestrator-client] could not build dispatch request for \(ticketId)")
            return
        }
        post(req, label: "dispatch \(ticketId)")
    }

    static func claimArtifactTicketID(
        repoPath: String,
        projectScopeToken: String?
    ) throws -> (prefix: String, id: Int) {
        let payload = artifactPayload(
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
        let data = try synchronousPost(
            path: "/v1/artifacts/tickets/claim-next-id",
            payload: payload
        )
        let response = try decode(ArtifactBoardClaimResponse.self, from: data)
        return (response.prefix, response.id)
    }

    static func writeArtifactTicket(
        repoPath: String,
        ticketID: String,
        markdown: String,
        projectScopeToken: String?
    ) throws -> String {
        var payload = artifactPayload(
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
        payload["ticket_id"] = ticketID
        payload["markdown_base64"] = Data(markdown.utf8).base64EncodedString()
        let data = try synchronousPost(
            path: "/v1/artifacts/tickets/write",
            payload: payload
        )
        let response = try decode(ArtifactBoardTicketResponse.self, from: data)
        guard let stored = Data(base64Encoded: response.markdownBase64),
              let value = String(data: stored, encoding: .utf8) else {
            throw OrchestratorClientError.decodeFailed("Artifact ticket bytes are not UTF-8.")
        }
        return value
    }

    static func deleteArtifactTicket(
        repoPath: String,
        ticketID: String,
        projectScopeToken: String?
    ) throws {
        var payload = artifactPayload(
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
        payload["ticket_id"] = ticketID
        _ = try synchronousPost(path: "/v1/artifacts/tickets/delete", payload: payload)
    }

    static func writeArtifactAttachment(
        repoPath: String,
        ticketID: String,
        filename: String,
        mimeType: String,
        content: Data,
        projectScopeToken: String?
    ) throws {
        var payload = artifactPayload(
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
        payload["ticket_id"] = ticketID
        payload["filename"] = filename
        payload["mime_type"] = mimeType
        payload["content_base64"] = content.base64EncodedString()
        _ = try synchronousPost(path: "/v1/artifacts/attachments/write", payload: payload)
    }

    static func artifactRequest(
        path: String,
        repoPath: String,
        projectScopeToken: String?,
        values: [String: Any] = [:],
        port: Int
    ) -> URLRequest? {
        var payload = artifactPayload(
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
        for (key, value) in values { payload[key] = value }
        return postRequest(path: path, payload: payload, port: port)
    }

    static func artifactGetRequest(
        path: String,
        repoPath: String,
        projectScopeToken: String?,
        values: [URLQueryItem] = [],
        port: Int
    ) -> URLRequest? {
        var query = [URLQueryItem(name: "repo_path", value: repoPath)]
        if let projectScopeToken, !projectScopeToken.isEmpty {
            query.append(URLQueryItem(name: "project_scope_token", value: projectScopeToken))
        }
        query.append(contentsOf: values)
        return getRequest(
            path: path,
            query: query,
            port: port,
            timeout: artifactReadTimeout
        )
    }

    static func artifactPostRequest(
        path: String,
        payload: [String: Any],
        port: Int
    ) -> URLRequest? {
        postRequest(
            path: path,
            payload: payload,
            port: port,
            timeout: artifactMutationTimeout
        )
    }

    static func fetchArtifactHistory(
        repoPath: String,
        query: String,
        projectScopeToken: String?
    ) async throws -> ArtifactHistorySearchResponse {
        try await artifactGet(
            ArtifactHistorySearchResponse.self,
            path: "/v1/artifacts/history/search",
            repoPath: repoPath,
            projectScopeToken: projectScopeToken,
            values: [URLQueryItem(name: "query", value: query)]
        )
    }

    static func fetchArtifactHistoryDetail(
        repoPath: String,
        artifactID: String,
        online: Bool,
        confirmGitHubExposure: Bool,
        projectScopeToken: String?
    ) async throws -> ArtifactHistoryDetailResponse {
        try await artifactGet(
            ArtifactHistoryDetailResponse.self,
            path: "/v1/artifacts/history/\(pathComponent(artifactID))",
            repoPath: repoPath,
            projectScopeToken: projectScopeToken,
            values: [
                URLQueryItem(name: "online", value: online ? "true" : "false"),
                URLQueryItem(
                    name: "confirm_github_exposure",
                    value: confirmGitHubExposure ? "true" : "false"
                ),
            ]
        )
    }

    static func fetchArtifactDependencySummary(
        repoPath: String,
        ticketID: String,
        projectScopeToken: String?
    ) async throws -> ArtifactDependencySummary {
        try await artifactGet(
            ArtifactDependencySummary.self,
            path: "/v1/artifacts/dependencies/\(pathComponent(ticketID))",
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
    }

    static func fetchArtifactRetentionStatus(
        repoPath: String,
        projectScopeToken: String?
    ) async throws -> ArtifactRetentionStatus {
        try await artifactGet(
            ArtifactRetentionStatus.self,
            path: "/v1/artifacts/retention/status",
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
    }

    static func fetchArtifactStorageMetrics(
        repoPath: String,
        projectScopeToken: String?
    ) async throws -> ArtifactStorageMetrics {
        try await artifactGet(
            ArtifactStorageMetrics.self,
            path: "/v1/artifacts/storage",
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
    }

    static func restoreArtifactHistory(
        repoPath: String,
        artifactID: String,
        reopen: Bool,
        online: Bool,
        confirmGitHubExposure: Bool,
        projectScopeToken: String?
    ) async throws -> ArtifactOperationResponse {
        var values: [String: Any] = [
            "artifact_id": artifactID,
            "request_id": UUID().uuidString,
            "online": online,
            "confirm_github_exposure": confirmGitHubExposure,
        ]
        if let projectScopeToken, !projectScopeToken.isEmpty {
            values["project_scope_token"] = projectScopeToken
        }
        values["repo_path"] = repoPath
        return try await artifactPost(
            ArtifactOperationResponse.self,
            path: "/v1/artifacts/history/\(pathComponent(artifactID))/\(reopen ? "reopen" : "restore")",
            payload: values
        )
    }

    static func applyArtifactRetention(
        repoPath: String,
        retry: Bool,
        confirmGitHubExposure: Bool,
        projectScopeToken: String?
    ) async throws -> ArtifactOperationResponse {
        var payload = artifactPayload(
            repoPath: repoPath,
            projectScopeToken: projectScopeToken
        )
        payload["confirm_github_exposure"] = confirmGitHubExposure
        return try await artifactPost(
            ArtifactOperationResponse.self,
            path: retry
                ? "/v1/artifacts/retention/retry"
                : "/v1/artifacts/retention/apply",
            payload: payload
        )
    }

    /// Ask the daemon to scan the active repo and dispatch eligible queued tickets.
    /// This is intentionally repo-scoped and provider-neutral: the daemon still
    /// creates workers through the same dispatch path as board drag/save.
    static func sweepReadyTickets(
        repoPath: String,
        trigger: String,
        projectScopeToken: String? = nil
    ) {
        guard let req = readySweepRequest(
            repoPath: repoPath,
            trigger: trigger,
            port: readPort(),
            projectScopeToken: projectScopeToken
        ) else {
            NSLog("[orchestrator-client] could not build ready-sweep request for \(repoPath)")
            return
        }
        post(req, label: "ready-sweep")
    }

    /// Ask the daemon to scan every registered project and dispatch eligible
    /// queued tickets without opening each repo individually.
    static func sweepProgramReadyTickets(trigger: String) {
        guard let req = programReadySweepRequest(trigger: trigger, port: readPort()) else {
            NSLog("[orchestrator-client] could not build program ready-sweep request")
            return
        }
        post(req, label: "program-ready-sweep")
    }

    static func dispatchRequest(
        ticketId: String,
        repoPath: String,
        source: String,
        port: Int,
        projectScopeToken: String? = nil
    ) -> URLRequest? {
        var payload: [String: Any] = [
            "ticket_id": ticketId,
            "repo_path": repoPath,
            "source": source,
        ]
        if let projectScopeToken, !projectScopeToken.isEmpty {
            payload["project_scope_token"] = projectScopeToken
        }
        return postRequest(path: "/v1/runs", payload: payload, port: port)
    }

    static func readySweepRequest(
        repoPath: String,
        trigger: String,
        port: Int,
        projectScopeToken: String? = nil
    ) -> URLRequest? {
        var payload: [String: Any] = [
            "repo_path": repoPath,
            "trigger": trigger,
        ]
        if let projectScopeToken, !projectScopeToken.isEmpty {
            payload["project_scope_token"] = projectScopeToken
        }
        return postRequest(path: "/v1/ready-sweep", payload: payload, port: port)
    }

    static func programReadySweepRequest(trigger: String, port: Int) -> URLRequest? {
        postRequest(
            path: "/v1/program/ready-sweep",
            payload: ["trigger": trigger],
            port: port
        )
    }

    static func proposeSpikeFollowupsRequest(
        originRepoPath: String,
        originTicketID: String,
        originRunID: Int,
        port: Int
    ) -> URLRequest? {
        postRequest(
            path: "/v1/spikes/follow-ups/propose",
            payload: [
                "origin_repo_path": originRepoPath,
                "origin_ticket_id": originTicketID,
                "origin_run_id": originRunID,
            ],
            port: port
        )
    }

    static func reviewSpikeFollowupRequest(
        batchID: String,
        proposalID: String,
        decision: String,
        updates: [String: Any]? = nil,
        port: Int
    ) -> URLRequest? {
        var payload: [String: Any] = ["decision": decision]
        if let updates { payload["updates"] = updates }
        return postRequest(
            path: "/v1/spikes/follow-ups/\(batchID)/proposals/\(proposalID)/review",
            payload: payload,
            port: port
        )
    }

    static func proposeSpikeFollowups(
        originRepoPath: String,
        originTicketID: String,
        originRunID: Int
    ) async throws -> SpikeFollowupBatch {
        guard let request = proposeSpikeFollowupsRequest(
            originRepoPath: originRepoPath,
            originTicketID: originTicketID,
            originRunID: originRunID,
            port: readPort()
        ) else {
            throw OrchestratorClientError.invalidRequest
        }
        return try await followupBatch(for: request)
    }

    static func reviewSpikeFollowup(
        batchID: String,
        proposalID: String,
        decision: String,
        updates: [String: Any]? = nil
    ) async throws -> SpikeFollowupBatch {
        guard let request = reviewSpikeFollowupRequest(
            batchID: batchID,
            proposalID: proposalID,
            decision: decision,
            updates: updates,
            port: readPort()
        ) else {
            throw OrchestratorClientError.invalidRequest
        }
        return try await followupBatch(for: request)
    }

    private static func followupBatch(for request: URLRequest) async throws -> SpikeFollowupBatch {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OrchestratorClientError.badStatus(status, body)
        }
        do {
            return try JSONDecoder().decode(SpikeFollowupBatchResponse.self, from: data).batch
        } catch {
            throw OrchestratorClientError.decodeFailed(error.localizedDescription)
        }
    }

    static func fetchProgramDashboard(
        limit: Int = 0,
        repoPaths: [String] = []
    ) async throws -> ProgramDashboardSnapshot {
        try await fetchProgramDashboardEnsuringDaemon(
            fetchDashboard: {
                try await fetchProgramDashboardRefreshingStaleDaemon(
                    limit: limit,
                    fetchDashboard: { limit in
                        try await fetchProgramDashboardSnapshot(
                            limit: limit,
                            trigger: "program-board-refresh",
                            repoPaths: repoPaths
                        )
                    },
                    refreshDaemon: {
                        await restartOrchestratorDaemonIfIdle()
                    }
                )
            },
            ensureDaemon: {
                await ensureOrchestratorDaemonInstalled()
            }
        )
    }

    static func fetchProgramDashboardEnsuringDaemon(
        retryDelaysNanoseconds: [UInt64] = programDashboardConnectionRetryDelaysNanoseconds,
        fetchDashboard: @escaping () async throws -> ProgramDashboardSnapshot,
        ensureDaemon: @escaping () async -> OrchestratorDaemonEnsureResult,
        sleep: @escaping (UInt64) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) async throws -> ProgramDashboardSnapshot {
        do {
            return try await fetchDashboard()
        } catch {
            guard isTransientDaemonConnectionError(error) else { throw error }
        }

        switch await ensureDaemon() {
        case .ready:
            return try await fetchProgramDashboardRetryingTransientConnection(
                retryDelaysNanoseconds: retryDelaysNanoseconds,
                fetchDashboard: fetchDashboard,
                sleep: sleep
            )
        case .failed(let message):
            throw OrchestratorClientError.daemonRefreshFailed(message)
        }
    }

    static func fetchProgramDashboardRetryingTransientConnection(
        retryDelaysNanoseconds: [UInt64] = programDashboardConnectionRetryDelaysNanoseconds,
        fetchDashboard: @escaping () async throws -> ProgramDashboardSnapshot,
        sleep: @escaping (UInt64) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) async throws -> ProgramDashboardSnapshot {
        var retryDelays = retryDelaysNanoseconds.makeIterator()
        while true {
            do {
                return try await fetchDashboard()
            } catch {
                guard isTransientDaemonConnectionError(error),
                      let retryDelay = retryDelays.next() else {
                    throw error
                }
                try Task.checkCancellation()
                try await sleep(retryDelay)
                try Task.checkCancellation()
            }
        }
    }

    static func isTransientDaemonConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch URLError.Code(rawValue: nsError.code) {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut:
            return true
        default:
            return false
        }
    }

    static func fetchProgramDashboardSnapshot(
        limit: Int = 0,
        trigger: String = "program-board-refresh",
        repoPaths: [String] = []
    ) async throws -> ProgramDashboardSnapshot {
        guard let req = programDashboardRequest(
            limit: limit,
            trigger: trigger,
            repoPaths: repoPaths,
            port: readPort()
        ) else {
            throw OrchestratorClientError.invalidRequest
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OrchestratorClientError.badStatus(status, body)
        }
        do {
            return try JSONDecoder().decode(ProgramDashboardResponse.self, from: data).snapshot
        } catch {
            throw OrchestratorClientError.decodeFailed(error.localizedDescription)
        }
    }

    static func fetchProgramDashboardRefreshingStaleDaemon(
        limit: Int = 0,
        fetchDashboard: @escaping (_ limit: Int) async throws -> ProgramDashboardSnapshot,
        refreshDaemon: @escaping () async -> OrchestratorDaemonRefreshResult
    ) async throws -> ProgramDashboardSnapshot {
        do {
            return try await fetchDashboard(limit)
        } catch {
            guard shouldRefreshDaemon(for: error) else { throw error }
            switch await refreshDaemon() {
            case .restarted:
                do {
                    return try await fetchDashboard(limit)
                } catch {
                    if shouldRefreshDaemon(for: error) {
                        throw OrchestratorClientError.daemonRefreshFailed(
                            "Relay Runner restarted the orchestrator, but it still reports an older Program Workspace schema."
                        )
                    }
                    throw error
                }
            case .deferredActiveRuns:
                throw OrchestratorClientError.daemonRefreshDeferred
            case .notInstalled:
                throw OrchestratorClientError.daemonRefreshFailed(
                    "Relay Runner could not find the installed orchestrator launch agent."
                )
            case .failed(let message):
                throw OrchestratorClientError.daemonRefreshFailed(message)
            }
        }
    }

    static func fetchProgramDashboardRefreshingStaleDaemon(
        limit: Int = 0,
        fetch: @escaping (_ query: String, _ limit: Int) async throws -> ProgramStatusResponse,
        refreshDaemon: @escaping () async -> OrchestratorDaemonRefreshResult
    ) async throws -> ProgramDashboardSnapshot {
        return try await fetchProgramDashboardRefreshingStaleDaemon(
            limit: limit,
            fetchDashboard: { limit in
                try await buildProgramDashboard(limit: limit, fetch: fetch)
            },
            refreshDaemon: refreshDaemon
        )
    }

    static func fetchProgramStatusOverlay(limit: Int = 6) async throws -> ProgramStatusOverlayMessage {
        try await buildProgramStatusOverlay(limit: limit) { query, limit in
            try await fetchProgramStatus(query: query, limit: limit)
        }
    }

    static func refreshBundledOrchestratorDaemonIfIdle() async -> OrchestratorDaemonRefreshResult {
        guard orchestratorDaemonInstalled() else {
            return .notInstalled
        }
        return await restartOrchestratorDaemonIfIdle()
    }

    static func buildProgramDashboard(
        limit: Int = 0,
        fetch: @escaping (_ query: String, _ limit: Int) async throws -> ProgramStatusResponse
    ) async throws -> ProgramDashboardSnapshot {
        async let summary = fetch("summary", limit)
        async let backlog = fetch("backlog_lane", limit)
        async let ready = fetch("ready_lane", limit)
        async let inProgress = fetch("in_progress_lane", limit)
        async let done = fetch("done_lane", limit)
        async let awaitingMerge = fetch("awaiting_merge", limit)
        let summaryResponse = try await summary
        return try await ProgramDashboardSnapshot(
            summary: summaryResponse,
            backlogWork: backlog,
            readyWork: ready,
            inProgressWork: inProgress,
            doneWork: done,
            awaitingMerge: awaitingMerge
        )
    }

    static func buildProgramStatusOverlay(
        limit: Int = 6,
        fetch: @escaping (_ query: String, _ limit: Int) async throws -> ProgramStatusResponse
    ) async throws -> ProgramStatusOverlayMessage {
        async let active = fetch("in_progress_lane", limit)
        async let awaitingMerge = fetch("awaiting_merge", limit)
        return try await ProgramStatusOverlayFormatter.message(
            active: active,
            awaitingMerge: awaitingMerge
        )
    }

    static func fetchProgramStatus(query: String, limit: Int = 20) async throws -> ProgramStatusResponse {
        guard let req = programStatusRequest(query: query, limit: limit, port: readPort()) else {
            throw OrchestratorClientError.invalidRequest
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OrchestratorClientError.badStatus(status, body)
        }
        do {
            return try JSONDecoder().decode(ProgramStatusResponse.self, from: data)
        } catch {
            throw OrchestratorClientError.decodeFailed(error.localizedDescription)
        }
    }

    static func programStatusRequest(query: String, limit: Int, port: Int) -> URLRequest? {
        getRequest(
            path: "/v1/program/status",
            query: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "limit", value: "\(limit)"),
            ],
            port: port
        )
    }

    static func programDashboardRequest(
        limit: Int,
        trigger: String,
        repoPaths: [String] = [],
        port: Int
    ) -> URLRequest? {
        getRequest(
            path: "/v1/program/dashboard",
            query: [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "trigger", value: trigger),
            ] + repoPaths.map { URLQueryItem(name: "repo_path", value: $0) },
            port: port,
            timeout: artifactReadTimeout
        )
    }

    private static func artifactPayload(
        repoPath: String,
        projectScopeToken: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "repo_path": repoPath,
            "request_id": UUID().uuidString,
        ]
        if let projectScopeToken, !projectScopeToken.isEmpty {
            payload["project_scope_token"] = projectScopeToken
        }
        return payload
    }

    private static func synchronousPost(
        path: String,
        payload: [String: Any],
        timeout: TimeInterval = 15
    ) throws -> Data {
        guard let request = artifactPostRequest(
            path: path,
            payload: payload,
            port: readPort()
        ) else {
            throw OrchestratorClientError.invalidRequest
        }
        let result = BlockingHTTPResult()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result.set(.failure(error))
            } else if let data, let response {
                result.set(.success((data, response)))
            } else {
                result.set(.failure(OrchestratorClientError.decodeFailed("Empty daemon response.")))
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw OrchestratorClientError.timedOut
        }
        guard let outcome = result.get() else {
            throw OrchestratorClientError.decodeFailed("Missing daemon response.")
        }
        let (data, response) = try outcome.get()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OrchestratorClientError.badStatus(status, body)
        }
        return data
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OrchestratorClientError.decodeFailed(error.localizedDescription)
        }
    }

    private static func artifactGet<Value: Decodable>(
        _ type: Value.Type,
        path: String,
        repoPath: String,
        projectScopeToken: String?,
        values: [URLQueryItem] = []
    ) async throws -> Value {
        guard let request = artifactGetRequest(
            path: path,
            repoPath: repoPath,
            projectScopeToken: projectScopeToken,
            values: values,
            port: readPort()
        ) else {
            throw OrchestratorClientError.invalidRequest
        }
        return try await response(type, for: request)
    }

    private static func artifactPost<Value: Decodable>(
        _ type: Value.Type,
        path: String,
        payload: [String: Any]
    ) async throws -> Value {
        guard let request = artifactPostRequest(
            path: path,
            payload: payload,
            port: readPort()
        ) else {
            throw OrchestratorClientError.invalidRequest
        }
        return try await response(type, for: request)
    }

    private static func response<Value: Decodable>(
        _ type: Value.Type,
        for request: URLRequest
    ) async throws -> Value {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OrchestratorClientError.badStatus(status, body)
        }
        return try decode(type, from: data)
    }

    private static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func postRequest(
        path: String,
        payload: [String: Any],
        port: Int,
        timeout: TimeInterval = 10
    ) -> URLRequest? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)"),
              let body = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return req
    }

    private static func getRequest(
        path: String,
        query: [URLQueryItem],
        port: Int,
        timeout: TimeInterval = 10
    ) -> URLRequest? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        components.queryItems = query
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        return req
    }

    private static func post(_ req: URLRequest, label: String) {
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                NSLog("[orchestrator-client] \(label) failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status >= 400 {
                let msg = data.flatMap { String(data: $0, encoding: .utf8) } ?? "(no body)"
                NSLog("[orchestrator-client] \(label) HTTP \(status): \(msg.prefix(200))")
            }
        }.resume()
    }

    private static func shouldRefreshDaemon(for error: Error) -> Bool {
        guard let clientError = error as? OrchestratorClientError,
              case OrchestratorClientError.badStatus(let status, let body) = clientError else { return false }
        let lower = body.lowercased()
        if status == 404 {
            return lower.contains("/v1/program/dashboard")
                || lower.contains("program/dashboard")
        }
        guard status == 400 else { return false }
        guard lower.contains("unknown program status query") else { return false }
        return lower.contains("backlog_lane")
            || lower.contains("ready_lane")
            || lower.contains("in_progress_lane")
            || lower.contains("done_lane")
    }

    private static func restartOrchestratorDaemonIfIdle() async -> OrchestratorDaemonRefreshResult {
        await Task.detached {
            let script = relayOrchestratorScript()
            guard FileManager.default.isExecutableFile(atPath: script.path) else {
                return .failed("Relay Runner could not find the bundled relay-orchestrator launcher.")
            }

            let proc = Process()
            proc.executableURL = script
            proc.arguments = ["--restart-if-idle"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                return .failed("Relay Runner could not restart the orchestrator: \(error.localizedDescription)")
            }

            switch proc.terminationStatus {
            case 0:
                return .restarted
            case 75:
                return .deferredActiveRuns
            default:
                return .failed(
                    "relay-orchestrator --restart-if-idle failed with exit code \(proc.terminationStatus)."
                )
            }
        }.value
    }

    private static func ensureOrchestratorDaemonInstalled() async -> OrchestratorDaemonEnsureResult {
        guard !orchestratorLaunchAgentInstalled() else { return .ready }

        return await Task.detached {
            let script = relayOrchestratorScript()
            guard FileManager.default.isExecutableFile(atPath: script.path) else {
                return .failed("Relay Runner could not find the bundled relay-orchestrator launcher.")
            }

            let proc = Process()
            proc.executableURL = script
            proc.arguments = ["--install"]
            proc.standardInput = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                return .failed("Relay Runner could not install the orchestrator: \(error.localizedDescription)")
            }

            guard proc.terminationStatus == 0 else {
                return .failed(
                    "relay-orchestrator --install failed with exit code \(proc.terminationStatus)."
                )
            }
            return .ready
        }.value
    }

    private static func relayOrchestratorScript() -> URL {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/SharedSupport/scripts/relay-orchestrator")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/relay-orchestrator")
    }

    private static func orchestratorDaemonInstalled() -> Bool {
        if FileManager.default.fileExists(atPath: portFile) {
            return true
        }
        return orchestratorLaunchAgentInstalled()
    }

    private static func orchestratorLaunchAgentInstalled() -> Bool {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.relay.orchestrator.plist")
        return FileManager.default.fileExists(atPath: plist.path)
    }

    private static func readPort() -> Int {
        if let raw = try? String(contentsOfFile: portFile, encoding: .utf8),
           let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           port > 0 {
            return port
        }
        return defaultPort
    }
}

enum OrchestratorDaemonRefreshResult: Equatable {
    case restarted
    case deferredActiveRuns
    case notInstalled
    case failed(String)
}

enum OrchestratorDaemonEnsureResult: Equatable {
    case ready
    case failed(String)
}

enum OrchestratorClientError: Error, LocalizedError, Equatable {
    case invalidRequest
    case badStatus(Int, String)
    case decodeFailed(String)
    case timedOut
    case daemonRefreshDeferred
    case daemonRefreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Could not build orchestrator request."
        case .badStatus(let status, let body):
            let detail = body.isEmpty ? "No response body." : body
            return "Orchestrator returned HTTP \(status). \(detail)"
        case .decodeFailed(let message):
            return "Could not decode orchestrator response: \(message)"
        case .timedOut:
            return "The local artifact writer did not respond before the board save timed out."
        case .daemonRefreshDeferred:
            return (
                "Relay Runner needs to restart the orchestrator to load the bundled Program Workspace schema, "
                + "but active workers are running. Refresh again after those workers finish."
            )
        case .daemonRefreshFailed(let message):
            return message.isEmpty
                ? "Relay Runner could not restart the orchestrator."
                : message
        }
    }
}
