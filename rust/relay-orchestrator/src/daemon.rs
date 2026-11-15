//! `Daemon.__init__`: the paths, stores and shared services every route
//! uses, opened as the Python daemon opens them so the two can take turns on
//! one data root.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, Weak};
use std::time::Duration;

use relay_artifacts::lifecycle::ArtifactLifecycleCoordinator;
use relay_artifacts::rollout::ArtifactRolloutStore;
use relay_artifacts::store::{ArtifactStore, StoreOptions};
use relay_artifacts::{paths, toml};
use relay_intents::json::{Dict, Value};
use relay_services::continuity::lifecycle::ContinuityLifecycleAdapter;
use relay_services::general_work::GeneralWork;
use relay_services::notes::NoteManager;
use relay_services::notes::global::GlobalNoteLibrary;
use relay_services::notes::metadata::{NoteMetadataGenerator, NoteMetadataQueue};
use relay_services::notes::project::ProjectNoteManager;
use relay_services::personal_storage::PersonalFileStorage;
use relay_store::commands::CommandStore;
use relay_store::continuity::ContinuityReportStore;
use relay_store::followups::FollowupProposalStore;
use relay_store::messenger::MessengerOutcomeStore;
use relay_store::queue_drains::QueueDrainStore;
use relay_store::runs::RunsStore;
use relay_store::sessions::SessionStore;

use crate::failure::{Class, Failure, Outcome};
use crate::worker::RunProcess;

pub const DEFAULT_PORT: u16 = 7634;
pub const DEFAULT_WORKER_HEALTH_CHECK_SECONDS: f64 = 600.0;

/// Locks a mutex, taking it over from a panicked holder as Python would
/// carry on.
pub fn guard<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// Every file the daemon shares with an installed copy, after the isolation
/// switches of docs/specs/orchestrator-http-api.md.
#[derive(Clone, Debug)]
pub struct Paths {
    /// `RELAY_ORCHESTRATOR_DATA_ROOT`: the databases and `runs.json`.
    pub data_root: PathBuf,
    /// The data root's parent when it is named `orchestrator`: the registry,
    /// artifact state, notes, personal storage and General work.
    pub state_root: PathBuf,
    /// `RELAY_ORCHESTRATOR_RUNTIME_DIR`, default `/tmp`.
    pub runtime_dir: PathBuf,
    pub port_file: PathBuf,
    pub command_state_file: PathBuf,
    pub authorization_file: PathBuf,
    pub session_spool_root: PathBuf,
    pub voice_state_sock: PathBuf,
    pub bridge_control_sock: PathBuf,
    /// `<state root>/projects/registry-v2.json`, owned by the app.
    pub registry_v2: PathBuf,
    /// `<data root>/../program/projects.json`, the pre-v2 registry.
    pub program_registry: PathBuf,
    pub workspace_root: PathBuf,
    pub workflow_path: PathBuf,
    /// `services/orchestrator_artifact_workflow.md`: the worker prompt of an
    /// artifact-enabled project.
    pub artifact_workflow_path: PathBuf,
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn expand(text: &str) -> PathBuf {
    PathBuf::from(paths::expanduser(text).unwrap_or_else(|_| text.to_string()))
}

impl Paths {
    /// The paths for the configured `workspace_root` and
    /// `default_workflow_path` (empty for their defaults).
    pub fn from_environment(workspace_root: &str, workflow_path: &str) -> Self {
        let data_root = relay_store::daemon::data_root();
        let state_root = relay_store::daemon::state_root(&data_root);
        let runtime_dir =
            env_path("RELAY_ORCHESTRATOR_RUNTIME_DIR").unwrap_or_else(|| PathBuf::from("/tmp"));
        let port_file = env_path("RELAY_ORCHESTRATOR_PORT_FILE")
            .unwrap_or_else(|| runtime_dir.join("relay_orchestrator.port"));
        let bridge_control_sock = std::env::var_os("BRIDGE_CONTROL_SOCK")
            .map(PathBuf::from)
            .unwrap_or_else(|| runtime_dir.join("voice_bridge.sock"));
        let workspace_root = if workspace_root.is_empty() {
            data_root.join("workspaces")
        } else {
            expand(workspace_root)
        };
        let user_workflow = data_root.join("WORKFLOW.md");
        let workflow_path = if !workflow_path.is_empty() {
            expand(workflow_path)
        } else if user_workflow.exists() {
            user_workflow
        } else {
            bundled_service_file("orchestrator_workflow.md")
        };
        let program_registry = data_root
            .parent()
            .map_or_else(|| PathBuf::from("program"), Path::to_path_buf)
            .join("program")
            .join("projects.json");
        Self {
            registry_v2: state_root.join("projects").join("registry-v2.json"),
            command_state_file: runtime_dir.join("voice_command_state.json"),
            authorization_file: runtime_dir.join("voice_command_authorizations.json"),
            session_spool_root: runtime_dir.join("relay-sessions"),
            voice_state_sock: runtime_dir.join("voice_state.sock"),
            program_registry,
            bridge_control_sock,
            port_file,
            runtime_dir,
            workspace_root,
            workflow_path,
            artifact_workflow_path: bundled_service_file("orchestrator_artifact_workflow.md"),
            state_root,
            data_root,
        }
    }

