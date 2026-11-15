//! Program capture, artifacts and graph ingest (RR-499).
//!
//! The contract case replays `ProgramAndFollowupTests.test_capture_status_and_dashboard`
//! of `tests/contract/test_orchestrator_contract_sessions.py` against the
//! library. The fixture cases capture into an artifact project, ingest it
//! into `graphify.db` (again without change), check that identical captures
//! commit identical events, track input identities, and export and rebuild
//! legacy captures.

mod common;

use std::fs;
use std::path::{Path, PathBuf};

use relay_artifacts::store::{ARTIFACT_REF, ArtifactStore, Mutation, Operation, StoreOptions};
use relay_intents::json::{self, Dict, Value};
use relay_services::program::artifacts::{
    DurableEvent, canonical_program_event, durable_program_event, expected_graph_manifest,
    export_graphify_project_captures, graph_capture_manifest, program_event_id,
    replace_graphify_with_clean_rebuild,
};
use relay_services::program::capture::{ArtifactAuthority, CaptureRequest, capture_session_review};
use relay_services::program::ingest::{
    IngestOptions, graph_file_state, ingest_registered_projects, registered_projects_input_state,
    unchanged_project_inputs,
};
use relay_services::program::{in_transaction, with_graph};
use relay_services::program_status::{
    STALE_AFTER_SECONDS, build_program_dashboard, build_program_status,
};
use relay_store::graphify::{GraphifyStore, NODE_DECISION, NODE_PROJECT};
use rusqlite::Connection;

use common::{TempRoot, git, make_repo};

const DEVICE: &str = "contract-device";
const OCCURRED_AT: f64 = 1_785_819_600.25;

fn parse(text: &str) -> Value {
    json::parse(text.trim()).unwrap_or_else(|| panic!("not JSON: {text}"))
}

fn show(value: Option<&Value>) -> String {
    value.map(json::dumps).unwrap_or_default()
}

fn dict(value: &Value) -> &Dict {
    value.as_dict().expect("an object")
}

fn open_store(repo: &Path, project_id: &str, state_root: &Path) -> ArtifactStore {
    ArtifactStore::open(
        repo,
        project_id,
        state_root,
        StoreOptions {
            enabled: true,
            ..Default::default()
        },
    )
    .expect("open the artifact store")
}

/// `registry-v2.json` with one record per `(project_id, repo)`, as the
/// suite's `register` writes it.
fn write_registry(path: &Path, projects: &[(&str, &Path)]) {
    let records: Vec<String> = projects
        .iter()
        .map(|(project_id, repo)| {
            let repo = json::str_repr(&repo.to_string_lossy()).replace('\'', "\"");
            format!(
                r#"{{"project_id": "{project_id}", "display_name": "{project_id}",
                "selected_path": {repo}, "last_resolved_path": {repo},
                "availability": "available", "worktree_kind": "main",
                "remote": {{"mode": "local_only", "artifactRef": "{ARTIFACT_REF}"}},
                "providers": {{"claude": {{"model": "opus"}}, "Codex CLI": {{}}}},
                "last_resolved_at": "2026-08-04T00:00:00Z"}}"#
            )
        })
        .collect();
    fs::write(
        path,
        format!(
            r#"{{"schema_version": 2, "active_project_id": "contract-program",
            "workspaceRoots": [{{"rootPath": "/nonexistent-workspace-root"}}],
            "projects": [{}]}}"#,
            records.join(", ")
        ),
    )
    .unwrap();
}

