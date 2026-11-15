//! Run execution after dispatch (RR-498): the worktree and ticket snapshot,
//! the worker prompt, what a finished worker leads to, the review worker,
//! the merge, a review retry, the verification resume and close-out, cancel,
//! and dependency progression (`services/orchestrator.py`, `create_worktree`,
//! `_build_prompt`, `_on_worker_complete` through `dispatch_review_worker`,
//! `_progress_dependents`, `accept_worker_run` through
//! `resume_verification_blocked`, and `cancel_run`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

use relay_artifacts::lifecycle::{ArtifactLifecycleCoordinator, FailureKind, MAX_LOCAL_LOG_BYTES};
use relay_artifacts::pystr;
use relay_artifacts::tickets::{self, Ticket};
use relay_intents::json::{Dict, Value, py_strip};
use relay_intents::pattern::{self, Regex};
use relay_store::runs::{
    ACTIVE_STATES, INTEGRATION_BLOCKED_RUN_STATE, MERGEABLE_REVIEW_STATES, REVIEW_BLOCKING_STATES,
    RunUpdate, SPIKE_EXECUTION_MODE, VERIFICATION_BLOCKED_RUN_STATE,
};

use crate::daemon::{Daemon, guard, resolve_path};
use crate::dispatch::{DispatchRequest, git, resolve_default_branch, source_checkout_blocker};
use crate::failure::{Failure, Outcome};
use crate::queue::VERIFICATION_BLOCKED_STATUS;
use crate::runs::{TicketRead, clean_required_text, delete_branch, remove_worktree};
use crate::spike::remove_spike_workspace;
use crate::trace::LifecycleEvent;
use crate::worker::{ReviewLaunch, RunProcess};

/// How long `cancel_run` waits for a worker's thread to finish.
const CANCEL_JOIN_TIMEOUT: Duration = Duration::from_secs(10);
/// How long shutdown waits for each canceled worker to record its run.
const SHUTDOWN_JOIN_TIMEOUT: Duration = Duration::from_secs(10);

static TEMPLATE_VARIABLE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"\{\{\s*([\w_]+)\s*\}\}", false));

/// `render_template(template, **vars)`: `{{key}}` replaced, a missing key
/// with nothing.
pub fn render_template(template: &str, variables: &[(&str, &str)]) -> String {
    let mut rendered = String::with_capacity(template.len());
    let mut last = 0;
    for captures in TEMPLATE_VARIABLE
        .captures_iter(template)
        .map_while(Result::ok)
    {
        let (Some(whole), Some(name)) = (captures.get(0), captures.get(1)) else {
            continue;
        };
        rendered.push_str(&template[last..whole.start()]);
        if let Some((_, value)) = variables.iter().find(|(key, _)| *key == name.as_str()) {
            rendered.push_str(value);
        }
        last = whole.end();
    }
    rendered.push_str(&template[last..]);
    rendered
}

/// `create_worktree(repo_path=, workspace_path=, branch=, base_branch=)`:
/// a worktree for `branch` off `base_branch`, reused when it already exists.
pub fn create_worktree(
    repo: &Path,
    workspace: &Path,
    branch: &str,
    base_branch: &str,
) -> Outcome<()> {
    if let Some(parent) = workspace.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let workspace_text = workspace.to_string_lossy().into_owned();
    let listed = git(repo, &["worktree", "list", "--porcelain"])?;
    if listed.stdout.contains(&workspace_text) {
        return Ok(());
    }
    if workspace.exists() {
        return Err(Failure::runtime(format!(
            "{workspace_text} exists but is not a git worktree"
        )));
    }
    let add = || {
        git(
            repo,
            &[
                "worktree",
                "add",
                "-b",
                branch,
                &workspace_text,
                base_branch,
            ],
        )
    };
    let added = add()?;
    if added.code == 0 {
        return Ok(());
    }
    // A stale branch ref no worktree owns (a cancel that left it behind, or a
    // changed default branch): delete it and retry fresh off the base.
    if added.stderr.contains("already exists") {
        delete_branch(&repo.to_string_lossy(), branch);
        let retry = add()?;
        if retry.code == 0 {
            return Ok(());
        }
        return Err(Failure::runtime(format!(
            "git worktree add (after stale branch cleanup) failed: {}",
            py_strip(&retry.stderr)
        )));
    }
    if added.stderr.contains("already used") {
        return Err(Failure::runtime(format!(
            "branch {branch} is checked out by another worktree; cancel that run first: {}",
            py_strip(&added.stderr)
        )));
    }
    Err(Failure::runtime(format!(
        "git worktree add failed: {}",
        py_strip(&added.stderr)
    )))
}

fn copy_tree(source: &Path, destination: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(destination)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let target = destination.join(entry.file_name());
        if entry.path().is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

/// `_materialize_ticket_snapshot(ticket_file=, workspace_path=, ticket_id=)`:
/// the legacy board's ticket and its attachments, copied into the worktree.
pub fn materialize_ticket_snapshot(
    ticket_file: &Path,
    workspace: &Path,
    ticket_id: &str,
) -> Outcome<()> {
    let copied = (|| -> std::io::Result<()> {
        let snapshot = std::fs::read(ticket_file)?;
        let destination = workspace
            .join(".orchestrator")
            .join(format!("{ticket_id}.md"));
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = destination.with_file_name(format!("{ticket_id}.md.tmp"));
        std::fs::write(&temporary, snapshot)?;
        std::fs::rename(&temporary, &destination)?;
        let attachments = ticket_file
            .parent()
            .map(|board| board.join("attachments").join(ticket_id));
        if let Some(attachments) = attachments.filter(|path| path.is_dir()) {
            copy_tree(
                &attachments,
                &workspace
                    .join(".orchestrator")
                    .join("attachments")
                    .join(ticket_id),
            )?;
        }
        Ok(())
    })();
    copied.map_err(|error| {
        Failure::runtime(format!(
            "ticket snapshot materialization failed for {ticket_id}: {}",
            crate::worker::os_error_text(&error, ticket_file)
        ))
    })
}

fn run_id_of(run: &Dict) -> i64 {
    run.get("id").and_then(Value::py_int).unwrap_or_default()
}

fn is_state(run: &Dict, states: &[&str]) -> bool {
    run.get("state")
        .and_then(Value::as_str)
        .is_some_and(|state| states.contains(&state))
}

fn unknown_run(run_id: i64) -> Failure {
    Failure::value(format!("unknown run_id {run_id}"))
}

/// The pieces of `_build_prompt` that name one run.
pub struct PromptInputs<'a> {
    pub ticket_id: &'a str,
    pub repo_path: &'a str,
    pub workspace_path: &'a str,
    pub branch: &'a str,
    pub attempt: i64,
    pub run_id: i64,
    pub caller_context: Option<&'a str>,
}

