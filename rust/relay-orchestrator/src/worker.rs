//! The worker and review-worker processes (RR-498): the Claude and Codex
//! launch lines, one provider process per run on its own thread, its log,
//! its stream-json activity, and the exit that decides the run's next
//! state (`services/orchestrator.py`, `_agent_command`, `Worker` and
//! `ReviewWorker`).
//!
//! Claude and Codex share every step but the launch line and the event
//! shapes: Claude prints `assistant`/`user` tool events and a `result`,
//! Codex prints `item.started`/`item.completed` items and an
//! `agent_message`.

use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::OsString;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Condvar, LazyLock, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use relay_artifacts::lifecycle::ArtifactLifecycleCoordinator;
use relay_artifacts::pystr;
use relay_intents::json::{self, Dict, Value, py_strip};
use relay_intents::pattern::{self, Regex};
use relay_services::providers::{catalog, subscription};
use relay_store::runs::{RunUpdate, SPIKE_EXECUTION_MODE};

use crate::activity::{
    ACTIVITY_DEBOUNCE_SECONDS, ACTIVITY_HEARTBEAT_SECONDS, NOOP_TOOLS, derive_activity,
    derive_codex_activity,
};
use crate::daemon::{Daemon, guard};
use crate::dispatch::{resolve_worker_model, validate_worker_effort};
use crate::failure::{Failure, Outcome};
use crate::queue::{VERIFICATION_BLOCKED_STATUS, now};
use crate::trace::LifecycleEvent;

/// How long a canceled provider has to exit before it is killed.
const TERMINATE_GRACE: Duration = Duration::from_secs(5);
/// The tools a Claude spike may call; `StructuredOutput` is how
/// `--json-schema` returns the terminal result and has no side effect.
const SPIKE_TOOLS: [&str; 6] = [
    "Read",
    "Glob",
    "Grep",
    "WebSearch",
    "WebFetch",
    "StructuredOutput",
];
const CLAUDE_SPIKE_TOOLS: &str = "Read,Glob,Grep,WebSearch,WebFetch";
/// The run states a review worker's exit leaves alone: the decision it
/// posted already moved the run on.
const REVIEW_DECIDED_STATES: [&str; 5] = [
    "Merged",
    "MergeConflict",
    relay_store::runs::INTEGRATION_BLOCKED_RUN_STATE,
    relay_store::runs::VERIFICATION_BLOCKED_RUN_STATE,
    "Failed",
];

static NULL_REDIRECT: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"(?<!\S)(?:2?>>?)[ \t]*/dev/null(?=$|[\s;&|])", false));
static MUTATING_COMMAND: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r"(?:^|[;&|]\s*)(?:rm|mv|cp|touch|mkdir|install|curl|wget|open|osascript|chmod|chown|ln|tee)\b|(?:^|\s)(?:>|>>|2>|2>>)\s*|\bgit\s+(?:add|apply|branch|checkout|clean|commit|merge|push|rebase|reset|restore|switch|tag|worktree)\b",
        false,
    )
});
static BLOCKED_COMMAND: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        r"operation not permitted|permission denied|read-only|sandbox|could not resolve host|network is unreachable|network access.*denied",
        true,
    )
});
static NETWORK_FAILURE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"network|connection|dns|timed? out|unavailable", true));

// -- small process helpers -------------------------------------------------------

/// `str(OSError)` for a failure on `path`.
pub(crate) fn os_error_text(error: &std::io::Error, path: &Path) -> String {
    crate::runs::os_error(error, path)
}

/// `subprocess.run(..., capture_output=True, timeout=)`: the output, or
/// `None` when the child outlived the timeout (it is killed).
pub(crate) fn wait_with_timeout(mut child: Child, timeout: Duration) -> Option<Output> {
    let reader = |stream: Option<Box<dyn Read + Send>>| {
        thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut stream) = stream {
                let _ = stream.read_to_end(&mut bytes);
            }
            bytes
        })
    };
    let stdout = reader(
        child
            .stdout
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    );
    let stderr = reader(
        child
            .stderr
            .take()
            .map(|s| Box::new(s) as Box<dyn Read + Send>),
    );
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    Some(Output {
        status,
        stdout: stdout.join().unwrap_or_default(),
        stderr: stderr.join().unwrap_or_default(),
    })
}

/// `proc.returncode`: the exit status, or minus the signal that ended it.
fn return_code(status: ExitStatus) -> i64 {
    match (status.code(), status.signal()) {
        (Some(code), _) => i64::from(code),
        (None, Some(signal)) => -i64::from(signal),
        (None, None) => -1,
    }
}

/// `text[:limit]` in characters.
fn prefix(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

// -- launch lines --------------------------------------------------------------

/// What a spike adds to its launch: Codex's output schema file and the
/// verified read-only Git environment.
#[derive(Clone, Debug, Default)]
pub struct SpikeLaunch {
    pub result_schema_path: String,
    pub git_environment: Option<Vec<(String, String)>>,
}

/// A launch line, and the Codex model it resolved to.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LaunchLine {
    pub command: Vec<String>,
    pub selected_model_family: Option<String>,
    pub resolved_model_alias: Option<String>,
    pub resolved_worker_effort: Option<String>,
}

