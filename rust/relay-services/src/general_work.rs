//! Daemon-owned, repository-independent General tasks and their reviewed
//! local artifacts: the domain of `services/general_work.py` on top of the
//! task ledger in [`relay_store::general_work`].
//!
//! The database is the only task writer. A worker's directory under
//! `<state root>/files/tasks/<task>/<run>` holds its output, never board
//! metadata or a source repository. A restart records an interruption and
//! requires an explicit retry; it never replays accepted work.
//!
//! What the daemon supplies, as `orchestrator.py` does: the command factory
//! that builds the Codex or Claude command line for a run, the provider
//! preflight (the subscription checks), and the personal file storage that
//! keeps approved outputs. [`ProcessRunner`] is `_run_process`, the default
//! way a run's command is executed.
//!
//! Deliberate differences from Python: a `result.json` that is not UTF-8 or
//! not JSON fails its run with "Worker result.json is not valid JSON" rather
//! than the decoder's own message, and an operating-system error starting a
//! worker reads `[Errno N] <strerror>: '<program>'` without Python's
//! errno-specific exception detail beyond that.

use std::collections::HashMap;
use std::ffi::OsString;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use relay_intents::json::{self, py_eq, py_strip};
use relay_intents::sha256::hex_digest;
use relay_store::general_work::GeneralWorkStore as TaskLedger;
use relay_store::sql;

use crate::providers::subscription::METERED_ENVIRONMENT;
use crate::{Dict, Error, Result, Value};

const EXCLUDED_ENVIRONMENT: [&str; 7] = [
    "ANTHROPIC_BASE_URL",
    "OPENAI_API_KEY",
    "CODEX_API_KEY",
    "RELAY_GENERAL_FILES_ROOT",
    "RELAY_PROVIDER_SESSION_ID",
    "RELAY_PROVIDER_PROCESS_ID",
    "RELAY_APP_SESSION_ID",
];
const EXCLUDED_PREFIXES: [&str; 3] = ["RELAY_PROJECT_", "RELAY_SESSION_", "RELAY_CONTEXT_"];

const DISPATCHABLE: [&str; 4] = ["backlog", "failed", "interrupted", "changes_requested"];
const RESULT_MAX_BYTES: u64 = 1024 * 1024;
const SIGTERM_STATUS: i32 = -libc::SIGTERM;

/// `general_worker_environment(files_root)` over this process's environment.
pub fn general_worker_environment(files_root: Option<&Path>) -> Vec<(OsString, OsString)> {
    general_worker_environment_from(std::env::vars_os(), files_root)
}

/// `general_worker_environment` over `environment`, in its order: no
/// metered credential, API key or Relay session identity; the scope is
/// `general`, and `RELAY_GENERAL_FILES_ROOT` names `files_root` when given.
pub fn general_worker_environment_from(
    environment: impl IntoIterator<Item = (OsString, OsString)>,
    files_root: Option<&Path>,
) -> Vec<(OsString, OsString)> {
    let mut kept: Vec<(OsString, OsString)> = environment
        .into_iter()
        .filter(|(key, _)| {
            let key = key.to_string_lossy();
            !METERED_ENVIRONMENT.contains(&key.as_ref())
                && !EXCLUDED_ENVIRONMENT.contains(&key.as_ref())
                && !EXCLUDED_PREFIXES
                    .iter()
                    .any(|prefix| key.starts_with(prefix))
        })
        .collect();
    let mut set =
        |key: &str, value: OsString| match kept.iter_mut().find(|(existing, _)| existing == key) {
            Some(entry) => entry.1 = value,
            None => kept.push((key.into(), value)),
        };
    set("RELAY_SESSION_SCOPE", "general".into());
    if let Some(files_root) = files_root {
        set(
            "RELAY_GENERAL_FILES_ROOT",
            files_root.as_os_str().to_owned(),
        );
    }
    kept
}

/// A run's cancellation signal (`threading.Event`).
#[derive(Clone, Debug, Default)]
pub struct Cancellation(Arc<AtomicBool>);

