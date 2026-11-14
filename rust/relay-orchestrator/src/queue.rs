//! Queue drains and the ready sweeps: `_record_queue_drain_locked` and its
//! classification, `reconcile_queue_drain(s)`, list and cancel,
//! `sweep_ready_tickets` and the program sweep.
//!
//! Two drain steps start or merge workers and wait for part 5 (RR-498): a
//! drain does not dispatch a review worker (an awaiting-review run stays
//! `awaiting_review`), and reconcile resumes no integration-blocked run
//! (`resumed_integrations` stays empty). A sweep's dispatch answers the
//! execution-deferred error, which the sweep records as `dispatch_failed`
//! exactly as Python records a dispatch exception.

use std::collections::{BTreeSet, HashMap, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use relay_artifacts::ErrorKind;
use relay_artifacts::lifecycle::ArtifactLifecycleCoordinator;
use relay_artifacts::retention::{ArtifactRetentionManager, HistoryAccess, RetentionOptions};
use relay_artifacts::tickets::{self, Ticket};
use relay_intents::json::{self, Dict, Value};
use relay_store::queue_drains::{DrainItem, DrainState};
use relay_store::runs::{
    ACTIVE_STATES, INTEGRATION_BLOCKED_RUN_STATE, MERGEABLE_REVIEW_STATES, RunUpdate,
    process_is_alive,
};

use crate::daemon::{Daemon, guard, registered_project_repo_paths, resolve_path};
use crate::dispatch::{
    DispatchRequest, SourceBlocker, git, git_text, resolve_default_branch, source_checkout_blocker,
    string_values,
};
use crate::failure::{Class, Failure, Outcome};
use crate::request::Request;
use crate::router::{Reply, reply, single};
use crate::trace::LifecycleEvent;

/// `AUTO_DISPATCH_BACKOFF_SECONDS`.
pub const AUTO_DISPATCH_BACKOFF_SECONDS: f64 = 30.0;
/// `QUEUE_DRAIN_QUIESCENCE_SECONDS`.
pub const QUEUE_DRAIN_QUIESCENCE_SECONDS: f64 = 2.0;
/// `VERIFICATION_BLOCKED_STATUS`.
pub const VERIFICATION_BLOCKED_STATUS: &str = "verification_blocked";

/// `time.time()`.
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64())
}

/// Python's `except (ValueError, RuntimeError)`: every failure but an
/// `OSError` and one the handler does not catch.
pub fn is_value_or_runtime(failure: &Failure) -> bool {
    !matches!(failure.class, Class::Io | Class::Escape)
}

/// Why `_all_dependencies_done` raised.
pub enum DependencyFailure {
    /// `DependencyHistoryUnavailable`: an archived predecessor whose
    /// verified history cannot be read.
    History {
        message: String,
        availability: Option<String>,
        recovery: Option<String>,
    },
    Failure(Failure),
}

impl DependencyFailure {
    fn into_failure(self) -> Failure {
        match self {
            Self::History { message, .. } => Failure::validation(message),
            Self::Failure(failure) => failure,
        }
    }
}

/// `str(body.get(key) or "")`.
fn body_text(request: &Request, key: &str) -> String {
    request.body.string(key)
}

impl Daemon {
    /// `GET /v1/queue-drains`.
    pub fn list_queue_drains_route(&self, request: &Request) -> Outcome<Reply> {
        let repo_path = request.query_first("repo_path");
        let include_terminal = request.query_flag("include_terminal");
        let limit = request.query_int("limit", 20)?;
        let drains = self
            .queue_drains
            .list(repo_path.as_deref(), include_terminal, limit)?;
        reply(
            200,
            single(
                "queue_drains",
                Value::List(drains.into_iter().map(Value::Dict).collect()),
            ),
        )
    }

    /// `POST /v1/ready-sweep`.
    pub fn sweep_ready_tickets_route(&self, request: &Request) -> Outcome<Reply> {
        let result = self.sweep_ready_tickets(
            &body_text(request, "repo_path"),
            request.optional_text("trigger").as_deref(),
            request.optional_text("project_scope_token").as_deref(),
        )?;
        reply(200, result)
    }

    /// `POST /v1/program/ready-sweep`.
    pub fn sweep_program_ready_tickets_route(&self, request: &Request) -> Outcome<Reply> {
        let trigger = request.optional_text("trigger");
        reply(
            200,
            self.sweep_program_ready_tickets(trigger.as_deref(), None)?,
        )
    }

    /// `POST /v1/queue-drain/reconcile`.
    pub fn reconcile_queue_drains_route(&self, request: &Request) -> Outcome<Reply> {
        let mut repo_paths = match request.get("repo_paths") {
            Some(Value::Str(path)) => Some(vec![path.clone()]),
            Some(Value::List(paths)) => Some(paths.iter().map(Value::py_str).collect()),
            _ => None,
        };
        if let Some(path) = request.body.truthy("repo_path") {
            repo_paths = Some(vec![path.py_str()]);
        }
        let trigger = request.optional_text("trigger");
        reply(
            200,
            self.reconcile_queue_drains(repo_paths, trigger.as_deref())?,
        )
    }

    /// `POST /v1/queue-drains/{drain_id}/cancel`.
    pub fn cancel_queue_drain_route(&self, request: &Request) -> Outcome<Reply> {
        let reason = request.optional_text("reason");
        reply(
            200,
            self.cancel_queue_drain(&request.segments[2], reason.as_deref())?,
        )
    }
}

/// `QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS`.
pub const QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS: f64 = 5.0;

impl Daemon {
    /// `reconcile_queue_drains(repo_paths=..., trigger=...)`: each requested
    /// project, or every registered project and every repository with a live
    /// drain.
    pub fn reconcile_queue_drains(
        &self,
        repo_paths: Option<Vec<String>>,
        trigger: Option<&str>,
    ) -> Outcome<Dict> {
        let mut requested: Vec<String> = repo_paths
            .unwrap_or_default()
            .iter()
            .filter(|path| !json::py_strip(path).is_empty())
            .map(|path| resolve_path(path).to_string_lossy().into_owned())
            .collect();
        if requested.is_empty() {
            requested = registered_project_repo_paths(self.paths.registered_projects());
            requested.extend(self.queue_drains.active_repo_paths()?);
        }
        let project_trigger = trigger
            .filter(|trigger| !trigger.is_empty())
            .unwrap_or("queue-drain-monitor");
        let mut seen = HashSet::new();
        let mut projects = Vec::new();
        for path in requested {
            if !seen.insert(path.clone()) {
                continue;
            }
            match self.reconcile_queue_drain(&path, Some(project_trigger)) {
                Ok(project) => projects.push(Value::Dict(project)),
                Err(failure) if is_value_or_runtime(&failure) => {
                    let mut entry = Dict::new();
                    entry.insert("repo_path", path.as_str());
                    entry.insert("error", failure.message);
                    projects.push(Value::Dict(entry));
                }
                Err(failure) => return Err(failure),
            }
        }
        let mut result = Dict::new();
        result.insert("trigger", trigger);
        result.insert("projects", Value::List(projects));
        Ok(result)
    }

    /// `_record_queue_drain_after_event`: record the drain after a run
    /// event; a failure is only logged, since the caller's outcome is durable.
    pub fn record_queue_drain_after_event(
        &self,
        repo_path: Option<&str>,
        trigger: &str,
        drive_reviews: bool,
    ) {
        let Some(repo_path) = repo_path.filter(|path| !path.is_empty()) else {
            return;
        };
        let repo = resolve_path(repo_path);
        if !repo.is_dir() || !repo.join(".git").exists() {
            return;
        }
        if let Err(error) =
            self.record_queue_drain_locked(&repo, Some(trigger), None, drive_reviews)
        {
            eprintln!("[orchestrator] queue-drain record failed after {trigger}: {error}");
        }
    }
}

/// A live run's last observed progress (`_run_health`).
struct Health {
    checked_at: f64,
    signature: Signature,
    warning: Option<String>,
}

/// `_run_progress_signature`: activity, HEAD, `git status`, log size and
/// log mtime in nanoseconds.
type Signature = (String, String, String, i64, i128);

/// Per data root and run id; the daemon is the only owner in a process.
static RUN_HEALTH: LazyLock<Mutex<HashMap<(PathBuf, i64), Health>>> =
    LazyLock::new(Default::default);

fn run_state(run: &Dict) -> String {
    run.string("state")
}

fn run_id(run: &Dict) -> Option<i64> {
    run.present("id").and_then(Value::py_int)
}

