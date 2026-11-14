//! A Rust and a Python daemon take turns on one data root (RR-496).
//!
//! `tests/python_interop.py` opens the same files with the Python stores in
//! `services/`. The test checks that both create the same schema, that rows
//! the Rust stores write read back through the Python stores exactly as the
//! Rust stores read them (and the other way round, after Python writes over
//! them), and that both write the same `runs.json`.

mod common;

use std::collections::BTreeSet;
use std::path::Path;

use relay_intents::json;
use relay_store::commands::{CommandRecord, CommandStatus, opaque_identifier};
use relay_store::daemon::{DATA_ROOT_DATABASES, DaemonStores};
use relay_store::graphify::{
    EDGE_EXECUTES, EDGE_USES_PROVIDER, FileChunk, FileIndex, NODE_AGENT_PROVIDER, NODE_PROJECT,
    NODE_RUN, NODE_TICKET,
};
use relay_store::messenger::PendingQuery;
use relay_store::personal_catalog::FileVersion;
use relay_store::queue_drains::DrainItem;
use relay_store::runs::{NewRun, RunUpdate};
use relay_store::sessions::EnsureSession;
use relay_store::{Dict, Value, followups};

use common::{TempRoot, journal_mode, master, python, python_phase};

/// The data root's databases and the state root's, relative to the data root.
const ALL_DATABASES: [&str; 10] = [
    "runs.db",
    "queue_drains.db",
    "orchestrator_sessions.db",
    "orchestrator_commands.db",
    "messenger_outcomes.db",
    "followup_proposals.db",
    "continuity_reports.db",
    "graphify.db",
    "../general/work.db",
    "../personal-storage/catalog.sqlite3",
];

fn open_rust(data_root: &Path) -> DaemonStores {
    let stores = DaemonStores::open(data_root).expect("open the Rust stores");
    stores.personal_catalog.ensure_note_tables().unwrap();
    stores
}

#[test]
fn rust_and_python_create_the_same_schema() {
    let Some(python) = python() else { return };
    let rust = TempRoot::new("fresh-rust");
    let py = TempRoot::new("fresh-python");
    {
        let stores = open_rust(&rust.data_root());
        stores.graphify().unwrap();
    }
    python_phase(&python, &py.data_root(), "fresh");
    assert_eq!(DATA_ROOT_DATABASES.len() + 2, ALL_DATABASES.len());
    for name in ALL_DATABASES {
        let ours = rust.data_root().join(name);
        let theirs = py.data_root().join(name);
        assert_eq!(
            master(&ours),
            master(&theirs),
            "{name}: schema objects differ"
        );
        assert_eq!(
            common::schema(&ours).user_version,
            common::schema(&theirs).user_version,
            "{name}: user_version differs"
        );
        assert_eq!(
            journal_mode(&ours),
            journal_mode(&theirs),
            "{name}: journal mode differs"
        );
    }
}

#[test]
fn rust_and_python_migrate_earlier_versions_alike() {
    let Some(python) = python() else { return };
    let rust = TempRoot::new("migrate-rust");
    let py = TempRoot::new("migrate-python");
    common::write_earlier_versions(&rust.data_root());
    common::write_earlier_versions(&py.data_root());
    drop(open_rust(&rust.data_root()));
    python_phase(&python, &py.data_root(), "fresh");
    for name in [
        "runs.db",
        "orchestrator_commands.db",
        "messenger_outcomes.db",
    ] {
        let ours = rust.data_root().join(name);
        let theirs = py.data_root().join(name);
        assert_eq!(
            master(&ours),
            master(&theirs),
            "{name}: migrated schemas differ"
        );
        assert_eq!(
            common::contents(&ours),
            common::contents(&theirs),
            "{name}: migrated rows differ"
        );
        assert_eq!(
            common::schema(&ours).user_version,
            common::schema(&theirs).user_version
        );
    }
}