impl Cancellation {
    pub fn set(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_set(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// `command_factory(provider)`: the selected provider and its command line.
pub type CommandFactory = Box<dyn Fn(Option<&str>) -> Result<(String, Vec<String>)> + Send + Sync>;

/// `preflight(provider, command, workspace)`: refuses a run that cannot use
/// the user's subscription.
pub type Preflight = Box<dyn Fn(&str, &[String], &Path) -> Result<()> + Send + Sync>;

/// `runner(command, workspace, prompt, run_id, cancelled)`: runs one
/// worker and returns its exit status (negative for a signal).
pub trait Runner: Send + Sync {
    fn run(
        &self,
        work: &GeneralWork,
        command: &[String],
        workspace: &Path,
        prompt: &str,
        run_id: &str,
        cancelled: &Cancellation,
    ) -> Result<i32>;
}

/// The personal file storage calls General review and retrieval make
/// (`PersonalFileStorage.register_file`, `read`, `reference` and `root`).
pub trait PersonalFiles: Send + Sync {
    /// Registers `path` as `artifact_id`; the answer carries its `sha256`.
    fn register_file(
        &self,
        path: &Path,
        artifact_id: &str,
        active: bool,
        approved: bool,
        adopt: bool,
    ) -> Result<Dict>;
    fn read(&self, artifact_id: &str, sha256: &str) -> Result<Vec<u8>>;
    /// The reference, with the `local_path` relative to [`Self::root`].
    fn reference(&self, artifact_id: &str, sha256: &str) -> Result<Dict>;
    fn root(&self) -> PathBuf;
}

/// What `GeneralWorkStore.__init__` takes beside the root.
#[derive(Default)]
pub struct GeneralWorkOptions {
    pub command_factory: Option<CommandFactory>,
    pub preflight: Option<Preflight>,
    /// `None` runs commands with [`ProcessRunner`].
    pub runner: Option<Box<dyn Runner>>,
    pub personal_storage: Option<Arc<dyn PersonalFiles>>,
}

/// `GeneralWorkStore`: General tasks, their runs and their review.
pub struct GeneralWork {
    ledger: TaskLedger,
    files: PathBuf,
    command_factory: Option<CommandFactory>,
    preflight: Option<Preflight>,
    runner: Box<dyn Runner>,
    personal_storage: Option<Arc<dyn PersonalFiles>>,
    lock: Mutex<()>,
    processes: Mutex<HashMap<String, u32>>,
    /// Run id → task id, for the runs this process dispatched.
    run_tasks: Mutex<HashMap<String, String>>,
    cancellations: Mutex<HashMap<String, Cancellation>>,
}

fn invalid(message: &str) -> Error {
    Error::value(message)
}

fn wrap(key: &str, value: Dict) -> Dict {
    let mut wrapped = Dict::new();
    wrapped.insert(key, Value::Dict(value));
    wrapped
}

/// The task's runs.
fn runs(task: &Dict) -> &[Value] {
    task.get("runs")
        .and_then(Value::as_list)
        .unwrap_or_default()
}

fn last_run(task: &Dict) -> Option<&Dict> {
    runs(task).last().and_then(Value::as_dict)
}

/// Replaces the task's last run with `change(run)`.
fn edit_last_run<T>(task: &mut Dict, change: impl FnOnce(&mut Dict) -> T) -> Option<T> {
    let mut list = match task.get("runs") {
        Some(Value::List(list)) => list.clone(),
        _ => return None,
    };
    let Some(Value::Dict(run)) = list.last_mut() else {
        return None;
    };
    let value = change(run);
    task.insert("runs", Value::List(list));
    Some(value)
}

fn status(task: &Dict) -> &str {
    task.get("status").and_then(Value::as_str).unwrap_or("")
}

fn run_id_of(run: &Dict) -> Value {
    run.get("id").cloned().unwrap_or(Value::Null)
}

fn random_hex(bytes: usize) -> Result<Vec<u8>> {
    let mut buffer = vec![0u8; bytes];
    fs::File::open("/dev/urandom")?.read_exact(&mut buffer)?;
    Ok(buffer)
}

/// `uuid.uuid4().hex`.
fn uuid4_hex() -> Result<String> {
    let mut bytes = random_hex(16)?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

impl GeneralWork {
    /// Opens `<state root>/general/work.db` and `<state root>/files/tasks`;
    /// a task still in progress was interrupted by a restart.
    pub fn open(root: &Path, options: GeneralWorkOptions) -> Result<Self> {
        let ledger = TaskLedger::open(root)?;
        let files = ledger.root().join("files").join("tasks");
        Ok(Self {
            files,
            ledger,
            command_factory: options.command_factory,
            preflight: options.preflight,
            runner: options.runner.unwrap_or_else(|| Box::new(ProcessRunner)),
            personal_storage: options.personal_storage,
            lock: Mutex::new(()),
            processes: Mutex::new(HashMap::new()),
            run_tasks: Mutex::new(HashMap::new()),
            cancellations: Mutex::new(HashMap::new()),
        })
    }

    /// The resolved state root.
    pub fn root(&self) -> &Path {
        self.ledger.root()
    }

    /// `<state root>/files/tasks`.
    pub fn files(&self) -> &Path {
        &self.files
    }

    pub fn ledger(&self) -> &TaskLedger {
        &self.ledger
    }

    fn guard(&self) -> std::sync::MutexGuard<'_, ()> {
        self.lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// `create(title=…, description=…, acceptance_criteria=…, request_id=…)`
    /// with the request body's values: `{"task": …, "idempotent": …}`.
    pub fn create(
        &self,
        title: &Value,
        description: &Value,
        acceptance_criteria: &Value,
        request_id: &Value,
    ) -> Result<Dict> {
        let text = |value: &Value| match value {
            Value::Str(text) if !py_strip(text).is_empty() => Some(text.clone()),
            _ => None,
        };
        let (Some(title), Some(description), Some(request_id)) =
            (text(title), text(description), text(request_id))
        else {
            return Err(invalid("title, description and request_id are required"));
        };
        let criteria: Option<Vec<String>> = match acceptance_criteria {
            Value::List(items) if !items.is_empty() => items.iter().map(text).collect(),
            _ => None,
        };
        let Some(criteria) = criteria else {
            return Err(invalid(
                "Provide at least one actionable acceptance criterion",
            ));
        };
        let _guard = self.guard();
        Ok(self
            .ledger
            .create(&title, &description, &criteria, &request_id)?)
    }

    /// `list(limit=…)`.
    pub fn list(&self, limit: i64) -> Result<Dict> {
        let _guard = self.guard();
        Ok(self.ledger.list(limit)?)
    }

    /// `get(task_id)`: `{"task": …, "events": […]}`.
    pub fn get(&self, task_id: &str) -> Result<Dict> {
        let _guard = self.guard();
        Ok(self.ledger.get(task_id)?)
    }

    fn task(&self, task_id: &str) -> Result<Dict> {
        let found = self.ledger.get(task_id)?;
        Ok(found
            .get("task")
            .and_then(Value::as_dict)
            .cloned()
            .unwrap_or_default())
    }

    /// `dispatch(task_id, provider=…)`: starts a run on its own thread,
    /// `{"task": …, "already_active": …}`.
    pub fn dispatch(self: &Arc<Self>, task_id: &str, provider: Option<&str>) -> Result<Dict> {
        let (task, run, command, cancelled) = {
            let _guard = self.guard();
            let task = self.task(task_id)?;
            if status(&task) == "in_progress" {
                let mut answer = wrap("task", task);
                answer.insert("already_active", true);
                return Ok(answer);
            }
            if !DISPATCHABLE.contains(&status(&task)) {
                return Err(invalid(
                    "Only backlog, failed, interrupted or changes-requested General tasks can run",
                ));
            }
            if let Some(previous) = last_run(&task)
                && preserved_process(previous)
            {
                return Err(invalid(
                    "The previous General worker is still running. Cancel that exact run before retrying; no work was replayed.",
                ));
            }
            let Some(factory) = &self.command_factory else {
                return Err(invalid("General task execution is unavailable"));
            };
            let run_id = uuid4_hex()?;
            let workspace = self.files.join(task_id).join(&run_id);
            if let Some(parent) = workspace.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::create_dir(&workspace)?;
            let prepared = factory(provider).and_then(|(selected, command)| {
                if selected != "codex" && selected != "claude" {
                    return Err(invalid("General tasks require Codex or Claude"));
                }
                if let Some(preflight) = &self.preflight {
                    preflight(&selected, &command, &workspace)?;
                }
                Ok((selected, command))
            });
            let (selected, command) = match prepared {
                Ok(prepared) => prepared,
                Err(error) => {
                    // A provider preflight may leave diagnostics; preserve them.
                    let _ = fs::remove_dir(&workspace);
                    return Err(error);
                }
            };
            let mut run = Dict::new();
            run.insert("id", run_id.as_str());
            run.insert("attempt", runs(&task).len() as i64 + 1);
            run.insert("provider", selected);
            run.insert("state", "running");
            run.insert("workspace_path", workspace.to_string_lossy().into_owned());
            run.insert("started_at", sql::now());
            run.insert("artifact_manifest", Value::List(Vec::new()));
            run.insert("result", Value::Null);
            run.insert("error", Value::Null);
            let added = run.clone();
            let (task, ()) = self.ledger.update(task_id, |task| {
                runs_push(task, Value::Dict(added));
                task.insert("status", "in_progress");
                Ok((
                    "dispatched".to_string(),
                    Value::Str(run_id.clone()),
                    None,
                    (),
                ))
            })?;
            let cancelled = Cancellation::default();
            lock(&self.run_tasks).insert(run_id.clone(), task_id.to_string());
            lock(&self.cancellations).insert(run_id, cancelled.clone());
            (task, run, command, cancelled)
        };
        let work = Arc::clone(self);
        let snapshot = task.clone();
        let run_id = run.get("id").map(Value::py_str).unwrap_or_default();
        let name = format!("general-{}", &run_id[..8.min(run_id.len())]);
        thread::Builder::new()
            .name(name)
            .spawn(move || work.execute(&snapshot, &run, &command, &cancelled))?;
        let mut answer = wrap("task", task);
        answer.insert("already_active", false);
        Ok(answer)
    }

    /// `_execute`: runs the worker, validates its result and records the
    /// run's terminal state unless a newer run replaced it.
    pub fn execute(&self, task: &Dict, run: &Dict, command: &[String], cancelled: &Cancellation) {
        let run_id = run.get("id").map(Value::py_str).unwrap_or_default();
        let workspace = PathBuf::from(
            run.get("workspace_path")
                .map(Value::py_str)
                .unwrap_or_default(),
        );
        let provider = run.get("provider").map(Value::py_str).unwrap_or_default();
        let outcome = self
            .runner
            .run(self, command, &workspace, &prompt(task), &run_id, cancelled)
            .and_then(|status| {
                if status != 0 {
                    return Err(invalid(&format!(
                        "{provider} worker exited with status {status}; inspect this run's local worker.log"
                    )));
                }
                if cancelled.is_set() {
                    return Ok((Value::Null, Vec::new()));
                }
                let (result, manifest) = validate_result(task, &workspace)?;
                Ok((Value::Dict(result), manifest))
            });
        let (error, result, manifest) = match outcome {
            Ok((result, manifest)) => (Value::Null, result, manifest),
            Err(error) => (Value::Str(error.message), Value::Null, Vec::new()),
        };
        let _guard = self.guard();
        let task_id = task.get("id").map(Value::py_str).unwrap_or_default();
        let _ = self.ledger.update(&task_id, |current| {
            let current_id = last_run(current).map(run_id_of).unwrap_or(Value::Null);
            if !py_eq(&current_id, &Value::Str(run_id.clone())) {
                return Err(relay_store::Error::Invalid("superseded".to_string()));
            }
            let state = if cancelled.is_set() {
                "canceled"
            } else if matches!(error, Value::Null) {
                "awaiting_review"
            } else {
                "failed"
            };
            edit_last_run(current, |current_run| {
                current_run.insert("state", state);
                current_run.insert("ended_at", sql::now());
                current_run.insert("error", error.clone());
                current_run.insert("result", result.clone());
                current_run.insert(
                    "artifact_manifest",
                    Value::List(manifest.iter().cloned().map(Value::Dict).collect()),
                );
            });
            current.insert("status", state);
            Ok((state.to_string(), Value::Str(run_id.clone()), None, ()))
        });
        lock(&self.processes).remove(&run_id);
        lock(&self.run_tasks).remove(&run_id);
        lock(&self.cancellations).remove(&run_id);
    }

    /// Records a started worker's pid and creation identity on the task
    /// whose current run is `run_id` (the `process_started` event).
    pub fn record_process(&self, run_id: &str, pid: u32) -> Result<()> {
        let _guard = self.guard();
        lock(&self.processes).insert(run_id.to_string(), pid);
        let known = lock(&self.run_tasks).get(run_id).cloned();
        let candidates: Vec<String> = match known {
            Some(task_id) => vec![task_id],
            None => self
                .ledger
                .list(500)?
                .get("tasks")
                .and_then(Value::as_list)
                .unwrap_or_default()
                .iter()
                .filter_map(|task| task.as_dict()?.get("id").map(Value::py_str))
                .collect(),
        };
        for task_id in candidates {
            let task = self.task(&task_id)?;
            if !last_run(&task).is_some_and(|run| run_id_of(run).is_str(run_id)) {
                continue;
            }
            let identity = process_identity(i64::from(pid));
            self.ledger.update(&task_id, |task| {
                edit_last_run(task, |run| {
                    run.insert("worker_pid", i64::from(pid));
                    run.insert("process_identity", identity.clone());
                });
                Ok((
                    "process_started".to_string(),
                    Value::Str(run_id.to_string()),
                    None,
                    (),
                ))
            })?;
            break;
        }
        Ok(())
    }

    /// `review(task_id, run_id=…, approve=…, summary=…)` with the request
    /// body's values: `{"task": …}`.
    pub fn review(
        &self,
        task_id: &str,
        run_id: &Value,
        approve: &Value,
        summary: &Value,
    ) -> Result<Dict> {
        let (Value::Bool(approve), Value::Str(summary)) = (approve, summary) else {
            return Err(invalid(
                "Review requires approve true/false and an evidence-based summary",
            ));
        };
        let summary = py_strip(summary);
        if summary.is_empty() {
            return Err(invalid(
                "Review requires approve true/false and an evidence-based summary",
            ));
        }
        let approve = *approve;
        let storage = self.personal_storage.clone();
        let (task, references) = {
            let _guard = self.guard();
            let mut failure: Option<Error> = None;
            let updated = self.ledger.update(task_id, |task| {
                let attempt = (|| -> Result<(Value, bool, Vec<Dict>)> {
                    let Some(run) = last_run(task).cloned() else {
                        return Err(invalid(
                            "Review must target the current General run awaiting review",
                        ));
                    };
                    if status(task) != "awaiting_review" || !py_eq(&run_id_of(&run), run_id) {
                        return Err(invalid(
                            "Review must target the current General run awaiting review",
                        ));
                    }
                    let workspace = PathBuf::from(
                        run.get("workspace_path").map(Value::py_str).unwrap_or_default(),
                    );
                    let recorded = run
                        .get("artifact_manifest")
                        .cloned()
                        .unwrap_or(Value::List(Vec::new()));
                    let mut references = Vec::new();
                    if approve {
                        let paths: Vec<Value> = recorded
                            .as_list()
                            .unwrap_or_default()
                            .iter()
                            .map(|item| {
                                item.as_dict()
                                    .and_then(|item| item.get("path"))
                                    .cloned()
                                    .unwrap_or(Value::Null)
                            })
                            .collect();
                        let actual = manifest(&workspace, &Value::List(paths))?;
                        let actual_value =
                            Value::List(actual.iter().cloned().map(Value::Dict).collect());
                        if !py_eq(&actual_value, &recorded) {
                            return Err(invalid(
                                "Artifacts changed after execution; reject this run and retry before approval",
                            ));
                        }
                        if let Some(storage) = &storage {
                            for item in &actual {
                                let path = item.get("path").map(Value::py_str).unwrap_or_default();
                                let sha = item.get("sha256").map(Value::py_str).unwrap_or_default();
                                let identity = format!(
                                    "general-{}",
                                    &hex_digest(
                                        format!("{task_id}/{}/{path}", run_id.py_str()).as_bytes()
                                    )[..40]
                                );
                                let registered = storage.register_file(
                                    &workspace.join(&path),
                                    &identity,
                                    false,
                                    false,
                                    false,
                                )?;
                                if !registered.get("sha256").is_some_and(|value| value.is_str(&sha)) {
                                    return Err(invalid(
                                        "Artifacts changed during review; original outputs are preserved",
                                    ));
                                }
                                let mut reference = Dict::new();
                                reference.insert("path", path);
                                reference.insert("artifact_id", identity);
                                reference.insert("sha256", sha);
                                references.push(reference);
                            }
                        }
                    }
                    let mut review = Dict::new();
                    review.insert("approved", approve);
                    review.insert("summary", summary);
                    review.insert("reviewed_at", sql::now());
                    review.insert("artifact_manifest", recorded);
                    Ok((Value::Dict(review), approve && storage.is_some(), references))
                })();
                match attempt {
                    Ok((review, with_references, references)) => {
                        let state = if approve { "done" } else { "changes_requested" };
                        edit_last_run(task, |run| {
                            if with_references {
                                run.insert(
                                    "artifact_references",
                                    Value::List(
                                        references.iter().cloned().map(Value::Dict).collect(),
                                    ),
                                );
                            }
                            run.insert("review", review.clone());
                            run.insert("state", state);
                        });
                        task.insert("status", state);
                        let detail = review.as_dict().cloned();
                        Ok((
                            "reviewed".to_string(),
                            run_id.clone(),
                            detail,
                            references,
                        ))
                    }
                    Err(error) => {
                        failure = Some(error);
                        Err(relay_store::Error::Invalid("review refused".to_string()))
                    }
                }
            });
            match (updated, failure) {
                (_, Some(error)) => return Err(error),
                (Err(error), None) => return Err(error.into()),
                (Ok((task, references)), None) => (task, references),
            }
        };
        // The durable task receipt exists before duplicate source files are
        // removed; storage approval and upload stay a separate user action.
        if approve && let Some(storage) = &storage {
            let workspace = PathBuf::from(
                last_run(&task)
                    .and_then(|run| run.get("workspace_path"))
                    .map(Value::py_str)
                    .unwrap_or_default(),
            );
            for reference in references {
                let path =
                    workspace.join(reference.get("path").map(Value::py_str).unwrap_or_default());
                let sha = reference
                    .get("sha256")
                    .map(Value::py_str)
                    .unwrap_or_default();
                let Ok(content) = fs::read(&path) else {
                    continue;
                };
                if hex_digest(&content) != sha {
                    continue;
                }
                let artifact_id = reference
                    .get("artifact_id")
                    .map(Value::py_str)
                    .unwrap_or_default();
                // Both verified copies remain safe if cleanup cannot complete.
                let _ = storage.register_file(&path, &artifact_id, false, false, true);
            }
        }
        Ok(wrap("task", task))
    }

    /// `artifact(task_id, run_id=…, artifact_id=…)`: materializes one
    /// reviewed output; never approves or uploads it.
    pub fn artifact(&self, task_id: &str, run_id: &Value, artifact_id: &Value) -> Result<Dict> {
        let Some(storage) = &self.personal_storage else {
            return Err(invalid("Personal file storage is unavailable"));
        };
        let task = {
            let _guard = self.guard();
            self.task(task_id)?
        };
        let run = runs(&task)
            .iter()
            .filter_map(Value::as_dict)
            .find(|run| py_eq(&run_id_of(run), run_id));
        let approved = run
            .and_then(|run| run.get("review"))
            .and_then(Value::as_dict)
            .and_then(|review| review.get("approved"))
            .is_some_and(Value::truthy);
        let Some(run) = run.filter(|_| approved) else {
            return Err(invalid("Only reviewed General outputs can be retrieved"));
        };
        let reference = run
            .get("artifact_references")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter_map(Value::as_dict)
            .find(|item| {
                item.get("artifact_id")
                    .is_some_and(|id| py_eq(id, artifact_id))
            });
        let Some(reference) = reference else {
            return Err(invalid(
                "The requested artifact does not belong to this General run",
            ));
        };
        let artifact_id = artifact_id.py_str();
        let sha = reference
            .get("sha256")
            .map(Value::py_str)
            .unwrap_or_default();
        storage.read(&artifact_id, &sha)?;
        let materialized = storage.reference(&artifact_id, &sha)?;
        let local = materialized
            .get("local_path")
            .map(Value::py_str)
            .unwrap_or_default();
        let absolute = storage.root().join(local);
        let mut answer = Dict::new();
        answer.insert("reference", Value::Dict(materialized));
        answer.insert("absolute_path", absolute.to_string_lossy().into_owned());
        Ok(answer)
    }

    /// `cancel(task_id, run_id=…)`: `{"task": …}`.
    pub fn cancel(&self, task_id: &str, run_id: &Value) -> Result<Dict> {
        let _guard = self.guard();
        let task = self.task(task_id)?;
        if !matches!(run_id, Value::Null)
            && !last_run(&task).is_some_and(|run| py_eq(&run_id_of(run), run_id))
        {
            return Err(invalid("Cancellation must target the current General run"));
        }
        if matches!(status(&task), "done" | "canceled") {
            return Ok(wrap("task", task));
        }
        if status(&task) == "in_progress" {
            let active = last_run(&task)
                .map(run_id_of)
                .unwrap_or(Value::Null)
                .py_str();
            if let Some(cancelled) = lock(&self.cancellations).get(&active) {
                cancelled.set();
            }
            if let Some(pid) = lock(&self.processes).get(&active).copied() {
                terminate_group(pid);
            }
        } else if let Some(previous) = last_run(&task).filter(|run| preserved_process(run)) {
            // Verify creation identity before touching a process inherited
            // from an older daemon.
            let identity = previous
                .get("process_identity")
                .cloned()
                .unwrap_or(Value::Null);
            let pid = previous
                .get("worker_pid")
                .and_then(Value::py_int)
                .unwrap_or(0);
            if !identity.truthy() || !py_eq(&process_identity(pid), &identity) {
                return Err(invalid(
                    "The previous worker may still be running, but its identity cannot be verified. No process was canceled; retry after it exits.",
                ));
            }
            // SAFETY: killpg only sends a signal.
            unsafe {
                libc::killpg(pid as libc::pid_t, libc::SIGTERM);
            }
        } else {
            return self.finish_cancel(task_id, run_id, false);
        }
        self.finish_cancel(task_id, run_id, true)
    }

    fn finish_cancel(&self, task_id: &str, run_id: &Value, mark_run: bool) -> Result<Dict> {
        let (task, ()) = self.ledger.update(task_id, |task| {
            if mark_run {
                edit_last_run(task, |run| {
                    run.insert("state", "canceled");
                    run.insert("ended_at", sql::now());
                });
            }
            task.insert("status", "canceled");
            Ok(("canceled".to_string(), run_id.clone(), None, ()))
        })?;
        Ok(wrap("task", task))
    }
}

fn runs_push(task: &mut Dict, run: Value) {
    let mut list = runs(task).to_vec();
    list.push(run);
    task.insert("runs", Value::List(list));
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `_prompt(task)`: the instructions a General worker reads on stdin.
pub fn prompt(task: &Dict) -> String {
    let mut shown = Dict::new();
    for key in ["id", "title", "description", "acceptance_criteria"] {
        shown.insert(key, task.get(key).cloned().unwrap_or(Value::Null));
    }
    format!(
        "You are a Relay Runner General task worker. Work only on this bounded task in the current \
         managed output directory. This is not a source repository; do not initialize Git, edit project \
         boards, dispatch workers, or commit. Preserve unrelated files and accepted work. \
         Task classification does not authorize sending messages, publishing, purchasing, deleting \
         existing user data or other external effects. If completing the task needs an effect not \
         explicitly authorized in the description, stop with an exact blocker instead of doing it. \
         Create local drafts for review. Do not copy credentials, machine logs or provider transcripts \
         into artifacts. Do not change your task's canonical lifecycle.\n\n{}\n\nWhen finished, write \
         result.json containing {{\"summary\":\"...\", \"criteria\":[{{\"criterion\":\"exact acceptance \
         criterion\", \"evidence\":\"specific result and validation\"}}], \"artifacts\":[\"relative/output.md\"]}}. \
         Cover each criterion exactly once. Include all deliverable files, not worker.log or result.json. \
         Outputs remain pending PM review. If blocked, exit without a success result and write a local \
         blocker.md explaining the resume path.\n",
        sql::dumps_indent(&Value::Dict(shown))
    )
}

/// `Path(relative).parts`, as pathlib normalises them (no `.`, no empty
/// segments).
fn parts(relative: &str) -> Vec<String> {
    Path::new(relative)
        .components()
        .filter_map(|component| match component {
            Component::CurDir => None,
            Component::RootDir => Some("/".to_string()),
            Component::ParentDir => Some("..".to_string()),
            Component::Normal(part) => Some(part.to_string_lossy().into_owned()),
            Component::Prefix(prefix) => Some(prefix.as_os_str().to_string_lossy().into_owned()),
        })
        .collect()
}

/// `_manifest(workspace, paths)`: each declared artifact's size and digest.
pub fn manifest(workspace: &Path, paths: &Value) -> Result<Vec<Dict>> {
    let declared: Option<Vec<&str>> = match paths {
        Value::List(items) if !items.is_empty() => items.iter().map(Value::as_str).collect(),
        _ => None,
    };
    let Some(declared) = declared else {
        return Err(invalid(
            "Worker result must name at least one local artifact",
        ));
    };
    let workspace_resolved = fs::canonicalize(workspace).ok();
    let mut manifest = Vec::new();
    for relative in declared {
        let parts = parts(relative);
        if relative.starts_with('/')
            || parts.iter().any(|part| part == "..")
            || relative == "result.json"
            || relative == "worker.log"
        {
            return Err(invalid(
                "Worker artifact path is outside its output contract",
            ));
        }
        let mut prefix = workspace.to_path_buf();
        for part in &parts {
            prefix.push(part);
            if prefix.is_symlink() {
                return Err(invalid("Worker artifacts cannot contain symlinks"));
            }
        }
        let candidate = workspace.join(parts.iter().collect::<PathBuf>());
        let inside = match (fs::canonicalize(&candidate), &workspace_resolved) {
            (Ok(resolved), Some(root)) => resolved.starts_with(root),
            _ => false,
        };
        if !inside || !candidate.is_file() {
            return Err(invalid(
                "Worker artifact is missing or outside its managed run",
            ));
        }
        let content = fs::read(&candidate)?;
        let mut item = Dict::new();
        item.insert("path", relative);
        item.insert("size_bytes", content.len() as i64);
        item.insert("sha256", hex_digest(&content));
        manifest.push(item);
    }
    let mut seen = std::collections::HashSet::new();
    if !manifest
        .iter()
        .all(|item| seen.insert(item.get("path").map(Value::py_str).unwrap_or_default()))
    {
        return Err(invalid("Worker artifacts must be unique"));
    }
    Ok(manifest)
}

/// `_validate_result(task, workspace)`: the worker's `result.json` and the
/// manifest of the artifacts it names.
pub fn validate_result(task: &Dict, workspace: &Path) -> Result<(Dict, Vec<Dict>)> {
    let path = workspace.join("result.json");
    let bounded = fs::metadata(&path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.size() <= RESULT_MAX_BYTES);
    if path.is_symlink() || !bounded {
        return Err(invalid(
            "Worker did not produce a valid bounded result.json",
        ));
    }
    let content = fs::read(&path)?;
    let parsed = std::str::from_utf8(&content)
        .ok()
        .and_then(json::parse_strict)
        .ok_or_else(|| invalid("Worker result.json is not valid JSON"))?;
    let result = match parsed {
        Value::Dict(result)
            if result
                .get("summary")
                .and_then(Value::as_str)
                .is_some_and(|summary| !py_strip(summary).is_empty()) =>
        {
            result
        }
        _ => return Err(invalid("Worker result needs a summary")),
    };
    let criteria = match result.get("criteria") {
        Some(Value::List(items))
            if items.iter().all(|item| {
                item.as_dict()
                    .and_then(|item| item.get("evidence"))
                    .and_then(Value::as_str)
                    .is_some_and(|evidence| !py_strip(evidence).is_empty())
            }) =>
        {
            items.clone()
        }
        _ => {
            return Err(invalid(
                "Worker result needs evidence for each acceptance criterion",
            ));
        }
    };
    let mut declared: Vec<Value> = criteria
        .iter()
        .map(|item| {
            item.as_dict()
                .and_then(|item| item.get("criterion"))
                .cloned()
                .unwrap_or(Value::Null)
        })
        .collect();
    declared.sort_by_key(Value::py_str);
    let mut expected: Vec<Value> = task
        .get("acceptance_criteria")
        .and_then(Value::as_list)
        .unwrap_or_default()
        .to_vec();
    expected.sort_by_key(Value::py_str);
    if !py_eq(&Value::List(declared), &Value::List(expected)) {
        return Err(invalid(
            "Worker result must cover every acceptance criterion exactly once",
        ));
    }
    let artifacts = result.get("artifacts").cloned().unwrap_or(Value::Null);
    let manifest = manifest(workspace, &artifacts)?;
    Ok((result, manifest))
}

/// `_process_identity(pid)`: the process's start time from `ps`, or `None`.
pub fn process_identity(pid: i64) -> Value {
    let child = Command::new("/bin/ps")
        .args(["-p", &pid.to_string(), "-o", "lstart="])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        return Value::Null;
    };
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let mut output = String::new();
                if let Some(mut stdout) = child.stdout.take() {
                    let _ = stdout.read_to_string(&mut output);
                }
                return if status.success() {
                    Value::Str(py_strip(&output).to_string())
                } else {
                    Value::Null
                };
            }
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Value::Null;
            }
        }
    }
}

