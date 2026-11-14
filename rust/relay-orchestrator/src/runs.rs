//! The run routes other than dispatch: list, get, the worker outcome,
//! review inspection and decision, cancel, verification resume and
//! preserved-run recovery (`services/orchestrator.py`, `Daemon.list_runs`
//! through `recover_preserved_run_collision` and `cancel_run`).
//!
//! Review workers, the merge and the verification close-out are part 5
//! (RR-498): those routes run every check Python makes before it starts a
//! reviewer, merges, publishes or redispatches, then answer
//! [`Failure::execution_deferred`] having written nothing.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use relay_artifacts::lifecycle::{ArtifactLifecycleCoordinator, FailureKind};
use relay_artifacts::tickets::{self, Ticket};
use relay_artifacts::{ErrorKind, pystr};
use relay_intents::json::{self, Dict, Value};
use relay_intents::pattern::Regex;
use relay_store::runs::{
    ACTIVE_STATES, MERGEABLE_REVIEW_STATES, REVIEW_BLOCKING_STATES, RunUpdate,
    SPIKE_EXECUTION_MODE, VERIFICATION_BLOCKED_RUN_STATE, sanitize_identifier,
};

use crate::daemon::{Daemon, guard, resolve_path};
use crate::failure::{Class, Failure, Outcome};
use crate::request::{Request, parse_int};
use crate::router::{Reply, reply, single};
use crate::trace::LifecycleEvent;

pub const VERIFICATION_BLOCKED_STATUS: &str = "verification_blocked";

// -- helpers ------------------------------------------------------------------

/// `int(segments[index])`.
fn run_id_segment(request: &Request, index: usize) -> Outcome<i64> {
    parse_int(&request.segments[index])
}

fn unknown_run(run_id: i64) -> Failure {
    Failure::value(format!("unknown run_id {run_id}"))
}

/// `str(OSError)` for a failure on `path`: `[Errno N] <message>: '<path>'`.
fn os_error(error: &std::io::Error, path: &Path) -> String {
    let message = error.to_string();
    let message = match message.rfind(" (os error ") {
        Some(index) => message[..index].to_string(),
        None => message,
    };
    match error.raw_os_error() {
        Some(code) => format!(
            "[Errno {code}] {message}: {}",
            pystr::repr(&path.to_string_lossy())
        ),
        None => message,
    }
}

/// Why a ticket file could not be read: `OSError`, `TicketParseError`, or
/// another failure that is not caught where Python catches those two.
enum TicketRead {
    Caught(String),
    Other(Failure),
}

/// `read_ticket(path)`, with Python's `str(error)` for the two caught kinds.
fn read_ticket(path: &Path) -> Result<Ticket, TicketRead> {
    let bytes = std::fs::read(path).map_err(|error| TicketRead::Caught(os_error(&error, path)))?;
    let text = pystr::decode_utf8(&bytes).map_err(|error| TicketRead::Other(error.into()))?;
    tickets::parse(&pystr::universal_newlines(text)).map_err(|error| match error.kind {
        ErrorKind::TicketParse => TicketRead::Caught(error.message),
        _ => TicketRead::Other(error.into()),
    })
}

/// `read_ticket(path)` where every failure propagates: an `OSError` as 503,
/// a `TicketParseError` as 400.
fn read_ticket_or_fail(path: &Path) -> Outcome<Ticket> {
    tickets::read(path).map_err(Failure::from)
}

/// `Path(body.get("repo_path", "")).expanduser().resolve()`: a value that is
/// not a string is Python's `TypeError`, which escapes the handler.
fn repo_argument(request: &Request) -> Outcome<PathBuf> {
    match request.get("repo_path") {
        None => Ok(resolve_path("")),
        Some(Value::Str(text)) => Ok(resolve_path(text)),
        Some(_) => Err(Failure::escape("repo_path must be str or PathLike")),
    }
}

/// `subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)`.
fn git(repo: &str, args: &[&str]) -> Outcome<Output> {
    Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .output()
        .map_err(Failure::from)
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// `_git_text(repo_path, *args)`: stdout, or stderr when git failed.
fn git_text(repo: &str, args: &[&str]) -> String {
    match git(repo, args) {
        Ok(output) => {
            let text = json::py_strip(&stdout(&output)).to_string();
            if output.status.success() {
                return text;
            }
            let error = json::py_strip(&stderr(&output)).to_string();
            if !error.is_empty() {
                error
            } else if !text.is_empty() {
                text
            } else {
                format!(
                    "git {} failed with exit {}",
                    args.join(" "),
                    output.status.code().unwrap_or(-1)
                )
            }
        }
        Err(failure) => failure.message,
    }
}

/// `_git_head(repo_path)`.
fn git_head(repo: &str) -> Option<String> {
    let output = git(repo, &["rev-parse", "HEAD"]).ok()?;
    if !output.status.success() {
        return None;
    }
    let head = json::py_strip(&stdout(&output)).to_string();
    (!head.is_empty()).then_some(head)
}

/// `_tail_text(path)`: the last 160 lines, at most 20 000 characters.
fn tail_text(path: &Path) -> String {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => return format!("unavailable: {}", os_error(&error, path)),
    };
    let text = pystr::universal_newlines(&String::from_utf8_lossy(&bytes));
    let lines = pystr::splitlines(&text);
    let joined = lines[lines.len().saturating_sub(160)..].join("\n");
    let count = joined.chars().count();
    joined.chars().skip(count.saturating_sub(20_000)).collect()
}

/// `_ticket_run_log(body)`: the body from `## Run log`, stripped.
fn ticket_run_log(body: &str) -> String {
    match body.find("## Run log") {
        Some(index) => json::py_strip(&body[index..]).to_string(),
        None => String::new(),
    }
}