impl Daemon {
    /// `_resolve_workflow_for_repo(repo_path)`: the project's own
    /// `.orchestrator/WORKFLOW.md`, else the daemon's template.
    pub(crate) fn resolve_workflow_for_repo(&self, repo_path: &str) -> PathBuf {
        let template = Path::new(repo_path)
            .join(".orchestrator")
            .join("WORKFLOW.md");
        if template.is_file() {
            template
        } else {
            self.paths.workflow_path.clone()
        }
    }

    /// `_build_prompt(...)`: the workflow template with the run's values.
    pub(crate) fn build_prompt(
        &self,
        inputs: &PromptInputs<'_>,
        template_path: &Path,
    ) -> Outcome<String> {
        let template = std::fs::read_to_string(template_path).map_err(|error| {
            Failure::runtime(format!(
                "could not read workflow template at {}: {}",
                template_path.display(),
                crate::worker::os_error_text(&error, template_path)
            ))
        })?;
        let missing: Vec<&str> = ["{{ticket_id}}", "{{run_id}}"]
            .into_iter()
            .filter(|marker| !template.contains(marker))
            .collect();
        if !missing.is_empty() {
            return Err(Failure::runtime(format!(
                "workflow template at {} is not an orchestrator ticket workflow; missing \
                 template variable(s): {}",
                template_path.display(),
                missing.join(", ")
            )));
        }
        // Sub-agents have no memory of the dispatching session; the caller's
        // context gets a heading only when there is some.
        let context_block = inputs
            .caller_context
            .map(py_strip)
            .filter(|context| !context.is_empty())
            .map(|context| format!("## Additional context from the dispatcher\n\n{context}\n"))
            .unwrap_or_default();
        let attempt = inputs.attempt.to_string();
        let run_id = inputs.run_id.to_string();
        let port_file = self.paths.port_file.to_string_lossy().into_owned();
        Ok(render_template(
            &template,
            &[
                ("ticket_id", inputs.ticket_id),
                ("repo_path", inputs.repo_path),
                ("workspace_path", inputs.workspace_path),
                ("branch", inputs.branch),
                ("attempt", &attempt),
                ("run_id", &run_id),
                ("caller_context", &context_block),
                ("port_file", &port_file),
            ],
        ))
    }

    // -- worker completion -------------------------------------------------------

    /// `_on_worker_complete(run_id)`: a finished worker's next step. A spike
    /// publishes its report; an implementation run that completed goes to a
    /// review worker; a failed artifact run publishes its failure.
    pub(crate) fn on_worker_complete(&self, run_id: i64, spike_result: Option<&Dict>) {
        guard(&self.workers).remove(&run_id);
        self.forget_run_health(run_id);
        let Ok(Some(run)) = self.runs.get(run_id) else {
            return;
        };
        let repo_path = run.string("repo_path");
        let lifecycle = match self.artifact_lifecycle(&repo_path) {
            Ok(lifecycle) => lifecycle,
            Err(error) => {
                eprintln!(
                    "[orchestrator] artifact lifecycle unavailable for run {run_id}: {error}"
                );
                None
            }
        };
        if run
            .get("execution_mode")
            .is_some_and(|mode| mode.is_str(SPIKE_EXECUTION_MODE))
        {
            self.complete_spike(&run, lifecycle.as_ref(), spike_result);
            self.record_queue_drain_after_event(Some(&repo_path), "spike-completion", false);
            return;
        }
        if let Some(lifecycle) = &lifecycle {
            if run.truthy("log_path").is_some() {
                let _ = lifecycle
                    .cap_local_log(Path::new(&run.string("log_path")), MAX_LOCAL_LOG_BYTES);
            }
            if is_state(&run, &["Failed", "Canceled", "Stalled"]) {
                let reason = run
                    .truthy("last_error")
                    .map(Value::py_str)
                    .unwrap_or_else(|| format!("run ended in {}", run.string("state")));
                if let Err(error) = lifecycle.record_failure(
                    run_id,
                    &run.string("ticket_id"),
                    &run.string("provider_key"),
                    &reason,
                    FailureKind {
                        canceled: is_state(&run, &["Canceled"]),
                        retry: false,
                    },
                ) {
                    let _ = self.runs.update(
                        run_id,
                        &RunUpdate {
                            last_error: Some(Some(format!(
                                "{reason}; artifact lifecycle publication failed: {}",
                                Failure::from(error).message
                            ))),
                            ..RunUpdate::default()
                        },
                    );
                }
            }
            let promoted = guard(&self.verification_closeouts).remove(&run_id);
            if let Some(promoted) = promoted
                && is_state(&run, &["Merged"])
            {
                self.finish_verification_closeout(&run, lifecycle, &promoted);
                return;
            }
        }
        if is_state(&run, &["AwaitingReview", "Succeeded"])
            && let Err(error) = self.dispatch_review_worker(run_id, "worker-completion", None)
        {
            let _ = self.runs.update(
                run_id,
                &RunUpdate {
                    state: Some("AwaitingReview".to_string()),
                    last_error: Some(Some(format!("review dispatch failed: {}", error.message))),
                    ..RunUpdate::default()
                },
            );
            let ticket_id = run.string("ticket_id");
            let message = format!("{ticket_id} run {run_id} review dispatch needs attention");
            self.emit_lifecycle(&LifecycleEvent {
                kind: "run-review-needed",
                ticket_id: Some(&ticket_id),
                run_id: Some(run_id),
                source: Some("orchestrator"),
                message: Some(&message),
                repo_path: Some(&repo_path),
                provider_key: run.get("provider_key").and_then(Value::as_str),
                ..LifecycleEvent::default()
            });
            eprintln!(
                "[orchestrator] review dispatch failed for run {run_id}: {}",
                error.message
            );
        }
        // Dependency progression happens only after the review worker accepts
        // and merges the implementation branch.
        self.record_queue_drain_after_event(Some(&repo_path), "worker-completion", false);
    }