/// `_agent_command(agent_kind=, agent_bin=, run=)`: the provider command for
/// an implementation, review, spike or General run. Claude and Codex lines
/// change together; `resolve` looks a Codex family up in the CLI's catalogue.
pub fn launch_line(
    kind: &str,
    binary: &str,
    model_alias: &str,
    worker_effort: &str,
    spike: Option<&SpikeLaunch>,
    resolve: impl Fn(&str, &str) -> Result<catalog::CodexModel, String>,
) -> Outcome<LaunchLine> {
    let mut model = py_strip(model_alias).to_lowercase();
    let mut effort = py_strip(worker_effort).to_lowercase();
    let mut line = LaunchLine {
        command: vec![binary.to_string()],
        ..LaunchLine::default()
    };
    let push = |command: &mut Vec<String>, args: &[&str]| {
        command.extend(args.iter().map(|arg| arg.to_string()));
    };
    if kind == "claude" {
        if model == "default" {
            model.clear();
        }
        if effort == "default" {
            effort.clear();
        }
        // Claude stream-json gives assistant/tool_use/tool_result events.
        // Implementation and review workers share one shape so the
        // provider-facing effort semantics stay aligned.
        if spike.is_some() {
            let schema = json::dumps_compact(&crate::spike::SPIKE_RESULT_SCHEMA);
            push(
                &mut line.command,
                &[
                    "-p",
                    "--safe-mode",
                    "--no-chrome",
                    "--no-session-persistence",
                    "--permission-mode",
                    "dontAsk",
                    "--tools",
                    CLAUDE_SPIKE_TOOLS,
                    // dontAsk denies anything not pre-approved, including web research.
                    "--allowedTools",
                    CLAUDE_SPIKE_TOOLS,
                    "--strict-mcp-config",
                    "--mcp-config",
                    "{\"mcpServers\":{}}",
                    "--json-schema",
                    &schema,
                    "--verbose",
                    "--output-format",
                    "stream-json",
                ],
            );
        } else {
            push(
                &mut line.command,
                &[
                    "-p",
                    "--dangerously-skip-permissions",
                    "--verbose",
                    "--output-format",
                    "stream-json",
                ],
            );
        }
        if !model.is_empty() {
            push(&mut line.command, &["--model", &model]);
        }
        if !effort.is_empty() {
            push(&mut line.command, &["--effort", &effort]);
        }
        return Ok(line);
    }
    if !model.is_empty() {
        let family = catalog::normalize_codex_family(&model, catalog::CODEX_DEFAULT_FAMILY);
        let unresolved = |model: &str, error: String| {
            Failure::runtime(format!(
                "could not resolve Codex worker model {}: {error}",
                json::str_repr(model)
            ))
        };
        let resolved = resolve(&family, binary).map_err(|error| unresolved(&model, error))?;
        model = resolved.launch_model().to_string();
        line.selected_model_family = Some(family);
        line.resolved_model_alias = Some(model.clone());
        if !effort.is_empty() {
            effort = catalog::resolve_effort(&effort, &resolved)
                .map_err(|error| unresolved(&model, error))?;
            line.resolved_worker_effort = Some(effort.clone());
        }
    }
    if effort == "default" {
        effort.clear();
    }
    // Codex exec --json emits JSONL events such as thread.started,
    // item.started command_execution, item.completed, and turn.completed.
    if let Some(spike) = spike {
        if py_strip(&spike.result_schema_path).is_empty() {
            return Err(Failure::runtime(
                "spike run is missing its structured result schema",
            ));
        }
        let Some(environment) = spike.git_environment.as_ref().filter(|env| !env.is_empty()) else {
            return Err(Failure::runtime(
                "spike run is missing its verified read-only Git environment",
            ));
        };
        push(
            &mut line.command,
            &[
                "--search",
                "exec",
                "--json",
                "--ephemeral",
                "--sandbox",
                "read-only",
                "--ignore-user-config",
                "--ignore-rules",
                "--output-schema",
                py_strip(&spike.result_schema_path),
                "--config",
                "approval_policy=\"never\"",
                "--config",
                "allow_login_shell=false",
                "--config",
                "features.shell_snapshot=false",
                "--config",
                "shell_environment_policy.experimental_use_profile=false",
            ],
        );
        for (key, value) in environment {
            let setting = format!(
                "shell_environment_policy.set.{key}={}",
                json::dumps(&Value::from(value.as_str()))
            );
            push(&mut line.command, &["--config", &setting]);
        }
    } else {
        push(
            &mut line.command,
            &[
                "--search",
                "exec",
                "--json",
                "--ephemeral",
                "--dangerously-bypass-approvals-and-sandbox",
                "--dangerously-bypass-hook-trust",
            ],
        );
    }
    if !model.is_empty() {
        push(&mut line.command, &["--model", &model]);
    }
    if !effort.is_empty() {
        push(
            &mut line.command,
            &["--config", &format!("model_reasoning_effort={effort}")],
        );
    }
    Ok(line)
}

/// `_review_command_run(run, review_provider)`: the model alias and effort a
/// reviewer launches with. A reviewer on the run's own provider keeps the
/// run's sizing; one on the other provider re-resolves it, dropping a value
/// that provider cannot take.
pub fn review_sizing(run: &Dict, review_provider: &str) -> (String, String) {
    let run_provider = py_strip(&run.string("provider_key")).to_lowercase();
    if run_provider.is_empty() || run_provider == review_provider {
        return (run.string("model_alias"), run.string("worker_effort"));
    }
    let worker_model = run.string("worker_model");
    let worker_effort = run.string("worker_effort");
    let model_alias = resolve_worker_model(&worker_model, review_provider).unwrap_or_default();
    let effort = validate_worker_effort(
        &worker_effort,
        &worker_model,
        review_provider,
        &run.string("worker_provider_notes"),
    )
    .unwrap_or_default();
    (model_alias, effort)
}

/// `_claude_result_error(agent_kind, tail)`: the terminal error Claude
/// reported in its `result` event.
fn claude_result_error(kind: &str, tail: &[String]) -> Option<String> {
    if kind != "claude" {
        return None;
    }
    for line in tail.iter().rev() {
        let Some(Value::Dict(event)) = json::parse(line) else {
            continue;
        };
        if !event.get("type").is_some_and(|kind| kind.is_str("result"))
            || !event.get("is_error").is_some_and(Value::truthy)
        {
            continue;
        }
        let text = event
            .truthy("result")
            .or_else(|| event.truthy("subtype"))
            .map_or_else(|| "error".to_string(), Value::py_str);
        let text = py_strip(&text);
        let prefix_text = match event.truthy("api_error_status") {
            Some(status) => format!("claude result error (HTTP {})", status.py_str()),
            None => "claude result error".to_string(),
        };
        return Some(prefix(&format!("{prefix_text}: {text}"), 300));
    }
    None
}

/// `_failure_tail(agent_kind, rc, tail)`.
pub fn failure_tail(kind: &str, rc: i64, tail: &[String]) -> String {
    let joined = tail.join(" / ");
    match claude_result_error(kind, tail) {
        Some(error) => prefix(&format!("exit={rc}; {error}; tail={joined}"), 500),
        None => format!("exit={rc}; tail={}", prefix(&joined, 500)),
    }
}