fn progress_signature(run: &Dict) -> Signature {
    let workspace = run.string("workspace_path");
    let mut head = String::new();
    let mut status = String::new();
    if !workspace.is_empty() {
        let workspace = Path::new(&workspace);
        if let Ok(output) = git(workspace, &["rev-parse", "HEAD"])
            && output.code == 0
        {
            head = json::py_strip(&output.stdout).to_string();
        }
        if let Ok(output) = git(
            workspace,
            &["status", "--porcelain=v1", "--untracked-files=normal"],
        ) && output.code == 0
        {
            status = output.stdout;
        }
    }
    let mut log_size = -1;
    let mut log_mtime_ns = -1;
    let log_path = run.string("log_path");
    if !log_path.is_empty()
        && let Ok(metadata) = std::fs::metadata(&log_path)
    {
        log_size = metadata.len() as i64;
        log_mtime_ns =
            i128::from(metadata.mtime()) * 1_000_000_000 + i128::from(metadata.mtime_nsec());
    }
    (run.string("activity"), head, status, log_size, log_mtime_ns)
}

/// Python's `f"{value:g}"`: six significant digits, trailing zeros dropped.
fn format_g(value: f64) -> String {
    if value == 0.0 || !value.is_finite() {
        return json::float_repr(value).trim_end_matches(".0").to_string();
    }
    let exponent = value.abs().log10().floor() as i32;
    let trim = |text: String| -> String {
        if text.contains('.') {
            text.trim_end_matches('0').trim_end_matches('.').to_string()
        } else {
            text
        }
    };
    if !(-4..6).contains(&exponent) {
        let formatted = format!("{value:.5e}");
        let (mantissa, power) = formatted.split_once('e').unwrap_or((&formatted, "0"));
        let power: i32 = power.parse().unwrap_or(0);
        let sign = if power < 0 { '-' } else { '+' };
        return format!("{}e{sign}{:02}", trim(mantissa.to_string()), power.abs());
    }
    let decimals = (5 - exponent).max(0) as usize;
    trim(format!("{value:.decimals$}"))
}

/// `_health_check_window_label(seconds)`.
fn window_label(seconds: f64) -> String {
    let minutes = seconds / 60.0;
    if minutes.fract() == 0.0 {
        let value = minutes as i64;
        return if value == 1 {
            "1 minute".to_string()
        } else {
            format!("{value} minutes")
        };
    }
    format!("{} seconds", format_g(seconds))
}

/// `_latest_runs_by_ticket(runs)`: each ticket's run with the highest id.
fn latest_runs_by_ticket(runs: &[Dict]) -> HashMap<String, Dict> {
    let mut ordered: Vec<&Dict> = runs.iter().collect();
    ordered.sort_by_key(|run| std::cmp::Reverse(run_id(run).unwrap_or(0)));
    let mut latest = HashMap::new();
    for run in ordered {
        let ticket_id = run.string("ticket_id").to_uppercase();
        if !ticket_id.is_empty() && !latest.contains_key(&ticket_id) {
            latest.insert(ticket_id, run.clone());
        }
    }
    latest
}

/// The ids in a drain's `observed_ticket_ids`.
fn observed_ticket_ids(drain: Option<&Dict>) -> Vec<String> {
    match drain.and_then(|drain| drain.get("observed_ticket_ids")) {
        Some(Value::List(items)) => items.iter().map(Value::py_str).collect(),
        _ => Vec::new(),
    }
}

/// `_queue_drain_candidate_ids`: the drain's observed tickets, every queued
/// or live ticket, and the unfinished predecessors they wait on.
fn queue_drain_candidate_ids(
    tickets: &[Ticket],
    runs_by_ticket: &HashMap<String, Dict>,
    active_drain: Option<&Dict>,
) -> Vec<String> {
    let by_id: HashMap<String, &Ticket> = tickets
        .iter()
        .map(|ticket| (ticket.id.to_uppercase(), ticket))
        .collect();
    let mut observed: BTreeSet<String> = observed_ticket_ids(active_drain).into_iter().collect();
    for ticket in tickets {
        if ticket.canceled || ticket.draft {
            continue;
        }
        if ["ready", "in_progress", VERIFICATION_BLOCKED_STATUS].contains(&ticket.status.as_str()) {
            observed.insert(ticket.id.to_uppercase());
        }
    }
    for (ticket_id, run) in runs_by_ticket {
        if by_id
            .get(ticket_id)
            .is_some_and(|ticket| ticket.status == "done")
        {
            continue;
        }
        let state = run_state(run);
        if ACTIVE_STATES.contains(&state.as_str())
            || MERGEABLE_REVIEW_STATES.contains(&state.as_str())
        {
            observed.insert(ticket_id.clone());
        }
    }
    // Predecessors join the drain only while an observed ticket waits on
    // them; unrelated backlog stays outside the goal.
    let mut expanded = observed.clone();
    for ticket_id in &observed {
        let Some(ticket) = by_id.get(ticket_id) else {
            continue;
        };
        for dependency in &ticket.depends_on {
            let dependency = dependency.to_uppercase();
            if by_id
                .get(&dependency)
                .is_some_and(|predecessor| predecessor.status != "done")
            {
                expanded.insert(dependency);
            }
        }
    }
    expanded.into_iter().collect()
}

/// An item of `state` with `reason`.
fn drain_item(ticket_id: &str, state: &str, run_id: Option<i64>, reason: &str) -> DrainItem {
    DrainItem {
        ticket_id: ticket_id.to_string(),
        state: Some(state.to_string()),
        run_id,
        reason: Some(reason.to_string()),
        ..DrainItem::default()
    }
}

/// `_blocked_item(ticket_id, reason=, owner=, next_step=, run_id=)`.
fn blocked_item(
    ticket_id: &str,
    reason: &str,
    owner: &str,
    next_step: Option<&str>,
    run_id: Option<i64>,
) -> DrainItem {
    DrainItem {
        blocker_owner: Some(owner.to_string()),
        blocker_next_step: Some(
            next_step
                .filter(|step| !step.is_empty())
                .unwrap_or(reason)
                .to_string(),
        ),
        ..drain_item(ticket_id, "blocked", run_id, reason)
    }
}

/// `_integration_blocked_item(ticket_id, blocker=, run_id=)`.
fn integration_blocked_item(
    ticket_id: &str,
    blocker: &SourceBlocker,
    run_id: Option<i64>,
) -> DrainItem {
    DrainItem {
        blocker_owner: Some("source_checkout".to_string()),
        blocker_next_step: Some(blocker.next_step.clone()),
        ..drain_item(ticket_id, "integration_blocked", run_id, &blocker.reason)
    }
}

/// The item of an observed ticket whose file is gone.
fn missing_ticket_item(ticket_id: &str) -> DrainItem {
    blocked_item(
        ticket_id,
        "ticket file missing",
        "human",
        Some(&format!(
            "Restore .orchestrator/{ticket_id}.md or cancel the drain."
        )),
        None,
    )
}

/// A canceled ticket, or one waiting on predecessors: the answers given
/// before its run is looked at.
fn waiting_item(
    ticket_id: &str,
    ticket: &Ticket,
    by_id: &HashMap<String, &Ticket>,
) -> Option<DrainItem> {
    if ticket.canceled {
        return Some(drain_item(
            ticket_id,
            "canceled",
            None,
            "ticket is canceled",
        ));
    }
    let unresolved: Vec<String> = ticket
        .depends_on
        .iter()
        .filter(|dependency| {
            by_id
                .get(&dependency.to_uppercase())
                .is_none_or(|predecessor| predecessor.status != "done")
        })
        .cloned()
        .collect();
    if unresolved.is_empty() {
        return None;
    }
    Some(DrainItem {
        blocker_owner: Some("dependency".to_string()),
        blocker_next_step: Some(
            "Automatically resume when every predecessor is reviewed, merged, and done."
                .to_string(),
        ),
        ..DrainItem {
            unresolved_dependencies: unresolved.clone(),
            ..drain_item(
                ticket_id,
                "dependency_waiting",
                None,
                &format!("waiting on {}", unresolved.join(", ")),
            )
        }
    })
}

/// What the classification knows about one ticket once its run is read.
struct Progress<'a> {
    ticket_id: &'a str,
    ticket: &'a Ticket,
    run: Option<&'a Dict>,
    run_state: &'a str,
    run_id: Option<i64>,
    health_warning: Option<String>,
    skip: Option<&'a Dict>,
    source_blocker: Option<&'a SourceBlocker>,
    now: f64,
}

