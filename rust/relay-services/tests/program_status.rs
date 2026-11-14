//! Program status and the Workspace dashboard (RR-499), against the RR-485
//! contract case and against `services/program_status.py` on one graph.

mod common;

use std::fs;
use std::path::Path;

use relay_intents::json;
use relay_services::program_status::{
    PROGRAM_STATUS_QUERIES, STALE_AFTER_SECONDS, build_program_dashboard, build_program_status,
    program_context,
};
use relay_services::{Dict, Value};
use relay_store::graphify::{GraphifyStore, NODE_PROGRAM_EVENT, NODE_PROJECT, NODE_TICKET};

use common::{TempRoot, python, run_python};

const NOW: f64 = 1_790_000_000.0;

fn dict(pairs: &[(&str, Value)]) -> Dict {
    let mut value = Dict::new();
    for (key, item) in pairs {
        value.insert(key, item.clone());
    }
    value
}

fn text(value: &str) -> Value {
    Value::Str(value.to_string())
}

/// ProgramAndFollowupTests.test_capture_status_and_dashboard: after one
/// program capture on one registered project, the status lists that project
/// and the dashboard answers with its summary.
#[test]
fn contract_capture_status_and_dashboard() {
    let root = TempRoot::new("status-contract");
    let repo = root.path.join("program");
    let repo_path = repo.to_string_lossy().into_owned();
    let store = GraphifyStore::open(&root.data_root().join("graphify.db")).unwrap();

    // Before any project is indexed.
    let empty =
        build_program_status(&store, None, None, 8, Some(NOW), STALE_AFTER_SECONDS).unwrap();
    assert_eq!(
        empty.get("message").and_then(Value::as_str),
        Some(
            "No registered projects are indexed in Graphify Core. Activate or register a \
             project, then refresh program status."
        )
    );

    // The nodes the ingest writes for the contract's artifact project.
    store
        .transaction(|graph| {
            let project = graph.upsert_node(
                NODE_PROJECT,
                &format!("repo:{repo_path}"),
                None,
                Some("program"),
                Some(&dict(&[
                    ("project_id", text(&repo_path)),
                    ("repo_path", text(&repo_path)),
                    ("root_path", text(&repo_path)),
                    ("alias", Value::Null),
                    ("display_name", Value::Null),
                    ("active", Value::Bool(false)),
                ])),
                None,
            )?;
            let project_id = project
                .get("id")
                .and_then(Value::as_str)
                .unwrap()
                .to_string();
            graph.upsert_node(
                NODE_TICKET,
                &format!("repo:{repo_path}:CT-1"),
                Some(&project_id),
                Some("CT-1"),
                Some(&dict(&[
                    ("ticket_id", text("CT-1")),
                    ("status", text("backlog")),
                    ("execution_mode", text("spike")),
                ])),
                None,
            )?;
            graph.upsert_node(
                NODE_PROGRAM_EVENT,
                "program-event:capture-1:decision",
                Some(&project_id),
                Some("Ship the contract suite."),
                Some(&dict(&[("kind", text("Decision"))])),
                None,
            )?;
            Ok(())
        })
        .unwrap();

    let status =
        build_program_status(&store, None, None, 8, Some(NOW), STALE_AFTER_SECONDS).unwrap();
    assert_eq!(
        json::dumps(status.get("counts").unwrap()),
        r#"{"projects": 1, "items": 1}"#
    );
    let item = status.get("items").and_then(Value::as_list).unwrap()[0]
        .as_dict()
        .unwrap()
        .clone();
    let project = item.get("project").and_then(Value::as_dict).unwrap();
    assert_eq!(
        project.get("path").and_then(Value::as_str),
        Some(repo_path.as_str())
    );
    assert_eq!(item.get("open_tickets").and_then(Value::py_int), Some(1));
    assert_eq!(item.get("backlog_tickets").and_then(Value::py_int), Some(1));

    let dashboard =
        build_program_dashboard(&store, None, None, 0, Some(NOW), STALE_AFTER_SECONDS, None)
            .unwrap();
    let keys: Vec<&str> = dashboard.iter().map(|(key, _)| key).collect();
    assert_eq!(
        keys,
        [
            "summary",
            "backlog",
            "ready",
            "in_progress",
            "done",
            "awaiting_merge"
        ]
    );
    // A context kept for the same graph gives the same dashboard.
    let context = program_context(&store, None).unwrap();
    let cached = build_program_dashboard(
        &store,
        None,
        None,
        0,
        Some(NOW),
        STALE_AFTER_SECONDS,
        Some(&context),
    )
    .unwrap();
    assert_eq!(
        json::dumps(&Value::Dict(cached)),
        json::dumps(&Value::Dict(dashboard))
    );

    let error = build_program_status(&store, Some("weather"), None, 8, None, STALE_AFTER_SECONDS)
        .unwrap_err();
    assert_eq!(error.class, "ProgramStatusError");
    assert!(
        error
            .message
            .starts_with("unknown program status query 'weather'")
    );
}