/// `_claude_subscription_error(agent_kind, cmd, cwd, environment)`: refuses a
/// Claude launch that would not use the user's subscription.
fn claude_subscription_error(
    kind: &str,
    command: &[String],
    cwd: &str,
    overrides: &[(String, String)],
) -> Option<String> {
    if kind != "claude" {
        return None;
    }
    let mut environment: std::collections::BTreeMap<OsString, OsString> =
        std::env::vars_os().collect();
    for (key, value) in overrides {
        environment.insert(key.into(), value.into());
    }
    let readiness = subscription::check(&command[..1], cwd, &environment);
    (!readiness.ready()).then_some(readiness.message)
}

// -- the provider process ------------------------------------------------------

#[derive(Default)]
struct Slot {
    child: Option<Child>,
    status: Option<ExitStatus>,
}

impl Slot {
    /// `proc.poll()`: the exit status once the child has exited.
    fn poll(&mut self) -> Option<ExitStatus> {
        if self.status.is_none()
            && let Some(child) = self.child.as_mut()
            && let Ok(Some(status)) = child.try_wait()
        {
            self.status = Some(status);
        }
        self.status
    }
}

/// One run's provider process, shared by its thread and the daemon (cancel,
/// shutdown, the abandoned-run check). The child is reaped only under the
/// slot lock, so a signal never reaches a reused pid.
#[derive(Default)]
pub struct RunProcess {
    slot: Mutex<Slot>,
    cancel_requested: AtomicBool,
    done: Mutex<bool>,
    finished: Condvar,
}

impl RunProcess {
    fn attach(&self, child: Child) {
        guard(&self.slot).child = Some(child);
    }

    /// The process is still starting or has not exited:
    /// `proc is None or proc.poll() is None`.
    pub fn running(&self) -> bool {
        let mut slot = guard(&self.slot);
        slot.child.is_none() || slot.poll().is_none()
    }

    fn signal(&self, signal: libc::c_int) -> bool {
        let mut slot = guard(&self.slot);
        if slot.poll().is_some() {
            return false;
        }
        let Some(child) = slot.child.as_ref() else {
            return false;
        };
        // SAFETY: the child is unreaped (poll saw it running under this
        // lock), so its pid still names it.
        unsafe {
            libc::kill(child.id() as libc::pid_t, signal);
        }
        true
    }