#[test]
fn rust_and_python_read_and_write_the_same_rows() {
    let Some(python) = python() else { return };
    let root = TempRoot::new("interop");
    let data_root = root.data_root();
    let repo_a = root.path.join("repo-a");
    std::fs::create_dir_all(&repo_a).unwrap();
    let repo_a = repo_a.to_string_lossy().into_owned();
    let repo_b = root.path.join("repo-b").to_string_lossy().into_owned();

    {
        let stores = open_rust(&data_root);
        rust_write(&stores, &repo_a);
    }
    // Opening clears `last_error` on merged runs, as the Python store does.
    open_rust(&data_root).runs.write_index();
    let schemas_before: Vec<_> = ALL_DATABASES
        .iter()
        .map(|name| master(&data_root.join(name)))
        .collect();

    // Python reads the Rust rows as the Rust stores read them, and writes
    // the same board index.
    python_phase(&python, &data_root, "index");
    assert_eq!(
        std::fs::read_to_string(data_root.join("runs.json")).unwrap(),
        std::fs::read_to_string(data_root.join("runs.python.json")).unwrap(),
        "runs.json differs from the Python daemon's"
    );
    compare_reads(&python, &data_root, &repo_a, &repo_b, "after Rust wrote");

    // Python writes over them; Rust reads the result as Python does.
    python_phase(&python, &data_root, "write");
    compare_reads(&python, &data_root, &repo_a, &repo_b, "after Python wrote");

    {
        // The Python writes are visible through the Rust stores.
        let stores = open_rust(&data_root);
        let runs = stores.runs.list(None, 100).unwrap();
        let python_run = runs
            .iter()
            .find(|run| sql_str(run, "ticket_id") == "PY-1")
            .expect("the Python run");
        assert_eq!(sql_str(python_run, "state"), "Merged");
        assert_eq!(sql_str(python_run, "activity"), "Python activity");
        let session = stores.orchestrator_sessions.get(1).unwrap().unwrap();
        assert_eq!(sql_str(&session, "state"), "reviewing");
        let command = stores
            .orchestrator_commands
            .get_public("cmd-8", None)
            .unwrap()
            .unwrap();
        assert_eq!(sql_str(&command, "recovery_generation"), "3");
        assert_eq!(sql_str(&command, "status"), "received");
        let delivered = stores
            .messenger_outcomes
            .pending(&PendingQuery {
                limit: 100,
                ..PendingQuery::default()
            })
            .unwrap();
        assert!(
            delivered
                .iter()
                .all(|outcome| outcome.get("id").and_then(Value::py_int) != Some(1))
        );
        let general = stores.general_work.list(100).unwrap();
        assert_eq!(general.get("total_count").and_then(Value::py_int), Some(2));
        assert_eq!(
            stores
                .personal_catalog
                .setting("python")
                .unwrap()
                .map(|value| json::dumps(&value)),
            Some("{\"wrote\": true, \"n\": 2}".to_string())
        );
        let (_, deleted) = stores
            .personal_catalog
            .note_entry("note-1")
            .unwrap()
            .unwrap();
        assert!(deleted);
        // Rust writes again after Python, and Python reads that too.
        stores.runs.set_activity(1, "Rust again").unwrap();
    }
    compare_reads(
        &python,
        &data_root,
        &repo_a,
        &repo_b,
        "after Rust wrote again",
    );

    // Neither daemon changed a schema the other created.
    for (name, before) in ALL_DATABASES.iter().zip(schemas_before) {
        assert_eq!(
            master(&data_root.join(name)),
            before,
            "{name}: schema changed"
        );
    }
}

fn sql_str<'a>(row: &'a Dict, key: &str) -> &'a str {
    row.get(key).and_then(Value::as_str).unwrap_or("")
}