/// `float(run["ended_at"]) + AUTO_DISPATCH_BACKOFF_SECONDS`, when it has one.
fn backoff_ends(run: Option<&Dict>) -> Option<Option<f64>> {
    run.and_then(|run| run.present("ended_at")).map(|ended| {
        ended
            .py_float()
            .map(|ended| ended + AUTO_DISPATCH_BACKOFF_SECONDS)
    })
}

/// The rest of `_classify_queue_drain_item`: a ticket's run, its sweep skip
/// and its board status, in Python's order.
fn progress_item(
    p: &Progress<'_>,
    auto_blocker: &mut dyn FnMut() -> Outcome<Option<String>>,
    dispatch_blocker: &mut dyn FnMut() -> Outcome<Option<SourceBlocker>>,
) -> Outcome<DrainItem> {
    let id = p.ticket_id;
    let state = p.run_state;
    let last_error = p
        .run
        .map(|run| run.string("last_error"))
        .unwrap_or_default();
    if ACTIVE_STATES.contains(&state) {
        let reason = p.health_warning.as_deref().unwrap_or(state);
        return Ok(drain_item(id, "active", p.run_id, reason));
    }
    if state == "Reviewing" {
        let reason = p
            .health_warning
            .as_deref()
            .unwrap_or("review/merge worker active");
        return Ok(drain_item(id, "reviewing", p.run_id, reason));
    }
    if state == "AwaitingReview" || state == "Succeeded" {
        // Python dispatches the review/merge worker here when the drain
        // drives reviews; that is part 5 (RR-498), so the run waits for it.
        return Ok(DrainItem {
            next_action_at: Some(p.now),
            ..drain_item(id, "awaiting_review", p.run_id, "awaiting review dispatch")
        });
    }
    if state == INTEGRATION_BLOCKED_RUN_STATE {
        let fallback = SourceBlocker {
            reason: if last_error.is_empty() {
                "integration is ready to resume".to_string()
            } else {
                last_error
            },
            dirty_paths: Vec::new(),
            next_step: "Recheck integration to merge the existing reviewed run.".to_string(),
        };
        let blocker = p.source_blocker.unwrap_or(&fallback);
        return Ok(integration_blocked_item(id, blocker, p.run_id));
    }
    if state == "MergeConflict" {
        let reason = if last_error.is_empty() {
            "merge conflict"
        } else {
            &last_error
        };
        return Ok(blocked_item(
            id,
            reason,
            "human",
            Some("Resolve the merge conflict or request an explicit retry."),
            p.run_id,
        ));
    }
    let status = p.ticket.status.as_str();
    if status == VERIFICATION_BLOCKED_STATUS {
        let reason = p
            .ticket
            .verification_blocker
            .as_deref()
            .unwrap_or("external verification is unavailable");
        let next_step = p.ticket.verification_resume.as_deref().unwrap_or(
            "Change the external verification condition, then explicitly resume this run.",
        );
        let run_id = p.run_id.filter(|id| *id != 0).or(p.ticket.run_id);
        return Ok(blocked_item(
            id,
            reason,
            "external_verification",
            Some(next_step),
            run_id,
        ));
    }
    if status == "done" {
        if p.run.is_some() && state != "Merged" && !state.is_empty() {
            return Ok(blocked_item(
                id,
                &format!("source ticket is done but latest run is {state}"),
                "human",
                Some("Inspect the run and merge evidence before completing the drain."),
                p.run_id,
            ));
        }
        return Ok(drain_item(id, "done", p.run_id, "source ticket is done"));
    }
    if let Some(skip) = p.skip {
        let error = skip.string("error");
        match skip.string("reason").as_str() {
            "capacity_wait" => {
                let message = skip.string("message");
                let reason = if message.is_empty() {
                    "waiting for worker capacity"
                } else {
                    &message
                };
                return Ok(DrainItem {
                    next_action_at: skip.present("next_action_at").and_then(Value::py_float),
                    ..drain_item(
                        id,
                        "scheduled",
                        skip.present("run_id").and_then(Value::py_int),
                        reason,
                    )
                });
            }
            "dispatch_failed" if error.contains("backoff active") => {
                let next_action_at = match backoff_ends(p.run) {
                    Some(Some(at)) => Some(at),
                    Some(None) => Some(p.now + AUTO_DISPATCH_BACKOFF_SECONDS),
                    None => None,
                }
                .filter(|at| *at != 0.0)
                .unwrap_or(p.now + AUTO_DISPATCH_BACKOFF_SECONDS);
                return Ok(DrainItem {
                    next_action_at: Some(next_action_at),
                    ..drain_item(id, "scheduled", p.run_id, &error)
                });
            }
            "dispatch_failed" => {
                let reason = if error.is_empty() {
                    "dispatch failed"
                } else {
                    &error
                };
                return Ok(blocked_item(
                    id,
                    reason,
                    "human",
                    Some(
                        "Fix the dispatch blocker and explicitly redispatch or reconcile the drain.",
                    ),
                    p.run_id,
                ));
            }
            "run_id_present" => {
                return Ok(blocked_item(
                    id,
                    "ticket has run_id but no live/mergeable run was found",
                    "human",
                    Some(
                        "Inspect the recorded run_id, reset the ticket, or explicitly redispatch.",
                    ),
                    skip.present("run_id").and_then(Value::py_int),
                ));
            }
            _ => {}
        }
    }
    if (state == "Failed" || state == "Stalled")
        && let Some(blocker) = auto_blocker()?.filter(|blocker| !blocker.is_empty())
    {
        if blocker.contains("backoff active") {
            let next_action_at = backoff_ends(p.run)
                .flatten()
                .unwrap_or(p.now + AUTO_DISPATCH_BACKOFF_SECONDS);
            return Ok(DrainItem {
                next_action_at: Some(next_action_at),
                ..drain_item(id, "scheduled", p.run_id, &blocker)
            });
        }
        return Ok(blocked_item(
            id,
            &blocker,
            "human",
            Some("Fix the last error and explicitly redispatch the ticket."),
            p.run_id,
        ));
    }
    if status == "ready" {
        if let Some(blocker) = dispatch_blocker()? {
            return Ok(integration_blocked_item(id, &blocker, None));
        }
        return Ok(DrainItem {
            next_action_at: Some(p.now),
            ..drain_item(id, "scheduled", None, "ready for automatic dispatch")
        });
    }
    if status == "in_progress" {
        return Ok(blocked_item(
            id,
            "ticket is in progress without a live or reviewable run",
            "human",
            Some("Inspect the partial work, mark it ready again, or cancel it."),
            p.ticket.run_id,
        ));
    }
    let state = if status == "done" {
        "done"
    } else {
        "scheduled"
    };
    Ok(drain_item(
        id,
        state,
        p.run_id,
        &format!("ticket status {status}"),
    ))
}

/// The board a drain record classifies.
struct DrainView<'a> {
    repo: &'a Path,
    repo_text: &'a str,
    tickets_by_id: HashMap<String, &'a Ticket>,
    source_blocker: Option<SourceBlocker>,
    /// `_source_checkout_blocker(ignore_board_metadata=True)`, read once and
    /// only for a ready ticket whose predecessors are done (RR-449).
    dispatch_blocker: Option<Option<SourceBlocker>>,
}

impl Daemon {
    /// `_run_abandoned(run)`: a claimed, running or reviewing run whose
    /// process is gone. The Rust daemon owns no worker process until part 5,
    /// so only the recorded pid is consulted.
    fn run_abandoned(&self, run: &Dict) -> bool {
        let state = run_state(run);
        if !["Claimed", "Running", "Reviewing"].contains(&state.as_str()) || run_id(run).is_none() {
            return false;
        }
        // A claim without a pid is still in the dispatch handoff window.
        if state == "Claimed" && !run.get("pid").is_some_and(Value::truthy) {
            return false;
        }
        !process_is_alive(run.get("pid").and_then(Value::py_int))
    }

    fn forget_run_health(&self, run_id: i64) {
        guard(&RUN_HEALTH).remove(&(self.paths.data_root.clone(), run_id));
    }