    /// `_registered_projects_path`: the v2 registry unless
    /// `RELAY_RUNNER_REGISTRY_V2` turns it off.
    pub fn registered_projects(&self) -> &Path {
        let enabled = std::env::var("RELAY_RUNNER_REGISTRY_V2").map_or(true, |value| {
            matches!(
                value.to_lowercase().as_str(),
                "1" | "true" | "yes" | "enabled"
            )
        });
        if enabled {
            &self.registry_v2
        } else {
            &self.program_registry
        }
    }
}

/// A file of `services/` beside the Python daemon (`orchestrator_workflow.md`,
/// `orchestrator_artifact_workflow.md`). The Rust binary looks for it in the
/// app bundle's `services/` directory next to `Contents/MacOS`, then in the
/// source checkout it was built from.
fn bundled_service_file(name: &str) -> PathBuf {
    if let Ok(executable) = std::env::current_exe()
        && let Some(directory) = executable.parent()
    {
        for candidate in [
            directory.join("../Resources/services").join(name),
            directory.join("../SharedSupport/services").join(name),
        ] {
            if candidate.exists() {
                return candidate;
            }
        }
    }
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../services")
        .join(name)
}

/// The TOML configuration as the JSON dict the Python code reads.
pub fn toml_to_json(value: &toml::Value) -> Value {
    match value {
        toml::Value::String(text) => Value::Str(text.clone()),
        toml::Value::Integer(number) => Value::Int(*number),
        toml::Value::BigInteger(digits) => Value::BigInt(digits.clone()),
        toml::Value::Float(number) => Value::Float(*number),
        toml::Value::Boolean(flag) => Value::Bool(*flag),
        toml::Value::Datetime(datetime) => Value::Str(datetime.py_str()),
        toml::Value::Array(items) => Value::List(items.iter().map(toml_to_json).collect()),
        toml::Value::Table(table) => Value::Dict(table_to_json(table)),
    }
}

pub fn table_to_json(table: &toml::Table) -> Dict {
    let mut dict = Dict::new();
    for (key, value) in table.iter() {
        dict.insert(key, toml_to_json(value));
    }
    dict
}

/// `load_config(path)` as a JSON dict; `None` reads `--config` from the
/// process arguments, as `load_config()` does.
pub fn load_config(path: Option<&Path>) -> Outcome<Dict> {
    let table = relay_artifacts::config::load_config(path, None, false)?;
    Ok(table_to_json(&table))
}

/// `"daemon-" + sha256(f"{hostname}:{data}")[:24]`.
pub fn device_id(data_root: &Path) -> String {
    let digest = relay_intents::sha256::hex_digest(
        format!("{}:{}", hostname(), data_root.display()).as_bytes(),
    );
    format!("daemon-{}", &digest[..24])
}

/// `socket.gethostname()`.
pub fn hostname() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer outlives the call and its length is passed.
    let result = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if result != 0 {
        return String::new();
    }
    let end = buffer
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(buffer.len());
    String::from_utf8_lossy(&buffer[..end]).into_owned()
}