/// `remove_worktree(repo_path, workspace_path)`: `(removed, error)`.
pub fn remove_worktree(repo: &str, workspace: &Path) -> (bool, Option<String>) {
    let workspace_text = workspace.to_string_lossy();
    let result = git(repo, &["worktree", "remove", "--force", &workspace_text]);
    if !workspace.exists() {
        return (true, None);
    }
    if let Err(error) = std::fs::remove_dir_all(workspace) {
        let git_error = match &result {
            Ok(output) => {
                let text = json::py_strip(&stderr(output)).to_string();
                if text.is_empty() {
                    format!("exit={}", output.status.code().unwrap_or(-1))
                } else {
                    text
                }
            }
            Err(failure) => failure.message.clone(),
        };
        return (
            false,
            Some(format!(
                "git worktree remove failed ({git_error}); rmtree fallback failed: {}",
                os_error(&error, workspace)
            )),
        );
    }
    let _ = git(repo, &["worktree", "prune"]);
    if workspace.exists() {
        return (
            false,
            Some(format!(
                "worktree directory still present after rm -rf: {}",
                workspace.display()
            )),
        );
    }
    (true, None)
}

/// `delete_branch(repo_path, branch)`: best effort.
pub fn delete_branch(repo: &str, branch: &str) {
    let _ = git(repo, &["branch", "-D", branch]);
}

/// `_clean_required_text(value, field)`: whitespace runs collapsed.
pub fn clean_required_text(value: Option<&Value>, field: &str) -> Outcome<String> {
    let raw = value
        .filter(|value| value.truthy())
        .map(Value::py_str)
        .unwrap_or_default();
    let words: Vec<&str> = raw
        .split(json::py_is_space)
        .filter(|word| !word.is_empty())
        .collect();
    let text = words.join(" ");
    if text.is_empty() {
        return Err(Failure::value(format!("{field} is required")));
    }
    Ok(text)
}

/// `Path(ticket_id).name != ticket_id or ticket_id in {".", ".."}`.
fn require_canonical_stem(ticket_id: &str) -> Outcome<()> {
    if ticket_id.contains('/') || ticket_id == "." || ticket_id == ".." {
        return Err(Failure::value(
            "ticket_id must be a canonical ticket filename stem",
        ));
    }
    Ok(())
}

/// `_ticket_authoring_pathspecs` for the one ticket a recovery edits.
fn ticket_pathspec(ticket_id: &str) -> String {
    format!(".orchestrator/{ticket_id}.md")
}

/// `_ensure_ticket_authoring_paths_clean(repo, [ticket_path])`.
fn ensure_ticket_authoring_paths_clean(repo: &str, pathspec: &str) -> Outcome<()> {
    let status = git(
        repo,
        &[
            "status",
            "--porcelain",
            "--untracked-files=all",
            "--",
            pathspec,
        ],
    )?;
    if !status.status.success() {
        return Err(Failure::value(format!(
            "could not check ticket-authoring state: {}",
            json::py_strip(&stderr(&status))
        )));
    }
    if !json::py_strip(&stdout(&status)).is_empty() {
        return Err(Failure::value(format!(
            "ticket authoring blocked by existing changes to {pathspec}"
        )));
    }
    Ok(())
}

/// `_commit_ticket_authorship(repo, [ticket_path], [ticket_id], message=...)`.
fn commit_ticket_authorship(repo: &str, pathspec: &str, message: &str) -> Outcome<()> {
    let status = git(repo, &["status", "--porcelain", "--untracked-files=all"])?;
    if !status.status.success() {
        return Err(Failure::value(format!(
            "could not check repository status before ticket commit: {}",
            json::py_strip(&stderr(&status))
        )));
    }
    let staged = git(repo, &["diff", "--cached", "--name-only"])?;
    if !staged.status.success() {
        return Err(Failure::value(format!(
            "could not inspect staged changes before ticket commit: {}",
            json::py_strip(&stderr(&staged))
        )));
    }
    if !json::py_strip(&stdout(&staged)).is_empty() {
        return Err(Failure::value(
            "ticket authoring blocked by already-staged changes",
        ));
    }
    let output_text = |output: &Output| {
        let error = stderr(output);
        let text = if error.is_empty() {
            stdout(output)
        } else {
            error
        };
        json::py_strip(&text).to_string()
    };
    let add = git(repo, &["add", "--", pathspec])?;
    if !add.status.success() {
        return Err(Failure::value(format!(
            "could not stage ticket authorship: {}",
            output_text(&add)
        )));
    }
    let commit = git(repo, &["commit", "-m", message, "--", pathspec])?;
    if !commit.status.success() {
        let _ = git(repo, &["restore", "--staged", "--worktree", "--", pathspec]);
        return Err(Failure::value(format!(
            "ticket authoring commit failed: {}",
            output_text(&commit)
        )));
    }
    Ok(())
}

/// `str(row.get(key) or "")`.
fn field(run: &Dict, key: &str) -> String {
    run.string(key)
}

/// `str(Path(str(row.get("repo_path") or "")).expanduser().resolve())`.
fn resolved_repo(run: Option<&Dict>) -> String {
    let text = run.map(|run| field(run, "repo_path")).unwrap_or_default();
    resolve_path(&text).to_string_lossy().into_owned()
}

/// The ticket's status, `str(ticket.get("status") or "")`.
fn status_of(ticket: &Ticket) -> String {
    ticket.status.clone()
}

/// `{verification_blocked: VerificationBlocked, done: Merged}[status]`.
fn expected_run_state(status: &str) -> Option<&'static str> {
    match status {
        VERIFICATION_BLOCKED_STATUS => Some(VERIFICATION_BLOCKED_RUN_STATE),
        "done" => Some("Merged"),
        _ => None,
    }
}