    /// `_observe_run_health(run, now=)`: the warning of a live run that made
    /// no observable progress over the health-check window.
    fn observe_run_health(&self, run: &Dict, now: f64) -> Option<String> {
        if !process_is_alive(run.get("pid").and_then(Value::py_int)) {
            return None;
        }
        let run_id = run_id(run)?;
        let interval = self.worker_health_check_seconds.max(1.0);
        let key = (self.paths.data_root.clone(), run_id);
        let (kind, message, queue_messenger, warning) = {
            let mut health = guard(&RUN_HEALTH);
            let Some(previous) = health.get(&key) else {
                health.insert(
                    key,
                    Health {
                        checked_at: now,
                        signature: progress_signature(run),
                        warning: None,
                    },
                );
                return None;
            };
            if now - previous.checked_at < interval {
                return previous.warning.clone();
            }
            let signature = progress_signature(run);
            let window = window_label(interval);
            let ticket_id = run.get("ticket_id").map(Value::py_str).unwrap_or_default();
            let (kind, message, queue_messenger, warning) = if signature == previous.signature {
                let message = format!(
                    "{ticket_id} run {run_id} is alive but has no observable progress in the \
                     last {window}"
                );
                // The trace stays current every interval; only entering the
                // warning state is spoken.
                let speak = previous.warning.is_none();
                ("run-health-warning", message.clone(), speak, Some(message))
            } else {
                let message = format!(
                    "{ticket_id} run {run_id} is alive and made observable progress in the last \
                     {window}"
                );
                ("run-health-check", message, false, None)
            };
            health.insert(
                key,
                Health {
                    checked_at: now,
                    signature,
                    warning: warning.clone(),
                },
            );
            (kind, message, queue_messenger, warning)
        };
        let ticket_id = run.get("ticket_id").map(Value::py_str);
        let repo_path = run.get("repo_path").map(Value::py_str);
        let provider_key = run.get("provider_key").map(Value::py_str);
        self.emit_lifecycle(&LifecycleEvent {
            kind,
            ticket_id: ticket_id.as_deref(),
            run_id: Some(run_id),
            source: Some("orchestrator"),
            message: Some(&message),
            repo_path: repo_path.as_deref(),
            provider_key: provider_key.as_deref(),
            queue_messenger: (!queue_messenger).then_some(false),
        });
        warning
    }

    /// `_capacity_wait_reason(repo_path=)`.
    fn capacity_wait_reason(&self, repo_path: &str) -> Outcome<Option<(String, f64)>> {
        let max_workers = self.max_concurrent_workers.max(0);
        if max_workers == 0 {
            return Ok(None);
        }
        let active = self.runs.active_count(Some(repo_path))?;
        if active < max_workers {
            return Ok(None);
        }
        Ok(Some((
            format!("capacity wait: {active}/{max_workers} implementation worker slot(s) active"),
            now() + QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS,
        )))
    }

    /// `_classify_queue_drain_item`.
    fn classify_queue_drain_item(
        &self,
        view: &mut DrainView<'_>,
        ticket_id: &str,
        mut latest_run: Option<Dict>,
        skip: Option<&Dict>,
        now: f64,
    ) -> Outcome<DrainItem> {
        let Some(ticket) = view.tickets_by_id.get(ticket_id).copied() else {
            return Ok(missing_ticket_item(ticket_id));
        };
        if let Some(item) = waiting_item(ticket_id, ticket, &view.tickets_by_id) {
            return Ok(item);
        }
        let mut state = latest_run.as_ref().map(run_state).unwrap_or_default();
        let id = latest_run.as_ref().and_then(run_id);
        let abandoned = latest_run
            .as_ref()
            .is_some_and(|run| self.run_abandoned(run));
        if abandoned && let Some(id) = id {
            self.forget_run_health(id);
            if state == "Reviewing" {
                self.runs.update(
                    id,
                    &RunUpdate {
                        state: Some("AwaitingReview".to_string()),
                        last_error: Some(Some(
                            "review worker process is no longer running; ownership recovered"
                                .to_string(),
                        )),
                        ..RunUpdate::default()
                    },
                )?;
                state = "AwaitingReview".to_string();
            } else {
                self.runs.update(
                    id,
                    &RunUpdate {
                        state: Some("Stalled".to_string()),
                        last_error: Some(Some(
                            "worker process is no longer running; ownership recovered".to_string(),
                        )),
                        ended: true,
                        exit_code: Some(-1),
                        ..RunUpdate::default()
                    },
                )?;
                latest_run = self.runs.get(id)?;
                state = "Stalled".to_string();
            }
        }
        let health_warning = match &latest_run {
            Some(run) if ACTIVE_STATES.contains(&state.as_str()) || state == "Reviewing" => {
                self.observe_run_health(run, now)
            }
            _ => None,
        };
        let progress = Progress {
            ticket_id,
            ticket,
            run: latest_run.as_ref(),
            run_state: &state,
            run_id: id,
            health_warning,
            skip,
            source_blocker: view.source_blocker.as_ref(),
            now,
        };
        let repo = view.repo;
        let repo_text = view.repo_text;
        let cache = &mut view.dispatch_blocker;
        progress_item(
            &progress,
            &mut || self.auto_dispatch_blocker(ticket_id, repo_text, "ready-sweeper"),
            &mut || {
                if cache.is_none() {
                    *cache = Some(source_checkout_blocker(repo, true)?);
                }
                Ok(cache.clone().flatten())
            },
        )
    }