/// `_agent_kind(raw)`.
pub fn agent_kind(raw: Option<&str>) -> &'static str {
    let value = raw.unwrap_or("codex").trim().to_lowercase();
    let value = if value.is_empty() {
        "codex".to_string()
    } else {
        value
    };
    let name = value.rsplit('/').next().unwrap_or_default();
    if name.contains("claude") {
        "claude"
    } else {
        "codex"
    }
}

fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

/// `shutil.which(name)`.
pub fn which(name: &str) -> Option<String> {
    if name.contains('/') {
        return executable(Path::new(name)).then(|| name.to_string());
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| executable(candidate))
        .map(|candidate| candidate.to_string_lossy().into_owned())
}

/// `_find_agent_bin(agent, configured)`; a `RuntimeError` when none is found.
pub fn find_agent_bin(agent: &str, configured: &str) -> Outcome<String> {
    if !configured.is_empty() {
        let expanded = expand(configured);
        if expanded.to_string_lossy().contains('/') && executable(&expanded) {
            return Ok(expanded.to_string_lossy().into_owned());
        }
        if let Some(found) = which(configured) {
            return Ok(found);
        }
        return Err(Failure::runtime(format!(
            "{agent} CLI not found: {configured}"
        )));
    }
    if agent == "claude" {
        if let Some(found) = which("claude") {
            return Ok(found);
        }
        let fallback = expand("~/.local/bin/claude");
        if executable(&fallback) {
            return Ok(fallback.to_string_lossy().into_owned());
        }
        return Err(Failure::runtime(
            "claude CLI not found on PATH or at ~/.local/bin/claude",
        ));
    }
    for candidate in [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
    ] {
        if executable(Path::new(candidate)) {
            return Ok(candidate.to_string());
        }
    }
    which("codex").ok_or_else(|| {
        Failure::runtime("codex CLI not found on PATH or in the ChatGPT/Codex applications")
    })
}

/// `str(d.get(key) or default)` for a config table.
pub fn config_text(table: &Dict, key: &str, default: &str) -> String {
    match table.get(key) {
        Some(value) if value.truthy() => value.py_str(),
        _ => default.to_string(),
    }
}

/// `cfg.get(name, {})` when it is a table.
pub fn config_table(config: &Dict, name: &str) -> Dict {
    config
        .get(name)
        .and_then(Value::as_dict)
        .cloned()
        .unwrap_or_default()
}

/// The per-project artifact lifecycle coordinators, shared with the notes
/// library's legacy-source lookup.
pub struct Lifecycles {
    pub state_root: PathBuf,
    pub registry_v2: PathBuf,
    pub device_id: String,
    pub rollout: ArtifactRolloutStore,
    cache: Mutex<HashMap<String, Arc<ArtifactLifecycleCoordinator>>>,
}

impl Lifecycles {
    /// `_artifact_lifecycle(repo_path)`: the coordinator of an
    /// artifact-enabled project, `None` for a legacy board (or a path with
    /// no readable board config).
    pub fn get(&self, repo_path: &str) -> Outcome<Option<Arc<ArtifactLifecycleCoordinator>>> {
        let repo = resolve_path(repo_path);
        let config_path = repo.join(".orchestrator").join("config.toml");
        let Ok(content) = std::fs::read(&config_path) else {
            return Ok(None);
        };
        let Ok(text) = String::from_utf8(content) else {
            return Ok(None);
        };
        let Ok(config) = toml::loads(&text) else {
            return Ok(None);
        };
        let lifecycle = config
            .get("artifact_lifecycle")
            .map(toml_to_json)
            .unwrap_or_else(|| Value::from("legacy"));
        if !relay_intents::json::py_eq(&lifecycle, &Value::from("enabled")) {
            return Ok(None);
        }
        let project_id = config
            .get("project_id")
            .map(toml_to_json)
            .filter(Value::truthy)
            .map(|value| value.py_str())
            .unwrap_or_default();
        let project_id = project_id.trim().to_string();
        if project_id.is_empty() {
            return Err(Failure::value(
                "artifact lifecycle config has no immutable project_id",
            ));
        }
        let decision = self.rollout.decision(&project_id, "existing", true)?;
        if !decision.artifact_writes_enabled {
            return Err(Failure::new(
                Class::Rollout {
                    code: Some(decision.reason_code.clone()),
                    recovery: Some(
                        "Review the per-project opt-in and cohort failure, then explicitly opt in \
                         or resume only after writers are drained and synchronization is safe."
                            .to_string(),
                    ),
                },
                format!(
                    "Artifact lifecycle is blocked by rollout policy ({}).",
                    decision.reason_code
                ),
            ));
        }
        let key = repo.to_string_lossy().into_owned();
        let mut cache = guard(&self.cache);
        if let Some(existing) = cache.get(&key)
            && existing.store.project_id == project_id
        {
            return Ok(Some(existing.clone()));
        }
        let store = ArtifactStore::open(
            &repo,
            &project_id,
            &self.state_root,
            StoreOptions {
                enabled: true,
                ..StoreOptions::default()
            },
        )?;
        if !ArtifactLifecycleCoordinator::is_enabled(&store)? {
            return Ok(None);
        }
        let coordinator = Arc::new(ArtifactLifecycleCoordinator::new(
            store,
            &self.registry_v2,
            &self.device_id,
            None,
        )?);
        cache.insert(key, coordinator.clone());
        Ok(Some(coordinator))
    }