/// `_preserved_process(run)`: whether the run's recorded worker may still
/// be alive, so it must not be replayed.
pub fn preserved_process(run: &Dict) -> bool {
    let pid = run.get("worker_pid").unwrap_or(&Value::Null);
    if !pid.truthy() {
        return false;
    }
    let Some(pid) = pid.py_int() else {
        return false;
    };
    let identity = run.get("process_identity").unwrap_or(&Value::Null);
    let current = process_identity(pid);
    if current.truthy() {
        return !identity.truthy() || py_eq(&current, identity);
    }
    // Identity is unavailable; do not replay a possibly live worker.
    // SAFETY: signal 0 only checks that the process exists.
    let alive = unsafe { libc::kill(pid as libc::pid_t, 0) } == 0;
    alive || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

/// `_terminate(proc)`: SIGTERM to the group, SIGKILL after three seconds.
fn terminate_group(pid: u32) {
    let group = pid as libc::pid_t;
    // SAFETY: killpg and kill only send signals.
    unsafe {
        if libc::killpg(group, libc::SIGTERM) != 0 {
            return;
        }
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        // SAFETY: as above.
        if unsafe { libc::kill(group, 0) } != 0 {
            return;
        }
        thread::sleep(Duration::from_millis(20));
    }
    // SAFETY: as above.
    unsafe {
        libc::killpg(group, libc::SIGKILL);
    }
}

fn exit_status(status: std::process::ExitStatus) -> i32 {
    status
        .code()
        .unwrap_or_else(|| status.signal().map_or(-1, |signal| -signal))
}

/// `[Errno N] <strerror>: '<program>'`, as Python reports a failed `Popen`.
fn spawn_error(error: &std::io::Error, program: &str) -> Error {
    let message = match error.raw_os_error() {
        Some(code) => {
            let text = std::io::Error::from_raw_os_error(code).to_string();
            let text = text
                .rsplit_once(" (os error")
                .map_or(text.as_str(), |(text, _)| text)
                .to_string();
            format!("[Errno {code}] {text}: {}", json::str_repr(program))
        }
        None => error.to_string(),
    };
    Error::new("OSError", message)
}

/// `_run_process`: runs the command in its own session in the run's
/// workspace, with the General worker environment, the prompt on stdin and
/// output in `worker.log`.
pub struct ProcessRunner;

impl Runner for ProcessRunner {
    fn run(
        &self,
        work: &GeneralWork,
        command: &[String],
        workspace: &Path,
        prompt: &str,
        run_id: &str,
        cancelled: &Cancellation,
    ) -> Result<i32> {
        if cancelled.is_set() {
            return Ok(SIGTERM_STATUS);
        }
        let Some((program, arguments)) = command.split_first() else {
            return Err(Error::new("IndexError", "list index out of range"));
        };
        let environment = general_worker_environment(Some(&work.root().join("files")));
        let log = fs::File::create(workspace.join("worker.log"))?;
        let mut builder = Command::new(program);
        builder
            .args(arguments)
            .current_dir(workspace)
            .env_clear()
            .envs(environment)
            .stdin(Stdio::piped())
            .stdout(log.try_clone()?)
            .stderr(log);
        // SAFETY: setsid is async-signal-safe, as `start_new_session` needs.
        unsafe {
            builder.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child: Child = builder
            .spawn()
            .map_err(|error| spawn_error(&error, program))?;
        let pid = child.id();
        let outcome = (|| -> Result<i32> {
            work.record_process(run_id, pid)?;
            if cancelled.is_set() {
                terminate_group(pid);
            }
            if let Some(mut stdin) = child.stdin.take() {
                // A worker that exits without reading its prompt closes the pipe.
                let _ = stdin.write_all(prompt.as_bytes());
            }
            Ok(exit_status(child.wait()?))
        })();
        if matches!(child.try_wait(), Ok(None)) {
            terminate_group(pid);
            let _ = child.wait();
        }
        outcome
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_environment_drops_metered_and_session_identity() {
        let environment: Vec<(OsString, OsString)> = [
            ("PATH", "/bin"),
            ("ANTHROPIC_API_KEY", "secret"),
            ("OPENAI_API_KEY", "secret"),
            ("RELAY_PROJECT_SCOPE_TOKEN", "token"),
            ("RELAY_SESSION_SCOPE", "project"),
            ("RELAY_CONTEXT_ID", "c"),
            ("RELAY_APP_SESSION_ID", "s"),
            ("HOME", "/Users/me"),
        ]
        .into_iter()
        .map(|(key, value)| (key.into(), value.into()))
        .collect();
        let kept = general_worker_environment_from(environment, Some(Path::new("/state/files")));
        let keys: Vec<String> = kept
            .iter()
            .map(|(key, _)| key.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            keys,
            [
                "PATH",
                "HOME",
                "RELAY_SESSION_SCOPE",
                "RELAY_GENERAL_FILES_ROOT"
            ]
        );
        assert_eq!(kept[2].1, "general");
        assert_eq!(kept[3].1, "/state/files");
    }

    #[test]
    fn uuid_hex_is_version_four() {
        let id = uuid4_hex().unwrap();
        assert_eq!(id.len(), 32);
        assert_eq!(&id[12..13], "4");
        assert!("89ab".contains(&id[16..17]));
    }

    #[test]
    fn parts_follow_pathlib() {
        assert_eq!(parts("./a//b/"), ["a", "b"]);
        assert_eq!(parts("../x"), ["..", "x"]);
    }
}
