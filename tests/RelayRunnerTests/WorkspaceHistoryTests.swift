import XCTest
@testable import relay_runner

final class WorkspaceHistoryTests: XCTestCase {
    func testArchiveStateBadgesUseTruthfulLocalityWording() {
        XCTAssertEqual(
            WorkspaceHistoryBadge.resolve(state: "materialized_recent"),
            WorkspaceHistoryBadge(label: "Materialized", isWarning: false)
        )
        XCTAssertEqual(
            WorkspaceHistoryBadge.resolve(state: "materialized_exempt"),
            WorkspaceHistoryBadge(label: "Temporary Safety Overage", isWarning: true)
        )
        XCTAssertEqual(
            WorkspaceHistoryBadge.resolve(state: "archive_pending_sync"),
            WorkspaceHistoryBadge(label: "Local Archive Only", isWarning: true)
        )
        XCTAssertEqual(
            WorkspaceHistoryBadge.resolve(state: "archived"),
            WorkspaceHistoryBadge(
                label: "GitHub-backed • Locally Reachable Through Git",
                isWarning: false
            )
        )
    }

    func testUnavailableBadgesOverrideArchiveState() {
        XCTAssertEqual(
            WorkspaceHistoryBadge.resolve(state: "archived", availability: "needs_network").label,
            "Needs Network"
        )
        XCTAssertEqual(
            WorkspaceHistoryBadge.resolve(state: "archived", availability: "not_found").label,
            "Missing"
        )
        XCTAssertEqual(
            WorkspaceHistoryBadge.resolve(state: "archived", availability: "tampered").label,
            "Tampered"
        )
    }