    fn wait_exit(&self, timeout: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(status) = guard(&self.slot).poll() {
                return Some(status);
            }
            if Instant::now() >= deadline {
                return None;
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    /// `Worker.cancel()`: mark the run canceled, then terminate the process.
    pub fn cancel(&self) {
        self.cancel_requested.store(true, Ordering::SeqCst);
        self.terminate();
    }

    /// `_terminate()`: SIGTERM, then SIGKILL after the grace period.
    fn terminate(&self) {
        if !self.signal(libc::SIGTERM) {
            return;
        }
        if self.wait_exit(TERMINATE_GRACE).is_none() {
            self.signal(libc::SIGKILL);
            self.wait_exit(Duration::from_secs(5));
        }
    }

    fn canceled(&self) -> bool {
        self.cancel_requested.load(Ordering::SeqCst)
    }

    fn mark_done(&self) {
        *guard(&self.done) = true;
        self.finished.notify_all();
    }

    /// `thread.join(timeout=)`: whether the run's thread finished, its
    /// completion callback included.
    pub fn wait_done(&self, timeout: Duration) -> bool {
        let done = guard(&self.done);
        let (done, _) = self
            .finished
            .wait_timeout_while(done, timeout, |done| !*done)
            .unwrap_or_else(|poison| poison.into_inner());
        *done
    }
}

/// `for line in proc.stdout`: text lines with universal newlines.
fn for_each_line(stream: impl Read, mut handle: impl FnMut(&str)) {
    let mut reader = BufReader::new(stream);
    let mut chunk = Vec::new();
    loop {
        chunk.clear();
        match reader.read_until(b'\n', &mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let text = String::from_utf8_lossy(&chunk);
        let text = text
            .strip_suffix("\r\n")
            .map_or_else(|| text.to_string(), |head| format!("{head}\n"));
        let mut pieces = text.split('\r').peekable();
        while let Some(piece) = pieces.next() {
            if pieces.peek().is_some() {
                handle(&format!("{piece}\n"));
            } else if !piece.is_empty() {
                handle(piece);
            }
        }
    }
}

/// A started provider: its output stream, fed its prompt.
struct Started {
    output: std::io::PipeReader,
    pid: i64,
}

/// `subprocess.Popen(cmd, cwd=, stdin=PIPE, stdout=PIPE,
/// stderr=STDOUT, env=)`, then the prompt on stdin.
fn start_process(
    process: &RunProcess,
    command: &[String],
    cwd: &str,
    overrides: &[(String, String)],
    prompt: &str,
) -> std::io::Result<Started> {
    let (output, writer) = std::io::pipe()?;
    let errors = writer.try_clone()?;
    let mut builder = Command::new(&command[0]);
    builder
        .args(&command[1..])
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(writer)
        .stderr(errors);
    for (key, value) in overrides {
        builder.env(key, value);
    }
    let mut child = builder.spawn()?;
    // The builder holds the write ends; drop them so the output ends when
    // the provider exits.
    drop(builder);
    let pid = i64::from(child.id());
    if let Some(mut stdin) = child.stdin.take() {
        let prompt = prompt.to_string();
        // A separate writer, so a large prompt never blocks against output.
        thread::spawn(move || {
            let _ = stdin.write_all(prompt.as_bytes());
        });
    }
    process.attach(child);
    Ok(Started { output, pid })
}

/// The exit status once the output has ended.
fn reap(process: &RunProcess) -> i64 {
    loop {
        if let Some(status) = guard(&process.slot).poll() {
            return return_code(status);
        }
        thread::sleep(Duration::from_millis(10));
    }
}

/// Refreshes `activity_at` every five seconds while `busy` says so.
fn heartbeat(
    daemon: &Arc<Daemon>,
    run_id: i64,
    busy: impl Fn() -> bool + Send + 'static,
) -> mpsc::Sender<()> {
    let (stop, stopped) = mpsc::channel::<()>();
    let owner = daemon.clone();
    thread::spawn(move || {
        while let Err(RecvTimeoutError::Timeout) =
            stopped.recv_timeout(Duration::from_secs_f64(ACTIVITY_HEARTBEAT_SECONDS))
        {
            if busy() {
                let _ = owner.runs.touch_activity(run_id);
            }
        }
    });
    stop
}

// -- the implementation and spike worker -------------------------------------

/// Everything a worker needs to run one ticket attempt.
pub struct WorkerLaunch {
    pub run_id: i64,
    pub run: Dict,
    pub prompt: String,
    pub agent_bin: String,
    pub agent_kind: String,
    pub workflow_path: Option<PathBuf>,
    pub log_path: PathBuf,
    /// The project is artifact-enabled.
    pub artifact: bool,
    pub spike: Option<SpikeLaunch>,
    /// The artifact completion check of an implementation run.
    pub completion: Option<Arc<ArtifactLifecycleCoordinator>>,
}

impl WorkerLaunch {
    fn spike(&self) -> bool {
        self.run
            .get("execution_mode")
            .is_some_and(|mode| mode.is_str(SPIKE_EXECUTION_MODE))
    }
}

/// The parsed stream state `_handle_event` keeps.
struct Events {
    spike: bool,
    inflight: Arc<Mutex<HashSet<String>>>,
    last_meaningful_at: f64,
    spike_violation: Option<String>,
    research_access_error: Option<String>,
}

fn dict_of(value: Option<&Value>) -> Option<&Dict> {
    value.and_then(Value::as_dict)
}

fn content_blocks(event: &Dict) -> Vec<Dict> {
    dict_of(event.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
        .cloned()
        .collect()
}

fn is_status(value: Option<&Value>, code: i64) -> bool {
    match value {
        Some(Value::Int(number)) => *number == code,
        Some(Value::Str(text)) => text == &code.to_string(),
        _ => false,
    }
}

impl Events {
    /// `_handle_event(line, last_meaningful_at)`: one stream-json line.
    /// Unknown shapes are ignored; the formats evolve.
    fn handle(&mut self, daemon: &Daemon, run_id: i64, line: &str) {
        let Some(Value::Dict(event)) = json::parse(line) else {
            return;
        };
        let kind = event
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        // Claude reports transient retries (429/529) as system/api_retry
        // events that may still succeed; only auth/access retries count.
        let transient_retry = kind == "system"
            && event
                .get("subtype")
                .is_some_and(|value| value.is_str("api_retry"))
            && !is_status(event.get("error_status"), 401)
            && !is_status(event.get("error_status"), 403);
        if self.spike && !transient_retry {
            let error_status = event
                .truthy("api_error_status")
                .or_else(|| event.truthy("error_status"));
            if is_status(error_status, 401) {
                self.research_access_error = Some(
                    "provider authentication failed (HTTP 401); re-authenticate the provider and retry"
                        .to_string(),
                );
            } else if is_status(error_status, 403) {
                self.research_access_error = Some(
                    "provider access was denied (HTTP 403); restore account access and retry"
                        .to_string(),
                );
            } else if let Some(status) = error_status {
                self.research_access_error = Some(format!(
                    "provider request failed (HTTP {}); retry when provider access is available",
                    status.py_str()
                ));
            } else if (kind == "error" || kind == "turn.failed")
                && pattern::search(
                    &NETWORK_FAILURE,
                    &event
                        .truthy("error")
                        .or_else(|| event.truthy("message"))
                        .map(Value::py_str)
                        .unwrap_or_default(),
                )
            {
                self.research_access_error = Some(
                    "provider network request failed; restore network/provider access and retry"
                        .to_string(),
                );
            }
        }
        match kind {
            "assistant" => {
                for block in content_blocks(&event) {
                    if !block
                        .get("type")
                        .is_some_and(|kind| kind.is_str("tool_use"))
                    {
                        continue;
                    }
                    if let Some(tool_id) = block.truthy("id") {
                        guard(&self.inflight).insert(tool_id.py_str());
                    }
                    let name = block.truthy("name").map(Value::py_str).unwrap_or_default();
                    if self.spike && !SPIKE_TOOLS.contains(&name.as_str()) {
                        let shown = if name.is_empty() { "unknown" } else { &name };
                        self.spike_violation =
                            Some(format!("spike attempted disallowed tool {shown}"));
                    }
                    let now = now();
                    let meaningful = !NOOP_TOOLS.contains(&name.as_str());
                    // A no-op tool does not replace a useful activity set
                    // seconds ago.
                    if !meaningful && now - self.last_meaningful_at < ACTIVITY_DEBOUNCE_SECONDS {
                        continue;
                    }
                    let _ = daemon
                        .runs
                        .set_activity(run_id, &derive_activity(&name, dict_of(block.get("input"))));
                    if meaningful {
                        self.last_meaningful_at = now;
                    }
                }
            }
            "user" => {
                for block in content_blocks(&event) {
                    if block
                        .get("type")
                        .is_some_and(|kind| kind.is_str("tool_result"))
                        && let Some(tool_id) = block.truthy("tool_use_id")
                    {
                        guard(&self.inflight).remove(&tool_id.py_str());
                    }
                }
            }
            "item.started" => {
                let Some(item) = dict_of(event.get("item")) else {
                    return;
                };
                if self.spike {
                    // Diagnostics only: the OS sandbox enforces all command
                    // writes and networking. Discarding output to the null
                    // device is not a mutation.
                    let command = pattern::sub(&NULL_REDIRECT, &item.string("command"), 0);
                    if item
                        .get("type")
                        .is_some_and(|kind| kind.is_str("command_execution"))
                        && pattern::search(&MUTATING_COMMAND, &command)
                    {
                        self.spike_violation =
                            Some("spike attempted a mutating or external command".to_string());
                    }
                }
                if let Some(item_id) = item.truthy("id") {
                    guard(&self.inflight).insert(item_id.py_str());
                }
                let _ = daemon
                    .runs
                    .set_activity(run_id, &derive_codex_activity(item));
            }
            "item.completed" => {
                let Some(item) = dict_of(event.get("item")) else {
                    return;
                };
                let failed_command = item
                    .get("type")
                    .is_some_and(|kind| kind.is_str("command_execution"))
                    && !matches!(item.get("exit_code"), None | Some(Value::Null))
                    && !is_status(item.get("exit_code"), 0);
                if self.spike && failed_command {
                    let output = item
                        .truthy("aggregated_output")
                        .or_else(|| item.truthy("output"))
                        .map(Value::py_str)
                        .unwrap_or_default();
                    // A command denial is never evidence of native web access
                    // failure, whatever the executable or its wrappers.
                    if pattern::search(&BLOCKED_COMMAND, &output) {
                        self.spike_violation =
                            Some("spike command was blocked by read-only isolation".to_string());
                    }
                }
                if let Some(item_id) = item.truthy("id") {
                    guard(&self.inflight).remove(&item_id.py_str());
                }
            }
            _ => {}
        }
    }
}

/// The log, written as Python writes it; a failed write is ignored.
struct Log(std::fs::File);

impl Log {
    fn write(&mut self, text: &str) {
        let _ = self.0.write_all(text.as_bytes());
    }

    fn flush(&mut self) {
        let _ = self.0.flush();
    }
}

impl Daemon {
    /// Registers and starts one implementation or spike worker
    /// (`Worker(...).start()`).
    pub(crate) fn start_worker(&self, launch: WorkerLaunch) {
        let Some(daemon) = self.arc() else {
            return;
        };
        let process = Arc::new(RunProcess::default());
        let run_id = launch.run_id;
        guard(&self.workers).insert(run_id, process.clone());
        let owner = process.clone();
        let started = thread::Builder::new()
            .name(format!("worker-{run_id}"))
            .spawn(move || {
                let spike_result = run_worker(&daemon, &owner, &launch);
                daemon.on_worker_complete(run_id, spike_result.as_ref());
                owner.mark_done();
            });
        if let Err(error) = started {
            guard(&self.workers).remove(&run_id);
            let _ = self.runs.update(
                run_id,
                &RunUpdate {
                    state: Some("Failed".to_string()),
                    last_error: Some(Some(format!("could not start worker thread: {error}"))),
                    ended: true,
                    exit_code: Some(-1),
                    ..RunUpdate::default()
                },
            );
            process.mark_done();
        }
    }

    /// Registers and starts the review worker of a completed run
    /// (`ReviewWorker(...).start()`); `reviewers` is the locked registry.
    pub(crate) fn start_review_worker(
        &self,
        reviewers: &mut HashMap<i64, Arc<RunProcess>>,
        launch: ReviewLaunch,
    ) {
        let Some(daemon) = self.arc() else {
            return;
        };
        let process = Arc::new(RunProcess::default());
        let run_id = launch.run_id;
        reviewers.insert(run_id, process.clone());
        let owner = process.clone();
        let started = thread::Builder::new()
            .name(format!("review-worker-{run_id}"))
            .spawn(move || {
                run_review_worker(&daemon, &owner, &launch);
                daemon.on_review_worker_complete(run_id);
                owner.mark_done();
            });
        if started.is_err() {
            reviewers.remove(&run_id);
            process.mark_done();
        }
    }
}

/// `Worker._run()`: the provider process from launch to the run's next
/// state; the spike result, when a spike printed a valid one.
fn run_worker(daemon: &Arc<Daemon>, process: &RunProcess, launch: &WorkerLaunch) -> Option<Dict> {
    let run_id = launch.run_id;
    let run = &launch.run;
    let ticket_id = run.string("ticket_id");
    let repo_path = run.get("repo_path").map(Value::py_str);
    let provider = run
        .truthy("provider_key")
        .map(Value::py_str)
        .unwrap_or_else(|| launch.agent_kind.clone());
    let workspace = run.string("workspace_path");
    let spike = launch.spike();
    let emit = |kind: &str, message: Option<&str>, queue_messenger: bool| {
        daemon.emit_lifecycle(&LifecycleEvent {
            kind,
            ticket_id: Some(&ticket_id),
            run_id: Some(run_id),
            source: Some("worker"),
            message,
            repo_path: repo_path.as_deref(),
            provider_key: Some(&provider),
            queue_messenger: Some(queue_messenger),
        });
    };
    let update = |update: RunUpdate| {
        if let Err(error) = daemon.runs.update(run_id, &update) {
            eprintln!("[orchestrator] could not record run {run_id}: {error}");
        }
    };
    let failed = |last_error: String, exit_code: Option<i64>| RunUpdate {
        state: Some("Failed".to_string()),
        last_error: Some(Some(last_error)),
        ended: true,
        exit_code,
        ..RunUpdate::default()
    };

    let opened = launch
        .log_path
        .parent()
        .map_or(Ok(()), std::fs::create_dir_all)
        .and_then(|()| std::fs::File::create(&launch.log_path));
    let mut log = match opened {
        Ok(file) => Log(file),
        Err(error) => {
            update(failed(
                format!(
                    "Could not open log: {}",
                    os_error_text(&error, &launch.log_path)
                ),
                None,
            ));
            emit("run-failed", None, true);
            return None;
        }
    };
    log.write(&format!("[orchestrator] provider={}\n", launch.agent_kind));
    let mode = run
        .truthy("execution_mode")
        .map_or_else(|| "implementation".to_string(), Value::py_str);
    log.write(&format!("[orchestrator] execution_mode={mode}\n"));
    for key in [
        "model_alias",
        "worker_model",
        "worker_effort",
        "worker_sizing_rationale",
        "worker_provider_notes",
    ] {
        if let Some(value) = run.truthy(key) {
            log.write(&format!("[orchestrator] {key}={}\n", value.py_str()));
        }
    }
    if let Some(workflow) = &launch.workflow_path {
        log.write(&format!(
            "[orchestrator] workflow_template={}\n",
            workflow.display()
        ));
    }
    log.write(&format!(
        "[orchestrator] prompt_sha256={}\n",
        relay_intents::sha256::hex_digest(launch.prompt.as_bytes())
    ));
    let start_head = crate::runs::git_head(&workspace);
    if let Some(head) = &start_head {
        log.write(&format!("[orchestrator] start_head={head}\n"));
    }
    let overrides: Vec<(String, String)> = launch
        .spike
        .as_ref()
        .filter(|_| spike)
        .and_then(|spike| spike.git_environment.clone())
        .unwrap_or_default();
    let line = launch_line(
        &launch.agent_kind,
        &launch.agent_bin,
        &run.string("model_alias"),
        &run.string("worker_effort"),
        launch.spike.as_ref().filter(|_| spike),
        crate::general::resolve_codex_family,
    )
    .and_then(|line| {
        match claude_subscription_error(&launch.agent_kind, &line.command, &workspace, &overrides) {
            Some(message) => Err(Failure::runtime(message)),
            None => Ok(line),
        }
    });
    let line = match line {
        Ok(line) => line,
        Err(error) => {
            update(failed(error.message.clone(), Some(-1)));
            log.write(&format!("[orchestrator] {}\n", error.message));
            emit("run-failed", None, true);
            return None;
        }
    };
    for (key, value) in [
        ("selected_model_family", &line.selected_model_family),
        ("resolved_model_alias", &line.resolved_model_alias),
        ("resolved_worker_effort", &line.resolved_worker_effort),
    ] {
        if let Some(value) = value.as_ref().filter(|value| !value.is_empty()) {
            log.write(&format!("[orchestrator] {key}={value}\n"));
        }
    }
    let started = match start_process(
        process,
        &line.command,
        &workspace,
        &overrides,
        &launch.prompt,
    ) {
        Ok(started) => started,
        Err(error) => {
            let message = format!(
                "{} CLI not found: {}",
                launch.agent_kind,
                os_error_text(&error, Path::new(&line.command[0]))
            );
            update(failed(message.clone(), Some(-1)));
            log.write(&format!("[orchestrator] {message}\n"));
            emit("run-failed", None, true);
            return None;
        }
    };
    update(RunUpdate {
        state: Some("Running".to_string()),
        pid: Some(started.pid),
        ..RunUpdate::default()
    });
    emit("run-running", None, false);

    let mut events = Events {
        spike,
        inflight: Arc::new(Mutex::new(HashSet::new())),
        last_meaningful_at: 0.0,
        spike_violation: None,
        research_access_error: None,
    };
    // Keep activity_at fresh while a tool is in flight (a long build), so
    // the board does not read the run as stalled.
    let inflight = events.inflight.clone();
    let stop = heartbeat(daemon, run_id, move || !guard(&inflight).is_empty());
    let mut tail: VecDeque<String> = VecDeque::with_capacity(5);
    for_each_line(started.output, |line| {
        log.write(line);
        // The daemon's advisory health check observes log growth.
        log.flush();
        let stripped = py_strip(line);
        if stripped.is_empty() {
            return;
        }
        if tail.len() == 5 {
            tail.pop_front();
        }
        tail.push_back(prefix(stripped, 500));
        events.handle(daemon, run_id, stripped);
    });
    log.flush();
    drop(stop);
    let rc = reap(process);
    let tail: Vec<String> = tail.into_iter().collect();

    let ended = |state: &str, last_error: Option<Option<String>>| RunUpdate {
        state: Some(state.to_string()),
        last_error,
        ended: true,
        exit_code: Some(rc),
        ..RunUpdate::default()
    };
    if process.canceled() {
        update(ended("Canceled", None));
        emit("run-canceled", None, true);
        return None;
    }
    if rc == 0 && spike {
        let extracted = match &events.spike_violation {
            Some(violation) => Err(Failure::value(violation.clone())),
            None => crate::spike::extract_spike_result(&launch.log_path),
        };
        return match extracted {
            Ok(result) => {
                update(ended("SpikeResultReady", None));
                emit("preparing-response", None, false);
                Some(result)
            }
            Err(error) => {
                log.write(&format!(
                    "\n[orchestrator] spike incomplete: {}\n",
                    error.message
                ));
                update(ended("Failed", Some(Some(error.message))));
                emit("run-failed", None, true);
                None
            }
        };
    }
    if rc == 0 {
        let (outcome, reason) = match &launch.completion {
            Some(lifecycle) => daemon.validate_artifact_completion(
                lifecycle,
                Path::new(&workspace),
                &ticket_id,
                run_id,
                &launch.agent_kind,
                start_head.as_deref(),
            ),
            None => validate_worker_outcome(&workspace, &ticket_id, run_id, start_head.as_deref()),
        };
        match outcome.as_deref() {
            Some("verification_closeout") => {
                update(ended("Merged", Some(None)));
                let message = format!(
                    "{ticket_id} closed out after verification resumed; no source change was needed"
                );
                emit("run-merged", Some(&message), true);
            }
            Some(status @ ("done" | "completed" | VERIFICATION_BLOCKED_STATUS)) => {
                let blocked = status == VERIFICATION_BLOCKED_STATUS;
                update(ended(
                    "AwaitingReview",
                    Some(blocked.then(|| reason.clone())),
                ));
                let message = blocked.then(|| {
                    format!(
                        "{ticket_id} declared an external verification blocker and needs review"
                    )
                });
                emit("run-review-needed", message.as_deref(), true);
            }
            _ => {
                log.write(&format!(
                    "\n[orchestrator] worker exited 0 but did not complete ticket: {reason}\n"
                ));
                update(ended(
                    "Failed",
                    Some(Some(format!("exit=0 but ticket incomplete: {reason}"))),
                ));
                let message = format!(
                    "{ticket_id} run {run_id} stopped without satisfying its completion \
                     contract. The worker exited successfully; saved findings remain available \
                     in the run worktree/log. Review the ticket's outstanding requirements: \
                     {reason}"
                );
                emit("run-failed", Some(&message), true);
            }
        }
        return None;
    }
    if rc == -9 || rc == -15 {
        update(ended("Canceled", None));
        emit("run-canceled", None, true);
        return None;
    }
    let failure = match &events.research_access_error {
        Some(error) if spike => format!("spike research access unavailable: {error}"),
        _ if launch.artifact && spike => format!(
            "spike provider exited with status {rc}; inspect the local run log before retrying."
        ),
        _ => failure_tail(&launch.agent_kind, rc, &tail),
    };
    update(ended("Failed", Some(Some(failure))));
    emit("run-failed", None, true);
    None
}

/// `validate_worker_outcome(workspace_path=, ticket_id=, run_id=,
/// start_head=)`: the declared, committed outcome of a legacy-board worker
/// that exited 0. Completion is evidence in the worktree: a new commit, the
/// ticket marked done or verification blocked, and a run log naming the run.
pub fn validate_worker_outcome(
    workspace: &str,
    ticket_id: &str,
    run_id: i64,
    start_head: Option<&str>,
) -> (Option<String>, String) {
    let ticket_path = Path::new(workspace)
        .join(".orchestrator")
        .join(format!("{ticket_id}.md"));
    let mut reasons: Vec<String> = Vec::new();
    let current_head = crate::runs::git_head(workspace);
    if start_head.is_some_and(|head| !head.is_empty()) && current_head.as_deref() == start_head {
        reasons.push("worker made no new commit".to_string());
    } else if current_head.is_none() {
        reasons.push("could not read worker git HEAD".to_string());
    }
    let ticket = match std::fs::read(&ticket_path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return (
                None,
                format!("ticket file missing at {}", ticket_path.display()),
            );
        }
        Err(error) => {
            return (
                None,
                format!(
                    "ticket file unreadable at {}: {}",
                    ticket_path.display(),
                    os_error_text(&error, &ticket_path)
                ),
            );
        }
        Ok(bytes) => {
            let text = String::from_utf8_lossy(&bytes);
            match relay_artifacts::tickets::parse(&pystr::universal_newlines(&text)) {
                Ok(ticket) => ticket,
                Err(error) => {
                    return (
                        None,
                        format!(
                            "ticket file unreadable at {}: {}",
                            ticket_path.display(),
                            error.message
                        ),
                    );
                }
            }
        }
    };
    if ticket.id != ticket_id {
        reasons.push(format!(
            "ticket id is {}, expected {}",
            pystr::repr(&ticket.id),
            pystr::repr(ticket_id)
        ));
    }
    let status = ticket.status.clone();
    if status != "done" && status != VERIFICATION_BLOCKED_STATUS {
        reasons.push(format!(
            "ticket status is {}, expected 'done' or {}",
            pystr::repr(&status),
            pystr::repr(VERIFICATION_BLOCKED_STATUS)
        ));
    }
    let blocker = ticket.verification_blocker.clone().unwrap_or_default();
    let resume = ticket.verification_resume.clone().unwrap_or_default();
    if status == VERIFICATION_BLOCKED_STATUS {
        for (field, value) in [
            ("verification_blocker", &blocker),
            ("verification_resume", &resume),
        ] {
            if py_strip(value).is_empty() {
                reasons.push(format!("verification-blocked ticket is missing {field}"));
            }
        }
    }
    if ticket.run_id != Some(run_id) {
        reasons.push(format!(
            "ticket run_id is {}, expected {run_id}",
            ticket
                .run_id
                .map_or("None".to_string(), |id| id.to_string())
        ));
    }
    let relative = format!(".orchestrator/{ticket_id}.md");
    let diff = Command::new("git")
        .arg("-C")
        .arg(workspace)
        .args(["diff", "--quiet", "HEAD", "--", &relative])
        .output();
    match diff.map(|output| output.status.code()) {
        Ok(Some(0)) => {}
        Ok(Some(1)) => reasons.push("ticket completion is not committed".to_string()),
        _ => reasons.push("could not verify committed ticket completion".to_string()),
    }
    if !ticket.body.contains("## Run log") || !ticket.body.contains(&run_id.to_string()) {
        reasons.push(format!("ticket run log does not mention run {run_id}"));
    }
    if !reasons.is_empty() {
        return (None, reasons.join("; "));
    }
    if status == VERIFICATION_BLOCKED_STATUS {
        return (
            Some(status),
            format!(
                "verification blocked: {}; resume: {}",
                py_strip(&blocker),
                py_strip(&resume)
            ),
        );
    }
    (
        Some(status),
        "ticket marked done with run evidence".to_string(),
    )
}

// -- the review worker -------------------------------------------------------------

/// Everything a review worker needs.
pub struct ReviewLaunch {
    pub run_id: i64,
    pub run: Dict,
    pub prompt: String,
    pub agent_bin: String,
    pub agent_kind: String,
    pub log_path: PathBuf,
}

/// `ReviewWorker._run()`: review the completed run in the source checkout.
/// The reviewer decides through the daemon's decision route; an exit without
/// a decision leaves the run awaiting review.
fn run_review_worker(daemon: &Arc<Daemon>, process: &RunProcess, launch: &ReviewLaunch) {
    let run_id = launch.run_id;
    let run = &launch.run;
    let ticket_id = run.string("ticket_id");
    let repo_path = run.string("repo_path");
    let provider = run
        .truthy("provider_key")
        .map(Value::py_str)
        .unwrap_or_else(|| launch.agent_kind.clone());
    let emit = |kind: &str, message: Option<&str>, queue_messenger: bool| {
        daemon.emit_lifecycle(&LifecycleEvent {
            kind,
            ticket_id: Some(&ticket_id),
            run_id: Some(run_id),
            source: Some("review-worker"),
            message,
            repo_path: Some(&repo_path),
            provider_key: Some(&provider),
            queue_messenger: Some(queue_messenger),
        });
    };
    let attention = format!("{ticket_id} run {run_id} still needs review attention");
    let awaiting = |last_error: String| {
        let _ = daemon.runs.update(
            run_id,
            &RunUpdate {
                state: Some("AwaitingReview".to_string()),
                last_error: Some(Some(last_error)),
                ..RunUpdate::default()
            },
        );
        emit("run-review-needed", Some(&attention), true);
    };
    let opened = launch
        .log_path
        .parent()
        .map_or(Ok(()), std::fs::create_dir_all)
        .and_then(|()| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&launch.log_path)
        });
    let mut log = match opened {
        Ok(file) => Log(file),
        Err(error) => {
            awaiting(format!(
                "Could not open review log: {}",
                os_error_text(&error, &launch.log_path)
            ));
            return;
        }
    };
    log.write(&format!(
        "\n[orchestrator] review_provider={}\n",
        launch.agent_kind
    ));
    log.write(&format!(
        "[orchestrator] review_prompt_sha256={}\n",
        relay_intents::sha256::hex_digest(launch.prompt.as_bytes())
    ));
    let (model_alias, effort) = review_sizing(run, &launch.agent_kind);
    let line = launch_line(
        &launch.agent_kind,
        &launch.agent_bin,
        &model_alias,
        &effort,
        None,
        crate::general::resolve_codex_family,
    )
    .and_then(|line| {
        match claude_subscription_error(&launch.agent_kind, &line.command, &repo_path, &[]) {
            Some(message) => Err(Failure::runtime(message)),
            None => Ok(line),
        }
    });
    let line = match line {
        Ok(line) => line,
        Err(error) => {
            log.write(&format!("[orchestrator] {}\n", error.message));
            awaiting(error.message);
            return;
        }
    };
    let started = match start_process(process, &line.command, &repo_path, &[], &launch.prompt) {
        Ok(started) => started,
        Err(error) => {
            let message = format!(
                "{} review CLI not found: {}",
                launch.agent_kind,
                os_error_text(&error, Path::new(&line.command[0]))
            );
            log.write(&format!("[orchestrator] {message}\n"));
            awaiting(message);
            return;
        }
    };
    let _ = daemon.runs.update(
        run_id,
        &RunUpdate {
            state: Some("Reviewing".to_string()),
            pid: Some(started.pid),
            ..RunUpdate::default()
        },
    );
    let _ = daemon.runs.set_activity(run_id, "Reviewing worker branch");
    emit("run-reviewing", None, false);
    let stop = heartbeat(daemon, run_id, || true);
    let mut tail: VecDeque<String> = VecDeque::with_capacity(5);
    for_each_line(started.output, |line| {
        log.write(line);
        // The daemon's advisory health check observes log growth.
        log.flush();
        let stripped = py_strip(line);
        if !stripped.is_empty() {
            if tail.len() == 5 {
                tail.pop_front();
            }
            tail.push_back(prefix(stripped, 500));
        }
    });
    log.flush();
    drop(stop);
    let rc = reap(process);
    let current = daemon.runs.get(run_id).ok().flatten().unwrap_or_default();
    if REVIEW_DECIDED_STATES.contains(&current.string("state").as_str()) {
        return;
    }
    let tail: Vec<String> = tail.into_iter().collect();
    let reason = if rc == 0 {
        "review worker exited 0 without accepting or retrying run".to_string()
    } else {
        format!(
            "review worker failed: {}",
            failure_tail(&launch.agent_kind, rc, &tail)
        )
    };
    awaiting(reason);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_catalog(_: &str, _: &str) -> Result<catalog::CodexModel, String> {
        Err("no catalog".to_string())
    }

    fn sol(_: &str, _: &str) -> Result<catalog::CodexModel, String> {
        Ok(catalog::CodexModel {
            id: "gpt-6-sol".to_string(),
            model: "gpt-6-sol".to_string(),
            hidden: false,
            is_default: true,
            default_reasoning_effort: "medium".to_string(),
            supported_reasoning_efforts: ["low", "medium", "high", "xhigh"]
                .iter()
                .map(|effort| effort.to_string())
                .collect(),
            input_modalities: Vec::new(),
        })
    }

    #[test]
    fn claude_spikes_are_confined_and_given_the_schema() {
        let spike = SpikeLaunch::default();
        let line = launch_line(
            "claude",
            "claude",
            "Sonnet",
            "medium",
            Some(&spike),
            no_catalog,
        )
        .unwrap();
        let command: Vec<&str> = line.command.iter().map(String::as_str).collect();
        assert_eq!(
            &command[..8],
            [
                "claude",
                "-p",
                "--safe-mode",
                "--no-chrome",
                "--no-session-persistence",
                "--permission-mode",
                "dontAsk",
                "--tools",
            ]
        );
        let schema = command
            .iter()
            .position(|arg| *arg == "--json-schema")
            .unwrap();
        assert!(command[schema + 1].starts_with("{\"type\":\"object\""));
        assert_eq!(
            &command[command.len() - 4..],
            ["--model", "sonnet", "--effort", "medium"]
        );
    }

    #[test]
    fn codex_spikes_need_a_schema_and_the_verified_git() {
        let missing = SpikeLaunch::default();
        assert_eq!(
            launch_line("codex", "codex", "", "", Some(&missing), no_catalog)
                .unwrap_err()
                .message,
            "spike run is missing its structured result schema"
        );
        let no_git = SpikeLaunch {
            result_schema_path: "/s.json".to_string(),
            git_environment: None,
        };
        assert_eq!(
            launch_line("codex", "codex", "", "", Some(&no_git), no_catalog)
                .unwrap_err()
                .message,
            "spike run is missing its verified read-only Git environment"
        );
        let spike = SpikeLaunch {
            result_schema_path: "/s.json".to_string(),
            git_environment: Some(vec![("RELAY_SPIKE_GIT".to_string(), "/g/git".to_string())]),
        };
        let line = launch_line("codex", "codex", "sol", "medium", Some(&spike), sol).unwrap();
        assert!(line.command.contains(&"--output-schema".to_string()));
        assert!(
            line.command
                .contains(&"shell_environment_policy.set.RELAY_SPIKE_GIT=\"/g/git\"".to_string())
        );
        assert_eq!(line.resolved_model_alias.as_deref(), Some("gpt-6-sol"));
        assert_eq!(line.selected_model_family.as_deref(), Some("sol"));
        assert_eq!(line.resolved_worker_effort.as_deref(), Some("medium"));
        assert_eq!(
            &line.command[line.command.len() - 4..],
            [
                "--model",
                "gpt-6-sol",
                "--config",
                "model_reasoning_effort=medium"
            ]
        );
    }

    #[test]
    fn a_reviewer_on_the_other_provider_resizes() {
        let mut run = Dict::new();
        run.insert("provider_key", "codex");
        run.insert("model_alias", "astra");
        run.insert("worker_model", "strong");
        run.insert("worker_effort", "ultra");
        run.insert("worker_provider_notes", "none");
        assert_eq!(
            review_sizing(&run, "claude"),
            ("opus".to_string(), String::new())
        );
        assert_eq!(
            review_sizing(&run, "codex"),
            ("astra".to_string(), "ultra".to_string())
        );
    }

    #[test]
    fn failure_tails_name_claude_result_errors() {
        let tail = vec![
            "plain".to_string(),
            r#"{"type":"result","is_error":true,"api_error_status":401,"result":" Invalid API key "}"#
                .to_string(),
        ];
        assert_eq!(
            failure_tail("claude", 1, &tail),
            format!(
                "exit=1; claude result error (HTTP 401): Invalid API key; tail={}",
                tail.join(" / ")
            )
        );
        assert_eq!(
            failure_tail("codex", 3, &["x".to_string()]),
            "exit=3; tail=x"
        );
    }

    #[test]
    fn output_lines_use_universal_newlines() {
        let mut lines = Vec::new();
        for_each_line("a\r\nb\rc\nd".as_bytes(), |line| {
            lines.push(line.to_string())
        });
        assert_eq!(lines, ["a\n", "b\n", "c\n", "d"]);
    }

    #[test]
    fn spike_commands_that_mutate_are_flagged() {
        let flagged = |command: &str| {
            let cleaned = pattern::sub(&NULL_REDIRECT, command, 0);
            pattern::search(&MUTATING_COMMAND, &cleaned)
        };
        assert!(!flagged("git log 2>/dev/null"));
        assert!(!flagged("ls > /dev/null"));
        assert!(flagged("echo hi > out.txt"));
        assert!(flagged("git commit -m x"));
        assert!(flagged("cd x; rm -rf y"));
        assert!(!flagged("git status"));
    }
}