    /// `_record_queue_drain_locked(repo=, trigger=, sweep_result=,
    /// drive_reviews=)`: classify every observed ticket and move the drain
    /// to blocked, active, waiting or (after the quiescence window)
    /// completed. `drive_reviews` is where part 5 (RR-498) starts review
    /// workers; until then no review is dispatched.
    pub(crate) fn record_queue_drain_locked(
        &self,
        repo: &Path,
        trigger: Option<&str>,
        sweep_result: Option<&Dict>,
        _drive_reviews: bool,
    ) -> Outcome<Option<Dict>> {
        let repo_text = repo.to_string_lossy().into_owned();
        let tickets: Vec<Ticket> = tickets::scan_repo(repo)?
            .into_iter()
            .map(|(_, ticket)| ticket)
            .collect();
        let runs = self.runs.list_for_repo(&repo_text, 5000)?;
        let mut runs_by_ticket = latest_runs_by_ticket(&runs);
        let runs_by_id: HashMap<i64, &Dict> = runs
            .iter()
            .filter_map(|run| run_id(run).map(|id| (id, run)))
            .collect();
        for ticket in &tickets {
            if ticket.status != "done" && ticket.status != VERIFICATION_BLOCKED_STATUS {
                continue;
            }
            let ticket_id = ticket.id.to_uppercase();
            if let Some(linked) = ticket.run_id.and_then(|id| runs_by_id.get(&id))
                && linked.string("ticket_id").to_uppercase() == ticket_id
            {
                runs_by_ticket.insert(ticket_id, (*linked).clone());
            }
        }
        let active_drain = self.queue_drains.active_for_repo(&repo_text, false)?;
        let candidates =
            queue_drain_candidate_ids(&tickets, &runs_by_ticket, active_drain.as_ref());
        if active_drain.is_none() && candidates.is_empty() {
            return Ok(None);
        }

        let provider_key = self
            .effective_worker_agent()
            .map(|(kind, _, _)| kind)
            .unwrap_or_else(|_| self.agent_kind.clone());
        // An active drain keeps the branch it started on, so Git is asked
        // only when one is created.
        let mut target_branch = active_drain
            .as_ref()
            .map(|drain| drain.string("target_branch"))
            .unwrap_or_default();
        if target_branch.is_empty() {
            target_branch = git_text(repo, &["branch", "--show-current"])?;
        }
        if target_branch.is_empty() {
            target_branch = resolve_default_branch(repo)?;
        }
        let started_by = trigger
            .filter(|trigger| !trigger.is_empty())
            .unwrap_or("reconcile");
        let (mut drain, created) = self.queue_drains.ensure_active(
            &repo_text,
            &target_branch,
            &provider_key,
            &candidates,
            Some(&format!("Queue drain started by {started_by}.")),
            false,
        )?;
        let drain_id = drain.string("id");
        if active_drain.is_some() {
            if let Some(updated) =
                self.queue_drains
                    .append_observed(&drain_id, &candidates, false)?
            {
                drain = updated;
            }
        } else if created {
            let message = format!("Started queue drain {drain_id}.");
            self.emit_lifecycle(&LifecycleEvent {
                kind: "reasoning-summary",
                message: Some(&message),
                repo_path: Some(&repo_text),
                provider_key: Some(&provider_key),
                ..LifecycleEvent::default()
            });
        }

        let observed: BTreeSet<String> = observed_ticket_ids(Some(&drain))
            .into_iter()
            .chain(candidates.iter().cloned())
            .collect();
        let mut skip_by_id: HashMap<String, &Dict> = HashMap::new();
        if let Some(Value::List(skipped)) = sweep_result.and_then(|result| result.get("skipped")) {
            for item in skipped.iter().filter_map(Value::as_dict) {
                if item.truthy("ticket_id").is_some() {
                    skip_by_id.insert(item.string("ticket_id").to_uppercase(), item);
                }
            }
        }
        // The source blocker is read only for integration-blocked runs and
        // the dispatch blocker only for ready tickets (RR-440).
        let integration_blocked = observed.iter().any(|ticket_id| {
            runs_by_ticket
                .get(ticket_id)
                .is_some_and(|run| run_state(run) == INTEGRATION_BLOCKED_RUN_STATE)
        });
        let source_blocker = if integration_blocked {
            source_checkout_blocker(repo, false)?
        } else {
            None
        };
        let mut view = DrainView {
            repo,
            repo_text: &repo_text,
            tickets_by_id: tickets
                .iter()
                .map(|ticket| (ticket.id.to_uppercase(), ticket))
                .collect(),
            source_blocker,
            dispatch_blocker: None,
        };
        let mut items = Vec::with_capacity(observed.len());
        for ticket_id in &observed {
            items.push(self.classify_queue_drain_item(
                &mut view,
                ticket_id,
                runs_by_ticket.get(ticket_id).cloned(),
                skip_by_id.get(ticket_id).copied(),
                now(),
            )?);
        }
        self.queue_drains.update_items(&drain_id, &items)?;

        let item_state = |item: &DrainItem| item.state.clone().unwrap_or_default();
        let update = |state: &str, goal: &str, message: String, quiescent_since: Option<f64>| {
            self.queue_drains.update_state(
                &drain_id,
                &DrainState {
                    state: state.to_string(),
                    provider_goal_state: Some(goal.to_string()),
                    status_message: Some(message),
                    quiescent_since,
                    complete: state == "completed",
                    canceled: false,
                },
            )
        };
        if let Some(first) = items.iter().find(|item| item_state(item) == "blocked") {
            let detail = first
                .blocker_next_step
                .clone()
                .filter(|step| !step.is_empty())
                .or_else(|| first.reason.clone())
                .unwrap_or_else(|| "None".to_string());
            let message = format!("Queue drain blocked on {}: {detail}", first.ticket_id);
            return Ok(update("blocked", "blocked", message, None)?);
        }
        let unfinished: Vec<&DrainItem> = items
            .iter()
            .filter(|item| !["done", "canceled"].contains(&item_state(item).as_str()))
            .collect();
        if !unfinished.is_empty() {
            let working = unfinished.iter().any(|item| {
                ["active", "reviewing", "awaiting_review", "scheduled"]
                    .contains(&item_state(item).as_str())
            });
            let state = if working { "active" } else { "waiting" };
            let message = format!("Queue drain waiting on {} ticket(s).", unfinished.len());
            return Ok(update(state, "active", message, None)?);
        }

        let now = now();
        let Some(quiescent_since) = drain.present("quiescent_since") else {
            let message = format!(
                "Queue drain is quiescent; verifying for {}s before completion.",
                format_g(QUEUE_DRAIN_QUIESCENCE_SECONDS)
            );
            return Ok(update("waiting", "active", message, Some(now))?);
        };
        let since = quiescent_since.py_float();
        let quiet_for = since.map_or(0.0, |since| now - since);
        if quiet_for < QUEUE_DRAIN_QUIESCENCE_SECONDS {
            let message = "Queue drain is still in the quiescence window.".to_string();
            return Ok(update("waiting", "active", message, since)?);
        }
        let message = format!(
            "Queue drain completed after {} observed ticket(s).",
            items.len()
        );
        let completed = update("completed", "completed", message, since)?;
        let message = format!("Queue drain {drain_id} completed.");
        self.emit_lifecycle(&LifecycleEvent {
            kind: "reasoning-summary",
            message: Some(&message),
            repo_path: Some(&repo_text),
            provider_key: Some(&provider_key),
            ..LifecycleEvent::default()
        });
        Ok(completed)
    }

    /// `reconcile_queue_drain(repo_path=, trigger=)`: sweep the board, then
    /// record its drain.
    pub fn reconcile_queue_drain(&self, repo_path: &str, trigger: Option<&str>) -> Outcome<Dict> {
        if repo_path.is_empty() {
            return Err(Failure::value("repo_path is required"));
        }
        let repo = resolve_path(repo_path);
        let repo_text = repo.to_string_lossy().into_owned();
        if !repo.is_dir() || !repo.join(".git").exists() {
            return Err(Failure::value(format!(
                "repo_path {repo_text} is not a git repository"
            )));
        }
        // `_resume_clean_integration_blocks` merges integration-blocked runs
        // once the checkout is clean: the merge path of part 5 (RR-498).
        let resumed_integrations: Vec<Value> = Vec::new();
        let drain_trigger = trigger
            .filter(|trigger| !trigger.is_empty())
            .unwrap_or("queue-drain");
        let (sweep, drain) = {
            let _authoring = guard(&self.authoring_lock);
            let sweep = self.sweep_ready_tickets_locked(&repo, Some(drain_trigger), false, None)?;
            let drain =
                self.record_queue_drain_locked(&repo, Some(drain_trigger), Some(&sweep), true)?;
            (sweep, drain)
        };
        let mut result = Dict::new();
        result.insert("repo_path", repo_text);
        result.insert("trigger", trigger);
        result.insert("resumed_integrations", Value::List(resumed_integrations));
        result.insert("sweep", sweep);
        result.insert("drain", drain);
        Ok(result)
    }

    /// `cancel_queue_drain(drain_id, reason=)`.
    pub fn cancel_queue_drain(&self, drain_id: &str, reason: Option<&str>) -> Outcome<Dict> {
        let Some(result) = self.queue_drains.cancel(drain_id, reason)? else {
            return Err(Failure::value(format!("unknown queue drain {drain_id}")));
        };
        let message = format!("Queue drain {drain_id} canceled.");
        self.emit_lifecycle(&LifecycleEvent {
            kind: "reasoning-summary",
            message: Some(&message),
            repo_path: result.get("repo_path").and_then(Value::as_str),
            provider_key: result.get("provider_key").and_then(Value::as_str),
            ..LifecycleEvent::default()
        });
        Ok(single("queue_drain", result))
    }

    /// `_promote_unblocked_dependents`: backlog tickets whose predecessors
    /// are done move to `ready`, through the canonical writer on an artifact
    /// board. A spike's result never promotes its dependents.
    pub(crate) fn promote_unblocked_dependents(
        &self,
        repo: &Path,
        lifecycle: Option<&Arc<ArtifactLifecycleCoordinator>>,
    ) -> Outcome<Vec<String>> {
        let found;
        let lifecycle = match lifecycle {
            Some(lifecycle) => Some(lifecycle),
            None => {
                found = self.artifact_lifecycle(&repo.to_string_lossy())?;
                found.as_ref()
            }
        };
        if let Some(lifecycle) = lifecycle {
            return Ok(lifecycle.promote_unblocked_dependents()?);
        }
        let board = tickets::scan_repo(repo)?;
        let all_tickets: Vec<Ticket> = board.iter().map(|(_, ticket)| ticket.clone()).collect();
        let mut by_id: HashMap<&str, &Ticket> = HashMap::new();
        for ticket in &all_tickets {
            by_id.insert(ticket.id.as_str(), ticket);
        }
        let mut promoted = Vec::new();
        for (path, ticket) in &board {
            if ticket.status != "backlog" || ticket.depends_on.is_empty() {
                continue;
            }
            if ticket.canceled || ticket.draft {
                continue;
            }
            if !self.all_dependencies_done(repo, &ticket.depends_on, &all_tickets, None)? {
                continue;
            }
            if ticket.depends_on.iter().any(|dependency| {
                by_id
                    .get(dependency.as_str())
                    .is_some_and(|predecessor| predecessor.execution_mode == "spike")
            }) {
                continue;
            }
            let mut ready = ticket.clone();
            ready.status = "ready".to_string();
            tickets::write(path, &ready)?;
            promoted.push(ticket.id.clone());
            self.notify_orchestration_trace("board-change", Some(&ticket.id), None, None, None);
        }
        Ok(promoted)
    }

