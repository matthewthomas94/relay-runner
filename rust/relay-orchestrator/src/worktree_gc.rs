//! Retention for the worktrees and `relay/<id>` branches that Failed, Stalled
//! and Canceled runs leave behind (RR-511).
//!
//! Those runs keep their worktree on purpose so their saved work can be
//! inspected or retried, and until now nothing removed them. The sweep finds
//! such runs that ended more than `[orchestrator] stale_worktree_retention_days`
//! (default 7) ago. It only reports them unless
//! `[orchestrator] delete_stale_worktrees = true`, and then removes them with
//! the same `remove_worktree` and `delete_branch` the merge and cancel paths
//! use. It never touches a run that is still live, awaiting review, kept for
//! verification or integration, a preserved-run recovery row, a run newer than
//! the retention window, or a run whose workspace a later run of the same
//! ticket has taken over. Claude and Codex runs are treated alike: the
//! decision reads only the run ledger.

use std::collections::HashSet;
use std::path::Path;

use relay_intents::json::{self, Dict, Value};

use crate::daemon::{Daemon, guard};
use crate::dispatch::git;
use crate::runs::{delete_branch, remove_worktree};
use crate::spike::remove_spike_workspace;

pub const DEFAULT_RETENTION_DAYS: f64 = 7.0;
/// The only run states whose worktree the sweep may remove.
pub const CLEANUP_STATES: [&str; 3] = ["Failed", "Stalled", "Canceled"];
/// How often the daemon looks again after its first sweep at startup.
pub const SWEEP_INTERVAL_SECONDS: f64 = 3600.0;
/// How many ledger rows one sweep reads.
const LEDGER_LIMIT: i64 = 100_000;

/// What one sweep is allowed to do, read from `[orchestrator]`.
pub struct Policy {
    pub now: f64,
    pub retention_days: f64,
    pub delete: bool,
    pub workspace_root: String,
    pub branch_prefix: String,
}

impl Policy {
    /// `[orchestrator] stale_worktree_retention_days` and
    /// `delete_stale_worktrees`. Deleting needs an explicit TOML `true`.
    pub fn from_config(orchestrator: &Dict, daemon: &Daemon, now: f64) -> Self {
        let (retention_days, delete) = settings(orchestrator);
        Self {
            now,
            retention_days,
            delete,
            workspace_root: daemon.paths.workspace_root.to_string_lossy().into_owned(),
            branch_prefix: daemon.branch_prefix.clone(),
        }
    }

    fn cutoff(&self) -> f64 {
        self.now - self.retention_days * 86_400.0
    }
}

/// `(retention_days, delete)` from the `[orchestrator]` table: a negative,
/// non-numeric or missing retention is the default, and anything other than
/// a boolean `true` leaves the sweep report-only.
pub fn settings(orchestrator: &Dict) -> (f64, bool) {
    let retention_days = orchestrator
        .get("stale_worktree_retention_days")
        .filter(|value| !matches!(value, Value::Bool(_)))
        .and_then(Value::py_float)
        .filter(|days| days.is_finite() && *days >= 0.0)
        .unwrap_or(DEFAULT_RETENTION_DAYS);
    let delete = matches!(
        orchestrator.get("delete_stale_worktrees"),
        Some(Value::Bool(true))
    );
    (retention_days, delete)
}

fn id_of(run: &Dict) -> i64 {
    run.get("id").and_then(Value::py_int).unwrap_or_default()
}

/// `path` lies strictly inside `root`.
fn inside(path: &str, root: &str) -> bool {
    let root = root.trim_end_matches('/');
    !root.is_empty() && path.len() > root.len() + 1 && path.starts_with(&format!("{root}/"))
}

