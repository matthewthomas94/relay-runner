//! The RR-485 database contract, against the Rust stores: databases written
//! by the previous release (`tests/contract/fixtures/orchestrator/v0.5.4/`)
//! open in place, keep their version, tables and columns, and serve their
//! rows unchanged; earlier schema versions migrate as the Python stores
//! migrate them; a newer one is refused and left alone.

mod common;

use std::fs;
use std::path::Path;

use rusqlite::Connection;

use relay_intents::json;
use relay_store::commands::CommandStore;
use relay_store::daemon::{DATA_ROOT_DATABASES, DaemonStores};
use relay_store::messenger::{MessengerOutcomeStore, PendingQuery};
use relay_store::runs::{NewRun, RunsStore};
use relay_store::{Dict, Error, Value, sql};

use common::{TempRoot, fixtures, repo_root, schema};

const PREVIOUS_RELEASE: &str = "v0.5.4";

/// `restore_release`: each dump into `<data root>/<name>.db`.
fn restore_release(root: &TempRoot) -> Vec<String> {
    let mut names = Vec::new();
    let mut dumps: Vec<_> = fs::read_dir(fixtures(PREVIOUS_RELEASE))
        .expect("release fixtures")
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|extension| extension == "sql"))
        .collect();
    dumps.sort();
    for dump in dumps {
        let name = format!("{}.db", dump.file_stem().unwrap().to_string_lossy());
        let script = fs::read_to_string(&dump)
            .unwrap()
            .replace("<ROOT>", &root.path.to_string_lossy());
        Connection::open(root.data_root().join(&name))
            .unwrap()
            .execute_batch(&script)
            .unwrap();
        names.push(name);
    }
    names
}

fn raw_rows(path: &Path, statement: &str) -> Vec<String> {
    let connection = Connection::open(path).unwrap();
    let mut prepared = connection.prepare(statement).unwrap();
    let columns: Vec<String> = prepared.column_names().map(str::to_string).collect();
    prepared
        .query_map([], |row| {
            let mut record = Dict::new();
            for (index, column) in columns.iter().enumerate() {
                record.insert(column, sql::sql_to_json(row.get(index)?));
            }
            Ok(json::dumps_sorted(&Value::Dict(record)))
        })
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn every_release_database_is_still_readable_and_not_downgraded() {
    let root = TempRoot::new("release-schema");
    let names = restore_release(&root);
    assert_eq!(names.len(), 8);
    let mut sorted_expected: Vec<&str> = DATA_ROOT_DATABASES.to_vec();
    sorted_expected.sort();
    assert_eq!(
        names, sorted_expected,
        "the fixture names the daemon's databases"
    );
    let before: Vec<_> = names
        .iter()
        .map(|name| schema(&root.data_root().join(name)))
        .collect();

    let stores = DaemonStores::open(&root.data_root()).expect("open the release databases");
    stores.graphify().expect("open the release program index");
    drop(stores);

    for (name, before) in names.iter().zip(before) {
        let after = schema(&root.data_root().join(name));
        assert!(
            after.user_version >= before.user_version,
            "{name} was downgraded"
        );
        for (table, columns) in &before.tables {
            let (_, now) = after
                .tables
                .iter()
                .find(|(candidate, _)| candidate == table)
                .unwrap_or_else(|| panic!("{name} lost table {table}"));
            assert_eq!(
                &now[..columns.len()],
                &columns[..],
                "{name}.{table} changed its existing columns"
            );
        }
    }
}

#[test]
fn release_runs_are_served_unchanged_and_match_the_contract_golden() {
    let root = TempRoot::new("release-runs");
    restore_release(&root);
    let runs_db = root.data_root().join("runs.db");
    let mut raw = raw_rows(&runs_db, "SELECT * FROM runs ORDER BY id DESC");
    let stores = DaemonStores::open(&root.data_root()).unwrap();
    let served = stores.runs.list(None, 100).unwrap();
    let released: Vec<&Dict> = served
        .iter()
        .filter(|run| {
            run.get("id")
                .and_then(Value::py_int)
                .is_some_and(|id| id <= 4)
        })
        .collect();
    let mut summary: Vec<(i64, String, String)> = released
        .iter()
        .map(|run| {
            (
                run.get("id").and_then(Value::py_int).unwrap(),
                run.get("ticket_id").unwrap().py_str(),
                run.get("state").unwrap().py_str(),
            )
        })
        .collect();
    summary.sort();
    assert_eq!(
        summary,
        vec![
            (1, "CT-1".into(), "Merged".into()),
            (2, "CT-2".into(), "Failed".into()),
            (3, "CT-3".into(), "Merged".into()),
            (4, "CT-4".into(), "Merged".into()),
        ]
    );
    raw.truncate(4);
    let served_text: Vec<String> = released
        .iter()
        .map(|run| json::dumps_sorted(&Value::Dict((*run).clone())))
        .collect();
    assert_eq!(
        served_text, raw,
        "release rows are served as they were stored"
    );

    // The rows the HTTP route returns, normalised as the contract suite
    // normalises them, are its `release/runs.response` golden.
    let repo = root.path.join("released").to_string_lossy().into_owned();
    let root_text = root.path.to_string_lossy().into_owned();
    let mut response = Dict::new();
    response.insert(
        "runs",
        Value::List(
            released
                .iter()
                .map(|run| normalise(&Value::Dict((*run).clone()), "", &repo, &root_text))
                .collect(),
        ),
    );
    let golden = fs::read_to_string(
        repo_root().join("tests/contract/golden/orchestrator/release/runs.response.json"),
    )
    .unwrap();
    assert_eq!(sql::dumps_indent(&Value::Dict(response)) + "\n", golden);
}

/// The contract suite's `Normalizer.value` for the fields a run row has, with
/// `sort_keys`.
fn normalise(value: &Value, key: &str, repo: &str, root: &str) -> Value {
    match value {
        Value::Dict(object) => {
            let mut keys: Vec<&str> = object.iter().map(|(name, _)| name).collect();
            keys.sort();
            let mut sorted = Dict::new();
            for name in keys {
                sorted.insert(name, normalise(object.get(name).unwrap(), name, repo, root));
            }
            Value::Dict(sorted)
        }
        Value::List(items) => Value::List(
            items
                .iter()
                .map(|item| normalise(item, key, repo, root))
                .collect(),
        ),
        Value::Str(text) => Value::Str(workspace_hash(
            &text
                .replace(repo, "<REPO:released>")
                .replace(root, "<ROOT>"),
        )),
        Value::Int(_) | Value::Float(_) if key == "pid" => Value::Str("<PID>".into()),
        Value::Int(_) | Value::Float(_) if key.ends_with("_at") => Value::Str("<TIME>".into()),
        other => other.clone(),
    }
}

/// `_WORKSPACE_RE`: `-<8 hex>-` before `<slug>-<digit>`.
fn workspace_hash(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::new();
    let mut index = 0;
    while index < bytes.len() {
        let hex = index + 10 <= bytes.len()
            && bytes[index] == b'-'
            && bytes[index + 9] == b'-'
            && bytes[index + 1..index + 9]
                .iter()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte));
        if hex {
            let rest = &text[index + 10..];
            let slug = rest
                .bytes()
                .take_while(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
                .count();
            if slug > 0
                && rest[slug..].starts_with('-')
                && rest[slug + 1..].starts_with(|c: char| c.is_ascii_digit())
            {
                out.push_str("-<HASH8>-");
                index += 10;
                continue;
            }
        }
        let character = text[index..].chars().next().unwrap();
        out.push(character);
        index += character.len_utf8();
    }
    out
}