fn rust_write(stores: &DaemonStores, repo_a: &str) {
    let runs = &stores.runs;
    let first = runs
        .insert(&NewRun {
            ticket_id: "RT-1".into(),
            repo_path: repo_a.into(),
            workspace_path: "/ws/rt-1".into(),
            branch: "relay/rt-1".into(),
            state: "Claimed".into(),
            log_path: Some("/ws/rt-1/.relay/run.log".into()),
            provider_key: Some("claude".into()),
            model_alias: Some("sonnet".into()),
            worker_model: Some("balanced".into()),
            worker_effort: Some("medium".into()),
            worker_sizing_rationale: Some("Rust wrote this run.".into()),
            worker_provider_notes: Some("none".into()),
            ..NewRun::default()
        })
        .unwrap();
    assert_eq!(first, 1);
    runs.update(
        first,
        &RunUpdate {
            state: Some("AwaitingReview".into()),
            pid: Some(1),
            exit_code: Some(0),
            last_error: Some(Some("tail \u{e9}\n\"quoted\"".into())),
            ended: true,
        },
    )
    .unwrap();
    let second = runs
        .insert(&NewRun {
            ticket_id: "RT-2".into(),
            repo_path: repo_a.into(),
            workspace_path: "/ws/rt-2".into(),
            branch: "relay/rt-2".into(),
            state: "Running".into(),
            execution_mode: Some(" Spike ".into()),
            provider_key: Some("codex".into()),
            ..NewRun::default()
        })
        .unwrap();
    runs.update(
        second,
        &RunUpdate {
            pid: Some(i64::from(std::process::id())),
            ..RunUpdate::default()
        },
    )
    .unwrap();
    runs.set_activity(second, "Running Swift build").unwrap();
    runs.insert_reconciled(50, "RT-3", repo_a, "Merged", 2, None)
        .unwrap();
    runs.insert_reconciled_replacement(50, "RT-3", repo_a, "Merged", 3, Some("occupied"))
        .unwrap();
    assert!(
        runs.insert_reconciled(50, "RT-3", repo_a, "Merged", 2, None)
            .is_err()
    );

    let drains = &stores.queue_drains;
    let (drain, created) = drains
        .ensure_active(
            repo_a,
            "main",
            "claude",
            &["RT-1".into(), "rt-2".into()],
            None,
            true,
        )
        .unwrap();
    assert!(created);
    let drain_id = sql_str(&drain, "id").to_string();
    drains
        .update_items(
            &drain_id,
            &[
                DrainItem {
                    ticket_id: "rt-1".into(),
                    state: Some("active".into()),
                    run_id: Some(1),
                    reason: Some("awaiting review".into()),
                    ..DrainItem::default()
                },
                DrainItem {
                    ticket_id: "RT-2".into(),
                    state: None,
                    next_action_at: Some(1_794_528_645.868_008),
                    blocker_owner: Some("worker".into()),
                    unresolved_dependencies: vec!["RT-1".into()],
                    ..DrainItem::default()
                },
            ],
        )
        .unwrap();
    drains
        .append_observed(&drain_id, &["RT-3".into()], true)
        .unwrap();

    stores
        .orchestrator_sessions
        .ensure(&EnsureSession {
            repo_path: repo_a.into(),
            provider_key: Some("Claude".into()),
            model_alias: Some("opus".into()),
            effort: Some("medium".into()),
            source: Some("rust".into()),
            state: Some("planning".into()),
            ..EnsureSession::default()
        })
        .unwrap();

    let commands = &stores.orchestrator_commands;
    commands
        .record(&CommandRecord {
            repo_path: repo_a.into(),
            source_text: "build it".into(),
            relay_command_seq: Value::Str("7".into()),
            relay_command_id: "cmd-7".into(),
            intent_id: Some("cmd-7:1".into()),
            provider_key: Some("claude".into()),
            context: Some(" two   lines\n\n x ".into()),
            received_at: Some(12.25),
            ..CommandRecord::default()
        })
        .unwrap();
    commands
        .record(&CommandRecord {
            repo_path: repo_a.into(),
            source_text: "and then this".into(),
            relay_command_seq: Value::Int(7),
            relay_command_id: "cmd-7".into(),
            intent_id: Some("cmd-7:2".into()),
            within_turn_order: Some(Value::Int(2)),
            status: Some("queued".into()),
            recovery_generation: Value::Int(1),
            ..CommandRecord::default()
        })
        .unwrap();
    commands
        .update_status(
            "cmd-7",
            Some("cmd-7:2"),
            &CommandStatus {
                status: "Mutation_Authorized".into(),
                ticket_id: Some("RT-1".into()),
                ..CommandStatus::default()
            },
        )
        .unwrap();

    let outcomes = &stores.messenger_outcomes;
    outcomes
        .bind_dispatcher(repo_a, "rt-1", "session-a")
        .unwrap();
    outcomes
        .record(
            repo_a,
            &trace("run-merged", "RT-1 run 1 merged", Some("rt-1"), Some(1)),
            Some("claude"),
        )
        .unwrap();
    outcomes
        .record(
            repo_a,
            &trace("reasoning-summary", "Started a drain.", None, None),
            None,
        )
        .unwrap();

    let mut draft = Dict::new();
    draft.insert("title", "Follow up in Rust");
    draft.insert("priority", "medium");
    draft.insert("depends_on", Value::List(vec![]));
    stores
        .followup_proposals
        .create_or_get(repo_a, "RT-9", 1, Some("claude"), &[draft.clone(), draft])
        .unwrap();

    let mut incident = Dict::new();
    incident.insert("incident_id", "incident-rr496");
    incident.insert("component", "bridge");
    let mut report = Dict::new();
    report.insert("schema_version", 1);
    report.insert("report_id", "continuity-report-rr496");
    report.insert("status", "unresolved");
    report.insert("incident", incident);
    report.insert("redaction_count", 0);
    let proposal = continuity_draft();
    stores
        .continuity_reports
        .record_unresolved(&report, &[proposal.clone(), proposal])
        .unwrap();

    let graph = stores.graphify().unwrap();
    graph
        .transaction(|g| {
            let mut provider = Dict::new();
            provider.insert("provider_key", "claude");
            g.upsert_node(
                NODE_PROJECT,
                "a",
                Some("project:a"),
                Some("A"),
                None,
                Some("project:a"),
            )?;
            g.upsert_node(
                NODE_AGENT_PROVIDER,
                "claude",
                None,
                Some("Claude"),
                Some(&provider),
                None,
            )?;
            let mut ticket = Dict::new();
            ticket.insert("state", "blocked");
            g.upsert_node(
                NODE_TICKET,
                "a:RT-1",
                Some("project:a"),
                Some("RT-1"),
                Some(&ticket),
                None,
            )?;
            let mut run = Dict::new();
            run.insert("state", "AwaitingReview");
            run.insert("score", 0.1);
            g.upsert_node(
                NODE_RUN,
                "a:1",
                Some("project:a"),
                Some("run 1"),
                Some(&run),
                None,
            )?;
            g.upsert_edge("run:a:1", "agentprovider:claude", EDGE_USES_PROVIDER, None)?;
            g.upsert_edge("run:a:1", "ticket:a:RT-1", EDGE_EXECUTES, Some(&provider))?;
            g.upsert_file_index(&FileIndex {
                project_id: "project:a".into(),
                rel_path: "src/relay.rs".into(),
                language: Some("rust".into()),
                size_bytes: 40,
                mtime_ns: Some(1_794_528_612_000_000_000),
                content_hash: Some("abc".into()),
                chunks: vec![
                    FileChunk {
                        text: "relay store in rust".into(),
                        start_line: Some(1),
                        end_line: Some(3),
                        chunk_ordinal: None,
                    },
                    FileChunk {
                        text: "second chunk mentions relay twice: relay".into(),
                        start_line: Some(4),
                        end_line: None,
                        chunk_ordinal: Some(7),
                    },
                ],
            })?;
            Ok(())
        })
        .unwrap();
    graph
        .with(|g| {
            let kept = BTreeSet::from(["src/relay.rs".to_string()]);
            assert_eq!(g.mark_missing_files_deleted("project:a", &kept)?, 0);
            Ok(())
        })
        .unwrap();

    stores
        .general_work
        .create(
            " Rust task ",
            "Written by Rust.",
            &["It reads back in Python.".into()],
            "rust-request",
        )
        .unwrap();
    let again = stores
        .general_work
        .create(
            " Rust task ",
            "Written by Rust.",
            &["It reads back in Python.".into()],
            "rust-request",
        )
        .unwrap();
    assert!(matches!(again.get("idempotent"), Some(Value::Bool(true))));

    let catalog = &stores.personal_catalog;
    catalog
        .set_setting("state", &Value::Str("local".into()))
        .unwrap();
    let mut metadata = Dict::new();
    metadata.insert("by", "rust");
    catalog
        .put_version(&FileVersion {
            artifact_id: "doc-1".into(),
            logical_path: "documents/a.md".into(),
            category: "documents".into(),
            sha256: "ab".repeat(32),
            size: 4,
            metadata,
            active: false,
            approved: Some(true),
            local_path: Some(format!("files/documents/doc-1/{}.md", "ab".repeat(32))),
            at: 1794528612.5,
        })
        .unwrap();
    let mut entry = Dict::new();
    entry.insert("artifact_id", "note-1");
    entry.insert("note_id", "N-1");
    entry.insert("project_id", "global-notes");
    catalog.save_note_entry("note-1", &entry, false).unwrap();
    assert!(
        catalog
            .insert_note_event("event-rs", "digest-rs", "note-1", "rev-rs")
            .unwrap()
    );
    assert!(
        !catalog
            .insert_note_event("event-rs", "other", "note-1", "rev")
            .unwrap()
    );
}

