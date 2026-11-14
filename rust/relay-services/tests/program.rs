//! Program capture, artifacts and graph ingest (RR-499).
//!
//! The contract case replays `ProgramAndFollowupTests.test_capture_status_and_dashboard`
//! of `tests/contract/test_orchestrator_contract_sessions.py` against the
//! library with Rust alone. The interop cases check that a Rust and a Python
//! daemon commit the same Program events, project the same graph and read
//! each other's events: one fixture is captured into by both, then ingested
//! by both into separate `graphify.db` files that must hold the same rows.

mod common;

use std::fs;
use std::path::{Path, PathBuf};

use relay_artifacts::store::{ARTIFACT_REF, ArtifactStore, StoreOptions};
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
use relay_store::graphify::{GraphifyStore, NODE_DECISION, NODE_PROJECT};
use rusqlite::Connection;

use common::{TempRoot, git, make_repo, python, run_python};

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

/// `ProgramAndFollowupTests.test_capture_status_and_dashboard`, its capture
/// half: the response fields, the artifact commit and the refusal.
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
    // is a different event under the same identity, which Python refuses too.
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
}

#[test]
fn capture_refusals_name_the_python_errors() {
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

// -- Python interop -----------------------------------------------------------

/// Builds an artifact project with two live tickets and one archived ticket,
/// the way the Python store and retention write them.
const PYTHON_FIXTURE: &str = r#"
import json, subprocess, sys
from pathlib import Path
from artifact_store import (ArchiveIndexWrite, ArtifactMutation, ArtifactStore, TicketDelete,
                            TicketWrite)
repo, state, project_id = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
store = ArtifactStore(repo, project_id, state, enabled=True)
store.initialize(device_id="contract-device", actor_type="migration")
def ticket(tid, title, status, deps, body):
    return (f"---\nid: {tid}\nartifact_id: ticket-{tid.lower()}-artifact\ntitle: {title}\n"
            f"status: {status}\npriority: high\nexecution_mode: implementation\n"
            f"depends_on: {deps}\nrun_id: null\ncanceled: false\n"
            f"activity_at: 2026-08-04T05:00:00Z\nworker_model: balanced\nworker_effort: medium\n"
            f"---\n## Description\n\n{body}\n").encode()
first = store.mutate(ArtifactMutation(
    event_id="fixture-1", actor_type="pm", device_id="contract-device", operations=(
        TicketWrite("CT-1", "ticket-ct-1-artifact",
                    ticket("CT-1", "Ship the parser", "done", "[]", "Edit src/main.rs.")),
        TicketWrite("CT-2", "ticket-ct-2-artifact",
                    ticket("CT-2", "Follow up", "backlog", "[CT-1, CT-9]", "Read README.md.")),
        TicketWrite("CT-9", "ticket-ct-9-artifact",
                    ticket("CT-9", "Old work", "done", "[]", "Done long ago.")),
    )))
blob = subprocess.check_output(
    ["git", "-C", str(repo), "rev-parse", f"{first.commit_id}:.orchestrator/CT-9.md"],
    text=True).strip()
entry = {"schema_version": 1, "artifact_id": "ticket-ct-9-artifact", "ticket_id": "CT-9",
         "title": "Old work", "status": "done", "activity_at": "2026-08-04T05:00:00Z",
         "dependencies": [], "state": "archived", "ticket_path": ".orchestrator/CT-9.md",
         "ticket_blob": blob, "ticket_size": 0, "attachments": [],
         "source_commit": first.commit_id, "archived_at": "2026-08-05T00:00:00Z",
         "restored_at": None, "deleted_at": None}
store.mutate(ArtifactMutation(
    event_id="fixture-2", actor_type="pm", device_id="contract-device", operations=(
        TicketDelete("CT-9"),
        ArchiveIndexWrite((json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n")
                          .encode()),
    )))
"#;

const PYTHON_CAPTURE: &str = r#"
import json, sys
from artifact_store import ArtifactStore
from graphify_core import GraphifyCoreStore
from session_capture import capture_session_review
graph, repo, state, project_id, entries, capture_id, occurred, artifact = sys.argv[1:9]
artifact_store = ArtifactStore(repo, project_id, state, enabled=True) if artifact == "1" else None
result = capture_session_review(
    GraphifyCoreStore(graph), repo_path=repo, entries=json.loads(entries), provider="Claude Code",
    capture_id=capture_id or None, occurred_at=float(occurred), ticket_id="CT-1", run_id="1",
    artifact_store=artifact_store,
    artifact_device_id="contract-device" if artifact_store else None)
print(json.dumps(result))
"#;

const PYTHON_INGEST: &str = r#"
import json, sys
from graphify_core import GraphifyCoreStore
from graphify_ingest import ingest_registered_projects
graph, registry, runs, index = sys.argv[1:5]
print(json.dumps(ingest_registered_projects(
    GraphifyCoreStore(graph), registry_path=registry, runs_db_path=runs or None,
    index_files=index == "1")))
"#;

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
fn fixture(python: &Path, label: &str) -> Fixture {
    let root = TempRoot::new(label);
    let repo = make_repo(&root.path.join("program"));
    fs::create_dir_all(repo.join("src")).unwrap();
    fs::write(repo.join("src/main.rs"), "fn main() {}\n// parser\n").unwrap();
    fs::write(repo.join("notes.txt"), "line\n".repeat(130)).unwrap();
    fs::write(repo.join("binary.json"), b"{\0}").unwrap();
    fs::create_dir_all(repo.join("node_modules")).unwrap();
    fs::write(repo.join("node_modules/skip.js"), "skipped").unwrap();
    run_python(
        python,
        &root.path,
        PYTHON_FIXTURE,
        &[
            &repo.to_string_lossy(),
            &root.state_root().to_string_lossy(),
            "contract-program",
        ],
    );
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

fn python_ingest(python: &Path, fixture: &Fixture, graph_path: &Path, index: bool) -> String {
    run_python(
        python,
        &fixture.root.path,
        PYTHON_INGEST,
        &[
            &graph_path.to_string_lossy(),
            &fixture.registry.to_string_lossy(),
            &fixture.runs.to_string_lossy(),
            if index { "1" } else { "0" },
        ],
    )
}

fn python_capture(
    python: &Path,
    fixture: &Fixture,
    graph_path: &Path,
    entries: &Value,
    capture_id: &str,
    artifact: bool,
) -> Value {
    parse(&run_python(
        python,
        &fixture.root.path,
        PYTHON_CAPTURE,
        &[
            &graph_path.to_string_lossy(),
            &fixture.repo.to_string_lossy(),
            &fixture.root.state_root().to_string_lossy(),
            "contract-program",
            &json::dumps(entries),
            capture_id,
            &json::float_repr(OCCURRED_AT),
            if artifact { "1" } else { "0" },
        ],
    ))
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

/// Both daemons capture into one project's ref (each reading what the
/// other wrote), then both ingest it; the graphs hold the same rows and the
/// counts agree.
#[test]
fn rust_and_python_ingest_each_others_events_identically() {
    let Some(python) = python() else { return };
    let fixture = fixture(&python, "program-ingest");
    let scratch = fixture.root.path.join("scratch");
    fs::create_dir_all(&scratch).unwrap();

    // Rust first, Python second: the second writer validates the first's events.
    let rust = rust_capture(
        &fixture,
        &scratch.join("rust-capture.db"),
        &mixed_entries(),
        "rust-capture",
        true,
    );
    let python_result = python_capture(
        &python,
        &fixture,
        &scratch.join("python-capture.db"),
        &decision_entries(),
        "python-capture",
        true,
    );
    assert_eq!(
        show(dict(&python_result).get("artifact_idempotent")),
        "false"
    );
    assert_eq!(
        json::dumps(dict(&rust).get("counts").unwrap()),
        r#"{"ProgramEvent": 1, "Decision": 1, "Risk": 1, "Idea": 1, "Status": 1}"#
    );

    for index_files in [false, true] {
        let rust_graph = scratch.join(format!("rust-{index_files}.db"));
        let python_graph = scratch.join(format!("python-{index_files}.db"));
        let rust_counts = rust_ingest(&fixture, &rust_graph, index_files);
        let python_counts = python_ingest(&python, &fixture, &python_graph, index_files);
        assert_eq!(
            json::dumps(&Value::Dict(rust_counts.clone())),
            python_counts.trim(),
            "ingest counts (index_files={index_files})"
        );
        assert_eq!(rust_counts.get("program_events").unwrap().py_int(), Some(6));
        assert_eq!(
            rust_counts.get("archived_tickets").unwrap().py_int(),
            Some(1)
        );
        assert_eq!(
            graph_rows(&rust_graph),
            graph_rows(&python_graph),
            "graph rows (index_files={index_files})"
        );
        // Ingesting again over the other daemon's graph changes nothing, and
        // each reuses the other's file manifests.
        let python_again = python_ingest(&python, &fixture, &rust_graph, index_files);
        let rust_again = rust_ingest(&fixture, &python_graph, index_files);
        assert_eq!(
            json::dumps(&Value::Dict(rust_again.clone())),
            python_again.trim()
        );
        assert_eq!(rust_again.get("tickets_deleted").unwrap().py_int(), Some(0));
        assert_eq!(rust_again.get("files_indexed").unwrap().py_int(), Some(0));
        assert_eq!(graph_rows(&rust_graph), graph_rows(&python_graph));
    }
    // The index skipped vendored, binary and dotted directories.
    let files: Vec<String> = graph_rows(&scratch.join("rust-true.db"))
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
fn rust_and_python_capture_commits_are_identical() {
    let Some(python) = python() else { return };
    let ours = fixture(&python, "program-capture-rust");
    let theirs = fixture(&python, "program-capture-python");
    for artifact in [true, false] {
        let capture_id = format!("same-{artifact}");
        let rust = rust_capture(
            &ours,
            &ours.root.path.join(format!("g-{artifact}.db")),
            &mixed_entries(),
            &capture_id,
            artifact,
        );
        let python_result = python_capture(
            &python,
            &theirs,
            &theirs.root.path.join(format!("g-{artifact}.db")),
            &mixed_entries(),
            &capture_id,
            artifact,
        );
        // Commit ids carry each fixture's own history; the rest must match.
        let normalize = |value: &Value, fixture: &Fixture| {
            let mut value = value.as_dict().unwrap().clone();
            value.remove("artifact_commit");
            json::dumps(&Value::Dict(value))
                .replace(&fixture.root.path.to_string_lossy().into_owned(), "<ROOT>")
        };
        assert_eq!(
            normalize(&rust, &ours),
            normalize(&python_result, &theirs),
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
    // A derived capture id is the same in both.
    let derived_rust = rust_capture(
        &ours,
        &ours.root.path.join("d.db"),
        &decision_entries(),
        "",
        false,
    );
    let derived_python = python_capture(
        &python,
        &theirs,
        &theirs.root.path.join("d.db"),
        &decision_entries(),
        "",
        false,
    );
    let id = |value: &Value| dict(value).get("capture_id").unwrap().py_str();
    let rust_id = id(&derived_rust);
    assert!(rust_id.starts_with("1785819600250-"), "{rust_id}");
    // The derivation hashes the repository path, which differs between the
    // two fixtures, so only the shape can be compared here.
    assert_eq!(rust_id.len(), id(&derived_python).len());
}

/// Input identities move only when an input does, and a reused project keeps
/// its graph.
#[test]
fn input_state_tracks_board_and_ref_changes() {
    let Some(python) = python() else { return };
    let fixture = fixture(&python, "program-inputs");
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
    let Some(python) = python() else { return };
    let fixture = fixture(&python, "program-export");
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