    /// `sweep_ready_tickets(repo_path=, trigger=, project_scope_token=)`.
    pub fn sweep_ready_tickets(
        &self,
        repo_path: &str,
        trigger: Option<&str>,
        project_scope_token: Option<&str>,
    ) -> Outcome<Dict> {
        if repo_path.is_empty() {
            return Err(Failure::value("repo_path is required"));
        }
        let repo = resolve_path(repo_path);
        if !repo.is_dir() || !repo.join(".git").exists() {
            return Err(Failure::value(format!(
                "repo_path {} is not a git repository",
                repo.display()
            )));
        }
        let lifecycle = self.artifact_lifecycle(&repo.to_string_lossy())?;
        if let Some(lifecycle) = &lifecycle {
            lifecycle.validate_scope(project_scope_token, None)?;
        }
        let _authoring = guard(&self.authoring_lock);
        self.sweep_ready_tickets_locked(&repo, trigger, true, lifecycle.as_ref())
    }

    /// `_sweep_ready_tickets_locked`: promote, then dispatch every ready
    /// ticket that can start, recording why each other ticket was skipped.
    /// Dispatch authority comes only from a caller-validated `lifecycle`.
    pub(crate) fn sweep_ready_tickets_locked(
        &self,
        repo: &Path,
        trigger: Option<&str>,
        record_drain: bool,
        lifecycle: Option<&Arc<ArtifactLifecycleCoordinator>>,
    ) -> Outcome<Dict> {
        let repo_text = repo.to_string_lossy().into_owned();
        let promoted = self.promote_unblocked_dependents(repo, lifecycle)?;
        let all_tickets: Vec<Ticket> = tickets::scan_repo(repo)?
            .into_iter()
            .map(|(_, ticket)| ticket)
            .collect();
        let mut dispatched = Vec::new();
        let mut skipped = Vec::new();
        // A full `git status` costs seconds in large checkouts; read it once,
        // and only for a ticket that could dispatch.
        let mut source_blocker: Option<Option<SourceBlocker>> = None;
        for ticket in &all_tickets {
            let skip = |reason: &str, extra: Dict| {
                let mut entry = Dict::new();
                entry.insert("ticket_id", ticket.id.as_str());
                entry.insert("reason", reason);
                entry.update(&extra);
                Value::Dict(entry)
            };
            if ticket.status != "ready" {
                skipped.push(skip(&format!("status:{}", ticket.status), Dict::new()));
                continue;
            }
            if ticket.canceled {
                skipped.push(skip("canceled", Dict::new()));
                continue;
            }
            if ticket.draft {
                skipped.push(skip("draft", Dict::new()));
                continue;
            }
            if let Some(run_id) = ticket.run_id {
                skipped.push(skip("run_id_present", single("run_id", run_id)));
                continue;
            }
            match self.dependencies_done(repo, &ticket.depends_on, &all_tickets, lifecycle) {
                Ok(true) => {}
                Ok(false) => {
                    skipped.push(skip("dependencies_not_done", Dict::new()));
                    continue;
                }
                Err(DependencyFailure::History {
                    message,
                    availability,
                    recovery,
                }) => {
                    let mut extra = Dict::new();
                    extra.insert("availability", availability);
                    extra.insert("recovery", recovery);
                    extra.insert("message", message);
                    skipped.push(skip("dependency_history_unavailable", extra));
                    continue;
                }
                Err(DependencyFailure::Failure(failure)) if failure.class == Class::Validation => {
                    let extra = single("message", failure.message);
                    skipped.push(skip("dependency_history_unavailable", extra));
                    continue;
                }
                Err(DependencyFailure::Failure(failure)) => return Err(failure),
            }

            if source_blocker.is_none() {
                source_blocker = Some(source_checkout_blocker(repo, true)?);
            }
            if let Some(Some(blocker)) = &source_blocker {
                let mut extra = Dict::new();
                extra.insert("message", blocker.reason.as_str());
                extra.insert("next_step", blocker.next_step.as_str());
                extra.insert("dirty_paths", string_values(&blocker.dirty_paths));
                skipped.push(skip("integration_blocked", extra));
                continue;
            }
            if let Some((message, next_action_at)) = self.capacity_wait_reason(&repo_text)? {
                let mut extra = Dict::new();
                extra.insert("message", message);
                extra.insert("next_action_at", next_action_at);
                skipped.push(skip("capacity_wait", extra));
                continue;
            }
            if let Some(existing) = self.runs.find_active(&ticket.id, Some(&repo_text))? {
                let extra = single("run_id", existing.get("id").cloned().unwrap_or(Value::Null));
                skipped.push(skip("already_active", extra));
                continue;
            }
            if let Some(awaiting) = self
                .runs
                .find_awaiting_merge(&ticket.id, Some(&repo_text))?
            {
                let mut extra = Dict::new();
                extra.insert("run_id", awaiting.get("id").cloned().unwrap_or(Value::Null));
                extra.insert(
                    "branch",
                    awaiting.get("branch").cloned().unwrap_or(Value::Null),
                );
                skipped.push(skip("awaiting_merge", extra));
                continue;
            }

            let mut request = DispatchRequest::new(&ticket.id, &repo_text, "ready-sweeper");
            request.internally_confirmed_project_id =
                lifecycle.map(|lifecycle| lifecycle.store.project_id.clone());
            let result = match self.dispatch(&request) {
                Ok(result) => result,
                Err(failure) if is_value_or_runtime(&failure) => {
                    eprintln!(
                        "[orchestrator] ready-sweeper dispatch failed for {}: {failure}",
                        ticket.id
                    );
                    skipped.push(skip("dispatch_failed", single("error", failure.message)));
                    continue;
                }
                Err(failure) => return Err(failure),
            };
            let run_id = result
                .get("run")
                .and_then(Value::as_dict)
                .and_then(|run| run.get("id"))
                .cloned()
                .unwrap_or(Value::Null);
            if result.truthy("integration_blocked").is_some() {
                let mut extra = Dict::new();
                extra.insert(
                    "message",
                    result.get("reason").cloned().unwrap_or(Value::Null),
                );
                extra.insert(
                    "next_step",
                    result.get("next_step").cloned().unwrap_or(Value::Null),
                );
                extra.insert(
                    "dirty_paths",
                    result
                        .truthy("dirty_paths")
                        .cloned()
                        .unwrap_or(Value::List(Vec::new())),
                );
                skipped.push(skip("integration_blocked", extra));
                continue;
            }
            if result.truthy("already_active").is_some() {
                let reason = if result.truthy("awaiting_merge").is_some() {
                    "awaiting_merge"
                } else {
                    "already_active"
                };
                skipped.push(skip(reason, single("run_id", run_id)));
                continue;
            }
            let after = trigger
                .map(|trigger| format!(" after {trigger}"))
                .unwrap_or_default();
            eprintln!(
                "[orchestrator] ready-sweeper auto-dispatched {}{after}: run {}",
                ticket.id,
                run_id.py_str()
            );
            let mut entry = Dict::new();
            entry.insert("ticket_id", ticket.id.as_str());
            entry.insert("run_id", run_id);
            dispatched.push(Value::Dict(entry));
        }

        let mut result = Dict::new();
        result.insert("repo_path", repo_text);
        result.insert("trigger", trigger);
        result.insert("promoted", string_values(&promoted));
        result.insert("dispatched", Value::List(dispatched));
        result.insert("skipped", Value::List(skipped));
        if record_drain {
            let drain = self.record_queue_drain_locked(repo, trigger, Some(&result), true)?;
            result.insert("drain", drain);
        }
        Ok(result)
    }

    /// `sweep_program_ready_tickets(trigger=, repo_paths=)`: the ready sweep
    /// of every registered project (or the requested ones among them). The
    /// program dashboard's `sweep=1` refresh calls this.
    pub fn sweep_program_ready_tickets(
        &self,
        trigger: Option<&str>,
        repo_paths: Option<&[String]>,
    ) -> Outcome<Dict> {
        let mut registered = registered_project_repo_paths(self.paths.registered_projects());
        if let Some(repo_paths) = repo_paths {
            let requested: HashSet<String> = repo_paths
                .iter()
                .filter(|path| !json::py_strip(path).is_empty())
                .map(|path| resolve_path(path).to_string_lossy().into_owned())
                .collect();
            registered.retain(|path| requested.contains(path));
        }
        let sweep_trigger = trigger
            .filter(|trigger| !trigger.is_empty())
            .unwrap_or("program-ready-sweep");
        let mut projects = Vec::new();
        let mut dispatched = Vec::new();
        let mut skipped = Vec::new();
        for repo_path in &registered {
            let result = match self.sweep_ready_tickets(repo_path, Some(sweep_trigger), None) {
                Ok(result) => result,
                Err(failure) if is_value_or_runtime(&failure) => {
                    let mut entry = Dict::new();
                    entry.insert("repo_path", repo_path.as_str());
                    entry.insert("error", failure.message);
                    projects.push(Value::Dict(entry.clone()));
                    skipped.push(Value::Dict(entry));
                    continue;
                }
                Err(failure) => return Err(failure),
            };
            let repo = result.get("repo_path").cloned().unwrap_or(Value::Null);
            for (key, into) in [("dispatched", &mut dispatched), ("skipped", &mut skipped)] {
                if let Some(Value::List(items)) = result.get(key) {
                    for item in items.iter().filter_map(Value::as_dict) {
                        let mut entry = single("repo_path", repo.clone());
                        entry.update(item);
                        into.push(Value::Dict(entry));
                    }
                }
            }
            projects.push(Value::Dict(result));
        }
        let mut result = Dict::new();
        result.insert("trigger", trigger);
        result.insert("projects", Value::List(projects));
        result.insert("dispatched", Value::List(dispatched));
        result.insert("skipped", Value::List(skipped));
        Ok(result)
    }

