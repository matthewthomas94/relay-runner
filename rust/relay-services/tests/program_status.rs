//! Program status and the Workspace dashboard (RR-499), against the RR-485
//! contract case.

mod common;

use relay_intents::json;
use relay_services::program_status::{
    STALE_AFTER_SECONDS, build_program_dashboard, build_program_status, program_context,
};
use relay_services::{Dict, Value};
use relay_store::graphify::{GraphifyStore, NODE_PROGRAM_EVENT, NODE_PROJECT, NODE_TICKET};

use common::TempRoot;

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