/// A graph with every state the views distinguish, written by the Python
/// store so both implementations read the same rows.
const BUILD_GRAPH: &str = r#"
import json, os, sys
from graphify_core import GraphifyCoreStore
root, source = sys.argv[1], sys.argv[2]
store = GraphifyCoreStore(os.path.join(root, "graphify.db"))
def project(key, title, body):
    return store.upsert_node(kind="Project", stable_key=key, title=title, body=body)["id"]
alpha = project("repo:/work/alpha", "Alpha", {"repo_path": "/work/alpha", "providers": {
    "codex": {"health": "degraded", "last_error": "login expired"},
    "claude": {"status": "ready"}, "open_router": {"config_status": "missing key"}}})
beta = project("repo:/work/beta", None, {"display_name": "beta board", "root_path": "/work/beta"})
gamma = project("repo:/work/gamma", None, {"project_id": "gamma-id"})
def ticket(project_id, ticket_id, body, title=None):
    body = {"ticket_id": ticket_id, **body}
    return store.upsert_node(kind="Ticket", stable_key=f"{project_id}:{ticket_id}",
                             project_id=project_id, title=title or f"Ticket {ticket_id}", body=body)["id"]
def run(project_id, run_id, body):
    return store.upsert_node(kind="Run", stable_key=f"run:{run_id}", project_id=project_id,
                             title=f"Run {run_id}", body={"run_id": run_id, **body})["id"]
t1 = ticket(alpha, "A-1", {"status": "backlog", "priority": " high ", "depends_on": ["A-2", "A-9"]})
t2 = ticket(alpha, "A-2", {"status": "ready", "worker_model": "fast", "source_path": source,
                           "ticket_created_at": 1789990000.5})
t3 = ticket(alpha, "A-3", {"status": "in_progress", "run_id": 3, "execution_mode": "spike",
                           "worker_effort": "high", "worker_model": "strong",
                           "worker_sizing_rationale": "r", "worker_provider_notes": "none"})
t4 = ticket(alpha, "A-4", {"state": "done", "run_id": 4})
t5 = ticket(alpha, "A-5", {"status": "awaiting_merge"})
t6 = ticket(alpha, "A-6", {"status": "blocked", "materialized": False})
t7 = ticket(alpha, "A-7", {"status": "ready", "worker_model": "fast", "worker_effort": "low",
                           "worker_sizing_rationale": "small", "worker_provider_notes": "none"})
t8 = ticket(alpha, "A-8", {"status": "verification_blocked", "depends_on": "A-4"})
b1 = ticket(beta, "B-1", {"status": "Discovery"})
b2 = ticket(beta, "B-2", {"status": "backlog", "depends_on": ["B-1"]})
b3 = ticket(beta, "B-3", {"status": "canceled"})
b4 = ticket(beta, "B-4", {"status": "ready"})
g1 = ticket(gamma, "G-1", {"status": "in-progress"})
orphan = store.upsert_node(kind="Ticket", stable_key="orphan:X-1", project_id="missing",
                           title="Orphan", body={"ticket_id": "X-1", "status": "ready"})
r1 = run(alpha, 1, {"state": "Running", "started_at": 1789990000, "activity_at": 1789990100,
                    "provider_key": "codex", "model_alias": "sol", "branch": "relay/a-3",
                    "activity": "editing files", "attempt": 1})
r2 = run(alpha, 2, {"state": "failed", "started_at": 1789990500, "provider": {"key": "Claude"},
                    "last_error": "boom", "attempt": 2})
r3 = run(alpha, 3, {"state": "claimed", "started_at": 1789980000, "provider_key": "codex",
                    "ticket_id": "A-3"})
r4 = run(alpha, 4, {"state": "merged", "started_at": 1789970000, "last_error": "old",
                    "provider_key": "claude", "ticket_id": "A-4"})
r5 = run(alpha, 5, {"program_state": "awaiting_review", "started_at": 1789960000,
                    "provider_key": "claude", "ticket_id": "A-5", "worker_model": "balanced"})
r6 = run(alpha, 6, {"state": "stalled", "started_at": "1789950000", "provider_key": "codex",
                    "ticket_id": "A-7"})
r7 = run(beta, 7, {"raw_state": "MergeConflict", "started_at": 1789999000, "provider_key": "codex",
                   "ticket_id": "B-4", "execution_mode": "implementation"})
r8 = run(beta, 8, {"state": "integration_blocked", "started_at": 1789999500,
                   "provider_key": "claude", "ticket_id": "B-2", "last_error": "conflict in x"})
r9 = run(gamma, 9, {"state": "reviewing", "started_at": 1789999990, "ticket_id": "nope",
                    "provider_key": "open-router"})
r10 = run(alpha, 10, {"state": "running", "started_at": 1789990000, "activity_at": 1789999990,
                      "provider_key": "codex"})
store.upsert_edge(src_id=r1, dst_id=t3, kind="executes")
store.upsert_edge(src_id=r2, dst_id=t3, kind="executes")
store.upsert_edge(src_id=r10, dst_id=t1, kind="executes")
store.upsert_edge(src_id=t2, dst_id=t1, kind="blocks")
store.upsert_edge(src_id=b1, dst_id=b2, kind="blocks")
store.upsert_edge(src_id=t7, dst_id=r6, kind="awaits_merge")
"#;

