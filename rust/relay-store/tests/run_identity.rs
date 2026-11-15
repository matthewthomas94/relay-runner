//! RR-504: the runs ledger keeps the provider's process group and start time
//! with its pid, and startup reconciliation follows what the caller found of
//! each active run's process.

mod common;

use relay_store::Value;
use relay_store::runs::{NewRun, RunUpdate, RunsStore, StartupProcess};

use common::TempRoot;

fn store(root: &TempRoot) -> RunsStore {
    RunsStore::open(&root.data_root().join("runs.db"), None).unwrap()
}

fn insert(store: &RunsStore, ticket_id: &str, mode: &str) -> i64 {
    store
        .insert(&NewRun {
            ticket_id: ticket_id.to_string(),
            repo_path: "/tmp/repo".to_string(),
            workspace_path: "/tmp/workspace".to_string(),
            branch: format!("relay/{}", ticket_id.to_lowercase()),
            state: "Claimed".to_string(),
            execution_mode: Some(mode.to_string()),
            ..NewRun::default()
        })
        .unwrap()
}

fn running(store: &RunsStore, run_id: i64, pid: i64, identity: Option<(i64, i64)>) {
    store
        .update(
            run_id,
            &RunUpdate {
                state: Some("Running".to_string()),
                pid: Some(pid),
                pgid: identity.map(|(pgid, _)| pgid),
                pid_start_us: identity.map(|(_, start)| start),
                ..RunUpdate::default()
            },
        )
        .unwrap();
}

fn field(store: &RunsStore, run_id: i64, key: &str) -> Value {
    store
        .get(run_id)
        .unwrap()
        .unwrap()
        .get(key)
        .unwrap()
        .clone()
}

#[test]
fn a_recorded_pid_carries_its_group_and_start_time_and_a_new_pid_replaces_both() {
    let root = TempRoot::new("run-identity");
    let store = store(&root);
    let run = insert(&store, "RR-1", "implementation");
    assert!(matches!(field(&store, run, "pgid"), Value::Null));
    assert!(matches!(field(&store, run, "pid_start_us"), Value::Null));

    running(&store, run, 4242, Some((4242, 1_700_000_000_123_456)));
    assert_eq!(field(&store, run, "pid").py_int(), Some(4242));
    assert_eq!(field(&store, run, "pgid").py_int(), Some(4242));
    assert_eq!(
        field(&store, run, "pid_start_us").py_int(),
        Some(1_700_000_000_123_456)
    );

    // An update without a pid leaves the identity alone.
    store
        .update(
            run,
            &RunUpdate {
                state: Some("AwaitingReview".to_string()),
                ..RunUpdate::default()
            },
        )
        .unwrap();
    assert_eq!(field(&store, run, "pgid").py_int(), Some(4242));

    // A pid recorded without an identity never keeps the previous one.
    running(&store, run, 5151, None);
    assert_eq!(field(&store, run, "pid").py_int(), Some(5151));
    assert!(matches!(field(&store, run, "pgid"), Value::Null));
    assert!(matches!(field(&store, run, "pid_start_us"), Value::Null));
}

#[test]
fn startup_reconciliation_follows_what_was_found_of_each_process() {
    let root = TempRoot::new("run-reconcile");
    let store = store(&root);
    let gone = insert(&store, "RR-1", "implementation");
    let stopped = insert(&store, "RR-2", "implementation");
    let unverified = insert(&store, "RR-3", "implementation");
    let spike = insert(&store, "RR-4", "spike");
    let claimed = insert(&store, "RR-5", "implementation");
    running(&store, gone, 101, Some((101, 1)));
    running(&store, stopped, 102, Some((102, 2)));
    running(&store, unverified, 103, None);
    running(&store, spike, 104, None);

    let mut seen = Vec::new();
    let reconciled = store
        .reconcile_on_startup(|run| {
            let id = run.get("id").and_then(Value::py_int).unwrap();
            seen.push((
                id,
                run.get("pgid").and_then(Value::py_int),
                run.get("pid_start_us").and_then(Value::py_int),
            ));
            match id {
                id if id == stopped => StartupProcess::Stopped,
                id if id == unverified || id == spike => StartupProcess::Unverified,
                _ => StartupProcess::Gone,
            }
        })
        .unwrap();
    assert_eq!(reconciled, 4);
    seen.sort();
    assert_eq!(
        seen,
        vec![
            (gone, Some(101), Some(1)),
            (stopped, Some(102), Some(2)),
            (unverified, None, None),
            (spike, None, None),
            (claimed, None, None),
        ],
        "every active run is settled with its recorded identity"
    );

    let state = |run| field(&store, run, "state").py_str();
    let error = |run| field(&store, run, "last_error").py_str();
    assert_eq!(state(gone), "Stalled");
    assert_eq!(
        error(gone),
        "Worker process was no longer running when daemon restarted"
    );
    assert_eq!(state(stopped), "Stalled");
    assert_eq!(
        error(stopped),
        "Worker process of the previous daemon was stopped when daemon restarted"
    );
    assert!(field(&store, stopped, "ended_at").py_float().is_some());
    assert_eq!(
        state(unverified),
        "Running",
        "an unverified worker keeps its run"
    );
    assert_eq!(state(spike), "Stalled", "a spike never survives a restart");
    assert_eq!(
        error(spike),
        "Spike stopped during daemon restart; retry is available"
    );
    assert_eq!(state(claimed), "Stalled");

    // Nothing active is left but the unverified worker.
    assert_eq!(
        store
            .reconcile_on_startup(|_| StartupProcess::Unverified)
            .unwrap(),
        0
    );
}