    /// `_all_dependencies_done(repo=, ticket=, all_tickets=,
    /// artifact_lifecycle=)`: every predecessor is `done` on the board, or
    /// archived as done with verified history.
    pub(crate) fn all_dependencies_done(
        &self,
        repo: &Path,
        depends_on: &[String],
        all_tickets: &[Ticket],
        lifecycle: Option<&Arc<ArtifactLifecycleCoordinator>>,
    ) -> Outcome<bool> {
        self.dependencies_done(repo, depends_on, all_tickets, lifecycle)
            .map_err(DependencyFailure::into_failure)
    }

    /// [`Daemon::all_dependencies_done`], keeping a history failure's detail
    /// for the ready sweep's skip entry.
    pub(crate) fn dependencies_done(
        &self,
        repo: &Path,
        depends_on: &[String],
        all_tickets: &[Ticket],
        lifecycle: Option<&Arc<ArtifactLifecycleCoordinator>>,
    ) -> Result<bool, DependencyFailure> {
        let mut by_id: HashMap<&str, &Ticket> = HashMap::new();
        for ticket in all_tickets {
            by_id.insert(ticket.id.as_str(), ticket);
        }
        let mut missing = Vec::new();
        for dependency in depends_on {
            match by_id.get(dependency.as_str()) {
                Some(ticket) if ticket.status != "done" => return Ok(false),
                Some(_) => {}
                None => missing.push(dependency),
            }
        }
        if missing.is_empty() {
            return Ok(true);
        }
        let found;
        let lifecycle = match lifecycle {
            Some(lifecycle) => lifecycle,
            None => {
                found = self
                    .artifact_lifecycle(&repo.to_string_lossy())
                    .map_err(DependencyFailure::Failure)?;
                match &found {
                    Some(lifecycle) => lifecycle,
                    None => return Ok(false),
                }
            }
        };
        let manager = ArtifactRetentionManager::new(
            &lifecycle.store,
            RetentionOptions {
                lease_store: Some(lifecycle.leases.clone()),
                enabled: true,
                ..RetentionOptions::default()
            },
        )
        .map_err(|error| DependencyFailure::Failure(error.into()))?;
        for dependency in missing {
            match manager.dependency_satisfied(dependency, None) {
                Ok(true) => {}
                Ok(false) => return Ok(false),
                Err(error) if matches!(error.kind, ErrorKind::DependencyHistoryUnavailable) => {
                    // The Rust error carries only its message; the verified
                    // detail is read again from the archived card.
                    let detail = manager
                        .historical_search(dependency)
                        .ok()
                        .and_then(|cards| {
                            cards.into_iter().find(|card| card.ticket_id == *dependency)
                        })
                        .and_then(|card| {
                            manager
                                .historical_detail(&card.artifact_id, HistoryAccess::default())
                                .ok()
                        });
                    return Err(DependencyFailure::History {
                        message: error.message,
                        availability: detail
                            .as_ref()
                            .map(|detail| detail.availability.value().to_string()),
                        recovery: detail.and_then(|detail| detail.recovery),
                    });
                }
                Err(error) => return Err(DependencyFailure::Failure(error.into())),
            }
        }
        Ok(true)
    }