/// Why `run` must be kept, or `None` when its worktree and branch may go.
/// `runs` is the whole ledger; `live` holds the run ids of workers the daemon
/// is still running.
pub fn keep_reason(
    run: &Dict,
    runs: &[Dict],
    policy: &Policy,
    live: &HashSet<i64>,
) -> Option<&'static str> {
    let id = id_of(run);
    let state = run.get("state").and_then(Value::as_str).unwrap_or_default();
    if !CLEANUP_STATES.contains(&state) {
        return Some("state");
    }
    if live.contains(&id)
        || relay_store::runs::process_is_alive(run.get("pid").and_then(Value::py_int))
    {
        return Some("live");
    }
    let Some(ended_at) = run.get("ended_at").and_then(Value::py_float) else {
        return Some("not-ended");
    };
    if ended_at > policy.cutoff() {
        return Some("recent");
    }
    let branch = run.string("branch");
    let spike = run.string("execution_mode") == relay_store::runs::SPIKE_EXECUTION_MODE;
    if branch.starts_with("preserved/") || (!spike && !branch.starts_with(&policy.branch_prefix)) {
        return Some("preserved");
    }
    let workspace = run.string("workspace_path");
    if !inside(&workspace, &policy.workspace_root) {
        return Some("preserved");
    }
    let repo = run.string("repo_path");
    let ticket = run.string("ticket_id");
    let superseded = runs.iter().any(|other| {
        id_of(other) > id
            && ((other.string("repo_path") == repo && other.string("ticket_id") == ticket)
                || other.string("workspace_path") == workspace)
    });
    if superseded {
        return Some("superseded");
    }
    None
}

/// The runs in `runs` whose worktree and branch the sweep may remove.
pub fn candidates(runs: &[Dict], policy: &Policy, live: &HashSet<i64>) -> Vec<Dict> {
    runs.iter()
        .filter(|run| keep_reason(run, runs, policy, live).is_none())
        .cloned()
        .collect()
}

fn branch_exists(repo: &str, branch: &str) -> bool {
    !branch.is_empty()
        && git(
            Path::new(repo),
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("refs/heads/{branch}"),
            ],
        )
        .is_ok_and(|output| output.code == 0)
}

/// Reports each candidate whose workspace or branch still exists, and when
/// `policy.delete` is set removes both. The entries are the report.
pub fn sweep(runs: &[Dict], policy: &Policy, live: &HashSet<i64>) -> Vec<Value> {
    let mut entries = Vec::new();
    for run in candidates(runs, policy, live) {
        let repo = run.string("repo_path");
        let workspace = run.string("workspace_path");
        let branch = run.string("branch");
        let spike = run.string("execution_mode") == relay_store::runs::SPIKE_EXECUTION_MODE;
        let has_workspace = Path::new(&workspace).exists();
        let has_branch = !spike && Path::new(&repo).is_dir() && branch_exists(&repo, &branch);
        if !has_workspace && !has_branch {
            continue;
        }
        let mut entry = Dict::new();
        entry.insert("run_id", id_of(&run));
        entry.insert("ticket_id", run.string("ticket_id"));
        entry.insert("state", run.string("state"));
        entry.insert("repo_path", repo.clone());
        entry.insert("workspace_path", workspace.clone());
        entry.insert("branch", branch.clone());
        if let Some(ended_at) = run.get("ended_at") {
            entry.insert("ended_at", ended_at.clone());
        }
        if policy.delete {
            let (removed, error) = if !has_workspace {
                (true, None)
            } else if spike {
                remove_spike_workspace(Path::new(&workspace))
            } else {
                remove_worktree(&repo, Path::new(&workspace))
            };
            if has_branch {
                delete_branch(&repo, &branch);
            }
            entry.insert("worktree_removed", removed);
            if let Some(error) = error {
                entry.insert("worktree_error", error);
            }
        }
        entries.push(Value::Dict(entry));
    }
    entries
}

impl Daemon {
    fn live_run_ids(&self) -> HashSet<i64> {
        let mut live: HashSet<i64> = guard(&self.workers).keys().copied().collect();
        live.extend(guard(&self.review_workers).keys().copied());
        live
    }