/// The `last_error` a reconciled verification-blocked run carries.
fn blocker_error(ticket: &Ticket, ticket_id: &str) -> Outcome<Option<String>> {
    if ticket.status != VERIFICATION_BLOCKED_STATUS {
        return Ok(None);
    }
    let blocker = ticket
        .verification_blocker
        .as_deref()
        .map(json::py_strip)
        .unwrap_or_default();
    let resume = ticket
        .verification_resume
        .as_deref()
        .map(json::py_strip)
        .unwrap_or_default();
    if blocker.is_empty() || resume.is_empty() {
        return Err(Failure::value(format!(
            "ticket {ticket_id} lacks verification blocker metadata"
        )));
    }
    Ok(Some(format!(
        "verification blocked: {blocker}; resume: {resume}"
    )))
}

/// A Python pattern with the given inline flags (`m`, `i`).
fn regex(flags: &str, pattern: &str) -> Regex {
    Regex::new(&format!("(?{flags}){pattern}")).expect("a valid preserved-run pattern")
}

/// `\bRun\s+{run_id}\b(?:\*\*)?\s*\(attempt\s+(\d+)\)` (IGNORECASE) for
/// `reconcile_preserved_run`; `None` when the body names the run but no
/// attempt, which reads as attempt 1.
fn reconcile_attempt(body: &str, run_id: i64) -> Option<String> {
    let pattern = regex(
        "i",
        &format!(r"\bRun\s+{run_id}\b(?:\*\*)?\s*\(attempt\s+(\d+)\)"),
    );
    let captures = pattern.captures(body).ok()??;
    captures.get(1).map(|group| group.as_str().to_string())
}

/// `^(?:###\s+Run|-\s+\*\*Run)\s+{run_id}(?:\*\*)?\s+\(attempt\s+(\d+)\)`
/// (IGNORECASE, MULTILINE): a run-log heading or entry with its attempt.
fn run_log_attempt(body: &str, run_id: i64) -> Option<String> {
    let pattern = regex(
        "mi",
        &format!(r"^(?:###\s+Run|-\s+\*\*Run)\s+{run_id}(?:\*\*)?\s+\(attempt\s+(\d+)\)"),
    );
    let captures = pattern.captures(body).ok()??;
    captures.get(1).map(|group| group.as_str().to_string())
}

/// `PRESERVED_RUN_COLLISION_ENTRY_RE.finditer(body)`: (historical run,
/// attempt, replacement run, occupied ticket).
fn collision_entries(body: &str) -> Vec<(String, String, String, String)> {
    let pattern = regex(
        "m",
        r"^- \*\*Preserved run collision recovery\*\* — historical run (\d+) \(attempt (\d+)\); replacement run (\d+); occupied row retained for ([^\s;]+)\.$",
    );
    pattern
        .captures_iter(body)
        .filter_map(Result::ok)
        .map(|captures| {
            let group = |index: usize| {
                captures
                    .get(index)
                    .map(|group| group.as_str().to_string())
                    .unwrap_or_default()
            };
            (group(1), group(2), group(3), group(4))
        })
        .collect()
}

/// `int(text)` for a `\d+` group.
fn digits(text: &str) -> Outcome<i64> {
    parse_int(text)
}

/// `Path(text).name == text`: one path component that is not `.`.
fn path_name_is(text: &str) -> bool {
    !text.is_empty() && !text.contains('/') && text != "."
}

/// The ledger row a preserved-run collision recovery inserts.
struct PreservedRow<'a> {
    state: &'a str,
    /// `f"preserved/{sanitize_identifier(ticket_id)}"`, evaluated lazily.
    branch: &'a Result<String, relay_store::Error>,
    last_error: Option<&'a str>,
}

impl PreservedRow<'_> {
    /// Python's field comparisons in order; the branch slug is computed (and
    /// its `ValueError` raised) only once the earlier fields matched.
    fn matches(&self, row: &Dict, attempt: i64, activity: Option<&str>) -> Outcome<bool> {
        if field(row, "state") != self.state
            || row.get("attempt").and_then(Value::py_int_not_bool) != Some(attempt)
            || activity.is_some_and(|text| !row.get("activity").is_some_and(|v| v.is_str(text)))
            || !row
                .get("workspace_path")
                .is_some_and(|value| value.is_str(""))
        {
            return Ok(false);
        }
        let branch = match self.branch {
            Ok(branch) => branch,
            Err(error) => return Err(Failure::value(error.to_string())),
        };
        let exit_zero = row.get("exit_code").is_some_and(|value| match value {
            Value::Int(code) => *code == 0,
            Value::Float(code) => *code == 0.0,
            _ => false,
        });
        let last_error = self.last_error.map_or(Value::Null, Value::from);
        Ok(row.get("branch").is_some_and(|value| value.is_str(branch))
            && exit_zero
            && json::py_eq(row.get("last_error").unwrap_or(&Value::Null), &last_error))
    }
}

impl Daemon {
    fn run_or_unknown(&self, run_id: i64) -> Outcome<Dict> {
        self.runs.get(run_id)?.ok_or_else(|| unknown_run(run_id))
    }

    fn lifecycle_for(
        &self,
        run: &Dict,
    ) -> Outcome<Option<std::sync::Arc<ArtifactLifecycleCoordinator>>> {
        self.artifact_lifecycle(&field(run, "repo_path"))
    }

    // -- list and get --------------------------------------------------------

    /// `GET /v1/runs?state=&limit=100`.
    pub fn list_runs_route(&self, request: &Request) -> Outcome<Reply> {
        let state = request.query_first("state");
        let limit = request.query_int("limit", 100)?;
        let runs = self.runs.list(state.as_deref(), limit)?;
        reply(
            200,
            single(
                "runs",
                Value::List(runs.into_iter().map(Value::Dict).collect()),
            ),
        )
    }

    /// `GET /v1/runs/{run_id}`: 404 `{"run": null}` when unknown.
    pub fn get_run_route(&self, request: &Request) -> Outcome<Reply> {
        let run_id = run_id_segment(request, 2)?;
        match self.runs.get(run_id)? {
            Some(run) => reply(200, single("run", run)),
            None => reply(404, single("run", Value::Null)),
        }
    }