fn trace(kind: &str, message: &str, ticket: Option<&str>, run_id: Option<i64>) -> Dict {
    let mut event = Dict::new();
    event.insert("kind", kind);
    event.insert("message", message);
    event.insert("source", "orchestrator");
    if let Some(ticket) = ticket {
        event.insert("ticket_id", ticket);
    }
    if let Some(run_id) = run_id {
        event.insert("run_id", run_id);
    }
    let mut payload = Dict::new();
    payload.insert("text", message);
    payload.insert("trace_event", event);
    payload
}

/// A draft `sanitize_proposal` accepts.
fn continuity_draft() -> Dict {
    let mut draft = Dict::new();
    draft.insert("title", "Prevent recurring bridge continuity failure");
    draft.insert("description", "Diagnose and correct the bridge failure.");
    draft.insert(
        "acceptance_criteria",
        Value::List(vec![Value::Str("The defect is reproduced.".into())]),
    );
    draft.insert("priority", "high");
    draft.insert("depends_on", Value::List(vec![]));
    draft.insert("worker_model", "strong");
    draft.insert("worker_effort", "high");
    draft.insert("worker_sizing_rationale", "Continuity crosses processes.");
    draft.insert("worker_provider_notes", "Codex and Claude alike.");
    draft
}

/// The reads `python_interop.py read` makes, made through the Rust stores.
fn rust_reads(data_root: &Path, repo_a: &str, repo_b: &str) -> Dict {
    let stores = open_rust(data_root);
    let graph = stores.graphify().unwrap();
    let mut reads = Dict::new();
    let list = |rows: Vec<Dict>| Value::List(rows.into_iter().map(Value::Dict).collect());
    let optional = |row: Option<Dict>| row.map_or(Value::Null, Value::Dict);

    let runs = &stores.runs;
    reads.insert("runs.list", list(runs.list(None, 100).unwrap()));
    reads.insert(
        "runs.list.state",
        list(runs.list(Some("Running"), 10).unwrap()),
    );
    reads.insert("runs.get.1", optional(runs.get(1).unwrap()));
    reads.insert(
        "runs.find_active.RT-2",
        optional(runs.find_active("RT-2", Some(repo_a)).unwrap()),
    );
    reads.insert(
        "runs.find_awaiting_merge.RT-1",
        optional(runs.find_awaiting_merge("RT-1", Some(repo_a)).unwrap()),
    );
    reads.insert(
        "runs.next_attempt.RT-1",
        runs.next_attempt("RT-1", Some(repo_a)).unwrap(),
    );
    reads.insert(
        "runs.recent.RT-3",
        list(runs.recent_for_ticket("RT-3", Some(repo_a), 10).unwrap()),
    );
    reads.insert("runs.active_count", runs.active_count(None).unwrap());
    reads.insert(
        "runs.list_for_repo.a",
        list(runs.list_for_repo(repo_a, 1000).unwrap()),
    );
    reads.insert(
        "runs.replacements",
        list(runs.reconciled_replacements(50, "RT-3", repo_a).unwrap()),
    );

    let drains = &stores.queue_drains;
    reads.insert("drains.list", list(drains.list(None, true, 20).unwrap()));
    reads.insert("drains.live", list(drains.list(None, false, 20).unwrap()));
    reads.insert(
        "drains.active.a",
        optional(drains.active_for_repo(repo_a, true).unwrap()),
    );
    let mut paths = drains.active_repo_paths().unwrap();
    paths.sort();
    reads.insert(
        "drains.active_paths",
        Value::List(paths.into_iter().map(Value::Str).collect()),
    );

    reads.insert(
        "sessions.get.1",
        optional(stores.orchestrator_sessions.get(1).unwrap()),
    );
    reads.insert(
        "sessions.get.2",
        optional(stores.orchestrator_sessions.get(2).unwrap()),
    );

    let commands = &stores.orchestrator_commands;
    reads.insert(
        "commands.private.7.1",
        optional(commands.get_private("cmd-7", Some("cmd-7:1")).unwrap()),
    );
    reads.insert(
        "commands.public.7",
        optional(commands.get_public("cmd-7", None).unwrap()),
    );
    reads.insert(
        "commands.pending",
        list(commands.pending(None, 20).unwrap()),
    );
    reads.insert(
        "commands.recoverable",
        list(commands.recoverable(None, 20).unwrap()),
    );
    let opaque = opaque_identifier("command", "cmd-7").unwrap();
    reads.insert(
        "commands.opaque",
        optional(commands.find_by_opaque_command_id(&opaque).unwrap()),
    );

    let outcomes = &stores.messenger_outcomes;
    reads.insert(
        "outcomes.all",
        list(
            outcomes
                .pending(&PendingQuery {
                    limit: 100,
                    ..PendingQuery::default()
                })
                .unwrap(),
        ),
    );
    reads.insert(
        "outcomes.session",
        list(
            outcomes
                .pending(&PendingQuery {
                    repo_path: Some(repo_b.into()),
                    limit: 100,
                    session_key: Some("session-a".into()),
                    live_session_keys: vec!["session-b".into()],
                })
                .unwrap(),
        ),
    );

    let followup = &stores.followup_proposals;
    reads.insert(
        "followups.a",
        optional(
            followup
                .get(&followups::batch_id(repo_a, "RT-9", 1))
                .unwrap(),
        ),
    );
    reads.insert(
        "followups.b",
        optional(
            followup
                .get(&followups::batch_id(repo_b, "PY-9", 2))
                .unwrap(),
        ),
    );
    reads.insert(
        "continuity",
        optional(
            stores
                .continuity_reports
                .get("continuity-report-rr496")
                .unwrap(),
        ),
    );

    graph
        .with(|g| {
            reads.insert("graph.nodes", list(g.nodes(None, None)?));
            reads.insert("graph.edges", list(g.edges(None, None, None)?));
            reads.insert(
                "graph.neighbors",
                list(g.neighbors("project:a", None, "both")?),
            );
            reads.insert(
                "graph.tickets.claude",
                list(g.tickets_by_state(None, None, Some("claude"))?),
            );
            reads.insert("graph.blocked", list(g.blocked_work(None, None)?));
            reads.insert("graph.manifests", list(g.file_manifests(None, true)?));
            reads.insert("graph.search", list(g.search_files("relay", None, 20)?));
            Ok(())
        })
        .unwrap();

    let listing = stores.general_work.list(100).unwrap();
    let tasks: Vec<Value> = match listing.get("tasks") {
        Some(Value::List(tasks)) => tasks
            .iter()
            .map(|task| {
                let id = task.as_dict().map(|task| sql_str(task, "id")).unwrap_or("");
                Value::Dict(stores.general_work.get(id).unwrap())
            })
            .collect(),
        _ => Vec::new(),
    };
    reads.insert("general.list", listing);
    reads.insert("general.get", Value::List(tasks));

    let catalog = &stores.personal_catalog;
    reads.insert(
        "catalog.state",
        catalog.setting("state").unwrap().unwrap_or(Value::Null),
    );
    reads.insert(
        "catalog.python",
        catalog.setting("python").unwrap().unwrap_or(Value::Null),
    );
    let files = catalog.files().unwrap();
    let mut files_by_id = files.clone();
    files_by_id.sort_by(|a, b| sql_str(a, "artifact_id").cmp(sql_str(b, "artifact_id")));
    let mut versions = Vec::new();
    let mut notes = Vec::new();
    for file in &files_by_id {
        let mut rows = catalog.versions(sql_str(file, "artifact_id")).unwrap();
        rows.sort_by(|a, b| sql_str(a, "sha256").cmp(sql_str(b, "sha256")));
        versions.extend(rows);
    }
    for id in ["note-1"] {
        if let Some((entry, deleted)) = catalog.note_entry(id).unwrap() {
            notes.push(Value::List(vec![entry, Value::Bool(deleted)]));
        }
    }
    let mut events = Vec::new();
    for id in ["event-py", "event-rs"] {
        if let Some(event) = catalog.note_event(id).unwrap() {
            events.push(event);
        }
    }
    reads.insert("catalog.files", list(files_by_id));
    reads.insert("catalog.versions", list(versions));
    reads.insert("catalog.notes", Value::List(notes));
    reads.insert("catalog.note_events", list(events));
    reads
}