#[test]
fn release_queue_drain_sessions_and_outcomes_are_served() {
    let root = TempRoot::new("release-ledgers");
    restore_release(&root);
    let stores = DaemonStores::open(&root.data_root()).unwrap();

    let drains = stores.queue_drains.list(None, true, 20).unwrap();
    let ids: Vec<String> = drains
        .iter()
        .map(|drain| drain.get("id").unwrap().py_str())
        .collect();
    assert_eq!(ids, vec!["drain-55c0a690382f-1"]);
    let observed: Vec<String> = drains[0]
        .get("observed_ticket_ids")
        .and_then(Value::as_list)
        .unwrap()
        .iter()
        .map(Value::py_str)
        .collect();
    assert_eq!(observed, vec!["CT-1", "CT-2", "CT-3", "CT-4"]);
    let items = drains[0].get("items").and_then(Value::as_list).unwrap();
    let scheduled: Vec<String> = items
        .iter()
        .filter_map(Value::as_dict)
        .filter(|item| {
            item.get("state")
                .is_some_and(|state| state.is_str("scheduled"))
        })
        .map(|item| item.get("ticket_id").unwrap().py_str())
        .collect();
    assert_eq!(items.len(), 4);
    assert_eq!(scheduled, vec!["CT-2"]);
    // The release drain is still live for its repository.
    let repo = root.path.join("released").to_string_lossy().into_owned();
    assert!(
        stores
            .queue_drains
            .active_for_repo(&repo, false)
            .unwrap()
            .is_some()
    );

    let sessions = stores.orchestrator_sessions.list(None, 100).unwrap();
    let sessions: Vec<(i64, String)> = sessions
        .iter()
        .map(|session| {
            (
                session.get("id").and_then(Value::py_int).unwrap(),
                session.get("provider_key").unwrap().py_str(),
            )
        })
        .collect();
    assert_eq!(sessions, vec![(1, "claude".to_string())]);

    let outcomes = stores
        .messenger_outcomes
        .pending(&PendingQuery {
            limit: 100,
            ..PendingQuery::default()
        })
        .unwrap();
    assert_eq!(outcomes.len(), 8);
    let payload = outcomes[1].get("payload").and_then(Value::as_dict).unwrap();
    assert!(
        payload
            .get("trace_event")
            .and_then(Value::as_dict)
            .is_some()
    );
    assert!(outcomes[1].get("payload_json").is_none());
}