    // -- worker outcome --------------------------------------------------------

    /// `POST /v1/runs/{run_id}/outcome` (`submit_worker_outcome`).
    pub fn submit_worker_outcome_route(&self, request: &Request) -> Outcome<Reply> {
        let run_id = run_id_segment(request, 2)?;
        let run = self.run_or_unknown(run_id)?;
        let state = field(&run, "state");
        if state != "Claimed" && state != "Running" {
            return Err(Failure::value(format!(
                "run {run_id} is not accepting a worker outcome"
            )));
        }
        let lifecycle = self.lifecycle_for(&run)?.ok_or_else(|| {
            Failure::value(format!("run {run_id} uses the legacy ticket lifecycle"))
        })?;
        let workspace = run
            .truthy("workspace_path")
            .map(|value| PathBuf::from(value.py_str()));
        let outcome = lifecycle
            .submit_outcome(
                run_id,
                &run.get("ticket_id").map(Value::py_str).unwrap_or_default(),
                &field(&run, "provider_key"),
                &request.body,
                workspace.as_deref(),
            )
            .map_err(validation_as_value)?;
        let mut body = Dict::new();
        body.insert("accepted", true);
        body.insert("outcome", outcome.to_json());
        reply(202, body)
    }

    /// `GET /v1/runs/{run_id}/outcome` (`get_worker_outcome`).
    pub fn get_worker_outcome_route(&self, request: &Request) -> Outcome<Reply> {
        let run_id = run_id_segment(request, 2)?;
        let run = self.run_or_unknown(run_id)?;
        let lifecycle = self.lifecycle_for(&run)?.ok_or_else(|| {
            Failure::value(format!("run {run_id} uses the legacy ticket lifecycle"))
        })?;
        let outcome = lifecycle.outcome(run_id).map_err(validation_as_value)?;
        let mut body = Dict::new();
        body.insert("run_id", run_id);
        body.insert("state", run.get("state").cloned().unwrap_or(Value::Null));
        body.insert("recorded", outcome.is_some());
        body.insert(
            "outcome",
            outcome.map_or(Value::Null, |outcome| Value::Dict(outcome.to_json())),
        );
        reply(200, body)
    }

    // -- review --------------------------------------------------------------

    /// `GET /v1/runs/{run_id}/review` (`inspect_run_for_review`).
    pub fn inspect_run_for_review_route(&self, request: &Request) -> Outcome<Reply> {
        let run_id = run_id_segment(request, 2)?;
        let run = self.run_or_unknown(run_id)?;
        let repo_path = field(&run, "repo_path");
        let workspace_text = field(&run, "workspace_path");
        let branch = field(&run, "branch");
        let ticket_id = field(&run, "ticket_id");
        let mut ticket_log = String::new();
        let mut ticket_status: Option<String> = None;
        let ticket_file = format!("{ticket_id}.md");
        if !workspace_text.is_empty() {
            match read_ticket(
                &Path::new(&workspace_text)
                    .join(".orchestrator")
                    .join(&ticket_file),
            ) {
                Ok(ticket) => {
                    ticket_status = Some(status_of(&ticket));
                    ticket_log = ticket_run_log(&ticket.body);
                }
                Err(TicketRead::Caught(_)) => ticket_log.clear(),
                Err(TicketRead::Other(failure)) => return Err(failure),
            }
        }
        if ticket_status.is_none() && !repo_path.is_empty() {
            match read_ticket(
                &Path::new(&repo_path)
                    .join(".orchestrator")
                    .join(&ticket_file),
            ) {
                Ok(ticket) => {
                    ticket_status = Some(status_of(&ticket));
                    ticket_log = ticket_run_log(&ticket.body);
                }
                Err(TicketRead::Caught(_)) => {}
                Err(TicketRead::Other(failure)) => return Err(failure),
            }
        }
        if !repo_path.is_empty()
            && let Some(lifecycle) = self.artifact_lifecycle(&repo_path)?
            && let Some(outcome) = lifecycle.outcome(run_id)?
        {
            ticket_status = Some(if outcome.status.value() == VERIFICATION_BLOCKED_STATUS {
                VERIFICATION_BLOCKED_STATUS.to_string()
            } else {
                "done".to_string()
            });
            let mut verification = outcome.verification.join("; ");
            if verification.is_empty() {
                verification = "(none)".to_string();
            }
            ticket_log = format!(
                "Structured outcome: {}\nVerification: {verification}\nSource commit: {}",
                outcome.summary, outcome.source_commit
            );
        }
        let state = field(&run, "state");
        let review_blocking = REVIEW_BLOCKING_STATES.contains(&state.as_str());
        let log_tail = if run.truthy("log_path").is_some() {
            tail_text(Path::new(&field(&run, "log_path")))
        } else {
            String::new()
        };
        let branch_git = |args: &[&str]| {
            if !repo_path.is_empty() && !branch.is_empty() {
                git_text(&repo_path, args)
            } else {
                String::new()
            }
        };
        let commits = branch_git(&["log", "--oneline", &format!("HEAD..{branch}")]);
        let diff_stat = branch_git(&["diff", "--stat", &format!("HEAD...{branch}")]);
        let name_status = branch_git(&["diff", "--name-status", &format!("HEAD...{branch}")]);
        let last_error = run.get("last_error").cloned().unwrap_or(Value::Null);
        let evidence = if ticket_status.as_deref() == Some(VERIFICATION_BLOCKED_STATUS) {
            last_error
        } else if review_blocking {
            Value::from("worker completion validation passed")
        } else {
            last_error
        };
        let mut body = Dict::new();
        body.insert("run", run);
        body.insert("review_needed", review_blocking);
        body.insert("ticket_status", ticket_status);
        body.insert("log_tail", log_tail);
        body.insert("ticket_run_log", ticket_log);
        body.insert("branch_commits", commits);
        body.insert("branch_diff_stat", diff_stat);
        body.insert("branch_diff_name_status", name_status);
        body.insert("verification_evidence", evidence);
        reply(200, body)
    }