    /// `_legacy_note_sources`: every registered artifact project's note
    /// manager, for the global library's one-time import.
    pub fn note_sources(&self) -> Vec<(String, Arc<dyn NoteManager>)> {
        let Some(document) = read_json(&self.registry_v2) else {
            return Vec::new();
        };
        let mut sources: Vec<(String, Arc<dyn NoteManager>)> = Vec::new();
        for record in projects(&document) {
            let repo_path = record
                .get("last_resolved_path")
                .filter(|value| value.truthy())
                .map(Value::py_str)
                .unwrap_or_default();
            let repo_path = repo_path.trim();
            if repo_path.is_empty() {
                continue;
            }
            if let Ok(Some(lifecycle)) = self.get(repo_path)
                && let Ok(store) = reopen_store(&lifecycle.store)
            {
                let manager: Arc<dyn NoteManager> =
                    Arc::new(ProjectNoteManager::new(Arc::new(store), &self.device_id));
                sources.push((repo_path.to_string(), manager));
            }
        }
        sources
    }
}

/// A second handle on a coordinator's store, for owners that need an
/// `Arc<ArtifactStore>` (the note managers). Both write through the same
/// lock file and ref, as two Python objects over one repository do.
pub fn reopen_store(store: &ArtifactStore) -> Outcome<ArtifactStore> {
    Ok(ArtifactStore::open(
        &store.repo_path,
        &store.project_id,
        &store.state_root,
        StoreOptions {
            enabled: true,
            ..StoreOptions::default()
        },
    )?)
}

/// `Path(text).expanduser().resolve()`.
pub fn resolve_path(text: &str) -> PathBuf {
    let expanded = paths::expanduser(text).unwrap_or_else(|_| text.to_string());
    PathBuf::from(paths::resolve(&expanded))
}

/// A JSON file, or `None` when it is missing or not JSON.
pub fn read_json(path: &Path) -> Option<Value> {
    let content = std::fs::read(path).ok()?;
    relay_intents::json::parse(std::str::from_utf8(&content).ok()?)
}

/// `document.get("projects", [])`, keeping only the objects.
pub fn projects(document: &Value) -> Vec<Dict> {
    document
        .as_dict()
        .and_then(|dict| dict.get("projects"))
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .filter_map(Value::as_dict)
        .cloned()
        .collect()
}

