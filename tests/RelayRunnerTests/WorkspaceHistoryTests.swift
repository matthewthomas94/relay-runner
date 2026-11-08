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
        XCTAssertEqual(request.timeoutInterval, 120)
    }

    func testRetentionMutationRequestAllowsVerifiedLargeCorpusCleanup() throws {
        let request = try XCTUnwrap(OrchestratorClient.artifactPostRequest(
            path: "/v1/artifacts/retention/apply",
            payload: [
                "repo_path": "/tmp/My Project",
                "project_scope_token": "scope-token",
                "request_id": "retention-1",
            ],
            port: 7634
        ))

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 600)
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

    /// History opens straight onto a project: the one asked for, else the
    /// board's selection, else the session's project, else the first one.
    func testHistoryOpensOnTheBestKnownProjectWithoutAPrompt() {
        let general = ProgramBoardProjectTarget(name: "general", path: "/tmp/general-tasks")
        let cad = ProgramBoardProjectTarget(name: "cad-engine", path: "/tmp/cad-engine")
        let projects = [general, cad]
        typealias C = ProgramBoardOverlayController
        XCTAssertEqual(C.historyTarget(in: projects, preferring: ["/tmp/cad-engine", "/tmp/general-tasks"]), cad)
        XCTAssertEqual(C.historyTarget(in: projects, preferring: [nil, "/tmp/missing", "/tmp/general-tasks"]), general)
        XCTAssertEqual(C.historyTarget(in: projects, preferring: [nil, nil]), general, "No preference opens the first project")
        XCTAssertNil(C.historyTarget(in: [], preferring: ["/tmp/cad-engine"]))
    }

    /// The History screen is the heading, the dropdown and the archive. Its
    /// dropdown switches History's project only: it never selects a board
    /// project, which would change context and jump to the Work tab.
    func testHistoryScreenHasNoExplainersAndItsPickerStaysOnHistory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/relay-runner/Board")
        let view = try String(contentsOf: root.appendingPathComponent("WorkspaceHistoryView.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("WorkspaceHistory.swift"), encoding: .utf8)
        let board = try String(contentsOf: root.appendingPathComponent("ProgramBoardOverlayView.swift"), encoding: .utf8)
        XCTAssertFalse(view.contains("Text(model.projectName)"), "No project-name subtitle")
        XCTAssertFalse(view.contains("policySummary"), "No retention paragraph")
        XCTAssertFalse(model.contains("notice = response.recovery"), "No GitHub-backup banner")
        let start = try XCTUnwrap(board.range(of: "private var historyTab: some View {"))
        let end = try XCTUnwrap(board.range(of: "private var notesLibrary: some View {"))
        let tab = String(board[start.upperBound..<end.lowerBound])
        XCTAssertTrue(tab.contains("onSelectHistoryProject(path)"))
        XCTAssertFalse(tab.contains("onSelectProject("), "Picking a History project must not select a board project")
        XCTAssertFalse(tab.contains("Choose a project"), "History never stops on a project prompt")
        XCTAssertTrue(tab.contains("model.historyProjects"))
    }

}