    /// `POST /v1/runs/{run_id}/review` (`dispatch_review_worker`).
    pub fn dispatch_review_worker_route(&self, request: &Request) -> Outcome<Reply> {
        let run_id = run_id_segment(request, 2)?;
        let run = self.run_or_unknown(run_id)?;
        if !REVIEW_BLOCKING_STATES.contains(&field(&run, "state").as_str()) {
            return Err(Failure::value(format!(
                "run {run_id} is not awaiting review"
            )));
        }
        self.effective_worker_agent()?;
        Err(Failure::execution_deferred("review worker dispatch"))
    }

    /// `POST /v1/runs/{run_id}/review/decision`: accept (200) or retry (202).
    pub fn review_decision_route(&self, request: &Request) -> Outcome<Reply> {
        let decision = request
            .get("decision")
            .filter(|value| value.truthy())
            .map(Value::py_str)
            .unwrap_or_default();
        match json::py_strip(&decision).to_lowercase().as_str() {
            "accept" => self.accept_worker_run(run_id_segment(request, 2)?),
            "retry" => self.request_worker_retry(run_id_segment(request, 2)?),
            _ => Err(Failure::value("decision must be 'accept' or 'retry'")),
        }
    }

    /// `accept_worker_run`: its checks before the merge.
    fn accept_worker_run(&self, run_id: i64) -> Outcome<Reply> {
        let _merge = guard(&self.merge_lock);
        let run = self.run_or_unknown(run_id)?;
        if !MERGEABLE_REVIEW_STATES.contains(&field(&run, "state").as_str()) {
            return Err(Failure::value(format!(
                "run {run_id} is not awaiting review"
            )));
        }
        let ticket_id = run.get("ticket_id").map(Value::py_str).unwrap_or_default();
        if let Some(lifecycle) = self.lifecycle_for(&run)? {
            if lifecycle.outcome(run_id)?.is_none() {
                return Err(Failure::value(format!(
                    "run {run_id} has no structured artifact outcome"
                )));
            }
        } else {
            let workspace = run
                .get("workspace_path")
                .map(Value::py_str)
                .unwrap_or_default();
            let path = Path::new(&workspace)
                .join(".orchestrator")
                .join(format!("{ticket_id}.md"));
            let ticket = read_ticket(&path).map_err(|failure| match failure {
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
        }
        Err(Failure::execution_deferred("review acceptance and merge"))
    }

    /// `request_worker_retry`: its checks before it publishes the retry.
    fn request_worker_retry(&self, run_id: i64) -> Outcome<Reply> {
        let run = self.run_or_unknown(run_id)?;
        if !REVIEW_BLOCKING_STATES.contains(&field(&run, "state").as_str()) {
            return Err(Failure::value(format!(
                "run {run_id} is not awaiting review"
            )));
        }
        Err(Failure::execution_deferred("review retry"))
    }

    /// `POST /v1/runs/{run_id}/resume-verification`: its checks before it
    /// publishes the resume.
    pub fn resume_verification_blocked_route(&self, request: &Request) -> Outcome<Reply> {
        let run_id = run_id_segment(request, 2)?;
        let run = self.run_or_unknown(run_id)?;
        if field(&run, "state") != VERIFICATION_BLOCKED_RUN_STATE {
            return Err(Failure::value(format!(
                "run {run_id} is not verification blocked"
            )));
        }
        clean_required_text(request.get("reason"), "reason")?;
        let repo = resolve_path(&field(&run, "repo_path"));
        let repo_text = repo.to_string_lossy().into_owned();
        if self.artifact_lifecycle(&repo_text)?.is_none() {
            let ticket_id = run.get("ticket_id").map(Value::py_str).unwrap_or_default();
            let pathspec = ticket_pathspec(&ticket_id);
            let _authoring = guard(&self.authoring_lock);
            ensure_ticket_authoring_paths_clean(&repo_text, &pathspec)?;
            let ticket = read_ticket_or_fail(&repo.join(&pathspec))?;
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
        }
        Err(Failure::execution_deferred("verification resume"))
    }

    // -- cancel ----------------------------------------------------------------

    /// `POST /v1/runs/{run_id}/cancel` (`cancel_run`). The Rust daemon has no
    /// live workers yet, so this is Python's "no live worker" path.
    pub fn cancel_run_route(&self, request: &Request) -> Outcome<Reply> {
        let run_id = run_id_segment(request, 2)?;
        let prune = request.truthy_or("prune_worktree", true);
        let run = self.run_or_unknown(run_id)?;
        let state = field(&run, "state");
        if !ACTIVE_STATES.contains(&state.as_str()) && state != "Stalled" {
            let mut body = Dict::new();
            body.insert("canceled", false);
            body.insert("reason", format!("run is in terminal state {state}"));
            body.insert("run", run);
            return reply(200, body);
        }
        if field(&run, "execution_mode") == SPIKE_EXECUTION_MODE {
            return Err(Failure::execution_deferred("spike cancellation"));
        }
        self.runs.update(
            run_id,
            &RunUpdate {
                state: Some("Canceled".to_string()),
                last_error: Some(Some("Canceled (no live worker)".to_string())),
                ended: true,
                ..RunUpdate::default()
            },
        )?;
        let repo_path = field(&run, "repo_path");
        let workspace = PathBuf::from(
            run.get("workspace_path")
                .map(Value::py_str)
                .unwrap_or_default(),
        );
        if let Some(lifecycle) = self.artifact_lifecycle(&repo_path)? {
            let current = self.runs.get(run_id)?.unwrap_or_else(|| run.clone());
            let reason = current
                .truthy("last_error")
                .map(Value::py_str)
                .unwrap_or_else(|| "Canceled by user.".to_string());
            lifecycle
                .record_failure(
                    run_id,
                    &field(&run, "ticket_id"),
                    &field(&run, "provider_key"),
                    &reason,
                    FailureKind {
                        canceled: true,
                        retry: false,
                    },
                )
                .map_err(|error| {
                    Failure::value(format!(
                        "run {run_id} stopped, but canonical cancellation could not be published: {error}"
                    ))
                })?;
            if prune {
                ArtifactLifecycleCoordinator::cleanup_snapshot(&workspace);
            }
        }
        let mut body = Dict::new();
        body.insert("canceled", true);
        body.insert("run", self.runs.get(run_id)?);
        if prune && !repo_path.is_empty() {
            let (removed, error) = remove_worktree(&repo_path, &workspace);
            body.insert("worktree_removed", removed);
            if let Some(error) = error {
                body.insert("worktree_error", error);
            }
            delete_branch(
                &repo_path,
                &run.get("branch").map(Value::py_str).unwrap_or_default(),
            );
        }
        self.record_queue_drain_after_event(
            run.get("repo_path").and_then(Value::as_str),
            "run-canceled",
            false,
        );
        reply(200, body)
    }

    // -- preserved runs ----------------------------------------------------------

    /// `POST /v1/runs/reconcile-preserved` (`reconcile_preserved_run`).
    pub fn reconcile_preserved_run_route(&self, request: &Request) -> Outcome<Reply> {
        let repo = repo_argument(request)?;
        let repo_text = repo.to_string_lossy().into_owned();
        let ticket_id = clean_required_text(request.get("ticket_id"), "ticket_id")?;
        require_canonical_stem(&ticket_id)?;
        let pathspec = ticket_pathspec(&ticket_id);
        let ticket_path = repo.join(&pathspec);
        let (run_id, reconciled) = {
            let _authoring = guard(&self.authoring_lock);
            ensure_ticket_authoring_paths_clean(&repo_text, &pathspec)?;
            let tracked = git(&repo_text, &["cat-file", "-e", &format!("HEAD:{pathspec}")])?;
            if !tracked.status.success() {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} is not committed at repository HEAD"
                )));
            }
            let ticket = read_ticket_or_fail(&ticket_path)?;
            if ticket.id != ticket_id {
                return Err(Failure::value(format!(
                    "ticket file id is {}, expected {}",
                    pystr::repr(&ticket.id),
                    pystr::repr(&ticket_id)
                )));
            }
            let status = status_of(&ticket);
            let Some(expected_state) = expected_run_state(&status) else {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} is {}; only committed done or verification_blocked \
                     tickets can restore preserved runs",
                    pystr::repr(&status)
                )));
            };
            let run_id = match ticket.run_id {
                Some(run_id) if run_id > 0 => run_id,
                _ => {
                    return Err(Failure::value(format!(
                        "ticket {ticket_id} does not declare a positive run_id"
                    )));
                }
            };
            let body = &ticket.body;
            let evidence = regex("i", &format!(r"\bRun\s+{run_id}\b"));
            if !body.contains("## Run log") || !evidence.is_match(body).unwrap_or(false) {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} lacks preserved run {run_id} evidence"
                )));
            }
            let attempt = match reconcile_attempt(body, run_id) {
                Some(text) => digits(&text)?,
                None => 1,
            };
            if attempt <= 0 {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} declares an invalid attempt for run {run_id}"
                )));
            }
            if let Some(existing) = self.runs.get(run_id)? {
                if field(&existing, "ticket_id") != ticket_id
                    || resolved_repo(Some(&existing)) != repo_text
                    || field(&existing, "state") != expected_state
                {
                    return Err(Failure::value(format!(
                        "run {run_id} already exists with a different ticket, repo, or state"
                    )));
                }
                let mut body = Dict::new();
                body.insert("reconciled", false);
                body.insert("run", existing);
                body.insert("source", "existing-ledger");
                return reply(200, body);
            }
            let last_error = blocker_error(&ticket, &ticket_id)?;
            let reconciled = self.runs.insert_reconciled(
                run_id,
                &ticket_id,
                &repo_text,
                expected_state,
                attempt,
                last_error.as_deref(),
            )?;
            (run_id, reconciled)
        };
        let message = format!("{ticket_id} preserved run {run_id} was restored");
        let provider = reconciled.get("provider_key").and_then(Value::as_str);
        self.emit_lifecycle(&LifecycleEvent {
            kind: "run-reconciled",
            ticket_id: Some(&ticket_id),
            run_id: Some(run_id),
            source: Some("orchestrator"),
            message: Some(&message),
            repo_path: Some(&repo_text),
            provider_key: provider,
            queue_messenger: None,
        });
        let mut body = Dict::new();
        body.insert("reconciled", true);
        body.insert("run", reconciled);
        body.insert("source", "canonical-ticket");
        reply(200, body)
    }

    /// `POST /v1/runs/recover-preserved-collision`
    /// (`recover_preserved_run_collision`).
    pub fn recover_preserved_run_collision_route(&self, request: &Request) -> Outcome<Reply> {
        let repo = repo_argument(request)?;
        let repo_text = repo.to_string_lossy().into_owned();
        let ticket_id = clean_required_text(request.get("ticket_id"), "ticket_id")?;
        require_canonical_stem(&ticket_id)?;
        let pathspec = ticket_pathspec(&ticket_id);
        let ticket_path = repo.join(&pathspec);
        let preserved_branch =
            sanitize_identifier(&ticket_id).map(|slug| format!("preserved/{slug}"));
        let _authoring = guard(&self.authoring_lock);
        ensure_ticket_authoring_paths_clean(&repo_text, &pathspec)?;
        let tracked = git(&repo_text, &["cat-file", "-e", &format!("HEAD:{pathspec}")])?;
        if !tracked.status.success() {
            return Err(Failure::value(format!(
                "ticket {ticket_id} is not committed at repository HEAD"
            )));
        }
        let staged = git(&repo_text, &["diff", "--cached", "--name-only"])?;
        if !staged.status.success() {
            return Err(Failure::value(format!(
                "could not inspect staged changes before collision recovery: {}",
                json::py_strip(&stderr(&staged))
            )));
        }
        if !json::py_strip(&stdout(&staged)).is_empty() {
            return Err(Failure::value(
                "preserved-run collision recovery blocked by already-staged changes",
            ));
        }
        let mut ticket = read_ticket_or_fail(&ticket_path)?;
        if ticket.id != ticket_id {
            return Err(Failure::value(format!(
                "ticket file id is {}, expected {}",
                pystr::repr(&ticket.id),
                pystr::repr(&ticket_id)
            )));
        }
        let status = status_of(&ticket);
        let Some(expected_state) = expected_run_state(&status) else {
            return Err(Failure::value(format!(
                "ticket {ticket_id} is {}; only committed done or verification_blocked \
                 tickets can recover preserved-run collisions",
                pystr::repr(&status)
            )));
        };
        let last_error = blocker_error(&ticket, &ticket_id)?;
        let current_run_id = match ticket.run_id {
            Some(run_id) if run_id > 0 => run_id,
            _ => {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} does not declare a positive run_id"
                )));
            }
        };
        let body = ticket.body.clone();
        let entries = collision_entries(&body);
        if entries.len() > 1 {
            return Err(Failure::value(format!(
                "ticket {ticket_id} has ambiguous preserved-run collision evidence"
            )));
        }
        let expected = PreservedRow {
            state: expected_state,
            branch: &preserved_branch,
            last_error: last_error.as_deref(),
        };
        if let Some((historical, attempt, replacement, occupied_ticket)) = entries.first() {
            let historical_run_id = digits(historical)?;
            let preserved_attempt = digits(attempt)?;
            let replacement_run_id = digits(replacement)?;
            let historical_evidence = run_log_attempt(&body, historical_run_id);
            let replacement_row = self.runs.get(replacement_run_id)?;
            let occupied = self.runs.get(historical_run_id)?;
            let expected_activity =
                format!("Reconciled replacement for occupied run {historical_run_id}");
            // In Python's condition order: the branch slug is only computed
            // (and can only fail) once every earlier condition held.
            let consistent = 'check: {
                if current_run_id != replacement_run_id
                    || historical_evidence
                        .as_deref()
                        .and_then(|text| parse_int(text).ok())
                        != Some(preserved_attempt)
                {
                    break 'check false;
                }
                let Some(row) = &replacement_row else {
                    break 'check false;
                };
                if field(row, "ticket_id") != ticket_id
                    || resolved_repo(Some(row)) != repo_text
                    || !expected.matches(row, preserved_attempt, Some(&expected_activity))?
                {
                    break 'check false;
                }
                occupied.as_ref().is_some_and(|row| {
                    row.get("ticket_id")
                        .is_some_and(|value| value.is_str(occupied_ticket))
                }) && *occupied_ticket != ticket_id
                    && path_name_is(occupied_ticket)
                    && resolved_repo(occupied.as_ref()) == repo_text
            };
            if !consistent {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} has inconsistent preserved-run collision evidence"
                )));
            }
            let mut answer = Dict::new();
            answer.insert("recovered", false);
            answer.insert("historical_run_id", historical_run_id);
            answer.insert("replacement_run_id", replacement_run_id);
            answer.insert("run", replacement_row);
            answer.insert("source", "existing-collision-recovery");
            return reply(200, answer);
        }

        let historical_run_id = current_run_id;
        if !body.contains("## Run log") {
            return Err(Failure::value(format!(
                "ticket {ticket_id} lacks preserved run {historical_run_id} evidence"
            )));
        }
        let Some(attempt_text) = run_log_attempt(&body, historical_run_id) else {
            return Err(Failure::value(format!(
                "ticket {ticket_id} lacks preserved run {historical_run_id} attempt evidence"
            )));
        };
        let preserved_attempt = digits(&attempt_text)?;
        if preserved_attempt <= 0 {
            return Err(Failure::value(format!(
                "ticket {ticket_id} declares an invalid attempt for run {historical_run_id}"
            )));
        }
        let Some(occupied) = self.runs.get(historical_run_id)? else {
            return Err(Failure::value(format!(
                "run {historical_run_id} is missing; use reconcile_preserved_run instead"
            )));
        };
        if resolved_repo(Some(&occupied)) != repo_text {
            return Err(Failure::value(format!(
                "run {historical_run_id} belongs to a different repository"
            )));
        }
        let occupied_ticket_id = field(&occupied, "ticket_id");
        let occupied_ticket_id = json::py_strip(&occupied_ticket_id).to_string();
        if occupied_ticket_id.is_empty()
            || occupied_ticket_id == ticket_id
            || !path_name_is(&occupied_ticket_id)
            || occupied_ticket_id
                .chars()
                .any(|character| json::py_is_space(character) || character == ';')
        {
            return Err(Failure::value(format!(
                "run {historical_run_id} does not represent a different-ticket collision"
            )));
        }
        let pending =
            self.runs
                .reconciled_replacements(historical_run_id, &ticket_id, &repo_text)?;
        if pending.len() > 1 {
            return Err(Failure::value(format!(
                "ticket {ticket_id} has ambiguous pending collision recoveries"
            )));
        }
        let replacement = match pending.into_iter().next() {
            Some(replacement) => {
                if !expected.matches(&replacement, preserved_attempt, None)? {
                    return Err(Failure::value(format!(
                        "ticket {ticket_id} has an inconsistent pending collision recovery"
                    )));
                }
                replacement
            }
            None => self.runs.insert_reconciled_replacement(
                historical_run_id,
                &ticket_id,
                &repo_text,
                expected_state,
                preserved_attempt,
                last_error.as_deref(),
            )?,
        };
        let replacement_run_id = replacement
            .get("id")
            .and_then(Value::py_int)
            .ok_or_else(|| Failure::escape("replacement run has no id"))?;
        ticket.run_id = Some(replacement_run_id);
        ticket.body = format!(
            "{}\n\n- **Preserved run collision recovery** — historical run {historical_run_id} \
             (attempt {preserved_attempt}); replacement run {replacement_run_id}; occupied row \
             retained for {occupied_ticket_id}.\n",
            body.trim_end_matches(json::py_is_space)
        );
        tickets::write(&ticket_path, &ticket)?;
        commit_ticket_authorship(
            &repo_text,
            &pathspec,
            &format!("chore: recover {ticket_id} preserved run collision"),
        )?;
        let recovery_commit = git_head(&repo_text);
        drop(_authoring);
        let message = format!(
            "{ticket_id} historical run {historical_run_id} was relinked to run {replacement_run_id}"
        );
        let provider = replacement.get("provider_key").and_then(Value::as_str);
        self.emit_lifecycle(&LifecycleEvent {
            kind: "run-reconciled",
            ticket_id: Some(&ticket_id),
            run_id: Some(replacement_run_id),
            source: Some("orchestrator"),
            message: Some(&message),
            repo_path: Some(&repo_text),
            provider_key: provider,
            queue_messenger: None,
        });
        let mut answer = Dict::new();
        answer.insert("recovered", true);
        answer.insert("historical_run_id", historical_run_id);
        answer.insert("replacement_run_id", replacement_run_id);
        answer.insert("recovery_commit", recovery_commit);
        answer.insert("run", replacement);
        answer.insert("source", "canonical-ticket-collision");
        reply(200, answer)
    }
}