/// `_registered_project_repo_paths(registry_path)`.
pub fn registered_project_repo_paths(registry_path: &Path) -> Vec<String> {
    let Some(Value::Dict(payload)) = read_json(registry_path) else {
        return Vec::new();
    };
    let Some(Value::List(records)) = payload.get("projects") else {
        return Vec::new();
    };
    let registry_v2 = payload
        .get("schema_version")
        .is_some_and(|version| relay_intents::json::py_eq(version, &Value::Int(2)));
    let resolved_text = |key: &str| -> Option<String> {
        let text = payload
            .get(key)
            .filter(|value| value.truthy())
            .map(Value::py_str)
            .unwrap_or_default();
        let text = text.trim();
        (!text.is_empty()).then(|| resolve_path(text).to_string_lossy().into_owned())
    };
    let active_project_path = resolved_text("activeProjectID");
    let active_workspace_root_path = resolved_text("activeWorkspaceRootID");
    let mut workspace_roots = HashSet::new();
    if let Some(Value::List(roots)) = payload.get("workspaceRoots") {
        for record in roots.iter().filter_map(Value::as_dict) {
            let raw = record
                .get("rootPath")
                .filter(|value| value.truthy())
                .or_else(|| record.get("id"))
                .filter(|value| value.truthy())
                .map(Value::py_str)
                .unwrap_or_default();
            let raw = raw.trim();
            if !raw.is_empty() {
                workspace_roots.insert(resolve_path(raw).to_string_lossy().into_owned());
            }
        }
    }
    let filtered: HashSet<String> = workspace_roots
        .into_iter()
        .filter(|path| {
            Some(path) != active_project_path.as_ref()
                || Some(path) == active_workspace_root_path.as_ref()
        })
        .collect();
    let mut repo_paths = Vec::new();
    let mut seen = HashSet::new();
    for record in records.iter().filter_map(Value::as_dict) {
        if registry_v2
            && !record
                .get("availability")
                .is_some_and(|value| value.is_str("available"))
        {
            continue;
        }
        let raw = if registry_v2 {
            record.get("last_resolved_path").cloned()
        } else {
            record
                .get("repoPath")
                .filter(|value| value.truthy())
                .or_else(|| record.get("id"))
                .cloned()
        };
        let text = raw
            .filter(Value::truthy)
            .map(|value| value.py_str())
            .unwrap_or_default();
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        let resolved = resolve_path(text).to_string_lossy().into_owned();
        if filtered.contains(&resolved) || !seen.insert(resolved.clone()) {
            continue;
        }
        repo_paths.push(resolved);
    }
    repo_paths
}

/// `_SingleFlight`: one expensive refresh at a time; callers that arrive
/// while it runs wait for, and share, its result.
pub struct SingleFlight {
    state: Mutex<FlightState>,
    condition: Condvar,
    wait: Duration,
}

#[derive(Default)]
struct FlightState {
    running: bool,
    waiters: usize,
    generation: u64,
    result: Option<Dict>,
    failure: Option<String>,
}

pub const PROGRAM_REFRESH_WAIT: Duration = Duration::from_secs(10);

impl SingleFlight {
    pub fn new(wait: Duration) -> Self {
        Self {
            state: Mutex::new(FlightState::default()),
            condition: Condvar::new(),
            wait,
        }
    }

    pub fn run(&self, operation: impl FnOnce() -> Outcome<Dict>) -> Outcome<Dict> {
        let mut state = guard(&self.state);
        if state.running {
            let generation = state.generation;
            state.waiters += 1;
            let (mut state, timeout) = self
                .condition
                .wait_timeout_while(state, self.wait, |state| state.generation == generation)
                .unwrap_or_else(|poison| poison.into_inner());
            state.waiters -= 1;
            if state.waiters == 0 {
                self.condition.notify_all();
            }
            if timeout.timed_out() && state.generation == generation {
                return Err(Failure::new(
                    Class::ProgramRefresh,
                    "Program Workspace refresh is still in progress; retry shortly.",
                ));
            }
            if let Some(failure) = &state.failure {
                return Err(Failure::new(Class::ProgramRefresh, failure.clone()));
            }
            return Ok(state.result.clone().unwrap_or_default());
        }
        let mut state = self
            .condition
            .wait_while(state, |state| state.waiters != 0)
            .unwrap_or_else(|poison| poison.into_inner());
        state.running = true;
        drop(state);
        let outcome = operation();
        let mut state = guard(&self.state);
        match &outcome {
            Ok(result) => {
                state.failure = None;
                state.result = Some(result.clone());
            }
            Err(failure) => {
                state.failure = Some(if failure.message.is_empty() {
                    "Exception".to_string()
                } else {
                    failure.message.clone()
                });
                state.result = None;
            }
        }
        state.running = false;
        state.generation += 1;
        self.condition.notify_all();
        outcome
    }
}