fn decision_entries() -> Value {
    parse(r#"[{"kind": "decision", "text": "Ship the contract suite."}]"#)
}

fn capture_request(repo: &Path, entries: Value, capture_id: &str) -> CaptureRequest {
    CaptureRequest {
        repo_path: Some(Value::Str(repo.to_string_lossy().into_owned())),
        entries: Some(entries),
        capture_id: Some(Value::Str(capture_id.to_string())),
        provider: Some(Value::Str("claude".to_string())),
        occurred_at: Some(OCCURRED_AT),
        ..Default::default()
    }
}

/// `ProgramAndFollowupTests.test_capture_status_and_dashboard`: the capture
/// response fields, the artifact commit and the refusal, then the status
/// counts and dashboard after the daemon's refresh ingests the capture.
#[test]
fn contract_capture_commits_one_decision() {
    let root = TempRoot::new("program-contract");
    let repo = make_repo(&root.path.join("program"));
    let store = open_store(&repo, "contract-program", &root.state_root());
    store.initialize(DEVICE, "migration").unwrap();
    let registry = root.path.join("registry-v2.json");
    write_registry(&registry, &[("contract-program", &repo)]);
    let graph = GraphifyStore::open(&root.data_root().join("graphify.db")).unwrap();
    let counts = ingest_registered_projects(
        &graph,
        &IngestOptions {
            registry_path: registry.clone(),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(counts.get("projects").and_then(Value::py_int), Some(1));

    let request = CaptureRequest {
        repo_path: Some(Value::Str(repo.to_string_lossy().into_owned())),
        entries: Some(decision_entries()),
        capture_id: Some(Value::Str("capture-1".to_string())),
        provider: Some(Value::Str("claude".to_string())),
        ..Default::default()
    };
    let authority = ArtifactAuthority {
        store: &store,
        device_id: Some(DEVICE),
    };
    let captured = with_graph(&graph, |g| {
        capture_session_review(g, &request, Some(&authority))
    })
    .unwrap();
    assert_eq!(
        captured.get("capture_id").unwrap().as_str(),
        Some("capture-1")
    );
    assert_eq!(
        json::dumps(captured.get("counts").unwrap()),
        r#"{"Decision": 1}"#
    );
    assert_eq!(
        captured.get("durable_authority").unwrap().as_str(),
        Some("relay/artifacts")
    );
    assert_eq!(
        captured.get("artifact_commit").unwrap().as_str().unwrap(),
        git(&repo, &["rev-parse", ARTIFACT_REF])
    );
    let keys: Vec<&str> = captured.iter().map(|(key, _)| key).collect();
    assert_eq!(
        keys,
        [
            "capture_id",
            "message",
            "nodes",
            "counts",
            "links",
            "provider",
            "repo_path",
            "artifact_commit",
            "artifact_event_ids",
            "artifact_idempotent",
            "durable_authority",
        ]
    );
    let event_id = program_event_id("capture:capture-1:0").unwrap();
    assert_eq!(
        json::dumps(captured.get("artifact_event_ids").unwrap()),
        format!(r#"["{event_id}"]"#)
    );
    // The decision is projected, linked to its project and named by the commit.
    let nodes = with_graph(&graph, |g| Ok(g.nodes(Some(NODE_DECISION), None)?)).unwrap();
    assert_eq!(nodes.len(), 1);
    assert_eq!(nodes[0].get("title").unwrap().as_str(), Some("Decision"));
    let message = git(&repo, &["log", "-1", "--format=%B", ARTIFACT_REF]);
    assert!(message.starts_with("Publish 1 Program artifact event(s)"));
    assert!(message.contains("Relay-Provider: claude"));

    // Repeating the capture with the same time is idempotent; another time
    // is a different event under the same identity, which is refused.
    let mut repeat = request.clone();
    repeat.capture_id = Some(Value::Str("capture-2".to_string()));
    repeat.occurred_at = Some(OCCURRED_AT);
    let first = with_graph(&graph, |g| {
        capture_session_review(g, &repeat, Some(&authority))
    })
    .unwrap();
    let again = with_graph(&graph, |g| {
        capture_session_review(g, &repeat, Some(&authority))
    })
    .unwrap();
    let collision = with_graph(&graph, |g| {
        capture_session_review(g, &request, Some(&authority))
    })
    .unwrap_err();
    assert_eq!(collision.class, "ArtifactEventCollision");
    assert_eq!(show(again.get("artifact_idempotent")), "true");
    assert_eq!(
        show(again.get("artifact_commit")),
        show(first.get("artifact_commit"))
    );

    let refused = with_graph(&graph, |g| {
        capture_session_review(
            g,
            &CaptureRequest {
                repo_path: request.repo_path.clone(),
                ..Default::default()
            },
            Some(&authority),
        )
    })
    .unwrap_err();
    assert_eq!(
        (refused.class, refused.message.as_str()),
        ("SessionCaptureError", "entries is required")
    );

    // The status half: the daemon refreshes the graph, then reads it.
    ingest_registered_projects(
        &graph,
        &IngestOptions {
            registry_path: registry.clone(),
            ..Default::default()
        },
    )
    .unwrap();
    let status = build_program_status(&graph, None, None, 8, None, STALE_AFTER_SECONDS).unwrap();
    assert_eq!(
        json::dumps(status.get("counts").unwrap()),
        r#"{"projects": 1, "items": 1}"#
    );
    let item = dict(&status.get("items").and_then(Value::as_list).unwrap()[0]);
    let project = dict(item.get("project").unwrap());
    assert_eq!(
        project.get("path").and_then(Value::as_str),
        Some(repo.to_string_lossy().as_ref())
    );
    let dashboard =
        build_program_dashboard(&graph, None, None, 8, None, STALE_AFTER_SECONDS, None).unwrap();
    assert!(dashboard.get("summary").is_some());
}

#[test]
fn capture_refusals_name_their_errors() {
    let root = TempRoot::new("program-refusals");
    let graph = GraphifyStore::open(&root.data_root().join("graphify.db")).unwrap();
    let refuse = |entries: Value| {
        with_graph(&graph, |g| {
            capture_session_review(
                g,
                &CaptureRequest {
                    entries: Some(entries),
                    ..Default::default()
                },
                None,
            )
        })
        .unwrap_err()
    };
    assert_eq!(refuse(parse("[]")).message, "entries is required");
    assert_eq!(refuse(parse("[1]")).message, "entry 0 must be an object");
    assert_eq!(
        refuse(parse(r#"[{"kind": "Rocket Launch"}]"#)).message,
        "entry 0 has unsupported kind 'rocket_launch'; expected one of blocked, blocker, decision, \
         event, idea, note, notes, program-event, program_event, risk, shipped, shipped_work, \
         started, started_work, status"
    );

    let event = |node_kind: &'static str, provider: Option<&'static str>| DurableEvent {
        project_id: "p",
        stable_key: "capture:x:0",
        node_kind,
        capture_id: "x",
        summary: "S",
        occurred_at: 1.0,
        source: "session_capture",
        provider,
        ..Default::default()
    };
    let error = durable_program_event(&event("Ticket", None)).unwrap_err();
    assert_eq!(
        (error.class, error.message.as_str()),
        (
            "ProgramArtifactError",
            "unsupported durable Program node kind: 'Ticket'"
        )
    );
    let error = durable_program_event(&event(NODE_DECISION, Some("gemini"))).unwrap_err();
    assert_eq!(error.message, "unsupported provider metadata: 'gemini'");
    let mut document = durable_program_event(&event(NODE_DECISION, Some("Claude Code"))).unwrap();
    assert_eq!(
        String::from_utf8(canonical_program_event(&document).unwrap()).unwrap(),
        format!(
            "{{\"attributes\":{{}},\"capture_id\":\"x\",\"capture_source\":\"session_capture\",\
             \"details\":null,\"entry_index\":0,\"event_id\":\"{}\",\"evidence\":{{\"run_id\":null,\
             \"ticket_id\":null}},\"occurred_at\":1.0,\"project_id\":\"p\",\"provider\":\"claude\",\
             \"record_kind\":\"decision\",\"schema_version\":1,\"stable_key\":\"capture:x:0\",\
             \"summary\":\"S\"}}\n",
            program_event_id("capture:x:0").unwrap()
        )
    );
    document.insert("extra", 1i64);
    assert_eq!(
        canonical_program_event(&document).unwrap_err().message,
        "Program event contains unsupported fields: extra"
    );
}

// -- the program fixture ------------------------------------------------------

/// A ticket file as the artifact board writes it.
fn ticket_markdown(id: &str, title: &str, status: &str, deps: &str, body: &str) -> Vec<u8> {
    format!(
        "---\nid: {id}\nartifact_id: ticket-{}-artifact\ntitle: {title}\n\
         status: {status}\npriority: high\nexecution_mode: implementation\n\
         depends_on: {deps}\nrun_id: null\ncanceled: false\n\
         activity_at: 2026-08-04T05:00:00Z\nworker_model: balanced\nworker_effort: medium\n\
         ---\n## Description\n\n{body}\n",
        id.to_lowercase()
    )
    .into_bytes()
}

/// Builds an artifact project with two live tickets and one archived ticket,
/// the way the store and retention write them.
fn write_artifact_fixture(repo: &Path, state_root: &Path, project_id: &str) {
    let store = open_store(repo, project_id, state_root);
    store.initialize(DEVICE, "migration").unwrap();
    let write =
        |id: &str, title: &str, status: &str, deps: &str, body: &str| Operation::TicketWrite {
            ticket_id: id.to_string(),
            artifact_id: format!("ticket-{}-artifact", id.to_lowercase()),
            markdown: ticket_markdown(id, title, status, deps, body),
        };
    let first = store
        .mutate(&Mutation::new(
            "fixture-1",
            "pm",
            DEVICE,
            vec![
                write("CT-1", "Ship the parser", "done", "[]", "Edit src/main.rs."),
                write(
                    "CT-2",
                    "Follow up",
                    "backlog",
                    "[CT-1, CT-9]",
                    "Read README.md.",
                ),
                write("CT-9", "Old work", "done", "[]", "Done long ago."),
            ],
        ))
        .unwrap();
    let blob = git(
        repo,
        &[
            "rev-parse",
            &format!("{}:.orchestrator/CT-9.md", first.commit_id),
        ],
    );
    let entry = parse(&format!(
        r#"{{"schema_version": 1, "artifact_id": "ticket-ct-9-artifact", "ticket_id": "CT-9",
            "title": "Old work", "status": "done", "activity_at": "2026-08-04T05:00:00Z",
            "dependencies": [], "state": "archived", "ticket_path": ".orchestrator/CT-9.md",
            "ticket_blob": "{blob}", "ticket_size": 0, "attachments": [],
            "source_commit": "{}", "archived_at": "2026-08-05T00:00:00Z",
            "restored_at": null, "deleted_at": null}}"#,
        first.commit_id
    ));
    store
        .mutate(&Mutation::new(
            "fixture-2",
            "pm",
            DEVICE,
            vec![
                Operation::TicketDelete {
                    ticket_id: "CT-9".to_string(),
                },
                Operation::ArchiveIndexWrite {
                    content: format!("{}\n", json::dumps_compact_sorted(&entry)).into_bytes(),
                },
            ],
        ))
        .unwrap();
}

/// Runs that exercise each provider source and program state.
fn write_runs(path: &Path, repo: &Path, log: &Path) {
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT, ticket_id TEXT NOT NULL,
                repo_path TEXT NOT NULL, workspace_path TEXT, branch TEXT, state TEXT NOT NULL,
                attempt INTEGER, started_at REAL, ended_at REAL, exit_code INTEGER,
                log_path TEXT, last_error TEXT, activity TEXT, activity_at REAL,
                provider_key TEXT, model_alias TEXT, worker_model TEXT, worker_effort TEXT,
                worker_sizing_rationale TEXT, worker_provider_notes TEXT, execution_mode TEXT
            );",
        )
        .unwrap();
    let repo = repo.to_string_lossy().into_owned();
    let log = log.to_string_lossy().into_owned();
    for (ticket, state, provider, log_path, repo_path) in [
        ("CT-1", "Merged", Some("claude"), None, repo.as_str()),
        (
            "CT-2",
            "Succeeded",
            Some("Claude Code"),
            None,
            repo.as_str(),
        ),
        ("CT-2", "Running", None, Some(log.as_str()), repo.as_str()),
        ("CT-7", "Failed", Some("codex"), None, "/not/registered"),
    ] {
        connection
            .execute(
                "INSERT INTO runs(ticket_id, repo_path, branch, state, attempt, started_at,
                    log_path, provider_key, worker_model)
                 VALUES (?, ?, 'relay/x', ?, 1, 1785819600.5, ?, ?, 'balanced')",
                rusqlite::params![ticket, repo_path, state, log_path, provider],
            )
            .unwrap();
    }
}

/// Every row of `graphify.db` that a projection owns, as text; the clock
/// fields (`updated_at`, `indexed_at`) are left out.
fn graph_rows(path: &Path) -> Vec<String> {
    let connection = Connection::open(path).unwrap();
    let mut rows = Vec::new();
    let mut query = |sql: &str, label: &str| {
        let mut statement = connection.prepare(sql).unwrap();
        let count = statement.column_count();
        let found: Vec<String> = statement
            .query_map([], |row| {
                let mut parts = Vec::new();
                for index in 0..count {
                    let value = relay_store::sql::sql_to_json(row.get(index)?);
                    let text = match value {
                        Value::Str(text) if text.starts_with('{') => {
                            let mut body = json::parse(&text).unwrap();
                            if let Value::Dict(dict) = &mut body {
                                dict.remove("indexed_at");
                            }
                            json::dumps_sorted(&body)
                        }
                        other => json::dumps(&other),
                    };
                    parts.push(text);
                }
                Ok(format!("{label} {}", parts.join(" | ")))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        rows.extend(found);
    };
    query(
        "SELECT id, kind, project_id, stable_key, title, body_json FROM graph_nodes ORDER BY id",
        "node",
    );
    query(
        "SELECT src_id, dst_id, kind, body_json FROM graph_edges ORDER BY src_id, dst_id, kind",
        "edge",
    );
    query(
        "SELECT id, project_id, rel_path, language, size_bytes, mtime_ns, content_hash, \
         deleted_at IS NULL FROM file_manifest ORDER BY project_id, rel_path",
        "file",
    );
    query(
        "SELECT file_id, rel_path, chunk_ordinal, start_line, end_line, text FROM file_chunks \
         ORDER BY file_id, chunk_ordinal",
        "chunk",
    );
    rows
}

struct Fixture {
    root: TempRoot,
    repo: PathBuf,
    legacy: PathBuf,
    registry: PathBuf,
    runs: PathBuf,
}

/// The registered artifact project (`contract-program`) beside a legacy
/// board (`contract-legacy`), a registry and a runs database.
fn fixture(label: &str) -> Fixture {
    let root = TempRoot::new(label);
    let repo = make_repo(&root.path.join("program"));
    fs::create_dir_all(repo.join("src")).unwrap();
    fs::write(repo.join("src/main.rs"), "fn main() {}\n// parser\n").unwrap();
    fs::write(repo.join("notes.txt"), "line\n".repeat(130)).unwrap();
    fs::write(repo.join("binary.json"), b"{\0}").unwrap();
    fs::create_dir_all(repo.join("node_modules")).unwrap();
    fs::write(repo.join("node_modules/skip.js"), "skipped").unwrap();
    write_artifact_fixture(&repo, &root.state_root(), "contract-program");
    let legacy = make_repo(&root.path.join("legacy"));
    fs::create_dir_all(legacy.join(".orchestrator")).unwrap();
    fs::write(
        legacy.join(".orchestrator/LG-1.md"),
        "---\nid: LG-1\ntitle: Legacy work\nstatus: in_progress\npriority: low\n\
         depends_on: []\nrun_id: null\ncanceled: false\n---\n## Description\n\nLegacy.\n",
    )
    .unwrap();
    let registry = root.path.join("registry-v2.json");
    write_registry(
        &registry,
        &[("contract-program", &repo), ("contract-legacy", &legacy)],
    );
    let log = root.path.join("run-3.log");
    fs::write(&log, "starting\n{\"type\": \"thread.started\"}\n").unwrap();
    let runs = root.data_root().join("runs.db");
    write_runs(&runs, &repo, &log);
    Fixture {
        root,
        repo,
        legacy,
        registry,
        runs,
    }
}

fn rust_ingest(fixture: &Fixture, graph_path: &Path, index_files: bool) -> Dict {
    let graph = GraphifyStore::open(graph_path).unwrap();
    ingest_registered_projects(
        &graph,
        &IngestOptions {
            registry_path: fixture.registry.clone(),
            runs_db_path: Some(fixture.runs.clone()),
            index_files,
            ..Default::default()
        },
    )
    .unwrap()
}

fn rust_capture(
    fixture: &Fixture,
    graph_path: &Path,
    entries: &Value,
    capture_id: &str,
    artifact: bool,
) -> Value {
    let graph = GraphifyStore::open(graph_path).unwrap();
    let store = open_store(
        &fixture.repo,
        "contract-program",
        &fixture.root.state_root(),
    );
    let authority = ArtifactAuthority {
        store: &store,
        device_id: Some(DEVICE),
    };
    let mut request = capture_request(&fixture.repo, entries.clone(), capture_id);
    request.provider = Some(Value::Str("Claude Code".to_string()));
    request.ticket_id = Some(Value::Str("CT-1".to_string()));
    request.run_id = Some(Value::Str("1".to_string()));
    Value::Dict(
        with_graph(&graph, |g| {
            capture_session_review(g, &request, artifact.then_some(&authority))
        })
        .unwrap(),
    )
}

fn mixed_entries() -> Value {
    parse(
        r#"[{"kind": "Decision", "title": "Use Rust", "details": "  For types.  "},
            {"type": "blocker", "summary": "Waiting on review", "ticket_id": "CT-2"},
            {"kind": "shipped", "run_id": 2},
            {"kind": "status", "state": "green", "note": "On track"},
            {"kind": "idea", "idea": "Cache the graph", "context": "x"}]"#,
    )
}

/// Two captures into one project's ref (the second validating the first's
/// events), then ingest; ingesting again over the same graph changes
/// nothing and reuses its file manifests.
#[test]
fn captured_events_ingest_and_reingest_unchanged() {
    let fixture = fixture("program-ingest");
    let scratch = fixture.root.path.join("scratch");
    fs::create_dir_all(&scratch).unwrap();

    let first = rust_capture(
        &fixture,
        &scratch.join("first-capture.db"),
        &mixed_entries(),
        "first-capture",
        true,
    );
    let second = rust_capture(
        &fixture,
        &scratch.join("second-capture.db"),
        &decision_entries(),
        "second-capture",
        true,
    );
    assert_eq!(show(dict(&second).get("artifact_idempotent")), "false");
    assert_eq!(
        json::dumps(dict(&first).get("counts").unwrap()),
        r#"{"ProgramEvent": 1, "Decision": 1, "Risk": 1, "Idea": 1, "Status": 1}"#
    );

    for index_files in [false, true] {
        let graph = scratch.join(format!("graph-{index_files}.db"));
        let counts = rust_ingest(&fixture, &graph, index_files);
        assert_eq!(counts.get("program_events").unwrap().py_int(), Some(6));
        assert_eq!(counts.get("archived_tickets").unwrap().py_int(), Some(1));
        let rows = graph_rows(&graph);
        let again = rust_ingest(&fixture, &graph, index_files);
        assert_eq!(again.get("tickets_deleted").unwrap().py_int(), Some(0));
        assert_eq!(again.get("files_indexed").unwrap().py_int(), Some(0));
        assert_eq!(
            graph_rows(&graph),
            rows,
            "graph rows (index_files={index_files})"
        );
    }
    // The index skipped vendored, binary and dotted directories.
    let files: Vec<String> = graph_rows(&scratch.join("graph-true.db"))
        .into_iter()
        .filter(|row| row.starts_with("file "))
        .collect();
    assert!(files.iter().any(|row| row.contains("\"src/main.rs\"")));
    assert!(!files.iter().any(|row| row.contains("node_modules")));
    assert!(!files.iter().any(|row| row.contains("binary.json")));
    assert!(fixture.legacy.exists());
}

/// The same capture into two identical projects commits the same tree and
/// message, and answers with the same response.
#[test]
fn capture_commits_are_reproducible() {
    let ours = fixture("program-capture-a");
    let theirs = fixture("program-capture-b");
    for artifact in [true, false] {
        let capture_id = format!("same-{artifact}");
        let capture = |fixture: &Fixture| {
            rust_capture(
                fixture,
                &fixture.root.path.join(format!("g-{artifact}.db")),
                &mixed_entries(),
                &capture_id,
                artifact,
            )
        };
        // Commit ids carry each fixture's own history; the rest must match.
        let normalize = |value: &Value, fixture: &Fixture| {
            let mut value = value.as_dict().unwrap().clone();
            value.remove("artifact_commit");
            json::dumps(&Value::Dict(value))
                .replace(&fixture.root.path.to_string_lossy().into_owned(), "<ROOT>")
        };
        assert_eq!(
            normalize(&capture(&ours), &ours),
            normalize(&capture(&theirs), &theirs),
            "capture response (artifact={artifact})"
        );
    }
    // The archive index names fixture-specific commits, so compare the
    // events' own tree.
    let tree = |fixture: &Fixture| {
        git(
            &fixture.repo,
            &[
                "rev-parse",
                &format!("{ARTIFACT_REF}:.orchestrator/program/events"),
            ],
        )
    };
    let message =
        |fixture: &Fixture| git(&fixture.repo, &["log", "-1", "--format=%B", ARTIFACT_REF]);
    assert_eq!(tree(&ours), tree(&theirs));
    assert_eq!(message(&ours), message(&theirs));
    // A derived capture id starts with the capture time in milliseconds.
    let derived = rust_capture(
        &ours,
        &ours.root.path.join("d.db"),
        &decision_entries(),
        "",
        false,
    );
    let derived = dict(&derived).get("capture_id").unwrap().py_str();
    assert!(derived.starts_with("1785819600250-"), "{derived}");
}

/// Input identities move only when an input does, and a reused project keeps
/// its graph.
#[test]
fn input_state_tracks_board_and_ref_changes() {
    let fixture = fixture("program-inputs");
    let graph_path = fixture.root.path.join("graph.db");
    let first = registered_projects_input_state(&fixture.registry, Some(&fixture.runs))
        .unwrap()
        .expect("plain .git directories are readable");
    let again = registered_projects_input_state(&fixture.registry, Some(&fixture.runs))
        .unwrap()
        .unwrap();
    assert_eq!(first, again);
    let (unchanged, runs_unchanged) = unchanged_project_inputs(Some(&first), Some(&again)).unwrap();
    assert_eq!(unchanged.len(), 2);
    assert!(runs_unchanged);

    let counts = rust_ingest(&fixture, &graph_path, false);
    let before = graph_file_state(&graph_path);
    assert!(before[0].is_some());
    fs::write(
        fixture.legacy.join(".orchestrator/LG-2.md"),
        "---\nid: LG-2\ntitle: More\nstatus: backlog\npriority: low\ndepends_on: [LG-1]\n\
         run_id: null\ncanceled: false\n---\nBody\n",
    )
    .unwrap();
    let moved = registered_projects_input_state(&fixture.registry, Some(&fixture.runs))
        .unwrap()
        .unwrap();
    let (unchanged, _) = unchanged_project_inputs(Some(&first), Some(&moved)).unwrap();
    assert_eq!(
        unchanged.into_iter().collect::<Vec<_>>(),
        [fixture.repo.to_string_lossy().into_owned()]
    );
    let graph = GraphifyStore::open(&graph_path).unwrap();
    let reused = ingest_registered_projects(
        &graph,
        &IngestOptions {
            registry_path: fixture.registry.clone(),
            runs_db_path: Some(fixture.runs.clone()),
            unchanged_repo_paths: [fixture.repo.to_string_lossy().into_owned()].into(),
            runs_unchanged: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        reused.get("tickets").unwrap().py_int(),
        counts
            .get("tickets")
            .unwrap()
            .py_int()
            .map(|count| count + 1)
    );
    assert_eq!(reused.get("program_events").unwrap().py_int(), Some(0));
    assert_eq!(reused.get("dependencies").unwrap().py_int(), Some(1));
    assert_ne!(graph_file_state(&graph_path), before);
}

/// A legacy capture-only node exports to a durable event, and a clean
/// rebuild reproduces its manifest.
#[test]
fn legacy_captures_export_and_rebuild() {
    let fixture = fixture("program-export");
    let graph_path = fixture.root.data_root().join("graphify.db");
    let graph = GraphifyStore::open(&graph_path).unwrap();
    rust_ingest(&fixture, &graph_path, false);
    let project = with_graph(&graph, |g| {
        Ok(
            g.find_node(NODE_PROJECT, &format!("repo:{}", fixture.repo.display()))?
                .unwrap(),
        )
    })
    .unwrap();
    let mut body = Dict::new();
    body.insert("capture_id", "legacy-1");
    body.insert("entry_index", 0i64);
    body.insert("summary", "Legacy decision");
    body.insert("occurred_at", 1_700_000_000.0);
    body.insert("capture_source", "session_capture");
    body.insert("provider_key", "codex");
    in_transaction(&graph, |g| {
        g.upsert_node(
            NODE_DECISION,
            "capture:legacy-1:0",
            project.get("id").and_then(Value::as_str),
            Some("Legacy decision"),
            Some(&body),
            None,
        )?;
        Ok(())
    })
    .unwrap();
    let store = open_store(
        &fixture.repo,
        "contract-program",
        &fixture.root.state_root(),
    );
    let report = export_graphify_project_captures(
        &graph,
        &store,
        &fixture.root.state_root(),
        DEVICE,
        Some("codex"),
        None,
    )
    .map_err(|failure| failure.error)
    .unwrap();
    assert_eq!(report.get("status").unwrap().as_str(), Some("verified"));
    assert_eq!(report.get("records").unwrap().py_int(), Some(1));
    let report_file = fixture
        .root
        .state_root()
        .join("artifacts/contract-program/program-migration/report.json");
    let written = fs::read_to_string(&report_file).unwrap();
    assert!(
        written.starts_with("{\n  \"artifact_commit\": "),
        "{written}"
    );
    // Exporting again is idempotent.
    let again = export_graphify_project_captures(
        &graph,
        &store,
        &fixture.root.state_root(),
        DEVICE,
        Some("codex"),
        None,
    )
    .map_err(|failure| failure.error)
    .unwrap();
    assert_eq!(show(again.get("idempotent")), "true");

    let documents = vec![
        json::parse(&git(
            &fixture.repo,
            &[
                "show",
                &format!(
                    "{ARTIFACT_REF}:.orchestrator/program/events/{}.json",
                    program_event_id("capture:legacy-1:0").unwrap()
                ),
            ],
        ))
        .unwrap()
        .as_dict()
        .unwrap()
        .clone(),
    ];
    let expected = expected_graph_manifest(&documents).unwrap();
    drop(graph);
    let rebuilt = replace_graphify_with_clean_rebuild(
        &graph_path,
        &fixture.registry,
        Some(&fixture.runs),
        &expected,
        &fixture.root.path.join("graphify-backup.db"),
    )
    .unwrap();
    assert_eq!(
        json::dumps(rebuilt.get("capture_manifest").unwrap()),
        json::dumps(&Value::Dict(expected.clone()))
    );
    let graph = GraphifyStore::open(&graph_path).unwrap();
    assert_eq!(
        json::dumps(&Value::Dict(graph_capture_manifest(&graph).unwrap())),
        json::dumps(&Value::Dict(expected))
    );
    assert!(fixture.root.path.join("graphify-backup.db").exists());
}