/// `except ArtifactValidationError as error: raise ValueError(str(error))`.
fn validation_as_value(error: relay_artifacts::Error) -> Failure {
    if error.kind.is_validation() {
        Failure::new(Class::Value, error.message)
    } else {
        error.into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn required_text_collapses_whitespace() {
        assert_eq!(
            clean_required_text(Some(&Value::from("  a \n\t b ")), "reason").unwrap(),
            "a b"
        );
        assert_eq!(
            clean_required_text(None, "ticket_id").unwrap_err().message,
            "ticket_id is required"
        );
        assert_eq!(
            clean_required_text(Some(&Value::from(" \n ")), "reason")
                .unwrap_err()
                .message,
            "reason is required"
        );
    }

    #[test]
    fn canonical_stems_have_no_directory() {
        assert!(require_canonical_stem("CT-1").is_ok());
        for bad in ["a/b", ".", "..", "CT-1/"] {
            assert_eq!(
                require_canonical_stem(bad).unwrap_err().message,
                "ticket_id must be a canonical ticket filename stem"
            );
        }
    }

    #[test]
    fn reconcile_reads_the_attempt_after_the_run_number() {
        let body = "## Run log\n\n- **Run 77** (attempt 3) - branch `relay/ct-21`\n";
        assert_eq!(reconcile_attempt(body, 77).as_deref(), Some("3"));
        assert_eq!(reconcile_attempt(body, 7), None);
        assert_eq!(
            reconcile_attempt("run 77 (ATTEMPT 2)", 77).as_deref(),
            Some("2")
        );
        assert_eq!(run_log_attempt(body, 77).as_deref(), Some("3"));
        assert_eq!(
            run_log_attempt("### Run 5 (attempt 2)\n", 5).as_deref(),
            Some("2")
        );
        assert_eq!(run_log_attempt("text - **Run 5** (attempt 2)", 5), None);
    }

    #[test]
    fn collision_entries_parse_the_recovery_line() {
        let body = "## Run log\n\n- **Run 4** (attempt 1)\n\n- **Preserved run collision \
                    recovery** — historical run 4 (attempt 1); replacement run 9; occupied \
                    row retained for CT-2.\n";
        assert_eq!(
            collision_entries(body),
            vec![(
                "4".to_string(),
                "1".to_string(),
                "9".to_string(),
                "CT-2".to_string()
            )]
        );
        assert!(collision_entries("- **Preserved run collision recovery** — x").is_empty());
    }

    #[test]
    fn run_log_starts_at_its_heading() {
        assert_eq!(
            ticket_run_log("a\n## Run log\n\n- x\n"),
            "## Run log\n\n- x"
        );
        assert_eq!(ticket_run_log("no log"), "");
    }

    #[test]
    fn tail_reports_an_unreadable_log() {
        let text = tail_text(Path::new("/nonexistent/relay/run.log"));
        assert_eq!(
            text,
            "unavailable: [Errno 2] No such file or directory: '/nonexistent/relay/run.log'"
        );
    }

    #[test]
    fn verification_blocker_needs_both_fields() {
        let mut ticket = tickets::parse(
            "---\nid: CT-1\ntitle: \"x\"\nstatus: done\npriority: low\n\
             depends_on: []\nrun_id: 3\ncanceled: false\n---\nbody\n",
        )
        .unwrap();
        ticket.status = VERIFICATION_BLOCKED_STATUS.into();
        ticket.verification_blocker = Some(" needs device ".into());
        assert_eq!(
            blocker_error(&ticket, "CT-1").unwrap_err().message,
            "ticket CT-1 lacks verification blocker metadata"
        );
        ticket.verification_resume = Some("device attached".into());
        assert_eq!(
            blocker_error(&ticket, "CT-1").unwrap(),
            Some("verification blocked: needs device; resume: device attached".into())
        );
        ticket.status = "done".into();
        assert_eq!(blocker_error(&ticket, "CT-1").unwrap(), None);
    }
}