/// The daemon: configuration, stores and shared services.
pub struct Daemon {
    /// `cfg`, as `load_config` returned it at startup; dispatch refreshes
    /// its `[general]` table (`_effective_worker_agent`).
    pub config: Mutex<Dict>,
    pub paths: Paths,
    /// The configured port; `serve` replaces it with the bound one.
    pub port: Mutex<u16>,
    pub branch_prefix: String,
    pub worker_health_check_seconds: f64,
    pub max_concurrent_workers: i64,

    pub runs: RunsStore,
    pub queue_drains: QueueDrainStore,
    pub orchestrator_sessions: SessionStore,
    pub orchestrator_commands: CommandStore,
    pub messenger_outcomes: MessengerOutcomeStore,
    pub followup_proposals: FollowupProposalStore,
    pub continuity_reports: ContinuityReportStore,
    pub continuity_incident_path: PathBuf,
    pub continuity_agent_audit_path: PathBuf,
    pub continuity: ContinuityLifecycleAdapter,
    pub graphify_path: PathBuf,

    pub lifecycles: Arc<Lifecycles>,
    pub device_id: String,
    pub global_notes: Arc<GlobalNoteLibrary>,
    pub personal_storage: Arc<PersonalFileStorage>,
    pub general_work: Arc<GeneralWork>,
    pub note_metadata: Option<NoteMetadataQueue>,

    /// `[orchestrator] agent`, or `[general] provider`.
    pub agent_kind: String,
    /// The worker CLI found at startup or first dispatch; empty when none was.
    pub agent_bin: Mutex<String>,

    /// `_artifact_board_mutex`: board writes queue here.
    pub board_lock: Mutex<()>,
    /// `_dispatch_lock`.
    pub dispatch_lock: Mutex<()>,
    /// `_merge_lock`.
    pub merge_lock: Mutex<()>,
    /// `_ticket_authoring_lock`.
    pub authoring_lock: Mutex<()>,
    /// `_orchestrator_action_request_ids`.
    pub action_request_ids: Mutex<HashSet<String>>,
    pub program_status_flight: SingleFlight,
    pub program_dashboard_flight: SingleFlight,

    /// `_workers`: the live implementation and spike workers by run id.
    pub workers: Mutex<HashMap<i64, Arc<RunProcess>>>,
    /// `_review_workers`.
    pub review_workers: Mutex<HashMap<i64, Arc<RunProcess>>>,
    /// `_verification_closeouts`: the dependents a verification-only
    /// close-out promoted, until its worker's completion dispatches them.
    pub verification_closeouts: Mutex<HashMap<i64, Vec<String>>>,
    /// `_spike_completion_lock`.
    pub spike_completion_lock: Mutex<()>,
    /// The daemon's own handle, for the threads that run its workers.
    self_ref: OnceLock<Weak<Daemon>>,
}