    /// One sweep: report, and when the setting allows it delete, the
    /// worktrees and branches of old Failed, Stalled and Canceled runs.
    pub fn sweep_stale_worktrees(&self, now: f64) -> Dict {
        let policy = Policy::from_config(&self.config_table("orchestrator"), self, now);
        // A dispatch reuses the per-ticket workspace and branch, so decide and
        // delete while no dispatch can start one.
        let _dispatching = guard(&self.dispatch_lock);
        let runs = match self.runs.list(None, LEDGER_LIMIT) {
            Ok(runs) => runs,
            Err(error) => {
                let mut result = Dict::new();
                result.insert("error", error.to_string());
                return result;
            }
        };
        let entries = sweep(&runs, &policy, &self.live_run_ids());
        let mut result = Dict::new();
        result.insert("mode", if policy.delete { "delete" } else { "report" });
        result.insert("retention_days", policy.retention_days);
        result.insert("runs", Value::List(entries));
        result
    }
}

/// The daemon's background sweep: once at startup, then hourly. A report is
/// logged when it differs from the last one, so report-only mode does not
/// repeat the same lines every hour.
pub fn sweep_loop(daemon: &Daemon, wait: &dyn Fn(f64) -> bool) {
    let mut previous: Option<String> = None;
    loop {
        let result = daemon.sweep_stale_worktrees(relay_store::sql::now());
        let text = json::dumps(&Value::Dict(result.clone()));
        let empty = result
            .get("runs")
            .is_some_and(|runs| matches!(runs, Value::List(items) if items.is_empty()));
        if previous.as_ref() != Some(&text) && !empty {
            eprintln!("[orchestrator] stale worktrees: {text}");
        }
        previous = Some(text);
        if !wait(SWEEP_INTERVAL_SECONDS) {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: f64 = 86_400.0;
    const NOW: f64 = 1_800_000_000.0;

    fn policy() -> Policy {
        Policy {
            now: NOW,
            retention_days: 7.0,
            delete: false,
            workspace_root: "/ws".to_string(),
            branch_prefix: "relay/".to_string(),
        }
    }

    fn run(id: i64, ticket: &str, state: &str, age_days: f64) -> Dict {
        let slug = ticket.to_lowercase();
        let mut run = Dict::new();
        run.insert("id", id);
        run.insert("ticket_id", ticket);
        run.insert("repo_path", "/repo");
        run.insert("workspace_path", format!("/ws/repo-abc-{slug}"));
        run.insert("branch", format!("relay/{slug}"));
        run.insert("execution_mode", "implementation");
        run.insert("state", state);
        run.insert("pid", Value::Null);
        run.insert("ended_at", NOW - age_days * DAY);
        run
    }

    fn reason(run: &Dict, runs: &[Dict]) -> Option<&'static str> {
        keep_reason(run, runs, &policy(), &HashSet::new())
    }

    #[test]
    fn old_failed_stalled_and_canceled_runs_are_candidates() {
        let runs = vec![
            run(1, "CT-1", "Failed", 8.0),
            run(2, "CT-2", "Stalled", 30.0),
            run(3, "CT-3", "Canceled", 7.5),
        ];
        let ids: Vec<i64> = candidates(&runs, &policy(), &HashSet::new())
            .iter()
            .map(id_of)
            .collect();
        assert_eq!(ids, vec![1, 2, 3]);
    }

    #[test]
    fn runs_newer_than_the_retention_window_are_kept() {
        for age in [0.0, 1.0, 6.99] {
            let runs = vec![run(1, "CT-1", "Failed", age)];
            assert_eq!(reason(&runs[0], &runs), Some("recent"), "age {age}");
        }
        let mut longer = policy();
        longer.retention_days = 30.0;
        let runs = vec![run(1, "CT-1", "Failed", 8.0)];
        assert_eq!(
            keep_reason(&runs[0], &runs, &longer, &HashSet::new()),
            Some("recent")
        );
    }

    #[test]
    fn runs_awaiting_review_or_otherwise_open_are_kept() {
        for state in [
            "AwaitingReview",
            "Reviewing",
            "MergeConflict",
            "Succeeded",
            "VerificationBlocked",
            "IntegrationBlocked",
            "Claimed",
            "Running",
            "SpikeResultReady",
            "Merged",
        ] {
            let runs = vec![run(1, "CT-1", state, 30.0)];
            assert_eq!(reason(&runs[0], &runs), Some("state"), "{state}");
        }
    }

    #[test]
    fn preserved_runs_are_kept() {
        let mut recovered = run(1, "CT-1", "Failed", 30.0);
        recovered.insert("branch", "preserved/ct-1");
        let runs = vec![recovered];
        assert_eq!(reason(&runs[0], &runs), Some("preserved"));

        let mut foreign = run(2, "CT-2", "Failed", 30.0);
        foreign.insert("workspace_path", "/Users/me/dev/repo");
        let runs = vec![foreign];
        assert_eq!(reason(&runs[0], &runs), Some("preserved"));

        let mut root = run(3, "CT-3", "Failed", 30.0);
        root.insert("workspace_path", "/ws");
        let runs = vec![root];
        assert_eq!(reason(&runs[0], &runs), Some("preserved"));

        let mut other_branch = run(4, "CT-4", "Failed", 30.0);
        other_branch.insert("branch", "main");
        let runs = vec![other_branch];
        assert_eq!(reason(&runs[0], &runs), Some("preserved"));
    }

    #[test]
    fn a_run_whose_workspace_a_later_run_reuses_is_kept() {
        for later in ["AwaitingReview", "Running", "Failed"] {
            let runs = vec![run(1, "CT-1", "Failed", 30.0), run(2, "CT-1", later, 0.0)];
            assert_eq!(reason(&runs[0], &runs), Some("superseded"), "{later}");
        }
        // The same ticket id in another repo is a different workspace.
        let mut elsewhere = run(2, "CT-1", "Running", 0.0);
        elsewhere.insert("repo_path", "/other");
        elsewhere.insert("workspace_path", "/ws/other-def-ct-1");
        let runs = vec![run(1, "CT-1", "Failed", 30.0), elsewhere];
        assert_eq!(reason(&runs[0], &runs), None);
    }

    #[test]
    fn live_or_unended_runs_are_kept() {
        let runs = vec![run(1, "CT-1", "Failed", 30.0)];
        let live: HashSet<i64> = [1].into_iter().collect();
        assert_eq!(keep_reason(&runs[0], &runs, &policy(), &live), Some("live"));

        let mut alive = run(2, "CT-2", "Stalled", 30.0);
        alive.insert("pid", i64::from(std::process::id()));
        let runs = vec![alive];
        assert_eq!(reason(&runs[0], &runs), Some("live"));

        let mut open = run(3, "CT-3", "Canceled", 30.0);
        open.insert("ended_at", Value::Null);
        let runs = vec![open];
        assert_eq!(reason(&runs[0], &runs), Some("not-ended"));
    }

    #[test]
    fn deleting_needs_an_explicit_true() {
        let config = |entries: &[(&str, Value)]| {
            let mut table = Dict::new();
            for (key, value) in entries {
                table.insert(key, value.clone());
            }
            table
        };
        let read = |table: &Dict| {
            let (days, delete) = settings(table);
            (delete, days)
        };
        assert_eq!(read(&config(&[])), (false, 7.0));
        assert_eq!(
            read(&config(&[("delete_stale_worktrees", Value::from("true"))])),
            (false, 7.0)
        );
        assert_eq!(
            read(&config(&[
                ("delete_stale_worktrees", Value::Bool(true)),
                ("stale_worktree_retention_days", Value::Int(14)),
            ])),
            (true, 14.0)
        );
        assert_eq!(
            read(&config(&[(
                "stale_worktree_retention_days",
                Value::Int(-1)
            )])),
            (false, 7.0)
        );
    }
    fn sh(cwd: &Path, args: &[&str]) {
        let status = std::process::Command::new("git")
            .arg("-C")
            .arg(cwd)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }

    /// A throwaway repo with one `relay/<id>` worktree per ticket.
    fn fixture(name: &str, tickets: &[&str]) -> (std::path::PathBuf, String, String) {
        let root = std::env::temp_dir().join(format!("relay-wtgc-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let repo = root.join("repo");
        let workspaces = root.join("ws");
        std::fs::create_dir_all(&repo).unwrap();
        std::fs::create_dir_all(&workspaces).unwrap();
        sh(&repo, &["init", "-q", "-b", "main"]);
        std::fs::write(repo.join("README"), "x").unwrap();
        sh(&repo, &["add", "README"]);
        sh(
            &repo,
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-qm",
                "init",
            ],
        );
        for ticket in tickets {
            let slug = ticket.to_lowercase();
            let workspace = workspaces.join(format!("repo-abc-{slug}"));
            sh(
                &repo,
                &[
                    "worktree",
                    "add",
                    "-q",
                    "-b",
                    &format!("relay/{slug}"),
                    &workspace.to_string_lossy(),
                ],
            );
        }
        let repo = repo.to_string_lossy().into_owned();
        let workspaces = workspaces.to_string_lossy().into_owned();
        (root, repo, workspaces)
    }

    fn on_disk(mut run: Dict, repo: &str, workspaces: &str) -> Dict {
        let slug = run.string("ticket_id").to_lowercase();
        run.insert("repo_path", repo);
        run.insert("workspace_path", format!("{workspaces}/repo-abc-{slug}"));
        run
    }

    #[test]
    fn report_only_leaves_everything_and_delete_removes_only_candidates() {
        let (root, repo, workspaces) = fixture("sweep", &["CT-1", "CT-2", "CT-3"]);
        let runs = vec![
            on_disk(run(1, "CT-1", "Failed", 8.0), &repo, &workspaces),
            on_disk(run(2, "CT-2", "Failed", 1.0), &repo, &workspaces),
            on_disk(run(3, "CT-3", "AwaitingReview", 30.0), &repo, &workspaces),
        ];
        let mut policy = policy();
        policy.workspace_root = workspaces.clone();
        let live = HashSet::new();

        let report = sweep(&runs, &policy, &live);
        assert_eq!(report.len(), 1);
        let Value::Dict(entry) = &report[0] else {
            panic!()
        };
        assert_eq!(entry.get("run_id").and_then(Value::py_int), Some(1));
        assert!(entry.get("worktree_removed").is_none());
        for ticket in ["ct-1", "ct-2", "ct-3"] {
            assert!(Path::new(&format!("{workspaces}/repo-abc-{ticket}")).exists());
            assert!(branch_exists(&repo, &format!("relay/{ticket}")));
        }

        policy.delete = true;
        let deleted = sweep(&runs, &policy, &live);
        assert_eq!(deleted.len(), 1);
        let Value::Dict(entry) = &deleted[0] else {
            panic!()
        };
        assert!(matches!(
            entry.get("worktree_removed"),
            Some(Value::Bool(true))
        ));
        assert!(!Path::new(&format!("{workspaces}/repo-abc-ct-1")).exists());
        assert!(!branch_exists(&repo, "relay/ct-1"));
        for ticket in ["ct-2", "ct-3"] {
            assert!(Path::new(&format!("{workspaces}/repo-abc-{ticket}")).exists());
            assert!(branch_exists(&repo, &format!("relay/{ticket}")));
        }
        // Nothing is left to report once it is gone.
        assert!(sweep(&runs, &policy, &live).is_empty());
        let _ = std::fs::remove_dir_all(root);
    }
}