#[test]
fn new_runs_continue_the_release_ledger() {
    let root = TempRoot::new("release-ledger");
    restore_release(&root);
    let stores = DaemonStores::open(&root.data_root()).unwrap();
    let repo = root.path.join("released").to_string_lossy().into_owned();
    assert_eq!(stores.runs.next_attempt("CT-1", Some(&repo)).unwrap(), 2);
    let run = stores
        .runs
        .insert(&NewRun {
            ticket_id: "CT-9".into(),
            repo_path: repo.clone(),
            workspace_path: "/ws/ct-9".into(),
            branch: "relay/ct-9".into(),
            state: "Claimed".into(),
            ..NewRun::default()
        })
        .unwrap();
    assert!(run > 4);
    let index: Value =
        json::parse(&fs::read_to_string(root.data_root().join("runs.json")).unwrap()).unwrap();
    let entries = index
        .as_dict()
        .unwrap()
        .get("runs")
        .and_then(Value::as_list)
        .unwrap();
    assert_eq!(
        entries[0]
            .as_dict()
            .unwrap()
            .get("run_id")
            .and_then(Value::py_int),
        Some(run)
    );
}

#[test]
fn earlier_runs_schema_gains_execution_mode_and_keeps_its_rows() {
    let root = TempRoot::new("runs-v4");
    let path = root.data_root().join("runs.db");
    Connection::open(&path)
        .unwrap()
        .execute_batch(common::RUNS_V4)
        .unwrap();
    let store = RunsStore::open(&path, None).unwrap();
    let run = store.get(1).unwrap().unwrap();
    assert_eq!(
        run.get("execution_mode").unwrap().py_str(),
        "implementation"
    );
    assert!(
        matches!(run.get("last_error"), Some(Value::Null)),
        "merged runs lose stale errors"
    );
    let after = schema(&path);
    assert_eq!(after.user_version, 5);
    assert_eq!(
        after.tables[0].1.last().map(String::as_str),
        Some("execution_mode")
    );
}

#[test]
fn earlier_command_and_outcome_schemas_migrate_in_place() {
    let root = TempRoot::new("ledgers-old");
    let commands = root.data_root().join("orchestrator_commands.db");
    Connection::open(&commands)
        .unwrap()
        .execute_batch(common::COMMANDS_V2)
        .unwrap();
    let store = CommandStore::open(&commands).unwrap();
    let migrated = store.get_private("cmd-1", None).unwrap().unwrap();
    assert_eq!(migrated.get("intent_id").unwrap().py_str(), "cmd-1");
    assert_eq!(migrated.get("source_text").unwrap().py_str(), "old command");
    assert_eq!(migrated.get("recovery_generation").unwrap().py_str(), "0");
    assert_eq!(schema(&commands).user_version, 5);

    let outcomes = root.data_root().join("messenger_outcomes.db");
    Connection::open(&outcomes)
        .unwrap()
        .execute_batch(common::OUTCOMES_V1)
        .unwrap();
    let store = MessengerOutcomeStore::open(&outcomes).unwrap();
    let pending = store
        .pending(&PendingQuery {
            limit: 10,
            ..PendingQuery::default()
        })
        .unwrap();
    assert_eq!(pending.len(), 1, "undelivered outcomes are kept");
    assert!(matches!(pending[0].get("session_key"), Some(Value::Null)));
    assert_eq!(json::dumps(pending[0].get("payload").unwrap()), "{}");
    assert_eq!(schema(&outcomes).user_version, 2);
}

#[test]
fn a_newer_schema_is_refused_and_left_alone() {
    let root = TempRoot::new("newer");
    let path = root.data_root().join("runs.db");
    Connection::open(&path)
        .unwrap()
        .execute_batch(
            "CREATE TABLE runs (id INTEGER PRIMARY KEY, future TEXT);
             INSERT INTO runs VALUES (1, 'kept');
             PRAGMA user_version = 6;",
        )
        .unwrap();
    let before = common::master(&path);
    match RunsStore::open(&path, None) {
        Err(Error::NewerSchema {
            found: 6,
            supported: 5,
            ..
        }) => {}
        Err(other) => panic!("unexpected error {other}"),
        Ok(_) => panic!("a newer schema opened"),
    }
    assert_eq!(common::master(&path), before);
    assert_eq!(
        raw_rows(&path, "SELECT * FROM runs"),
        vec!["{\"future\": \"kept\", \"id\": 1}"]
    );
}