    func testHistoryDetailDecodesMarkdownWithoutMaterializing() throws {
        let markdown = "---\nid: RR-1\n---\n## Description\nArchived"
        let json = """
        {
          "availability": "available",
          "card": {
            "artifact_id": "artifact-RR-1",
            "ticket_id": "RR-1",
            "title": "Archived",
            "status": "done",
            "state": "archived",
            "activity_at": "2026-08-20T00:00:00Z"
          },
          "markdown_base64": "\(Data(markdown.utf8).base64EncodedString())",
          "attachments": [{"path":"attachments/RR-1/proof.png","filename":"proof.png","mime_type":"image/png","size":42}],
          "recovery": null,
          "materialized": false
        }
        """

        let detail = try JSONDecoder().decode(
            ArtifactHistoryDetailResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(detail.markdown, markdown)
        XCTAssertFalse(detail.materialized)
        XCTAssertEqual(detail.attachments.first?.displayName, "proof.png")
    }

    func testRetentionStatusDecodesExactPreviewAndStorageState() throws {
        let status = try JSONDecoder().decode(
            ArtifactRetentionStatus.self,
            from: Data(Self.statusJSON.utf8)
        )

        XCTAssertEqual(status.plan.limit, 25)
        XCTAssertEqual(status.plan.nonterminalIDs, ["RR-open"])
        XCTAssertEqual(status.plan.retainedTerminalIDs, ["RR-new"])
        XCTAssertEqual(status.plan.evictionCandidateIDs, ["RR-old"])
        XCTAssertEqual(status.plan.estimatedRemovedFileCount, 3)
        XCTAssertEqual(status.remoteName, "origin")
        XCTAssertTrue(status.exposureConfirmationRequired)
        XCTAssertEqual(status.transaction.lastError, "offline")
    }

    func testStorageMetricsDistinguishMaterializationFromOtherLocalData() throws {
        let json = """
        {
          "materialized":{"bytes":100,"files":3,"tickets":{"bytes":60,"files":2},"attachments":{"bytes":40,"files":1}},
          "retention":{"retained_terminal_count":1,"nonterminal_count":1,"temporary_overage_count":0,"remotely_backed_history_count":30},
          "reachable_git_objects_bytes":500,
          "databases_bytes":20,
          "run_logs_bytes":30,
          "indexes_bytes":40,
          "caches_bytes":50,
          "reclaimable_estimate_bytes":45
        }
        """
        let metrics = try JSONDecoder().decode(ArtifactStorageMetrics.self, from: Data(json.utf8))

        XCTAssertEqual(metrics.materialized.tickets.files, 2)
        XCTAssertEqual(metrics.materialized.attachments.files, 1)
        XCTAssertEqual(metrics.retention.remotelyBackedHistoryCount, 30)
        XCTAssertEqual(metrics.reachableGitObjectsBytes, 500)
        XCTAssertEqual(metrics.reclaimableEstimateBytes, 45)
    }

    func testHistoryGETRequestCarriesProjectScopeAndSearch() throws {
        let request = try XCTUnwrap(OrchestratorClient.artifactGetRequest(
            path: "/v1/artifacts/history/search",
            repoPath: "/tmp/My Project",
            projectScopeToken: "scope-token",
            values: [URLQueryItem(name: "query", value: "canceled release")],
            port: 7634
        ))
        let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value) })

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(values["repo_path"], "/tmp/My Project")
        XCTAssertEqual(values["project_scope_token"], "scope-token")
        XCTAssertEqual(values["query"], "canceled release")
    }

    @MainActor
    func testBoardModelPresentsAndClosesScopedHistory() {
        let model = ProgramBoardViewModel(fetchDashboard: { .empty() })

        model.presentHistory(
            repoPath: "/tmp/project",
            projectName: "Project",
            projectScopeToken: "scope"
        )

        XCTAssertEqual(model.history?.repoPath, "/tmp/project")
        XCTAssertEqual(model.history?.projectScopeToken, "scope")
        model.closeHistory()
        XCTAssertNil(model.history)
    }

    func testPolicyCopyKeepsUnfinishedUncappedAndExplainsGitObjectsRemain() {
        XCTAssertTrue(WorkspaceHistoryViewModel.policySummary.contains("without a cap"))
        XCTAssertTrue(WorkspaceHistoryViewModel.policySummary.contains("Done and Canceled"))
        XCTAssertTrue(WorkspaceHistoryViewModel.policySummary.contains("25"))
        XCTAssertTrue(WorkspaceHistoryViewModel.materializationDisclaimer.contains("reachable Git objects"))
        XCTAssertTrue(WorkspaceHistoryViewModel.materializationDisclaimer.contains("run logs remain"))
    }

    private static let statusJSON = """
    {
      "state":"blocked",
      "remote_mode":"enabled",
      "remote_name":"origin",
      "exposure_confirmation_required":true,
      "plan":{
        "schema_version":1,
        "policy":"terminal-count-v1",
        "limit":25,
        "project_id":"project-1",
        "artifact_head":"abc",
        "evaluated_at":"2026-08-20T00:00:00Z",
        "retained_terminal_ids":["RR-new"],
        "nonterminal_ids":["RR-open"],
        "eviction_candidate_ids":["RR-old"],
        "materialize_ids":[],
        "temporary_overage":{},
        "retained_terminal":[{
          "ticket_id":"RR-new","artifact_id":"artifact-new","title":"New","status":"done",
          "activity_at":"2026-08-20T00:00:00Z","dependencies":[],"attachment_paths":[],"exemptions":[],"materialized":true
        }],
        "eviction_candidates":[{
          "ticket_id":"RR-old","artifact_id":"artifact-old","title":"Old","status":"canceled",
          "activity_at":"2026-01-01T00:00:00Z","dependencies":[],
          "attachment_paths":["attachments/RR-old/a.png","attachments/RR-old/b.txt"],"exemptions":[],"materialized":true
        }]
      },
      "transaction":{"state":"prepared","phase":"prepared","retry_available":true,"last_error":"offline"},
      "remote":{"state":"offline","recovery":"Reconnect and retry."},
      "blocked_reasons":["Reconnect and retry."],
      "retry_actions":["POST /v1/artifacts/retention/retry"]
    }
    """
}