impl Daemon {
    /// `Daemon(cfg)`: opens every store and runs the startup reconciliation.
    pub fn new(config: Dict) -> Outcome<Arc<Self>> {
        let orchestrator = config_table(&config, "orchestrator");
        let general = config_table(&config, "general");
        let paths = Paths::from_environment(
            &config_text(&orchestrator, "workspace_root", ""),
            &config_text(&orchestrator, "default_workflow_path", ""),
        );
        std::fs::create_dir_all(&paths.workspace_root)?;
        std::fs::create_dir_all(&paths.data_root)?;
        let float = |key: &str, default: f64| {
            orchestrator
                .get(key)
                .and_then(Value::py_float)
                .unwrap_or(default)
        };
        let port = orchestrator
            .get("port")
            .and_then(Value::py_int)
            .unwrap_or(i64::from(DEFAULT_PORT));
        let port = u16::try_from(port).unwrap_or(DEFAULT_PORT);
        let max_concurrent_workers = orchestrator
            .get("max_concurrent_workers")
            .filter(|value| value.truthy())
            .and_then(Value::py_int)
            .unwrap_or(0)
            .max(0);
        let data = &paths.data_root;
        let device = device_id(data);
        let lifecycles = Arc::new(Lifecycles {
            state_root: paths.state_root.clone(),
            registry_v2: paths.registry_v2.clone(),
            device_id: device.clone(),
            rollout: ArtifactRolloutStore::new(&paths.state_root, None)?,
            cache: Mutex::new(HashMap::new()),
        });
        let sources_owner = lifecycles.clone();
        let global_notes = Arc::new(GlobalNoteLibrary::new(
            &paths.state_root,
            &device,
            Box::new(move || sources_owner.note_sources()),
        ));
        let personal_storage = Arc::new(PersonalFileStorage::open(&paths.state_root, None, None)?);
        personal_storage.attach_notes(&global_notes)?;
        let general_work = Arc::new(GeneralWork::open(
            &paths.state_root,
            crate::general::general_work_options(&config, personal_storage.clone()),
        )?);
        let explicit_agent = config_text(&orchestrator, "agent", "");
        let explicit_agent = explicit_agent.trim();
        let agent = if explicit_agent.is_empty() {
            crate::general::provider_from_general(&general, "codex")
        } else {
            agent_kind(Some(explicit_agent)).to_string()
        };
        let agent_bin = match find_agent_bin(&agent, &config_text(&orchestrator, "command", "")) {
            Ok(path) => path,
            Err(error) => {
                eprintln!("[orchestrator] worker CLI unavailable at startup: {error}");
                String::new()
            }
        };
        let note_metadata = Some(NoteMetadataQueue::new(
            Arc::new(NoteMetadataGenerator::new(
                Box::new(|| load_config(None).unwrap_or_default()),
                Box::new(|provider: &str, configured: &str| {
                    find_agent_bin(provider, configured)
                        .map_err(|failure| relay_services::Error::runtime(failure.message))
                }),
            )),
            Duration::from_secs(2),
            128,
        ));
        let daemon = Arc::new(Self {
            port: Mutex::new(port),
            branch_prefix: config_text(&orchestrator, "branch_prefix", "relay/"),
            worker_health_check_seconds: float(
                "worker_health_check_seconds",
                DEFAULT_WORKER_HEALTH_CHECK_SECONDS,
            )
            .max(1.0),
            max_concurrent_workers,
            runs: RunsStore::open(&data.join("runs.db"), Some(&data.join("runs.json")))?,
            queue_drains: QueueDrainStore::open(&data.join("queue_drains.db"))?,
            orchestrator_sessions: SessionStore::open(&data.join("orchestrator_sessions.db"))?,
            orchestrator_commands: CommandStore::open(&data.join("orchestrator_commands.db"))?,
            messenger_outcomes: MessengerOutcomeStore::open(&data.join("messenger_outcomes.db"))?,
            followup_proposals: FollowupProposalStore::open(&data.join("followup_proposals.db"))?,
            continuity_reports: ContinuityReportStore::open(&data.join("continuity_reports.db"))?,
            continuity_incident_path: data.join("continuity_incidents.jsonl"),
            continuity_agent_audit_path: data.join("continuity_agent_events.jsonl"),
            continuity: crate::sessions::continuity_adapter(data),
            graphify_path: data.join("graphify.db"),
            device_id: device,
            lifecycles,
            global_notes,
            personal_storage,
            general_work,
            note_metadata,
            agent_kind: agent,
            agent_bin: Mutex::new(agent_bin),
            board_lock: Mutex::new(()),
            dispatch_lock: Mutex::new(()),
            merge_lock: Mutex::new(()),
            authoring_lock: Mutex::new(()),
            action_request_ids: Mutex::new(HashSet::new()),
            program_status_flight: SingleFlight::new(PROGRAM_REFRESH_WAIT),
            program_dashboard_flight: SingleFlight::new(PROGRAM_REFRESH_WAIT),
            workers: Mutex::new(HashMap::new()),
            review_workers: Mutex::new(HashMap::new()),
            verification_closeouts: Mutex::new(HashMap::new()),
            spike_completion_lock: Mutex::new(()),
            self_ref: OnceLock::new(),
            paths,
            config: Mutex::new(config),
        });
        let _ = daemon.self_ref.set(Arc::downgrade(&daemon));
        daemon.reconcile_on_startup();
        Ok(daemon)
    }

    /// A strong handle on this daemon, for a worker thread.
    pub fn arc(&self) -> Option<Arc<Daemon>> {
        self.self_ref.get().and_then(Weak::upgrade)
    }