    /// The spike half of `_on_worker_complete`.
    fn complete_spike(
        &self,
        run: &Dict,
        lifecycle: Option<&Arc<ArtifactLifecycleCoordinator>>,
        spike_result: Option<&Dict>,
    ) {
        if let Some(lifecycle) = lifecycle {
            self.finish_artifact_spike(run, lifecycle, spike_result);
            return;
        }
        let run_id = run_id_of(run);
        let persisted = match spike_result {
            Some(result) if is_state(run, &["SpikeResultReady"]) => self
                .spike_ticket_update(run, Some(result), None, false)
                .and_then(|()| {
                    self.runs.update(
                        run_id,
                        &RunUpdate {
                            state: Some(crate::spike::SPIKE_COMPLETED_RUN_STATE.to_string()),
                            last_error: Some(Some(String::new())),
                            ..RunUpdate::default()
                        },
                    )?;
                    let ticket_id = run.string("ticket_id");
                    let message = format!("{ticket_id} spike findings are ready");
                    self.emit_lifecycle(&LifecycleEvent {
                        kind: "run-succeeded",
                        ticket_id: Some(&ticket_id),
                        run_id: Some(run_id),
                        source: Some("orchestrator"),
                        message: Some(&message),
                        repo_path: run.get("repo_path").and_then(Value::as_str),
                        provider_key: run.get("provider_key").and_then(Value::as_str),
                        ..LifecycleEvent::default()
                    });
                    Ok(())
                }),
            _ => {
                let reason = run
                    .truthy("last_error")
                    .map(Value::py_str)
                    .unwrap_or_else(|| format!("spike ended in {}", run.string("state")));
                self.spike_ticket_update(run, None, Some(&reason), false)
            }
        };
        if let Err(error) = persisted {
            let _ = self.runs.update(
                run_id,
                &RunUpdate {
                    state: Some("Failed".to_string()),
                    last_error: Some(Some(format!(
                        "spike result persistence failed: {}",
                        error.message
                    ))),
                    ..RunUpdate::default()
                },
            );
        }
        let (removed, error) = remove_spike_workspace(Path::new(&run.string("workspace_path")));
        if !removed || error.is_some() {
            let current = self
                .runs
                .get(run_id)
                .ok()
                .flatten()
                .unwrap_or_else(|| run.clone());
            let cleanup = error.unwrap_or_else(|| "spike workspace still exists".to_string());
            let previous = current.text("last_error");
            let joined = [previous, cleanup]
                .into_iter()
                .filter(|item| !item.is_empty())
                .collect::<Vec<_>>()
                .join("; ");
            let _ = self.runs.update(
                run_id,
                &RunUpdate {
                    last_error: Some(Some(joined)),
                    ..RunUpdate::default()
                },
            );
        }
    }

    /// `_validate_artifact_completion(...)`: the structured outcome check; a
    /// verification-only close-out publishes `done` here, before the run
    /// ledger reports it, since the earlier run's merge already stands.
    pub(crate) fn validate_artifact_completion(
        &self,
        lifecycle: &Arc<ArtifactLifecycleCoordinator>,
        workspace: &Path,
        ticket_id: &str,
        run_id: i64,
        provider: &str,
        start_head: Option<&str>,
    ) -> (Option<String>, String) {
        let (outcome, reason) = match lifecycle
            .validate_worker_completion(workspace, ticket_id, run_id, provider, start_head)
        {
            Ok(result) => result,
            Err(error) => return (None, Failure::from(error).message),
        };
        if outcome.as_deref() != Some("verification_closeout") {
            return (outcome, reason);
        }
        let published = {
            let _merge = guard(&self.merge_lock);
            lifecycle.publish_verification_closeout(run_id, ticket_id, provider)
        };
        match published {
            Ok(result) => {
                guard(&self.verification_closeouts).insert(run_id, result.promoted_ticket_ids);
                (outcome, reason)
            }
            Err(error) => (
                None,
                format!(
                    "verification-only close-out publication failed: {}",
                    Failure::from(error).message
                ),
            ),
        }
    }

    /// `_finish_verification_closeout(run, lifecycle, promoted)`.
    fn finish_verification_closeout(
        &self,
        run: &Dict,
        lifecycle: &Arc<ArtifactLifecycleCoordinator>,
        promoted: &[String],
    ) {
        let repo_path = run.string("repo_path");
        let workspace = PathBuf::from(run.string("workspace_path"));
        ArtifactLifecycleCoordinator::cleanup_snapshot(&workspace);
        let (removed, error) = remove_worktree(&repo_path, &workspace);
        delete_branch(&repo_path, &run.string("branch"));
        if !removed || error.is_some() {
            let _ = self.runs.update(
                run_id_of(run),
                &RunUpdate {
                    last_error: Some(Some(format!(
                        "close-out published; {}",
                        error.unwrap_or_else(|| "worker worktree cleanup failed".to_string())
                    ))),
                    ..RunUpdate::default()
                },
            );
        }
        self.dispatch_promoted(&repo_path, lifecycle, promoted);
        self.dispatch_queued_dependents(&repo_path, lifecycle, &run.string("ticket_id"), promoted);
        self.record_queue_drain_after_event(Some(&repo_path), "verification-closeout", true);
    }

    /// Dispatches the dependents the canonical writer promoted.
    fn dispatch_promoted(
        &self,
        repo_path: &str,
        lifecycle: &Arc<ArtifactLifecycleCoordinator>,
        promoted: &[String],
    ) {
        for dependent in promoted {
            let mut request = DispatchRequest::new(dependent, repo_path, "dependency-progression");
            request.internally_confirmed_project_id = Some(lifecycle.store.project_id.clone());
            if let Err(error) = self.dispatch(&request) {
                eprintln!(
                    "[orchestrator] artifact dependent dispatch declined for {dependent}: {}",
                    error.message
                );
            }
        }
    }

    /// `_dispatch_queued_dependents`: starts the dependents that were
    /// already waiting in `ready`. The canonical writer reports only the
    /// tickets it promoted from backlog; a dependent dispatched before its
    /// predecessor is already `ready`, so it is not among them, and the
    /// sweeper holds no project confirmation to start it.
    fn dispatch_queued_dependents(
        &self,
        repo_path: &str,
        lifecycle: &Arc<ArtifactLifecycleCoordinator>,
        finished_ticket_id: &str,
        promoted: &[String],
    ) {
        let repo = Path::new(repo_path);
        let all_tickets: Vec<Ticket> = match tickets::scan_repo(repo) {
            Ok(board) => board.into_iter().map(|(_, ticket)| ticket).collect(),
            Err(error) => {
                // The merge stands; report it.
                eprintln!(
                    "[orchestrator] queued dependent scan failed in {repo_path}: {}",
                    Failure::from(error).message
                );
                return;
            }
        };
        for dependent in &all_tickets {
            if !dependent
                .depends_on
                .iter()
                .any(|id| id == finished_ticket_id)
                || promoted.contains(&dependent.id)
            {
                continue;
            }
            if dependent.status != "ready" || dependent.canceled || dependent.draft {
                continue;
            }
            let started = self
                .all_dependencies_done(repo, &dependent.depends_on, &all_tickets, Some(lifecycle))
                .and_then(|done| {
                    if !done {
                        return Ok(());
                    }
                    let mut request =
                        DispatchRequest::new(&dependent.id, repo_path, "dependency-progression");
                    request.internally_confirmed_project_id =
                        Some(lifecycle.store.project_id.clone());
                    self.dispatch(&request).map(|_| ())
                });
            if let Err(error) = started {
                eprintln!(
                    "[orchestrator] artifact dependent dispatch declined for {}: {}",
                    dependent.id, error.message
                );
            }
        }
    }