fn compare_reads(python: &Path, data_root: &Path, repo_a: &str, repo_b: &str, when: &str) {
    let theirs = python_phase(python, data_root, "read");
    let theirs = match json::parse(theirs.trim()) {
        Some(Value::Dict(reads)) => reads,
        _ => panic!("python read printed no object"),
    };
    let ours = rust_reads(data_root, repo_a, repo_b);
    let mut differences = Vec::new();
    for (key, value) in theirs.iter() {
        let expected = json::dumps_sorted(value);
        let actual = ours.get(key).map(json::dumps_sorted).unwrap_or_default();
        if expected != actual {
            differences.push(format!("{key}\n  python: {expected}\n  rust:   {actual}"));
        }
    }
    assert_eq!(ours.len(), theirs.len(), "{when}: the read sets differ");
    assert!(
        differences.is_empty(),
        "{when}: reads differ:\n{}",
        differences.join("\n")
    );
    // The comparison covers real rows in every store, not empty answers.
    for key in [
        "runs.list",
        "runs.replacements",
        "drains.list",
        "commands.pending",
        "commands.recoverable",
        "outcomes.all",
        "graph.nodes",
        "graph.neighbors",
        "graph.tickets.claude",
        "graph.search",
        "general.get",
        "catalog.files",
        "catalog.versions",
        "catalog.notes",
        "catalog.note_events",
    ] {
        let rows = theirs
            .get(key)
            .and_then(Value::as_list)
            .map_or(0, <[Value]>::len);
        assert!(rows > 0, "{when}: {key} read no rows");
    }
    for key in [
        "runs.get.1",
        "runs.find_active.RT-2",
        "drains.active.a",
        "sessions.get.1",
        "commands.private.7.1",
        "commands.opaque",
        "followups.a",
        "continuity",
        "catalog.state",
    ] {
        assert!(
            theirs.get(key).is_some_and(Value::truthy),
            "{when}: {key} read nothing"
        );
    }
}