    /// The startup half of `Daemon.__init__` after the stores open.
    fn reconcile_on_startup(&self) {
        let stalled = match self.runs.reconcile_on_startup() {
            Ok(stalled) => {
                if stalled > 0 {
                    eprintln!("[orchestrator] reconciled {stalled} stalled run(s) on startup");
                }
                stalled
            }
            Err(error) => {
                eprintln!("[orchestrator] stalled-run reconciliation failed: {error}");
                0
            }
        };
        self.recover_stalled_spikes(stalled == 0);
        // Seed the runs index so the board has something to read before the
        // first transition (the reconciliation bypasses the write hooks).
        self.runs.write_index();
        crate::board::recover_artifact_lifecycle_leases(self);
        match self
            .orchestrator_sessions
            .reconcile_stale(relay_store::sessions::STALE_AFTER_SECONDS)
        {
            Ok(stale) if stale > 0 => eprintln!(
                "[orchestrator] reconciled {stale} stale orchestrator session(s) on startup"
            ),
            Ok(_) => {}
            Err(error) => eprintln!("[orchestrator] session reconciliation failed: {error}"),
        }
        if let Err(error) = self.reconcile_queue_drains(None, Some("daemon-startup")) {
            eprintln!("[orchestrator] queue-drain startup reconcile failed: {error}");
        }
    }

    /// `cfg.get(name, {})` of the current configuration.
    pub fn config_table(&self, name: &str) -> Dict {
        config_table(&guard(&self.config), name)
    }

    /// `_effective_worker_agent()`: the worker provider, its CLI and the
    /// `[general]` table, reloading `[general]` from the config file unless
    /// `[orchestrator] agent` names the provider outright.
    pub fn effective_worker_agent(&self) -> Outcome<(String, String, Dict)> {
        let orchestrator = self.config_table("orchestrator");
        let explicit = config_text(&orchestrator, "agent", "");
        let explicit = explicit.trim();
        let mut general = self.config_table("general");
        let kind = if explicit.is_empty() {
            match load_config(None) {
                Ok(current) => {
                    if let Some(Value::Dict(table)) = current.get("general") {
                        general = table.clone();
                        guard(&self.config).insert("general", Value::Dict(table.clone()));
                    }
                }
                Err(error) => {
                    eprintln!("[orchestrator] could not reload config for dispatch: {error}");
                }
            }
            crate::general::provider_from_general(&general, &self.agent_kind)
        } else {
            agent_kind(Some(explicit)).to_string()
        };
        if kind == self.agent_kind {
            let mut binary = guard(&self.agent_bin);
            if binary.is_empty() {
                *binary = find_agent_bin(&kind, &config_text(&orchestrator, "command", ""))?;
            }
            return Ok((kind, binary.clone(), general));
        }
        let binary = find_agent_bin(&kind, "")?;
        Ok((kind, binary, general))
    }

    /// The bound port, once `serve` has bound it.
    pub fn port(&self) -> u16 {
        *guard(&self.port)
    }

    /// `_artifact_lifecycle(repo_path)`.
    pub fn artifact_lifecycle(
        &self,
        repo_path: &str,
    ) -> Outcome<Option<Arc<ArtifactLifecycleCoordinator>>> {
        self.lifecycles.get(repo_path)
    }

    /// `_artifact_board_lifecycle`: an artifact project whose scope token
    /// the caller confirmed.
    pub fn artifact_board_lifecycle(
        &self,
        repo_path: &str,
        project_scope_token: Option<&str>,
    ) -> Outcome<Arc<ArtifactLifecycleCoordinator>> {
        let lifecycle = self.artifact_lifecycle(repo_path)?.ok_or_else(|| {
            Failure::value("project is not using the artifact-backed board writer")
        })?;
        lifecycle.validate_scope(project_scope_token, None)?;
        Ok(lifecycle)
    }

    /// `shutdown`: stop the background workers, then cancel every run
    /// worker and let each record its run.
    pub fn shutdown(&self) {
        if let Some(queue) = &self.note_metadata {
            queue.shutdown();
        }
        self.cancel_workers();
    }
}