    // -- review --------------------------------------------------------------------

    /// `_on_review_worker_complete(run_id)`.
    pub(crate) fn on_review_worker_complete(&self, run_id: i64) {
        guard(&self.review_workers).remove(&run_id);
        self.forget_run_health(run_id);
        if let Ok(Some(run)) = self.runs.get(run_id) {
            self.record_queue_drain_after_event(
                run.get("repo_path").and_then(Value::as_str),
                "review-worker-completion",
                false,
            );
        }
    }

    /// `_build_review_prompt(run, source=, review_provider=, context=)`.
    fn build_review_prompt(
        &self,
        run: &Dict,
        source: &str,
        review_provider: &str,
        context: Option<&str>,
    ) -> Outcome<String> {
        let repo_path = run.string("repo_path");
        let branch = run.string("branch");
        let ticket_id = run.string("ticket_id");
        let run_id = run_id_of(run);
        let mut target_branch = crate::runs::git_text(&repo_path, &["branch", "--show-current"]);
        if target_branch.is_empty() {
            target_branch = resolve_default_branch(Path::new(&repo_path))?;
        }
        let evidence = self.inspect_run_for_review(run_id)?;
        let context_block = context
            .map(py_strip)
            .filter(|context| !context.is_empty())
            .map(|context| format!("\n## Additional context\n\n{context}\n"))
            .unwrap_or_default();
        let or = |value: String, fallback: &str| {
            if value.is_empty() {
                fallback.to_string()
            } else {
                value
            }
        };
        let evidence_text = |key: &str, fallback: &str| or(evidence.string(key), fallback);
        let port = self.port();
        Ok(format!(
            "You are a relay-runner review/merge sub-agent.\n\
\n\
Review implementation worker run {run_id} for ticket {ticket_id}. The foreground orchestrator handed this to you so it does not perform the substantive review or merge itself.\n\
\n\
## Context\n\
\n\
- Source repo path: `{repo_path}`\n\
- Target branch: `{target_branch}`\n\
- Implementation worker branch: `{branch}`\n\
- Implementation worker worktree: `{workspace}`\n\
- Implementation provider: `{provider}`\n\
- Review provider: `{review_provider}`\n\
- Worker model: `{worker_model}`\n\
- Worker effort: `{worker_effort}`\n\
- Provider notes: {notes}\n\
- Dispatch source: `{source}`\n\
{context_block}\
## Evidence from the completed worker\n\
\n\
### Branch commits\n\
```text\n\
{commits}\n\
```\n\
\n\
### Changed paths\n\
```text\n\
{changed}\n\
```\n\
\n\
### Diff stat\n\
```text\n\
{stat}\n\
```\n\
\n\
### Worker run log\n\
```text\n\
{run_log}\n\
```\n\
\n\
### Declared ticket outcome\n\
```text\n\
{status}\n\
```\n\
\n\
### Worker log tail\n\
```text\n\
{log_tail}\n\
```\n\
\n\
## What you must do\n\
\n\
1. Confirm the source repo and implementation branch exist.\n\
2. Inspect the worker branch changes against `{target_branch}`.\n\
3. Run the appropriate verification for the changed files. Public internet research is available for reading public evidence, but it does not authorize publishing, messages, uploads of private workspace data, or unrelated mutations. Pin any public-repository evidence to a commit and report provider/network failure explicitly.\n\
4. If the branch is acceptable, call the private daemon decision endpoint with `decision: accept`. A `verification_blocked` outcome is acceptable only when implementation is reviewable and the ticket names an exact external blocker plus explicit resume condition; accepting it merges useful work without closing the ticket or progressing dependents. If the work itself needs follow-up, call the same endpoint with `decision: retry` and a concise reason.\n\
\n\
Use this command shape for the final decision:\n\
\n\
```bash\n\
python3 - <<'PY'\n\
import json, urllib.request\n\
body = json.dumps({{\"decision\": \"accept\"}}).encode()\n\
request = urllib.request.Request(\n\
    \"http://127.0.0.1:{port}/v1/runs/{run_id}/review/decision\",\n\
    data=body,\n\
    headers={{\"Content-Type\": \"application/json\"}},\n\
    method=\"POST\",\n\
)\n\
print(urllib.request.urlopen(request, timeout=30).read().decode())\n\
PY\n\
```\n\
\n\
For a retry decision, send `{{\"decision\": \"retry\", \"reason\": \"...\", \"redispatch\": true}}`.\n\
\n\
Do not edit tickets directly. Do not push. The daemon merge path publishes `done` or the reviewed `verification_blocked` state only after acceptance and merge succeeds.\n",
            workspace = run
                .get("workspace_path")
                .map_or("None".to_string(), Value::py_str),
            provider = or(run.string("provider_key"), "unknown"),
            worker_model = or(run.string("worker_model"), "unknown"),
            worker_effort = or(run.string("worker_effort"), "unknown"),
            notes = or(run.string("worker_provider_notes"), "none"),
            commits = evidence_text("branch_commits", "(none)"),
            changed = evidence_text("branch_diff_name_status", "(none)"),
            stat = evidence_text("branch_diff_stat", "(none)"),
            run_log = evidence_text("ticket_run_log", "(none)"),
            status = evidence_text("ticket_status", "(unknown)"),
            log_tail = evidence_text("log_tail", "(none)"),
        ))
    }

    /// `dispatch_review_worker(run_id, source=, context=)`: start the
    /// review/merge worker of a run awaiting review.
    pub fn dispatch_review_worker(
        &self,
        run_id: i64,
        source: &str,
        context: Option<&str>,
    ) -> Outcome<Dict> {
        let run = self.runs.get(run_id)?.ok_or_else(|| unknown_run(run_id))?;
        if !is_state(&run, &REVIEW_BLOCKING_STATES) {
            return Err(Failure::value(format!(
                "run {run_id} is not awaiting review"
            )));
        }
        let provider = {
            let mut reviewers = guard(&self.review_workers);
            if reviewers.contains_key(&run_id) {
                drop(reviewers);
                let mut result = Dict::new();
                result.insert("review_already_active", true);
                result.insert("run", self.runs.get(run_id)?);
                return Ok(result);
            }
            let (provider, binary, _general) = self.effective_worker_agent()?;
            if let Some(lifecycle) = self.artifact_lifecycle(&run.string("repo_path"))? {
                lifecycle.begin_review(run_id, &provider)?;
            }
            let prompt = self.build_review_prompt(&run, source, &provider, context)?;
            let log_path = match run.truthy("log_path") {
                Some(path) => PathBuf::from(path.py_str()),
                None => Path::new(&run.string("workspace_path"))
                    .join(".relay")
                    .join("run.log"),
            };
            self.start_review_worker(
                &mut reviewers,
                ReviewLaunch {
                    run_id,
                    run: run.clone(),
                    prompt,
                    agent_bin: binary,
                    agent_kind: provider.clone(),
                    log_path,
                },
            );
            provider
        };
        eprintln!(
            "[orchestrator] review worker dispatched for {} run {run_id} from {source}: {provider}",
            run.string("ticket_id")
        );
        let mut result = Dict::new();
        result.insert("review_dispatched", true);
        result.insert("run", self.runs.get(run_id)?);
        Ok(result)
    }