    /// `_ensure_queue_drain_for_ticket`: a live drain for a ready or
    /// in-progress ticket.
    pub(crate) fn ensure_queue_drain_for_ticket(
        &self,
        repo: &Path,
        ticket: &Ticket,
        provider_key: &str,
        target_branch: &str,
        trigger: &str,
    ) -> Outcome<Option<Dict>> {
        if ticket.canceled || ticket.draft {
            return Ok(None);
        }
        if !["ready", "in_progress"].contains(&ticket.status.as_str()) {
            return Ok(None);
        }
        let repo_text = repo.to_string_lossy();
        let (drain, created) = self.queue_drains.ensure_active(
            &repo_text,
            target_branch,
            provider_key,
            std::slice::from_ref(&ticket.id),
            Some(&format!("Queue drain started by {trigger}.")),
            false,
        )?;
        if created {
            let message = format!(
                "Started queue drain {} for {}.",
                drain.string("id"),
                ticket.id
            );
            self.emit_lifecycle(&LifecycleEvent {
                kind: "reasoning-summary",
                message: Some(&message),
                repo_path: Some(&repo_text),
                provider_key: Some(provider_key),
                ..LifecycleEvent::default()
            });
        }
        Ok(Some(drain))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ticket(id: &str, status: &str, extra: &str) -> Ticket {
        tickets::parse(&format!(
            "---\nid: {id}\ntitle: Work\nstatus: {status}\npriority: medium\n{extra}\
             run_id: null\ncanceled: false\n---\nBody\n"
        ))
        .unwrap()
    }

    fn with_deps(id: &str, status: &str, deps: &str) -> Ticket {
        ticket(id, status, &format!("depends_on: [{deps}]\n"))
    }

    fn run(id: i64, ticket_id: &str, state: &str) -> Dict {
        let mut run = Dict::new();
        run.insert("id", id);
        run.insert("ticket_id", ticket_id);
        run.insert("state", state);
        run
    }

    fn progress<'a>(ticket: &'a Ticket, run: Option<&'a Dict>, state: &'a str) -> Progress<'a> {
        Progress {
            ticket_id: &ticket.id,
            ticket,
            run,
            run_state: state,
            run_id: run.and_then(run_id),
            health_warning: None,
            skip: None,
            source_blocker: None,
            now: 1000.0,
        }
    }

    fn classify(p: &Progress<'_>) -> DrainItem {
        classify_with(p, None, None)
    }

    fn classify_with(
        p: &Progress<'_>,
        auto: Option<&str>,
        dispatch: Option<SourceBlocker>,
    ) -> DrainItem {
        progress_item(p, &mut || Ok(auto.map(str::to_string)), &mut || {
            Ok(dispatch.clone())
        })
        .unwrap()
    }

    fn summary(item: &DrainItem) -> (String, String, Option<i64>) {
        (
            item.state.clone().unwrap_or_default(),
            item.reason.clone().unwrap_or_default(),
            item.run_id,
        )
    }

    #[test]
    fn the_latest_run_per_ticket_has_the_highest_id() {
        let runs = [
            run(1, "ct-1", "Failed"),
            run(3, "CT-1", "Running"),
            run(2, "CT-2", "Merged"),
        ];
        let latest = latest_runs_by_ticket(&runs);
        assert_eq!(run_id(&latest["CT-1"]), Some(3));
        assert_eq!(run_id(&latest["CT-2"]), Some(2));
    }

    #[test]
    fn candidates_are_live_work_and_the_predecessors_it_waits_on() {
        let tickets = [
            with_deps("CT-1", "backlog", ""),
            with_deps("CT-2", "ready", "CT-1"),
            with_deps("CT-3", "backlog", ""),
            with_deps("CT-4", "done", ""),
            with_deps("CT-5", "backlog", ""),
        ];
        let mut runs = HashMap::new();
        runs.insert("CT-4".to_string(), run(1, "CT-4", "AwaitingReview"));
        runs.insert("CT-5".to_string(), run(2, "CT-5", "Running"));
        let mut drain = Dict::new();
        drain.insert(
            "observed_ticket_ids",
            Value::List(vec![Value::from("CT-9")]),
        );
        assert_eq!(
            queue_drain_candidate_ids(&tickets, &runs, Some(&drain)),
            ["CT-1", "CT-2", "CT-5", "CT-9"]
        );
        assert!(queue_drain_candidate_ids(&tickets[2..4], &HashMap::new(), None).is_empty());
    }

    #[test]
    fn missing_canceled_and_waiting_tickets_are_answered_first() {
        let missing = missing_ticket_item("CT-1");
        assert_eq!(missing.state.as_deref(), Some("blocked"));
        assert_eq!(
            missing.blocker_next_step.as_deref(),
            Some("Restore .orchestrator/CT-1.md or cancel the drain.")
        );
        let done = with_deps("CT-1", "done", "");
        let waiting = with_deps("CT-3", "ready", "CT-1, ct-2");
        let by_id: HashMap<String, &Ticket> = [("CT-1".to_string(), &done)].into_iter().collect();
        let item = waiting_item("CT-3", &waiting, &by_id).unwrap();
        assert_eq!(item.state.as_deref(), Some("dependency_waiting"));
        assert_eq!(item.reason.as_deref(), Some("waiting on ct-2"));
        assert_eq!(item.unresolved_dependencies, ["ct-2"]);
        assert_eq!(item.blocker_owner.as_deref(), Some("dependency"));
        assert!(waiting_item("CT-1", &done, &by_id).is_none());
        let canceled = tickets::parse(
            "---\nid: CT-4\ntitle: W\nstatus: ready\npriority: low\ndepends_on: []\n\
             run_id: null\ncanceled: true\n---\n",
        )
        .unwrap();
        let item = waiting_item("CT-4", &canceled, &by_id).unwrap();
        assert_eq!(
            summary(&item),
            ("canceled".into(), "ticket is canceled".into(), None)
        );
    }

    #[test]
    fn live_and_review_runs_are_active_or_awaiting_review() {
        let ready = with_deps("CT-1", "in_progress", "");
        let running = run(4, "CT-1", "Running");
        let mut p = progress(&ready, Some(&running), "Running");
        assert_eq!(
            summary(&classify(&p)),
            ("active".into(), "Running".into(), Some(4))
        );
        p.health_warning = Some("no progress".to_string());
        assert_eq!(classify(&p).reason.as_deref(), Some("no progress"));
        let p = progress(&ready, Some(&running), "Reviewing");
        assert_eq!(
            classify(&p).reason.as_deref(),
            Some("review/merge worker active")
        );
        let p = progress(&ready, Some(&running), "Succeeded");
        let item = classify(&p);
        assert_eq!(
            summary(&item),
            (
                "awaiting_review".into(),
                "awaiting review dispatch".into(),
                Some(4)
            )
        );
        assert_eq!(item.next_action_at, Some(1000.0));
    }

    #[test]
    fn integration_and_merge_blocks_name_their_next_step() {
        let ticket = with_deps("CT-1", "in_progress", "");
        let mut blocked_run = run(5, "CT-1", INTEGRATION_BLOCKED_RUN_STATE);
        let item = classify(&progress(
            &ticket,
            Some(&blocked_run),
            INTEGRATION_BLOCKED_RUN_STATE,
        ));
        assert_eq!(item.state.as_deref(), Some("integration_blocked"));
        assert_eq!(
            item.reason.as_deref(),
            Some("integration is ready to resume")
        );
        assert_eq!(item.blocker_owner.as_deref(), Some("source_checkout"));
        blocked_run.insert("last_error", "conflict in a.rs");
        let item = classify(&progress(&ticket, Some(&blocked_run), "MergeConflict"));
        assert_eq!(
            summary(&item),
            ("blocked".into(), "conflict in a.rs".into(), Some(5))
        );
    }

    #[test]
    fn done_and_verification_blocked_tickets() {
        let done = with_deps("CT-1", "done", "");
        let merged = run(2, "CT-1", "Merged");
        assert_eq!(
            classify(&progress(&done, Some(&merged), "Merged"))
                .state
                .as_deref(),
            Some("done")
        );
        assert_eq!(
            classify(&progress(&done, None, "")).state.as_deref(),
            Some("done")
        );
        let item = classify(&progress(&done, Some(&merged), "Failed"));
        assert_eq!(
            item.reason.as_deref(),
            Some("source ticket is done but latest run is Failed")
        );
        let blocked = tickets::parse(
            "---\nid: CT-2\ntitle: W\nstatus: verification_blocked\npriority: low\n\
             depends_on: []\nrun_id: 7\ncanceled: false\nverification_blocker: no device\n\
             verification_resume: plug it in\n---\n",
        )
        .unwrap();
        let item = classify(&progress(&blocked, None, ""));
        assert_eq!(
            summary(&item),
            ("blocked".into(), "no device".into(), Some(7))
        );
        assert_eq!(item.blocker_owner.as_deref(), Some("external_verification"));
        assert_eq!(item.blocker_next_step.as_deref(), Some("plug it in"));
    }

    #[test]
    fn sweep_skips_shape_ready_tickets() {
        let ready = with_deps("CT-1", "ready", "");
        let mut skip = Dict::new();
        skip.insert("reason", "capacity_wait");
        skip.insert(
            "message",
            "capacity wait: 1/1 implementation worker slot(s) active",
        );
        skip.insert("next_action_at", 1005.0);
        let mut p = progress(&ready, None, "");
        p.skip = Some(&skip);
        let item = classify(&p);
        assert_eq!(item.state.as_deref(), Some("scheduled"));
        assert_eq!(item.next_action_at, Some(1005.0));

        let mut failed = Dict::new();
        failed.insert("reason", "dispatch_failed");
        failed.insert("error", "worker dispatch is not available");
        p.skip = Some(&failed);
        let item = classify(&p);
        assert_eq!(item.state.as_deref(), Some("blocked"));
        assert_eq!(
            item.blocker_next_step.as_deref(),
            Some("Fix the dispatch blocker and explicitly redispatch or reconcile the drain.")
        );

        let mut ended = run(3, "CT-1", "Failed");
        ended.insert("ended_at", 990.0);
        failed.insert(
            "error",
            "automatic retry backoff active after attempt 1; retry in 20s",
        );
        let mut p = progress(&ready, Some(&ended), "Failed");
        p.skip = Some(&failed);
        let item = classify(&p);
        assert_eq!(item.state.as_deref(), Some("scheduled"));
        assert_eq!(item.next_action_at, Some(1020.0));

        let mut present = Dict::new();
        present.insert("reason", "run_id_present");
        present.insert("run_id", 9);
        let mut p = progress(&ready, None, "");
        p.skip = Some(&present);
        assert_eq!(classify(&p).run_id, Some(9));
    }

    #[test]
    fn failed_runs_and_ready_tickets_follow_their_blockers() {
        let ready = with_deps("CT-1", "ready", "");
        let failed = run(3, "CT-1", "Failed");
        let p = progress(&ready, Some(&failed), "Failed");
        let item = classify_with(&p, Some("automatic retry circuit open"), None);
        assert_eq!(
            item.blocker_next_step.as_deref(),
            Some("Fix the last error and explicitly redispatch the ticket.")
        );
        let item = classify_with(
            &p,
            Some("automatic retry backoff active after attempt 1"),
            None,
        );
        assert_eq!(item.next_action_at, Some(1030.0));
        let item = classify_with(&p, None, None);
        assert_eq!(
            summary(&item),
            (
                "scheduled".into(),
                "ready for automatic dispatch".into(),
                None
            )
        );
        let dirty = SourceBlocker {
            reason: "source checkout has uncommitted changes (tracked: a)".to_string(),
            dirty_paths: vec!["a".to_string()],
            next_step: "Commit.".to_string(),
        };
        let item = classify_with(&progress(&ready, None, ""), None, Some(dirty));
        assert_eq!(item.state.as_deref(), Some("integration_blocked"));
        let in_progress = with_deps("CT-2", "in_progress", "");
        let item = classify(&progress(&in_progress, None, ""));
        assert_eq!(
            item.reason.as_deref(),
            Some("ticket is in progress without a live or reviewable run")
        );
        let backlog = with_deps("CT-3", "backlog", "");
        assert_eq!(
            summary(&classify(&progress(&backlog, None, ""))),
            ("scheduled".into(), "ticket status backlog".into(), None)
        );
    }

    #[test]
    fn numbers_format_as_python_g() {
        assert_eq!(format_g(2.0), "2");
        assert_eq!(format_g(0.5), "0.5");
        assert_eq!(format_g(90.0), "90");
        assert_eq!(format_g(1234567.0), "1.23457e+06");
        assert_eq!(format_g(0.0001), "0.0001");
        assert_eq!(window_label(600.0), "10 minutes");
        assert_eq!(window_label(60.0), "1 minute");
        assert_eq!(window_label(90.0), "90 seconds");
    }
}