const REPORT: &str = r#"
import json, os, sys
from graphify_core import GraphifyCoreStore
from program_status import (PROGRAM_STATUS_QUERIES, ProgramStatusError, build_program_dashboard,
                            build_program_status, program_context)
root, now = sys.argv[1], float(sys.argv[2])
store = GraphifyCoreStore(os.path.join(root, "graphify.db"))
report = {}
for provider in (None, "codex", "Claude", "open router"):
    for query in PROGRAM_STATUS_QUERIES:
        for limit in (8, 0, 1):
            report[f"{provider}/{query}/{limit}"] = build_program_status(
                store, query=query, provider=provider, limit=limit, now=now)
    report[f"{provider}/dashboard"] = build_program_dashboard(store, provider=provider, now=now)
report["filtered"] = build_program_dashboard(
    store, repo_paths=["/work/beta", " ", "/work/gamma/../gamma"], limit=2, now=now)
report["context"] = build_program_dashboard(
    store, now=now, context=program_context(store, repo_paths=["/work/alpha"]))
for query in ("Look-At Next", "attention", "bogus"):
    try:
        report[f"alias/{query}"] = build_program_status(store, query=query, now=now)
    except ProgramStatusError as error:
        report[f"alias/{query}"] = {"error": str(error)}
print(json.dumps(report))
"#;

fn rust_report(store: &GraphifyStore) -> Dict {
    let mut report = Dict::new();
    for provider in [None, Some("codex"), Some("Claude"), Some("open router")] {
        let label = provider.unwrap_or("None");
        for query in PROGRAM_STATUS_QUERIES {
            for limit in [8, 0, 1] {
                let status = build_program_status(
                    store,
                    Some(query),
                    provider,
                    limit,
                    Some(NOW),
                    STALE_AFTER_SECONDS,
                )
                .unwrap();
                report.insert(&format!("{label}/{query}/{limit}"), Value::Dict(status));
            }
        }
        let dashboard = build_program_dashboard(
            store,
            provider,
            None,
            0,
            Some(NOW),
            STALE_AFTER_SECONDS,
            None,
        )
        .unwrap();
        report.insert(&format!("{label}/dashboard"), Value::Dict(dashboard));
    }
    let filter: Vec<String> = ["/work/beta", " ", "/work/gamma/../gamma"]
        .iter()
        .map(|path| path.to_string())
        .collect();
    let filtered = build_program_dashboard(
        store,
        None,
        Some(&filter),
        2,
        Some(NOW),
        STALE_AFTER_SECONDS,
        None,
    )
    .unwrap();
    report.insert("filtered", Value::Dict(filtered));
    let alpha = vec!["/work/alpha".to_string()];
    let context = program_context(store, Some(&alpha)).unwrap();
    let cached = build_program_dashboard(
        store,
        None,
        None,
        0,
        Some(NOW),
        STALE_AFTER_SECONDS,
        Some(&context),
    )
    .unwrap();
    report.insert("context", Value::Dict(cached));
    for query in ["Look-At Next", "attention", "bogus"] {
        let answer =
            match build_program_status(store, Some(query), None, 8, Some(NOW), STALE_AFTER_SECONDS)
            {
                Ok(status) => Value::Dict(status),
                Err(error) => {
                    let mut failure = Dict::new();
                    failure.insert("error", error.message);
                    Value::Dict(failure)
                }
            };
        report.insert(&format!("alias/{query}"), answer);
    }
    report
}

#[test]
fn python_and_rust_report_the_same_graph() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("status-parity");
    let data_root = root.data_root();
    let source = root.path.join("A-2.md");
    fs::write(&source, "---\nid: A-2\n---\n").unwrap();
    let data = data_root.to_string_lossy().into_owned();
    run_python(
        &python,
        &root.path,
        BUILD_GRAPH,
        &[&data, &source.to_string_lossy()],
    );
    let theirs = run_python(
        &python,
        &root.path,
        REPORT,
        &[&data, &json::float_repr(NOW)],
    );
    let theirs = json::parse(theirs.trim()).expect("Python report");
    let store = GraphifyStore::open(&data_root.join("graphify.db")).unwrap();
    let ours = rust_report(&store);
    let Value::Dict(theirs) = theirs else {
        panic!("report is an object")
    };
    let mut compared = 0;
    for (key, expected) in theirs.iter() {
        let actual = ours.get(key).unwrap_or_else(|| panic!("missing {key}"));
        assert_eq!(json::dumps(actual), json::dumps(expected), "{key} differs");
        compared += 1;
    }
    assert_eq!(compared, ours.len());
    // The graph exercises the views rather than leaving them empty.
    let next = ours.get("None/next/0").and_then(Value::as_dict).unwrap();
    assert!(next.get("items").and_then(Value::as_list).unwrap().len() >= 5);
    assert!(Path::new(&source).exists());
}