    /// Whether a review worker of this daemon runs for the run.
    pub(crate) fn review_active(&self, run_id: i64) -> bool {
        guard(&self.review_workers).contains_key(&run_id)
    }

    /// `_local_run_owner(run_id, state)`: this daemon's process for the run.
    pub(crate) fn local_run_owner(&self, run_id: i64, state: &str) -> Option<Arc<RunProcess>> {
        let owners = if state == "Reviewing" {
            guard(&self.review_workers)
        } else {
            guard(&self.workers)
        };
        owners.get(&run_id).cloned()
    }

    // -- merge -------------------------------------------------------------------------

    /// `accept_worker_run(run_id)`: merge a reviewed run into the checked-out
    /// branch, publish its outcome and progress its dependents.
    pub fn accept_worker_run(&self, run_id: i64) -> Outcome<Dict> {
        let _merge = guard(&self.merge_lock);
        self.accept_worker_run_locked(run_id)
    }

    fn accept_worker_run_locked(&self, run_id: i64) -> Outcome<Dict> {
        let run = self.runs.get(run_id)?.ok_or_else(|| unknown_run(run_id))?;
        if !is_state(&run, &MERGEABLE_REVIEW_STATES) {
            return Err(Failure::value(format!(
                "run {run_id} is not awaiting review"
            )));
        }
        let repo_path = run.string("repo_path");
        let repo = PathBuf::from(&repo_path);
        let branch = run.string("branch");
        let ticket_id = run.string("ticket_id");
        let provider = run.string("provider_key");
        let lifecycle = self.artifact_lifecycle(&repo_path)?;
        let mut artifact_outcome = None;
        let expected_status = if let Some(lifecycle) = &lifecycle {
            let outcome = lifecycle.outcome(run_id)?.ok_or_else(|| {
                Failure::value(format!("run {run_id} has no structured artifact outcome"))
            })?;
            let status = if outcome.status.value() == VERIFICATION_BLOCKED_STATUS {
                VERIFICATION_BLOCKED_STATUS
            } else {
                "done"
            };
            artifact_outcome = Some(outcome);
            status.to_string()
        } else {
            let path = Path::new(&run.string("workspace_path"))
                .join(".orchestrator")
                .join(format!("{ticket_id}.md"));
            let ticket = crate::runs::read_ticket(&path).map_err(|failure| match failure {
                TicketRead::Caught(message) => Failure::value(format!(
                    "could not read reviewed ticket for run {run_id}: {message}"
                )),
                TicketRead::Other(failure) => failure,
            })?;
            if ticket.status != "done" && ticket.status != VERIFICATION_BLOCKED_STATUS {
                return Err(Failure::value(format!(
                    "run {run_id} ticket status {} is not a reviewable outcome",
                    pystr::repr(&ticket.status)
                )));
            }
            ticket.status
        };
        let emit = |kind: &str, message: Option<&str>| {
            self.emit_lifecycle(&LifecycleEvent {
                kind,
                ticket_id: Some(&ticket_id),
                run_id: Some(run_id),
                source: Some("orchestrator"),
                message,
                repo_path: Some(&repo_path),
                provider_key: run.get("provider_key").and_then(Value::as_str),
                ..LifecycleEvent::default()
            });
        };
        let set = |state: &str, last_error: Option<String>| {
            self.runs.update(
                run_id,
                &RunUpdate {
                    state: Some(state.to_string()),
                    last_error: Some(last_error),
                    ..RunUpdate::default()
                },
            )
        };
        let refused = |reason: &str| -> Outcome<Dict> {
            let mut result = Dict::new();
            result.insert("accepted", false);
            result.insert("run", self.runs.get(run_id)?);
            result.insert("reason", reason);
            Ok(result)
        };

        if let Some(blocker) = source_checkout_blocker(&repo, false)? {
            let reason = format!("{}. {}", blocker.reason, blocker.next_step);
            set(INTEGRATION_BLOCKED_RUN_STATE, Some(reason.clone()))?;
            emit("run-integration-blocked", Some(&reason));
            self.record_queue_drain_after_event(
                Some(&repo_path),
                "merge-blocked-dirty-source",
                false,
            );
            let mut result = Dict::new();
            result.insert("accepted", false);
            result.insert("integration_blocked", true);
            result.insert("run", self.runs.get(run_id)?);
            result.insert("reason", blocker.reason.as_str());
            result.insert(
                "dirty_paths",
                crate::dispatch::string_values(&blocker.dirty_paths),
            );
            result.insert("next_step", blocker.next_step.as_str());
            return Ok(result);
        }

        let message = format!("merge {ticket_id} worker run {run_id}");
        let merge = git(&repo, &["merge", "--no-ff", &branch, "-m", &message])?;
        if merge.code != 0 {
            let _ = git(&repo, &["merge", "--abort"]);
            let mut reason = py_strip(if merge.stderr.is_empty() {
                &merge.stdout
            } else {
                &merge.stderr
            })
            .to_string();
            if reason.is_empty() {
                reason = "merge failed".to_string();
            }
            if let Some(lifecycle) = &lifecycle
                && let Err(error) =
                    lifecycle.record_merge_conflict(run_id, &ticket_id, &provider, &reason)
            {
                reason.push_str(&format!(
                    "; artifact conflict publication failed: {}",
                    Failure::from(error).message
                ));
            }
            set("MergeConflict", Some(reason.clone()))?;
            let attention = format!("{ticket_id} run {run_id} merge needs attention");
            emit("run-failed", Some(&attention));
            self.record_queue_drain_after_event(Some(&repo_path), "merge-conflict", false);
            return refused(&reason);
        }

        let mut promoted: Vec<String> = Vec::new();
        let mut merged_ticket: Option<Ticket> = None;
        if let Some(lifecycle) = &lifecycle {
            let merged_source = crate::runs::git_head(&repo_path).unwrap_or_default();
            match lifecycle.publish_merge_success(run_id, &ticket_id, &provider, &merged_source) {
                Ok(published) => promoted = published.promoted_ticket_ids,
                Err(error) => {
                    // The source merge is durable; stop honestly.
                    let reason = format!(
                        "source merge succeeded but artifact lifecycle publication failed: {}",
                        Failure::from(error).message
                    );
                    set("MergeConflict", Some(reason.clone()))?;
                    let attention =
                        format!("{ticket_id} source merged but canonical outcome needs recovery");
                    emit("run-failed", Some(&attention));
                    self.record_queue_drain_after_event(
                        Some(&repo_path),
                        "artifact-publication-failed",
                        false,
                    );
                    return refused(&reason);
                }
            }
            ArtifactLifecycleCoordinator::cleanup_snapshot(Path::new(
                &run.string("workspace_path"),
            ));
        } else {
            let ticket =
                tickets::read(&repo.join(".orchestrator").join(format!("{ticket_id}.md")))?;
            if ticket.status != expected_status {
                let reason =
                    format!("merged branch did not publish {ticket_id} as {expected_status}");
                set("MergeConflict", Some(reason.clone()))?;
                let attention = format!("{ticket_id} run {run_id} merge needs attention");
                emit("run-failed", Some(&attention));
                self.record_queue_drain_after_event(
                    Some(&repo_path),
                    "merge-missing-reviewed-ticket-state",
                    false,
                );
                return refused(&reason);
            }
            merged_ticket = Some(ticket);
        }

        let (removed, worktree_error) =
            remove_worktree(&repo_path, Path::new(&run.string("workspace_path")));
        delete_branch(&repo_path, &branch);
        let verification_blocked = expected_status == VERIFICATION_BLOCKED_STATUS;
        if verification_blocked {
            let (blocker, resume) = match (&artifact_outcome, &merged_ticket) {
                (Some(outcome), _) => (
                    outcome.verification_blocker.clone().unwrap_or_default(),
                    outcome.verification_resume.clone().unwrap_or_default(),
                ),
                (None, Some(ticket)) => (
                    ticket.verification_blocker.clone().unwrap_or_default(),
                    ticket.verification_resume.clone().unwrap_or_default(),
                ),
                (None, None) => (String::new(), String::new()),
            };
            set(
                VERIFICATION_BLOCKED_RUN_STATE,
                Some(format!(
                    "verification blocked: {}; resume: {}",
                    py_strip(&blocker),
                    py_strip(&resume)
                )),
            )?;
            let waiting = format!("{ticket_id} is reviewed and waiting on external verification");
            emit("run-verification-blocked", Some(&waiting));
        } else {
            set("Merged", None)?;
            emit("run-merged", None);
            match &lifecycle {
                None => {
                    if let Err(error) = self.progress_dependents(&repo, &ticket_id) {
                        eprintln!(
                            "[orchestrator] dep-progression error after merging {ticket_id}: {}",
                            error.message
                        );
                    }
                }
                Some(lifecycle) => {
                    self.dispatch_promoted(&repo_path, lifecycle, &promoted);
                    self.dispatch_queued_dependents(&repo_path, lifecycle, &ticket_id, &promoted);
                }
            }
        }
        self.record_queue_drain_after_event(Some(&repo_path), "run-merged", true);
        let mut result = Dict::new();
        result.insert("accepted", true);
        result.insert("run", self.runs.get(run_id)?);
        result.insert("worktree_removed", removed);
        result.insert("promoted", crate::dispatch::string_values(&promoted));
        if let Some(error) = worktree_error {
            result.insert("worktree_error", error);
        }
        Ok(result)
    }

    /// `_resume_clean_integration_blocks(repo)`: merge the integration-blocked
    /// runs of a checkout that is clean again.
    pub(crate) fn resume_clean_integration_blocks(&self, repo: &Path) -> Outcome<Vec<Value>> {
        let mut resumed = Vec::new();
        let repo_text = repo.to_string_lossy().into_owned();
        for run in self.runs.list(Some(INTEGRATION_BLOCKED_RUN_STATE), 1000)? {
            if resolve_path(&run.string("repo_path")).to_string_lossy() != repo_text {
                continue;
            }
            if source_checkout_blocker(repo, false)?.is_some() {
                continue;
            }
            let result = self.accept_worker_run(run_id_of(&run))?;
            let mut entry = Dict::new();
            entry.insert(
                "ticket_id",
                run.get("ticket_id").cloned().unwrap_or(Value::Null),
            );
            entry.insert("run_id", run.get("id").cloned().unwrap_or(Value::Null));
            entry.insert(
                "accepted",
                result.get("accepted").is_some_and(Value::truthy),
            );
            entry.insert(
                "state",
                result
                    .get("run")
                    .and_then(Value::as_dict)
                    .and_then(|run| run.get("state").cloned())
                    .unwrap_or(Value::Null),
            );
            resumed.push(Value::Dict(entry));
        }
        Ok(resumed)
    }

    // -- dependency progression ---------------------------------------------------

    /// `_progress_dependents(repo_path=, finished_ticket_id=)`: when a ticket
    /// is done in the source repo, dispatch the dependents whose
    /// predecessors are all done.
    pub(crate) fn progress_dependents(&self, repo: &Path, finished_ticket_id: &str) -> Outcome<()> {
        let _authoring = guard(&self.authoring_lock);
        let lifecycle = self.artifact_lifecycle(&repo.to_string_lossy())?;
        if lifecycle.is_some() {
            // The projected board changes only through the canonical writer;
            // the loop below reads the re-materialized projection.
            self.promote_unblocked_dependents(repo, lifecycle.as_ref())?;
        }
        let board = tickets::scan_repo(repo)?;
        let all_tickets: Vec<Ticket> = board.iter().map(|(_, ticket)| ticket.clone()).collect();
        let Some(finished) = all_tickets
            .iter()
            .find(|ticket| ticket.id == finished_ticket_id)
        else {
            return Ok(());
        };
        if finished.status != "done" {
            return Ok(());
        }
        let finished_spike = finished.execution_mode == SPIKE_EXECUTION_MODE;
        let repo_text = repo.to_string_lossy().into_owned();
        for (path, dependent) in &board {
            if !dependent
                .depends_on
                .iter()
                .any(|id| id == finished_ticket_id)
            {
                continue;
            }
            if dependent.status != "backlog" && dependent.status != "ready" {
                continue;
            }
            if dependent.canceled || dependent.draft {
                continue;
            }
            if !self.all_dependencies_done(
                repo,
                &dependent.depends_on,
                &all_tickets,
                lifecycle.as_ref(),
            )? {
                continue;
            }
            if dependent.status == "backlog" && lifecycle.is_some() {
                // The canonical writer declined to promote it.
                continue;
            }
            if dependent.status == "backlog" && finished_spike {
                // A research result informs refinement; it never authorizes a
                // downstream implementation ticket on the user's behalf.
                continue;
            }
            if dependent.status == "backlog" {
                let mut ready = dependent.clone();
                ready.status = "ready".to_string();
                tickets::write(path, &ready)?;
                self.notify_orchestration_trace(
                    "board-change",
                    Some(&dependent.id),
                    None,
                    None,
                    None,
                );
            }
            let mut request =
                DispatchRequest::new(&dependent.id, &repo_text, "dependency-progression");
            if let Some(lifecycle) = &lifecycle {
                request.internally_confirmed_project_id = Some(lifecycle.store.project_id.clone());
            }
            if let Err(error) = self.dispatch(&request) {
                // The status flip stays; the user can redispatch.
                eprintln!(
                    "[orchestrator] auto-dispatch declined for {}: {}",
                    dependent.id, error.message
                );
            }
        }
        Ok(())
    }

    // -- retry and resume ------------------------------------------------------------

    /// `request_worker_retry(run_id, reason=, redispatch=)`.
    pub fn request_worker_retry(
        &self,
        run_id: i64,
        reason: Option<&str>,
        redispatch: bool,
    ) -> Outcome<Dict> {
        let run = self.runs.get(run_id)?.ok_or_else(|| unknown_run(run_id))?;
        if !is_state(&run, &REVIEW_BLOCKING_STATES) {
            return Err(Failure::value(format!(
                "run {run_id} is not awaiting review"
            )));
        }
        let repo_path = run.string("repo_path");
        let ticket_id = run.string("ticket_id");
        let workspace = PathBuf::from(run.string("workspace_path"));
        let failure_reason = format!(
            "Review requested retry: {}",
            py_strip(reason.unwrap_or("work incomplete"))
        );
        let lifecycle = self.artifact_lifecycle(&repo_path)?;
        if let Some(lifecycle) = &lifecycle {
            lifecycle
                .record_failure(
                    run_id,
                    &ticket_id,
                    &run.string("provider_key"),
                    &failure_reason,
                    FailureKind {
                        canceled: false,
                        retry: true,
                    },
                )
                .map_err(|error| {
                    Failure::value(format!(
                        "could not publish canonical review retry for run {run_id}: {}",
                        Failure::from(error).message
                    ))
                })?;
            ArtifactLifecycleCoordinator::cleanup_snapshot(&workspace);
        }
        let (removed, worktree_error) = remove_worktree(&repo_path, &workspace);
        delete_branch(&repo_path, &run.string("branch"));
        self.runs.update(
            run_id,
            &RunUpdate {
                state: Some("Failed".to_string()),
                last_error: Some(Some(failure_reason)),
                ..RunUpdate::default()
            },
        )?;
        let message = format!("{ticket_id} run {run_id} needs retry after review");
        self.emit_lifecycle(&LifecycleEvent {
            kind: "run-failed",
            ticket_id: Some(&ticket_id),
            run_id: Some(run_id),
            source: Some("orchestrator"),
            message: Some(&message),
            repo_path: Some(&repo_path),
            provider_key: run.get("provider_key").and_then(Value::as_str),
            ..LifecycleEvent::default()
        });
        let mut result = Dict::new();
        result.insert("retry_requested", true);
        result.insert("run", self.runs.get(run_id)?);
        result.insert("worktree_removed", removed);
        result.insert("redispatched", Value::Null);
        if let Some(error) = worktree_error {
            result.insert("worktree_error", error);
        }
        if redispatch {
            let mut request =
                DispatchRequest::new(&ticket_id, &repo_path, "orchestrator-review-retry");
            if let Some(lifecycle) = &lifecycle {
                request.internally_confirmed_project_id = Some(lifecycle.store.project_id.clone());
            }
            match self.dispatch(&request) {
                Ok(dispatched) => result.insert("redispatched", dispatched),
                Err(error) if crate::queue::is_value_or_runtime(&error) => {
                    result.insert("redispatch_error", error.message)
                }
                Err(error) => return Err(error),
            }
        }
        self.record_queue_drain_after_event(Some(&repo_path), "review-retry", false);
        Ok(result)
    }

    /// `resume_verification_blocked(run_id, reason=, redispatch=)`: record
    /// what changed for a reviewed verification blocker, then optionally
    /// dispatch the ticket again.
    pub fn resume_verification_blocked(
        &self,
        run_id: i64,
        reason: Option<&Value>,
        redispatch: bool,
    ) -> Outcome<Dict> {
        let run = self.runs.get(run_id)?.ok_or_else(|| unknown_run(run_id))?;
        if !is_state(&run, &[VERIFICATION_BLOCKED_RUN_STATE]) {
            return Err(Failure::value(format!(
                "run {run_id} is not verification blocked"
            )));
        }
        let resume_reason = clean_required_text(reason, "reason")?;
        let repo = resolve_path(&run.string("repo_path"));
        let repo_text = repo.to_string_lossy().into_owned();
        let ticket_id = run.get("ticket_id").map(Value::py_str).unwrap_or_default();
        let lifecycle = self.artifact_lifecycle(&repo_text)?;
        let resume_commit: Option<String> = if let Some(lifecycle) = &lifecycle {
            let published = lifecycle
                .resume_verification(
                    run_id,
                    &ticket_id,
                    &run.string("provider_key"),
                    &resume_reason,
                )
                .map_err(|error| {
                    Failure::value(format!(
                        "could not publish canonical verification resume for run {run_id}: {}",
                        Failure::from(error).message
                    ))
                })?;
            Some(published.commit_id)
        } else {
            let ticket_path = repo.join(".orchestrator").join(format!("{ticket_id}.md"));
            let _authoring = guard(&self.authoring_lock);
            crate::actions::ensure_ticket_authoring_paths_clean(
                &repo,
                std::slice::from_ref(&ticket_path),
            )?;
            let mut ticket = tickets::read(&ticket_path)?;
            if ticket.status != VERIFICATION_BLOCKED_STATUS {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} is {}, expected {}",
                    pystr::repr(&ticket.status),
                    pystr::repr(VERIFICATION_BLOCKED_STATUS)
                )));
            }
            if ticket.run_id != Some(run_id) {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} run_id is {}, expected {run_id}",
                    ticket
                        .run_id
                        .map_or("None".to_string(), |id| id.to_string())
                )));
            }
            let body = ticket
                .body
                .trim_end_matches(relay_intents::json::py_is_space);
            let entry =
                format!("- **Verification resumed after run {run_id}** \u{2014} {resume_reason}");
            ticket.body = if body.contains("## Run log") {
                format!("{body}\n{entry}\n")
            } else {
                format!("{body}\n\n## Run log\n\n{entry}\n")
            };
            ticket.status = "ready".to_string();
            ticket.run_id = None;
            ticket.verification_blocker = None;
            ticket.verification_resume = None;
            tickets::write(&ticket_path, &ticket)?;
            crate::actions::commit_ticket_authorship(
                &repo,
                std::slice::from_ref(&ticket_path),
                std::slice::from_ref(&ticket_id),
                None,
            )?;
            crate::runs::git_head(&repo_text)
        };
        let message = format!("{ticket_id} verification resumed: {resume_reason}");
        self.emit_lifecycle(&LifecycleEvent {
            kind: "run-verification-resumed",
            ticket_id: Some(&ticket_id),
            run_id: Some(run_id),
            source: Some("orchestrator"),
            message: Some(&message),
            repo_path: Some(&repo_text),
            provider_key: run.get("provider_key").and_then(Value::as_str),
            ..LifecycleEvent::default()
        });
        let mut result = Dict::new();
        result.insert("resumed", true);
        result.insert("reason", resume_reason.as_str());
        result.insert("resume_commit", resume_commit);
        result.insert("previous_run", self.runs.get(run_id)?);
        result.insert("redispatched", Value::Null);
        if redispatch {
            let mut request = DispatchRequest::new(&ticket_id, &repo_text, "verification-resume");
            request.context = Some(format!("Verification resumed because: {resume_reason}"));
            if let Some(lifecycle) = &lifecycle {
                request.internally_confirmed_project_id = Some(lifecycle.store.project_id.clone());
            }
            result.insert("redispatched", self.dispatch(&request)?);
        }
        self.record_queue_drain_after_event(Some(&repo_text), "verification-resumed", false);
        Ok(result)
    }

    // -- cancel ------------------------------------------------------------------------

    /// `cancel_run(run_id, prune_worktree=)`: stop a live run's worker (or
    /// record a run without one as canceled), publish the cancellation and
    /// remove its worktree.
    pub fn cancel_run(&self, run_id: i64, prune_worktree: bool) -> Outcome<Dict> {
        let run = self.runs.get(run_id)?.ok_or_else(|| unknown_run(run_id))?;
        let state = run.string("state");
        if !ACTIVE_STATES.contains(&state.as_str()) && state != "Stalled" {
            let mut body = Dict::new();
            body.insert("canceled", false);
            body.insert(
                "reason",
                format!(
                    "run is in terminal state {}",
                    run.get("state").map_or("None".to_string(), Value::py_str)
                ),
            );
            body.insert("run", run);
            return Ok(body);
        }
        let spike = run
            .get("execution_mode")
            .is_some_and(|mode| mode.is_str(SPIKE_EXECUTION_MODE));
        let repo_path = run.string("repo_path");
        let workspace = PathBuf::from(run.string("workspace_path"));
        let mut spike_lifecycle = None;
        if spike {
            spike_lifecycle = self.artifact_lifecycle(&repo_path)?;
            if let Some(lifecycle) = &spike_lifecycle
                && lifecycle.recover_spike_completion(run_id)?.is_some()
            {
                self.finish_artifact_spike(&run, lifecycle, None);
                let mut body = Dict::new();
                body.insert("canceled", false);
                body.insert("reason", "spike findings are already published");
                body.insert("run", self.runs.get(run_id)?);
                return Ok(body);
            }
        }
        let worker = guard(&self.workers).get(&run_id).cloned();
        if let Some(worker) = worker {
            worker.cancel();
            if !worker.wait_done(CANCEL_JOIN_TIMEOUT) {
                let mut body = Dict::new();
                body.insert("canceled", false);
                body.insert("cancel_requested", true);
                body.insert(
                    "reason",
                    "worker is still terminating; snapshot and lease were preserved",
                );
                body.insert("run", self.runs.get(run_id)?);
                return Ok(body);
            }
        } else {
            self.runs.update(
                run_id,
                &RunUpdate {
                    state: Some("Canceled".to_string()),
                    last_error: Some(Some("Canceled (no live worker)".to_string())),
                    ended: true,
                    ..RunUpdate::default()
                },
            )?;
            if spike {
                let current = self.runs.get(run_id)?.unwrap_or_else(|| run.clone());
                match &spike_lifecycle {
                    Some(lifecycle) => self.finish_artifact_spike(&current, lifecycle, None),
                    None => {
                        if let Err(error) = self.spike_ticket_update(
                            &current,
                            None,
                            Some("Canceled by user."),
                            false,
                        ) {
                            self.runs.update(
                                run_id,
                                &RunUpdate {
                                    last_error: Some(Some(format!(
                                        "Canceled; ticket reset failed: {}",
                                        error.message
                                    ))),
                                    ..RunUpdate::default()
                                },
                            )?;
                        }
                    }
                }
            }
        }
        let lifecycle = self.artifact_lifecycle(&repo_path)?;
        if lifecycle.is_some() && spike {
            let current = self.runs.get(run_id)?.unwrap_or_else(|| run.clone());
            let mut body = Dict::new();
            body.insert("canceled", is_state(&current, &["Canceled"]));
            body.insert("run", current);
            body.insert("worktree_removed", !workspace.exists());
            return Ok(body);
        }
        if let Some(lifecycle) = &lifecycle {
            let current = self.runs.get(run_id)?.unwrap_or_else(|| run.clone());
            let reason = current
                .truthy("last_error")
                .map(Value::py_str)
                .unwrap_or_else(|| "Canceled by user.".to_string());
            lifecycle
                .record_failure(
                    run_id,
                    &run.string("ticket_id"),
                    &run.string("provider_key"),
                    &reason,
                    FailureKind {
                        canceled: true,
                        retry: false,
                    },
                )
                .map_err(|error| {
                    Failure::value(format!(
                        "run {run_id} stopped, but canonical cancellation could not be published: {}",
                        Failure::from(error).message
                    ))
                })?;
            if prune_worktree {
                ArtifactLifecycleCoordinator::cleanup_snapshot(&workspace);
            }
        }
        let mut body = Dict::new();
        body.insert("canceled", true);
        body.insert("run", self.runs.get(run_id)?);
        if prune_worktree && !repo_path.is_empty() {
            let (removed, error) = if spike {
                remove_spike_workspace(&workspace)
            } else {
                remove_worktree(&repo_path, &workspace)
            };
            body.insert("worktree_removed", removed);
            if let Some(error) = error {
                body.insert("worktree_error", error);
            }
            // Drop the throwaway branch so a redispatch starts fresh off the
            // current default branch.
            if !spike {
                delete_branch(&repo_path, &run.string("branch"));
            }
        }
        self.record_queue_drain_after_event(
            run.get("repo_path").and_then(Value::as_str),
            "run-canceled",
            false,
        );
        Ok(body)
    }

    /// `shutdown()`'s worker half: cancel every implementation and spike
    /// worker and let each record its run before the daemon exits.
    pub(crate) fn cancel_workers(&self) {
        let workers: HashMap<i64, Arc<RunProcess>> = guard(&self.workers).clone();
        for worker in workers.values() {
            worker.cancel();
        }
        for worker in workers.values() {
            worker.wait_done(SHUTDOWN_JOIN_TIMEOUT);
        }
    }
}
