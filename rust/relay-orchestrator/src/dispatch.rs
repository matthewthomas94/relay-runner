//! `POST /v1/runs`: `Daemon.dispatch`, with the checks and worker sizing it
//! resolves before a launch, and the launch itself (RR-498): the attempt
//! number, the worktree or read-only spike snapshot, the run claim, the
//! prompt and the worker process.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, LazyLock};

use relay_artifacts::ErrorKind;
use relay_artifacts::lifecycle::ArtifactLifecycleCoordinator;
use relay_artifacts::tickets::{self, Fields, Ticket};
use relay_intents::json::{self, Dict, Value};
use relay_intents::pattern::{self, Regex};
use relay_services::providers::catalog::{
    CODEX_DEFAULT_FAMILY, CODEX_WORKER_TIER_FAMILIES, normalize_codex_family,
};
use relay_store::commands::CommandStatus;
use relay_store::runs::{
    self as run_store, INTEGRATION_BLOCKED_RUN_STATE, NewRun, RunUpdate, SPIKE_EXECUTION_MODE,
    sanitize_identifier,
};

use crate::daemon::{Daemon, guard, resolve_path};
use crate::failure::{Failure, Outcome};
use crate::queue::{AUTO_DISPATCH_BACKOFF_SECONDS, VERIFICATION_BLOCKED_STATUS, now};
use crate::relay_command::{
    VoiceFields, mutation_metadata, optional_relay_session_key, validate_relay_command,
};
use crate::request::Request;
use crate::router::Reply;
use crate::trace::LifecycleEvent;

/// `WORKER_SIZING_FIELDS`.
pub const WORKER_SIZING_FIELDS: [&str; 4] = [
    "worker_model",
    "worker_effort",
    "worker_sizing_rationale",
    "worker_provider_notes",
];
/// `WORKER_MODEL_TIERS["claude"]`; Codex uses `CODEX_WORKER_TIER_FAMILIES`.
const CLAUDE_WORKER_TIERS: [(&str, &str); 3] = [
    ("fast", "haiku"),
    ("balanced", "sonnet"),
    ("strong", "opus"),
];
/// `CODEX_WORKER_EFFORTS`, which is also `BASE_GENERAL_EFFORTS`.
const BASE_EFFORTS: [&str; 4] = ["low", "medium", "high", "xhigh"];
/// `GENERAL_MODEL_OPTIONS["claude"]`.
const CLAUDE_GENERAL_MODELS: [&str; 6] = [
    "claude-fable-5-2",
    "claude-fable-5-1",
    "fable",
    "opus",
    "sonnet",
    "haiku",
];
/// The Claude models whose General effort may be `max`.
const CLAUDE_MAX_EFFORT_MODELS: [&str; 5] = [
    "claude-fable-5-2",
    "claude-fable-5-1",
    "fable",
    "opus",
    "sonnet",
];
/// `AUTO_DISPATCH_SOURCES`.
pub const AUTO_DISPATCH_SOURCES: [&str; 3] = [
    "ready-sweeper",
    "dependency-progression",
    "orchestrator-review-retry",
];
const DETERMINISTIC_FAILURE_PREFIXES: [&str; 6] = [
    "missing worker sizing metadata",
    "invalid worker_model",
    "invalid worker_effort",
    "worker_model",
    "ticket snapshot materialization failed",
    "worker exited 0 but did not complete ticket",
];
const DETERMINISTIC_PROVIDER_LAUNCH_MARKERS: [&str; 7] = [
    "model_reasoning_effort",
    "reasoning effort",
    "reasoning_effort",
    "--effort",
    "--model",
    "invalid value",
    "unsupported value",
];
/// `_source_checkout_blocker`'s `max_paths`.
const SOURCE_BLOCKER_MAX_PATHS: usize = 8;

static EXPLICIT_EXECUTION_MODE: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"(?m)^execution_mode:\s*\S+", false));
static REQUIRED_INPUTS: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"(?ms)^## Required inputs\s*\n(.*?)(?=^## |\z)", false));
static UNCHECKED_INPUT: LazyLock<Regex> =
    LazyLock::new(|| pattern::compile(r"(?m)^\s*- \[ \]", false));

/// The arguments of `Daemon.dispatch`.
#[derive(Clone, Debug, Default)]
pub struct DispatchRequest {
    pub ticket_id: String,
    pub repo_path: String,
    /// The caller's context for the worker prompt.
    pub context: Option<String>,
    /// `direct` from the route; the sweeps pass `ready-sweeper`.
    pub source: String,
    pub voice: VoiceFields,
    pub project_scope_token: Option<String>,
    /// A daemon-owned continuation of an already confirmed project.
    pub internally_confirmed_project_id: Option<String>,
    pub dispatcher_session_key: Option<Value>,
}

impl DispatchRequest {
    pub fn new(ticket_id: &str, repo_path: &str, source: &str) -> Self {
        Self {
            ticket_id: ticket_id.to_string(),
            repo_path: repo_path.to_string(),
            source: source.to_string(),
            ..Self::default()
        }
    }
}

/// The resolved (or, for a refusal, raw) worker sizing of a run.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct WorkerSizing {
    pub provider_key: String,
    pub model_alias: Option<String>,
    pub worker_model: Option<String>,
    pub worker_effort: Option<String>,
    pub worker_sizing_rationale: Option<String>,
    pub worker_provider_notes: Option<String>,
}

/// A source checkout's uncommitted changes, as `_source_checkout_blocker`
/// reports them.
#[derive(Clone, Debug, PartialEq)]
pub struct SourceBlocker {
    pub reason: String,
    pub dirty_paths: Vec<String>,
    pub next_step: String,
}

impl SourceBlocker {
    pub fn to_dict(&self) -> Dict {
        let mut dict = Dict::new();
        dict.insert("reason", self.reason.as_str());
        dict.insert("dirty_paths", string_values(&self.dirty_paths));
        dict.insert("next_step", self.next_step.as_str());
        dict
    }
}

/// A list of strings as a JSON list.
pub fn string_values(items: &[String]) -> Value {
    Value::List(
        items
            .iter()
            .map(|item| Value::from(item.as_str()))
            .collect(),
    )
}

/// One finished `git -C <repo> ...`, run as `subprocess.run(text=True)`.
pub struct GitOutput {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// `_git(repo, *args, check=False)`.
pub fn git(repo: &Path, arguments: &[&str]) -> Outcome<GitOutput> {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .stdin(Stdio::null())
        .output()?;
    Ok(GitOutput {
        code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

/// `_git_text(repo, *args)`: the stripped output, or on failure Git's
/// message (which callers then use as text, as Python does).
pub fn git_text(repo: &Path, arguments: &[&str]) -> Outcome<String> {
    let output = git(repo, arguments)?;
    let text = json::py_strip(&output.stdout).to_string();
    if output.code != 0 {
        let error = json::py_strip(&output.stderr);
        if !error.is_empty() {
            return Ok(error.to_string());
        }
        if !text.is_empty() {
            return Ok(text);
        }
        return Ok(format!(
            "git {} failed with exit {}",
            arguments.join(" "),
            output.code
        ));
    }
    Ok(text)
}

/// `_resolve_default_branch`: `origin/HEAD`'s branch, else `main`.
pub fn resolve_default_branch(repo: &Path) -> Outcome<String> {
    let output = git(
        repo,
        &["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
    )?;
    if output.code == 0
        && let Some(branch) = json::py_strip(&output.stdout).strip_prefix("origin/")
    {
        return Ok(branch.to_string());
    }
    Ok("main".to_string())
}

/// `_source_checkout_blocker(repo, ignore_board_metadata=...)`.
pub fn source_checkout_blocker(
    repo: &Path,
    ignore_board_metadata: bool,
) -> Outcome<Option<SourceBlocker>> {
    let status = git(
        repo,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )?;
    if status.code != 0 {
        return Ok(Some(SourceBlocker {
            reason: "source checkout cleanliness could not be verified".to_string(),
            dirty_paths: Vec::new(),
            next_step: "Restore Git status checks, then recheck integration.".to_string(),
        }));
    }
    Ok(dirty_source_blocker(
        &status.stdout,
        ignore_board_metadata,
        SOURCE_BLOCKER_MAX_PATHS,
    ))
}

/// The blocker `git status --porcelain=v1 -z` output describes, if any.
fn dirty_source_blocker(
    stdout: &str,
    ignore_board_metadata: bool,
    max_paths: usize,
) -> Option<SourceBlocker> {
    let entries: Vec<&str> = stdout
        .split('\0')
        .filter(|entry| !entry.is_empty())
        .collect();
    let mut dirty: Vec<(&str, String)> = Vec::new();
    let mut index = 0;
    while index < entries.len() {
        let entry = entries[index];
        let code: String = entry.chars().take(2).collect();
        let path: String = if entry.chars().count() > 3 {
            entry.chars().skip(3).collect()
        } else {
            String::new()
        };
        let renamed = code.contains('R') || code.contains('C');
        if ignore_board_metadata && path.starts_with(".orchestrator/") {
            index += if renamed { 2 } else { 1 };
            continue;
        }
        if !path.is_empty() {
            let quoted = json::dumps(&Value::from(path.as_str()));
            let mut safe = quoted[1..quoted.len() - 1].to_string();
            if safe.len() > 160 {
                safe = format!("{}...", &safe[..157]);
            }
            dirty.push((if code == "??" { "untracked" } else { "tracked" }, safe));
        }
        // porcelain -z puts the second rename/copy path next.
        index += if renamed { 2 } else { 1 };
    }
    if dirty.is_empty() {
        return None;
    }
    let visible = &dirty[..dirty.len().min(max_paths)];
    let labels: Vec<String> = visible
        .iter()
        .map(|(kind, path)| format!("{kind}: {path}"))
        .collect();
    let hidden = dirty.len() - visible.len();
    let suffix = if hidden > 0 {
        format!("; +{hidden} more")
    } else {
        String::new()
    };
    Some(SourceBlocker {
        reason: format!(
            "source checkout has uncommitted changes ({}{suffix})",
            labels.join("; ")
        ),
        dirty_paths: visible.iter().map(|(_, path)| path.clone()).collect(),
        next_step: "Commit or otherwise resolve the listed source-checkout changes, then \
                    recheck integration; Relay Runner will not alter them."
            .to_string(),
    })
}

/// `_dispatch_failure_signature`: whitespace collapsed, stripped, lowered.
fn dispatch_failure_signature(reason: &str) -> Option<String> {
    let mut collapsed = String::with_capacity(reason.len());
    let mut in_space = false;
    for character in reason.chars() {
        if json::py_is_space(character) {
            if !in_space {
                collapsed.push(' ');
            }
            in_space = true;
        } else {
            collapsed.push(character);
            in_space = false;
        }
    }
    let text = json::py_strip(&collapsed);
    (!text.is_empty()).then(|| text.to_lowercase())
}

/// `_is_deterministic_dispatch_failure`: a failure a retry cannot fix.
pub fn is_deterministic_dispatch_failure(reason: &str) -> bool {
    let Some(signature) = dispatch_failure_signature(reason) else {
        return false;
    };
    if DETERMINISTIC_FAILURE_PREFIXES
        .iter()
        .any(|prefix| signature.starts_with(prefix))
    {
        return true;
    }
    signature.starts_with("exit=")
        && ["http 400", "bad request", "invalid request"]
            .iter()
            .any(|marker| signature.contains(marker))
        && DETERMINISTIC_PROVIDER_LAUNCH_MARKERS
            .iter()
            .any(|marker| signature.contains(marker))
}

/// `validate_research_dispatch(ticket, contents)`: an explicit research
/// contract and no unchecked `## Required inputs`.
pub fn validate_research_dispatch(ticket: &Ticket, contents: &str) -> Outcome<()> {
    let frontmatter = contents
        .split("---")
        .nth(1)
        .ok_or_else(|| Failure::escape("list index out of range"))?;
    if ticket.title.to_lowercase().starts_with("spike:")
        && !pattern::search(&EXPLICIT_EXECUTION_MODE, frontmatter)
    {
        return Err(Failure::value(
            "Research execution mode must be explicit before dispatch: choose spike for \
             read-only findings, or implementation for writable prototypes/benchmarks.",
        ));
    }
    if let Some(inputs) = pattern::group(&REQUIRED_INPUTS, &ticket.body, 1)
        && pattern::search(&UNCHECKED_INPUT, inputs)
    {
        return Err(Failure::value(
            "Resolve the ticket's Required inputs before dispatch; no worker was started.",
        ));
    }
    Ok(())
}

/// `workspace_slug(repo_path, ticket_id)`: `<repo>-<sha1[:8]>-<ticket>`.
pub fn workspace_slug(repo: &Path, ticket_id: &str) -> Outcome<String> {
    let name = repo
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| "repo".to_string());
    let repo_name = sanitize_identifier(&name)?;
    let ticket = sanitize_identifier(ticket_id)?;
    let resolved = resolve_path(&repo.to_string_lossy());
    let digest = relay_services::notes::util::sha1_hex(resolved.to_string_lossy().as_bytes());
    Ok(format!("{repo_name}-{}-{ticket}", &digest[..8]))
}

/// `str(general.get(key) or "").strip().lower()`.
fn general_text(general: &Dict, key: &str) -> String {
    general.text(key).to_lowercase()
}

/// `_required_sizing_value(ticket, field)`.
fn required_sizing_value(ticket: &Ticket, field: &str) -> String {
    json::py_strip(ticket.raw_fields.get(field).unwrap_or_default()).to_string()
}

fn non_empty(text: String) -> Option<String> {
    (!text.is_empty()).then_some(text)
}

/// `_resolve_worker_model(worker_model, agent_kind)`: a shared tier, or a
/// provider-scoped `provider:model` override.
pub fn resolve_worker_model(worker_model: &str, agent_kind: &str) -> Outcome<String> {
    let value = json::py_strip(worker_model).to_lowercase();
    let repr = json::str_repr(worker_model);
    if let Some((provider, model)) = value.split_once(':') {
        let model = json::py_strip(model);
        if !["codex", "claude"].contains(&provider) || model.is_empty() {
            return Err(Failure::value(format!("invalid worker_model {repr}")));
        }
        if provider != agent_kind {
            return Err(Failure::value(format!(
                "worker_model {repr} is scoped to {provider}, but configured worker \
                 provider is {agent_kind}"
            )));
        }
        if agent_kind == "codex" {
            return Ok(normalize_codex_family(model, CODEX_DEFAULT_FAMILY));
        }
        return Ok(model.to_string());
    }
    let tiers: &[(&str, &str)] = match agent_kind {
        "codex" => &CODEX_WORKER_TIER_FAMILIES,
        "claude" => &CLAUDE_WORKER_TIERS,
        _ => &[],
    };
    if let Some((_, model)) = tiers.iter().find(|(tier, _)| *tier == value) {
        return Ok((*model).to_string());
    }
    let mut allowed: Vec<&str> = tiers.iter().map(|(tier, _)| *tier).collect();
    allowed.sort_unstable();
    Err(Failure::value(format!(
        "invalid worker_model {repr} for {agent_kind}; expected one of {} or {agent_kind}:<model>",
        allowed.join(", ")
    )))
}

/// `_uses_inherited_worker_defaults(general)`: "Use my defaults".
pub fn uses_inherited_worker_defaults(general: &Dict) -> bool {
    general_text(general, "subagent_sizing_policy") == "user_default"
}

/// `_configured_orchestrator_model(general)`.
fn configured_orchestrator_model(general: &Dict) -> Option<String> {
    if !uses_inherited_worker_defaults(general) {
        return None;
    }
    let model = general_text(general, "model");
    (!model.is_empty() && model != "default").then_some(model)
}

/// `_normalized_general_model(general, agent_kind)`.
fn normalized_general_model(general: &Dict, agent_kind: &str) -> String {
    let model = general_text(general, "model");
    if agent_kind == "codex" {
        return normalize_codex_family(&model, CODEX_DEFAULT_FAMILY);
    }
    if CLAUDE_GENERAL_MODELS.contains(&model.as_str()) {
        model
    } else {
        "opus".to_string()
    }
}

/// `_general_effort_options(agent_kind, model)`.
fn general_effort_options(agent_kind: &str, model: &str) -> Vec<&'static str> {
    let mut options = BASE_EFFORTS.to_vec();
    if agent_kind == "codex" {
        options.extend(["max", "ultra"]);
    } else if CLAUDE_MAX_EFFORT_MODELS.contains(&model) {
        options.push("max");
    } else {
        options = vec!["low"];
    }
    options
}

/// `_normalized_general_effort(general, agent_kind, model)`.
fn normalized_general_effort(general: &Dict, agent_kind: &str, model: &str) -> String {
    let raw = general
        .truthy("orchestrator_effort")
        .or_else(|| general.truthy("codex_reasoning_effort"))
        .map(Value::py_str)
        .unwrap_or_default();
    let mut effort = json::py_strip(&raw).to_lowercase();
    if effort == "default" {
        effort = "medium".to_string();
    }
    let options = general_effort_options(agent_kind, model);
    if options.contains(&effort.as_str()) {
        return effort;
    }
    if options.contains(&"medium") {
        "medium".to_string()
    } else {
        "low".to_string()
    }
}

/// `_inherited_worker_sizing(general, agent_kind)`: General Settings'
/// provider, model and effort.
pub fn inherited_worker_sizing(general: &Dict, agent_kind: &str) -> WorkerSizing {
    let model = normalized_general_model(general, agent_kind);
    let effort = normalized_general_effort(general, agent_kind, &model);
    WorkerSizing {
        provider_key: agent_kind.to_string(),
        worker_model: Some(format!("{agent_kind}:{model}")),
        model_alias: Some(model),
        worker_effort: Some(effort),
        worker_sizing_rationale: Some(
            "Inherited provider, model, and effort from Relay Runner General Settings.".to_string(),
        ),
        worker_provider_notes: Some(
            "Use my defaults preserves explicit stable provider selections; Codex resolves \
             Astra/Sol/Terra/Luna then uses model_reasoning_effort and Claude uses --effort."
                .to_string(),
        ),
    }
}

/// `_validate_worker_effort(worker_effort, worker_model=, agent_kind=,
/// provider_notes=)`.
pub fn validate_worker_effort(
    worker_effort: &str,
    worker_model: &str,
    agent_kind: &str,
    provider_notes: &str,
) -> Outcome<String> {
    let effort = json::py_strip(worker_effort).to_lowercase();
    let model = json::py_strip(worker_model).to_lowercase();
    let mut allowed: Vec<&str> = BASE_EFFORTS.to_vec();
    if agent_kind == "claude" {
        allowed.push("max");
    }
    let scoped_astra =
        agent_kind == "codex" && ["codex:astra", "codex:gpt-6-astra"].contains(&model.as_str());
    // Astra advertises these levels; the worker launch still checks them
    // against the configured CLI's catalogue.
    if scoped_astra {
        for extra in ["max", "ultra"] {
            if !allowed.contains(&extra) {
                allowed.push(extra);
            }
        }
    }
    if !allowed.contains(&effort.as_str()) {
        allowed.sort_unstable();
        return Err(Failure::value(format!(
            "invalid worker_effort {} for {agent_kind}; expected one of {}",
            json::str_repr(worker_effort),
            allowed.join(", ")
        )));
    }
    if effort == "max" && !scoped_astra {
        let scoped_to_claude = model.starts_with("claude:");
        let notes = json::py_strip(provider_notes).to_lowercase();
        let notes_document_limitation = !["", "none"].contains(&notes.as_str());
        if !scoped_to_claude || !notes_document_limitation {
            return Err(Failure::value(
                "worker_effort 'max' requires a Claude-scoped worker_model and \
                 worker_provider_notes documenting the Codex limitation",
            ));
        }
    }
    Ok(effort)
}

/// `resolve_worker_sizing(ticket, agent_kind, general)`.
pub fn resolve_worker_sizing(
    ticket: &Ticket,
    agent_kind: &str,
    general: &Dict,
) -> Outcome<WorkerSizing> {
    if uses_inherited_worker_defaults(general) {
        return Ok(inherited_worker_sizing(general, agent_kind));
    }
    let missing: Vec<&str> = WORKER_SIZING_FIELDS
        .iter()
        .copied()
        .filter(|field| required_sizing_value(ticket, field).is_empty())
        .collect();
    if !missing.is_empty() {
        return Err(Failure::value(format!(
            "missing worker sizing metadata: {}",
            missing.join(", ")
        )));
    }
    let worker_model = required_sizing_value(ticket, "worker_model");
    let worker_effort = required_sizing_value(ticket, "worker_effort");
    let provider_notes = required_sizing_value(ticket, "worker_provider_notes");
    let model_alias = match configured_orchestrator_model(general) {
        Some(model) => model,
        None => resolve_worker_model(&worker_model, agent_kind)?,
    };
    let effort =
        validate_worker_effort(&worker_effort, &worker_model, agent_kind, &provider_notes)?;
    Ok(WorkerSizing {
        provider_key: agent_kind.to_string(),
        model_alias: Some(model_alias),
        worker_model: Some(worker_model),
        worker_effort: Some(effort),
        worker_sizing_rationale: Some(required_sizing_value(ticket, "worker_sizing_rationale")),
        worker_provider_notes: Some(provider_notes),
    })
}

/// `raw_worker_sizing_metadata(ticket, agent_kind)`: what a refused run
/// records.
pub fn raw_worker_sizing_metadata(ticket: &Ticket, agent_kind: &str) -> WorkerSizing {
    let field = |name: &str| non_empty(required_sizing_value(ticket, name));
    WorkerSizing {
        provider_key: agent_kind.to_string(),
        model_alias: None,
        worker_model: field("worker_model"),
        worker_effort: field("worker_effort"),
        worker_sizing_rationale: field("worker_sizing_rationale"),
        worker_provider_notes: field("worker_provider_notes"),
    }
}

/// `apply_default_worker_sizing(ticket, general, agent_kind)`: write the
/// inherited sizing into the front matter; whether anything changed.
pub fn apply_default_worker_sizing(
    ticket: &mut Ticket,
    general: &Dict,
    agent_kind: Option<&str>,
) -> bool {
    if !uses_inherited_worker_defaults(general) {
        return false;
    }
    let kind = match agent_kind.filter(|kind| !kind.is_empty()) {
        Some(kind) => kind.to_string(),
        None => crate::general::provider_from_general(general, "codex"),
    };
    let inherited = inherited_worker_sizing(general, &kind);
    let defaults = [
        ("worker_model", inherited.worker_model),
        ("worker_effort", inherited.worker_effort),
        ("worker_sizing_rationale", inherited.worker_sizing_rationale),
        ("worker_provider_notes", inherited.worker_provider_notes),
    ];
    if defaults.iter().all(|(field, value)| {
        ticket.raw_fields.get(field).unwrap_or_default() == value.as_deref().unwrap_or_default()
    }) {
        return false;
    }
    for (field, value) in &defaults {
        ticket
            .raw_fields
            .insert(field, value.as_deref().unwrap_or_default());
    }
    true
}

/// The front matter as the dict `update_worker_sizing` reads.
fn fields_dict(fields: &Fields) -> Dict {
    let mut dict = Dict::new();
    for (key, value) in fields.iter() {
        dict.insert(key, value);
    }
    dict
}

/// The run a dispatch would start, as far as it is known before the launch.
struct PlannedRun {
    workspace_path: PathBuf,
    branch: String,
    log_path: PathBuf,
    execution_mode: String,
}

/// What the launch half of a dispatch receives from its checks.
struct Launching<'a> {
    request: &'a DispatchRequest,
    ticket: Ticket,
    ticket_file: &'a Path,
    sizing: &'a WorkerSizing,
    provider: &'a str,
    binary: &'a str,
    base_branch: &'a str,
}

/// One dispatch's identity, shared by its early answers.
struct Dispatching<'a> {
    repo: PathBuf,
    repo_text: String,
    ticket_id: &'a str,
    source: &'a str,
    /// `relay_command_id` (when truthy) and `relay_intent_id`.
    command_id: Option<String>,
    intent_id: Option<String>,
    lifecycle: Option<Arc<ArtifactLifecycleCoordinator>>,
}

impl Daemon {
    /// `POST /v1/runs`.
    pub fn dispatch_route(&self, request: &Request) -> Outcome<Reply> {
        let body = &request.body;
        let truthy_text = |key: &str| body.truthy(key).map(Value::py_str);
        let dispatch = DispatchRequest {
            ticket_id: truthy_text("ticket_id").unwrap_or_default(),
            repo_path: truthy_text("repo_path").unwrap_or_default(),
            context: request.optional_text("context"),
            source: truthy_text("source").unwrap_or_else(|| "direct".to_string()),
            voice: VoiceFields {
                relay_command_seq: body.present("relay_command_seq").cloned(),
                relay_command_id: body.truthy("relay_command_id").cloned(),
                relay_intent_id: body.truthy("relay_intent_id").cloned(),
                relay_session_key: body.truthy("relay_session_key").cloned(),
            },
            project_scope_token: truthy_text("project_scope_token"),
            internally_confirmed_project_id: None,
            dispatcher_session_key: body.truthy("dispatcher_session_key").cloned(),
        };
        let result = self.dispatch(&dispatch)?;
        let status = if result.get("already_active").is_some_and(Value::truthy) {
            200
        } else {
            202
        };
        Ok((status, Value::Dict(result)))
    }

    /// `Daemon.dispatch(...)`: every check before a worker starts, then the
    /// launch.
    pub(crate) fn dispatch(&self, request: &DispatchRequest) -> Outcome<Dict> {
        let ticket_id = request.ticket_id.as_str();
        if ticket_id.is_empty() {
            return Err(Failure::value("ticket_id is required"));
        }
        if request.repo_path.is_empty() {
            return Err(Failure::value("repo_path is required"));
        }
        let mutation = mutation_metadata("dispatch_ticket", Some(ticket_id), None, None, None);
        validate_relay_command(&self.paths, &request.voice, Some(&mutation))?;

        let repo = resolve_path(&request.repo_path);
        let repo_text = repo.to_string_lossy().into_owned();
        if !repo.is_dir() || !repo.join(".git").exists() {
            return Err(Failure::value(format!(
                "repo_path {repo_text} is not a git repository"
            )));
        }
        let lifecycle = self.artifact_lifecycle(&repo_text)?;
        if let Some(lifecycle) = &lifecycle {
            lifecycle.validate_scope(
                request.project_scope_token.as_deref(),
                request.internally_confirmed_project_id.as_deref(),
            )?;
        }
        let ticket_file = repo.join(".orchestrator").join(format!("{ticket_id}.md"));
        if !ticket_file.is_file() {
            return Err(Failure::value(format!(
                "ticket {ticket_id} not found at {}",
                ticket_file.display()
            )));
        }
        let mut ticket = match tickets::read(&ticket_file) {
            Ok(ticket) => ticket,
            Err(error) if matches!(error.kind, ErrorKind::Io | ErrorKind::TicketParse) => {
                return Err(Failure::value(format!(
                    "ticket {ticket_id} could not be read: {}",
                    error.message
                )));
            }
            Err(error) => return Err(error.into()),
        };
        let execution_mode = run_store::execution_mode(Some(&ticket.execution_mode))?;
        validate_research_dispatch(&ticket, &std::fs::read_to_string(&ticket_file)?)?;
        if ticket.status == VERIFICATION_BLOCKED_STATUS {
            return Err(Failure::value(format!(
                "ticket {ticket_id} is verification blocked; use the explicit resume action \
                 after the external condition changes"
            )));
        }
        // RR-469: this ticket's lifecycle updates go to the dispatching PM
        // tab, including a queued dispatch that starts later.
        if let Some(dispatcher) =
            optional_relay_session_key(request.dispatcher_session_key.as_ref())
        {
            self.messenger_outcomes
                .bind_dispatcher(&repo_text, ticket_id, &dispatcher)?;
        }
        let context = Dispatching {
            repo: repo.clone(),
            repo_text: repo_text.clone(),
            ticket_id,
            source: &request.source,
            command_id: request
                .voice
                .relay_command_id
                .as_ref()
                .filter(|value| value.truthy())
                .map(Value::py_str),
            intent_id: request
                .voice
                .relay_intent_id
                .as_ref()
                .filter(|value| value.truthy())
                .map(Value::py_str),
            lifecycle,
        };
        if ["backlog", "ready"].contains(&ticket.status.as_str()) && !ticket.depends_on.is_empty() {
            let all_tickets: Vec<Ticket> = tickets::scan_repo(&repo)?
                .into_iter()
                .map(|(_, ticket)| ticket)
                .collect();
            let mut waiting_on = Vec::new();
            for dependency in &ticket.depends_on {
                if !self.all_dependencies_done(
                    &repo,
                    std::slice::from_ref(dependency),
                    &all_tickets,
                    context.lifecycle.as_ref(),
                )? {
                    waiting_on.push(dependency.clone());
                }
            }
            if !waiting_on.is_empty() {
                return self.queue_for_dependencies(&context, &ticket_file, ticket, &waiting_on);
            }
        }
        self.notify_orchestration_trace(
            "dispatch-started",
            Some(ticket_id),
            None,
            request.voice.relay_command_seq.as_ref(),
            context.command_id.as_deref(),
        );

        let sanitized = sanitize_identifier(ticket_id)?;
        let branch = if execution_mode == SPIKE_EXECUTION_MODE {
            String::new()
        } else {
            format!("{}{sanitized}", self.branch_prefix)
        };
        let workspace_path = self
            .paths
            .workspace_root
            .join(workspace_slug(&repo, ticket_id)?);
        let planned = PlannedRun {
            log_path: workspace_path.join(".relay").join("run.log"),
            workspace_path,
            branch,
            execution_mode,
        };
        let base_branch = resolve_default_branch(&repo)?;
        let mut target_branch = git_text(&repo, &["branch", "--show-current"])?;
        if target_branch.is_empty() {
            target_branch = base_branch.clone();
        }

        let dispatching = guard(&self.dispatch_lock);
        let (worker_provider, worker_bin, general) = self.effective_worker_agent()?;
        self.ensure_queue_drain_for_ticket(
            &repo,
            &ticket,
            &worker_provider,
            &target_branch,
            &request.source,
        )?;
        if let Some(existing) = self.runs.find_active(ticket_id, Some(&repo_text))? {
            eprintln!(
                "[orchestrator] dispatch skipped for {ticket_id} from {}: already active run {}",
                request.source,
                existing.get("id").map(Value::py_str).unwrap_or_default()
            );
            self.record_queue_drain_after_event(
                Some(&repo_text),
                &format!("dispatch-{}-already-active", request.source),
                false,
            );
            self.update_dispatch_command(
                &context,
                ticket_id,
                "dispatched",
                "dispatch-already-active",
                &format!("{ticket_id} already has an active run."),
            )?;
            let mut result = Dict::new();
            result.insert("already_active", true);
            result.insert("run", existing);
            return Ok(result);
        }

        if let Some(awaiting) = self.runs.find_awaiting_merge(ticket_id, Some(&repo_text))? {
            return self.awaiting_merge_answer(&context, awaiting);
        }

        if let Some(blocker) = self.auto_dispatch_blocker(ticket_id, &repo_text, &request.source)? {
            eprintln!(
                "[orchestrator] auto-dispatch held for {ticket_id} from {}: {blocker}",
                request.source
            );
            self.record_queue_drain_after_event(
                Some(&repo_text),
                &format!("dispatch-{}-held", request.source),
                false,
            );
            return Err(Failure::runtime(blocker));
        }

        if let Some(blocker) = source_checkout_blocker(&repo, true)? {
            return self.integration_blocked_answer(&context, &blocker, &worker_provider);
        }

        if apply_default_worker_sizing(&mut ticket, &general, Some(&worker_provider)) {
            if let Some(lifecycle) = &context.lifecycle {
                lifecycle.update_worker_sizing(
                    ticket_id,
                    &worker_provider,
                    &fields_dict(&ticket.raw_fields),
                )?;
                ticket = tickets::read(&ticket_file)?;
            } else if planned.execution_mode != SPIKE_EXECUTION_MODE {
                tickets::write(&ticket_file, &ticket)?;
            }
        }

        let sizing_general = if uses_inherited_worker_defaults(&general) {
            general.clone()
        } else {
            Dict::new()
        };
        let sizing = match resolve_worker_sizing(&ticket, &worker_provider, &sizing_general) {
            Ok(sizing) => sizing,
            Err(error) => {
                let reason = error.message;
                self.record_dispatch_refusal(
                    &context,
                    &planned,
                    &reason,
                    &raw_worker_sizing_metadata(&ticket, &worker_provider),
                )?;
                eprintln!(
                    "[orchestrator] dispatch refused for {ticket_id} from {}: {reason}",
                    request.source
                );
                self.record_queue_drain_after_event(
                    Some(&repo_text),
                    &format!("dispatch-{}-refused", request.source),
                    false,
                );
                return Err(Failure::value(reason));
            }
        };

        let run = self.launch_run(
            &context,
            &planned,
            Launching {
                request,
                ticket,
                ticket_file: &ticket_file,
                sizing: &sizing,
                provider: &worker_provider,
                binary: &worker_bin,
                base_branch: &base_branch,
            },
        )?;
        drop(dispatching);
        self.record_queue_drain_after_event(
            Some(&repo_text),
            &format!("dispatch-{}-claimed", request.source),
            false,
        );
        self.update_dispatch_command(
            &context,
            ticket_id,
            "dispatched",
            "ticket-dispatched",
            &format!("Dispatched {ticket_id}."),
        )?;
        let mut result = Dict::new();
        result.insert("already_active", false);
        result.insert("run", run);
        Ok(result)
    }

    /// The launch half of `dispatch`: the attempt number, the worktree or
    /// read-only spike snapshot, the run claim, the ticket snapshot, the
    /// prompt and the worker. The run row as claimed, before its worker
    /// starts.
    fn launch_run(
        &self,
        context: &Dispatching<'_>,
        planned: &PlannedRun,
        launching: Launching<'_>,
    ) -> Outcome<Option<Dict>> {
        let Launching {
            request,
            mut ticket,
            ticket_file,
            sizing,
            provider,
            binary,
            base_branch,
        } = launching;
        let ticket_id = context.ticket_id;
        let repo = &context.repo;
        let repo_text = &context.repo_text;
        let source = request.source.as_str();
        let spike = planned.execution_mode == SPIKE_EXECUTION_MODE;
        let attempt = self.runs.next_attempt(ticket_id, Some(repo_text))?;
        let (workspace_path, log_path) = if spike {
            (
                PathBuf::from(format!(
                    "{}-spike-{attempt}",
                    planned.workspace_path.display()
                )),
                self.paths
                    .workspace_root
                    .join(".spike-runs")
                    .join(workspace_slug(repo, ticket_id)?)
                    .join(format!("run-{attempt}.log")),
            )
        } else {
            (planned.workspace_path.clone(), planned.log_path.clone())
        };
        let workspace_text = workspace_path.to_string_lossy().into_owned();
        let new_run = |state: &str| NewRun {
            ticket_id: ticket_id.to_string(),
            repo_path: repo_text.clone(),
            workspace_path: workspace_text.clone(),
            branch: planned.branch.clone(),
            state: state.to_string(),
            execution_mode: Some(planned.execution_mode.clone()),
            attempt: Some(attempt),
            log_path: Some(log_path.to_string_lossy().into_owned()),
            provider_key: Some(sizing.provider_key.clone()),
            model_alias: sizing.model_alias.clone(),
            worker_model: sizing.worker_model.clone(),
            worker_effort: sizing.worker_effort.clone(),
            worker_sizing_rationale: sizing.worker_sizing_rationale.clone(),
            worker_provider_notes: sizing.worker_provider_notes.clone(),
        };
        let fail_run = |run_id: i64, reason: &str| {
            self.runs.update(
                run_id,
                &RunUpdate {
                    state: Some("Failed".to_string()),
                    last_error: Some(Some(reason.to_string())),
                    ended: true,
                    exit_code: Some(-1),
                    ..RunUpdate::default()
                },
            )
        };
        // A pre-flight failure is recorded as a failed attempt, for the board.
        let preflight_failed = |error: Failure, trigger: &str| -> Outcome<Option<Dict>> {
            if error.class == crate::failure::Class::Runtime {
                let run_id = self.runs.insert(&new_run("Failed"))?;
                fail_run(run_id, &error.message)?;
                self.emit_lifecycle(&LifecycleEvent {
                    kind: "run-failed",
                    ticket_id: Some(ticket_id),
                    run_id: Some(run_id),
                    source: Some("worker"),
                    repo_path: Some(repo_text),
                    provider_key: Some(&sizing.provider_key),
                    ..LifecycleEvent::default()
                });
                self.record_queue_drain_after_event(
                    Some(repo_text),
                    &format!("dispatch-{source}-{trigger}"),
                    false,
                );
            }
            Err(error)
        };
        let created = if spike {
            crate::spike::create_spike_workspace(repo_text, &workspace_path, base_branch)
        } else {
            crate::execution::create_worktree(repo, &workspace_path, &planned.branch, base_branch)
        };
        if let Err(error) = created {
            return preflight_failed(error, "worktree-failed");
        }
        if !spike
            && context.lifecycle.is_none()
            && let Err(error) = crate::execution::materialize_ticket_snapshot(
                ticket_file,
                &workspace_path,
                ticket_id,
            )
        {
            return preflight_failed(error, "snapshot-failed");
        }

        let run_id = self.runs.insert(&new_run("Claimed"))?;
        if let Some(lifecycle) = &context.lifecycle {
            let claimed = (|| -> Outcome<Ticket> {
                // Only the daemon may add artifact inputs, before the worker
                // starts.
                let mode = std::fs::metadata(&workspace_path)?.permissions();
                if spike {
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(
                        &workspace_path,
                        std::fs::Permissions::from_mode(mode.mode() | 0o200),
                    )?;
                }
                let materialized =
                    lifecycle.claim_and_materialize(ticket_id, run_id, provider, &workspace_path);
                if spike {
                    std::fs::set_permissions(&workspace_path, mode)?;
                }
                materialized?;
                let snapshot = workspace_path
                    .join(".orchestrator")
                    .join(format!("{ticket_id}.md"));
                let claimed = tickets::read(&snapshot)?;
                if claimed.execution_mode != planned.execution_mode {
                    return Err(Failure::value(
                        "ticket execution mode changed during dispatch; retry with current inputs",
                    ));
                }
                validate_research_dispatch(&claimed, &std::fs::read_to_string(&snapshot)?)?;
                Ok(claimed)
            })();
            match claimed {
                Ok(claimed) => ticket = claimed,
                Err(error) => {
                    let mut reason =
                        format!("artifact lifecycle snapshot failed: {}", error.message);
                    if let Err(recovery) = lifecycle.record_failure(
                        run_id,
                        ticket_id,
                        provider,
                        &reason,
                        relay_artifacts::lifecycle::FailureKind::default(),
                    ) {
                        reason.push_str(&format!(
                            "; lifecycle recovery failed: {}",
                            Failure::from(recovery).message
                        ));
                    }
                    ArtifactLifecycleCoordinator::cleanup_snapshot(&workspace_path);
                    let (removed, cleanup_error) = if spike {
                        crate::spike::remove_spike_workspace(&workspace_path)
                    } else {
                        let removed = crate::runs::remove_worktree(repo_text, &workspace_path);
                        crate::runs::delete_branch(repo_text, &planned.branch);
                        removed
                    };
                    if !removed || cleanup_error.is_some() {
                        reason.push_str(&format!(
                            "; {}",
                            cleanup_error
                                .unwrap_or_else(|| "worker worktree cleanup failed".to_string())
                        ));
                    }
                    fail_run(run_id, &reason)?;
                    return Err(Failure::runtime(reason));
                }
            }
        }
        self.notify_orchestration_trace(
            "dispatch-claimed",
            Some(ticket_id),
            Some(run_id),
            request.voice.relay_command_seq.as_ref(),
            context.command_id.as_deref(),
        );

        let mut workflow_path = None;
        let mut spike_launch = None;
        let prompt = if spike {
            ticket.status = "in_progress".to_string();
            ticket.run_id = Some(run_id);
            if context.lifecycle.is_none()
                && let Err(error) = crate::spike::commit_daemon_ticket_update(
                    repo,
                    ticket_file,
                    &ticket,
                    &format!("chore({ticket_id}): start spike run {run_id}"),
                )
            {
                let (_, cleanup_error) = crate::spike::remove_spike_workspace(&workspace_path);
                let mut reason = error.message.clone();
                if let Some(cleanup) = cleanup_error {
                    reason.push_str(&format!("; {cleanup}"));
                }
                fail_run(run_id, &reason)?;
                return Err(error);
            }
            let prepared = (|| -> Outcome<(String, crate::worker::SpikeLaunch)> {
                let log_directory = log_path.parent().map(Path::to_path_buf).unwrap_or_default();
                std::fs::create_dir_all(&log_directory)?;
                let schema_path = log_directory.join(format!("run-{attempt}-result.schema.json"));
                std::fs::write(
                    &schema_path,
                    relay_artifacts::history::dumps_indent(&crate::spike::SPIKE_RESULT_SCHEMA),
                )?;
                let git_environment = if provider == "codex" {
                    Some(crate::spike::prepare_spike_git_environment(
                        &workspace_text,
                    )?)
                } else {
                    None
                };
                let git_path = git_environment.as_ref().and_then(|environment| {
                    environment
                        .iter()
                        .find(|(key, _)| key == "RELAY_SPIKE_GIT")
                        .map(|(_, value)| value.clone())
                });
                let prompt = crate::spike::SpikePrompt {
                    ticket: &ticket,
                    repo_path: repo_text,
                    workspace_path: &workspace_text,
                    attempt,
                    run_id,
                    caller_context: request.context.as_deref(),
                    agent_kind: provider,
                    git_path: git_path.as_deref(),
                }
                .render();
                Ok((
                    prompt,
                    crate::worker::SpikeLaunch {
                        result_schema_path: schema_path.to_string_lossy().into_owned(),
                        git_environment,
                    },
                ))
            })();
            match prepared {
                Ok((prompt, launch)) => {
                    spike_launch = Some(launch);
                    prompt
                }
                Err(error) => {
                    let mut reason = format!("spike launch preparation failed: {}", error.message);
                    let current = self.runs.get(run_id)?.unwrap_or_default();
                    if let Err(reset) =
                        self.spike_ticket_update(&current, None, Some(&reason), false)
                    {
                        reason.push_str(&format!("; ticket reset failed: {}", reset.message));
                    }
                    let (removed, cleanup_error) =
                        crate::spike::remove_spike_workspace(&workspace_path);
                    if !removed || cleanup_error.is_some() {
                        reason.push_str(&format!(
                            "; {}",
                            cleanup_error
                                .unwrap_or_else(|| "spike workspace still exists".to_string())
                        ));
                    }
                    fail_run(run_id, &reason)?;
                    return Err(Failure::runtime(reason));
                }
            }
        } else {
            let template = if context.lifecycle.is_some() {
                self.paths.artifact_workflow_path.clone()
            } else {
                self.resolve_workflow_for_repo(repo_text)
            };
            let built = self.build_prompt(
                &crate::execution::PromptInputs {
                    ticket_id,
                    repo_path: repo_text,
                    workspace_path: &workspace_text,
                    branch: &planned.branch,
                    attempt,
                    run_id,
                    caller_context: request.context.as_deref(),
                },
                &template,
            );
            workflow_path = Some(template);
            match built {
                Ok(prompt) => prompt,
                Err(error) => {
                    fail_run(run_id, &error.message)?;
                    return Err(error);
                }
            }
        };

        let run = self.runs.get(run_id)?;
        self.start_worker(crate::worker::WorkerLaunch {
            run_id,
            run: run.clone().unwrap_or_default(),
            prompt,
            agent_bin: binary.to_string(),
            agent_kind: provider.to_string(),
            workflow_path,
            log_path,
            artifact: context.lifecycle.is_some(),
            spike: spike_launch,
            completion: context.lifecycle.clone().filter(|_| !spike),
        });
        eprintln!(
            "[orchestrator] dispatch claimed {ticket_id} from {source}: run {run_id} ({provider})"
        );
        Ok(run)
    }

    /// The answer for a ticket whose run already waits for review or merge.
    fn awaiting_merge_answer(&self, context: &Dispatching<'_>, run: Dict) -> Outcome<Dict> {
        let ticket_id = context.ticket_id;
        let run_id = run.get("id").map(Value::py_str).unwrap_or_default();
        let integration_blocked = run
            .get("state")
            .is_some_and(|state| state.is_str(INTEGRATION_BLOCKED_RUN_STATE));
        let reason = if integration_blocked {
            let next_step = source_checkout_blocker(&context.repo, false)?
                .map(|blocker| blocker.next_step)
                .filter(|step| !step.is_empty())
                .unwrap_or_else(|| "recheck the existing reviewed run".to_string());
            format!("ticket {ticket_id} run {run_id} is waiting for integration; {next_step}")
        } else {
            format!(
                "ticket {ticket_id} already has succeeded run {run_id} awaiting merge; merge \
                 {} or explicitly reset the ticket before retrying",
                run.get("branch").map(Value::py_str).unwrap_or_default()
            )
        };
        eprintln!(
            "[orchestrator] dispatch skipped for {ticket_id} from {}: {reason}",
            context.source
        );
        self.record_queue_drain_after_event(
            Some(&context.repo_text),
            &format!("dispatch-{}-awaiting-merge", context.source),
            true,
        );
        self.update_dispatch_command(
            context,
            ticket_id,
            "dispatched",
            "dispatch-awaiting-merge",
            &format!("{ticket_id} already has a run awaiting merge."),
        )?;
        let mut result = Dict::new();
        result.insert("already_active", true);
        result.insert("awaiting_merge", true);
        result.insert("integration_blocked", integration_blocked);
        result.insert("reason", reason);
        result.insert("run", run);
        Ok(result)
    }

    /// The answer for a dispatch held by a dirty source checkout.
    fn integration_blocked_answer(
        &self,
        context: &Dispatching<'_>,
        blocker: &SourceBlocker,
        provider_key: &str,
    ) -> Outcome<Dict> {
        let ticket_id = context.ticket_id;
        let message = format!("{}. {}", blocker.reason, blocker.next_step);
        self.emit_lifecycle(&LifecycleEvent {
            kind: "run-integration-blocked",
            ticket_id: Some(ticket_id),
            source: Some("orchestrator"),
            message: Some(&message),
            repo_path: Some(&context.repo_text),
            provider_key: Some(provider_key),
            ..LifecycleEvent::default()
        });
        self.record_queue_drain_after_event(
            Some(&context.repo_text),
            &format!("dispatch-{}-integration-blocked", context.source),
            false,
        );
        self.update_dispatch_command(
            context,
            ticket_id,
            "blocked",
            "integration-blocked",
            &format!("{ticket_id} is waiting for a clean source checkout."),
        )?;
        let mut result = Dict::new();
        result.insert("already_active", false);
        result.insert("integration_blocked", true);
        result.insert("reason", blocker.reason.as_str());
        result.insert("dirty_paths", string_values(&blocker.dirty_paths));
        result.insert("next_step", blocker.next_step.as_str());
        result.insert("run", Value::Null);
        Ok(result)
    }

    /// The command-status update a dispatch makes for a voice command the
    /// daemon knows.
    fn update_dispatch_command(
        &self,
        context: &Dispatching<'_>,
        ticket_id: &str,
        status: &str,
        outcome: &str,
        message: &str,
    ) -> Outcome<()> {
        let Some(command_id) = context.command_id.as_deref() else {
            return Ok(());
        };
        let intent = context.intent_id.as_deref();
        if self
            .orchestrator_commands
            .get_private(command_id, intent)?
            .is_some_and(|command| !command.is_empty())
        {
            self.orchestrator_commands.update_status(
                command_id,
                intent,
                &CommandStatus {
                    status: status.to_string(),
                    action: None,
                    outcome: Some(outcome.to_string()),
                    ticket_id: Some(ticket_id.to_string()),
                    status_message: Some(message.to_string()),
                    error: None,
                },
            )?;
        }
        Ok(())
    }

    /// `_queue_for_dependencies`: hold a dependency-gated ticket in `ready`;
    /// the sweeper starts it once its predecessors are done.
    fn queue_for_dependencies(
        &self,
        context: &Dispatching<'_>,
        ticket_file: &Path,
        mut ticket: Ticket,
        waiting_on: &[String],
    ) -> Outcome<Dict> {
        let ticket_id = ticket.id.clone();
        if ticket.status == "backlog" {
            if let Some(lifecycle) = &context.lifecycle {
                lifecycle.queue_for_dependencies(&ticket_id)?;
            } else {
                ticket.status = "ready".to_string();
                tickets::write(ticket_file, &ticket)?;
            }
            self.notify_orchestration_trace("board-change", Some(&ticket_id), None, None, None);
        }
        let waiting = waiting_on.join(", ");
        eprintln!(
            "[orchestrator] dispatch queued {ticket_id} from {}: waiting on {waiting}",
            context.source
        );
        self.update_dispatch_command(
            context,
            &ticket_id,
            "dispatched",
            "dispatch-queued",
            &format!("{ticket_id} is queued, waiting on {waiting}."),
        )?;
        let mut result = Dict::new();
        result.insert("queued", true);
        result.insert("already_active", false);
        result.insert("run", Value::Null);
        result.insert("waiting_on", string_values(waiting_on));
        Ok(result)
    }

    /// `_record_dispatch_refusal`: a `Failed` run with exit code -1, so the
    /// refusal is visible on the board.
    fn record_dispatch_refusal(
        &self,
        context: &Dispatching<'_>,
        planned: &PlannedRun,
        reason: &str,
        sizing: &WorkerSizing,
    ) -> Outcome<Option<Dict>> {
        let attempt = self
            .runs
            .next_attempt(context.ticket_id, Some(&context.repo_text))?;
        let run_id = self.runs.insert(&NewRun {
            ticket_id: context.ticket_id.to_string(),
            repo_path: context.repo_text.clone(),
            workspace_path: planned.workspace_path.to_string_lossy().into_owned(),
            branch: planned.branch.clone(),
            state: "Failed".to_string(),
            execution_mode: Some(planned.execution_mode.clone()),
            attempt: Some(attempt),
            log_path: Some(planned.log_path.to_string_lossy().into_owned()),
            provider_key: Some(sizing.provider_key.clone()),
            model_alias: sizing.model_alias.clone(),
            worker_model: sizing.worker_model.clone(),
            worker_effort: sizing.worker_effort.clone(),
            worker_sizing_rationale: sizing.worker_sizing_rationale.clone(),
            worker_provider_notes: sizing.worker_provider_notes.clone(),
        })?;
        self.runs.update(
            run_id,
            &RunUpdate {
                last_error: Some(Some(reason.to_string())),
                ended: true,
                exit_code: Some(-1),
                ..RunUpdate::default()
            },
        )?;
        self.emit_lifecycle(&LifecycleEvent {
            kind: "run-failed",
            ticket_id: Some(context.ticket_id),
            run_id: Some(run_id),
            source: Some("worker"),
            repo_path: Some(&context.repo_text),
            provider_key: Some(&sizing.provider_key),
            ..LifecycleEvent::default()
        });
        Ok(self.runs.get(run_id)?)
    }

    /// `_auto_dispatch_blocker`: an automatic retry held after a
    /// deterministic failure or inside the backoff window.
    pub(crate) fn auto_dispatch_blocker(
        &self,
        ticket_id: &str,
        repo_path: &str,
        source: &str,
    ) -> Outcome<Option<String>> {
        if !AUTO_DISPATCH_SOURCES.contains(&source) {
            return Ok(None);
        }
        let history = self.runs.recent_for_ticket(ticket_id, Some(repo_path), 1)?;
        let Some(latest) = history.first() else {
            return Ok(None);
        };
        if !latest
            .get("state")
            .is_some_and(|state| state.is_str("Failed") || state.is_str("Stalled"))
        {
            return Ok(None);
        }
        let latest_error = latest.text("last_error");
        if is_deterministic_dispatch_failure(&latest_error) {
            return Ok(Some(format!(
                "automatic retry circuit open after deterministic failure: {latest_error}; fix \
                 the root cause and explicitly redispatch the ticket"
            )));
        }
        if let Some(ended_at) = latest.present("ended_at") {
            let age = ended_at
                .py_float()
                .map_or(AUTO_DISPATCH_BACKOFF_SECONDS, |ended| now() - ended);
            if age < AUTO_DISPATCH_BACKOFF_SECONDS {
                let remaining = ((AUTO_DISPATCH_BACKOFF_SECONDS - age) as i64).max(1);
                let attempt = latest
                    .get("attempt")
                    .map_or_else(|| "None".to_string(), Value::py_str);
                return Ok(Some(format!(
                    "automatic retry backoff active after attempt {attempt}; retry in {remaining}s"
                )));
            }
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ticket(fields: &[(&str, &str)]) -> Ticket {
        let mut text = String::from(
            "---\nid: CT-1\ntitle: Work\nstatus: ready\npriority: medium\ndepends_on: []\n\
             run_id: null\ncanceled: false\n",
        );
        for (key, value) in fields {
            text.push_str(&format!("{key}: {value}\n"));
        }
        text.push_str("---\n## Description\nDo it.\n");
        tickets::parse(&text).unwrap()
    }

    fn sized() -> Ticket {
        ticket(&[
            ("worker_model", "balanced"),
            ("worker_effort", "Medium"),
            ("worker_sizing_rationale", "Small change."),
            ("worker_provider_notes", "none"),
        ])
    }

    fn general(pairs: &[(&str, &str)]) -> Dict {
        let mut dict = Dict::new();
        for (key, value) in pairs {
            dict.insert(key, *value);
        }
        dict
    }

    #[test]
    fn missing_sizing_names_every_absent_field() {
        let error = resolve_worker_sizing(&ticket(&[]), "claude", &Dict::new()).unwrap_err();
        assert_eq!(
            error.message,
            "missing worker sizing metadata: worker_model, worker_effort, \
             worker_sizing_rationale, worker_provider_notes"
        );
        assert!(is_deterministic_dispatch_failure(&error.message));
    }

    #[test]
    fn shared_tiers_resolve_per_provider() {
        let claude = resolve_worker_sizing(&sized(), "claude", &Dict::new()).unwrap();
        assert_eq!(claude.model_alias.as_deref(), Some("sonnet"));
        assert_eq!(claude.worker_effort.as_deref(), Some("medium"));
        assert_eq!(claude.worker_model.as_deref(), Some("balanced"));
        let codex = resolve_worker_sizing(&sized(), "codex", &Dict::new()).unwrap();
        assert_eq!(codex.model_alias.as_deref(), Some("sol"));
        assert_eq!(resolve_worker_model("Strong", "codex").unwrap(), "astra");
        assert_eq!(
            resolve_worker_model("codex:gpt-6-luna", "codex").unwrap(),
            "luna"
        );
        assert_eq!(
            resolve_worker_model("claude:Opus ", "claude").unwrap(),
            "opus"
        );
    }

    #[test]
    fn worker_model_errors_read_as_python() {
        assert_eq!(
            resolve_worker_model("huge", "claude").unwrap_err().message,
            "invalid worker_model 'huge' for claude; expected one of balanced, fast, strong \
             or claude:<model>"
        );
        assert_eq!(
            resolve_worker_model("claude:opus", "codex")
                .unwrap_err()
                .message,
            "worker_model 'claude:opus' is scoped to claude, but configured worker provider \
             is codex"
        );
        assert_eq!(
            resolve_worker_model("other:x", "codex")
                .unwrap_err()
                .message,
            "invalid worker_model 'other:x'"
        );
    }

    #[test]
    fn effort_rules_follow_the_provider() {
        assert_eq!(
            validate_worker_effort("max", "balanced", "codex", "none")
                .unwrap_err()
                .message,
            "invalid worker_effort 'max' for codex; expected one of high, low, medium, xhigh"
        );
        assert_eq!(
            validate_worker_effort("ultra", "codex:astra", "codex", "none").unwrap(),
            "ultra"
        );
        assert!(
            validate_worker_effort("max", "claude:opus", "claude", "none")
                .unwrap_err()
                .message
                .starts_with("worker_effort 'max' requires a Claude-scoped worker_model")
        );
        assert_eq!(
            validate_worker_effort("MAX", "claude:opus", "claude", "Codex has no max.").unwrap(),
            "max"
        );
        assert!(validate_worker_effort("max", "strong", "claude", "notes").is_err());
    }

    #[test]
    fn use_my_defaults_inherits_general_settings() {
        let defaults = general(&[
            ("subagent_sizing_policy", "User_Default"),
            ("model", "haiku"),
            ("orchestrator_effort", "high"),
        ]);
        let sizing = resolve_worker_sizing(&ticket(&[]), "claude", &defaults).unwrap();
        assert_eq!(sizing.worker_model.as_deref(), Some("claude:haiku"));
        // Haiku offers only `low`.
        assert_eq!(sizing.worker_effort.as_deref(), Some("low"));
        let codex = inherited_worker_sizing(
            &general(&[("model", "default"), ("codex_reasoning_effort", "default")]),
            "codex",
        );
        assert_eq!(codex.worker_model.as_deref(), Some("codex:sol"));
        assert_eq!(codex.worker_effort.as_deref(), Some("medium"));
        let unknown = inherited_worker_sizing(&general(&[("model", "gpt")]), "claude");
        assert_eq!(unknown.model_alias.as_deref(), Some("opus"));
    }

    #[test]
    fn default_sizing_is_written_once() {
        let defaults = general(&[
            ("subagent_sizing_policy", "user_default"),
            ("model", "opus"),
        ]);
        let mut target = ticket(&[]);
        assert!(apply_default_worker_sizing(
            &mut target,
            &defaults,
            Some("claude")
        ));
        assert_eq!(target.raw_fields.get("worker_model"), Some("claude:opus"));
        assert_eq!(target.raw_fields.get("worker_effort"), Some("medium"));
        assert!(!apply_default_worker_sizing(
            &mut target,
            &defaults,
            Some("claude")
        ));
        assert!(!apply_default_worker_sizing(
            &mut ticket(&[]),
            &Dict::new(),
            Some("claude")
        ));
    }

    #[test]
    fn raw_sizing_keeps_only_present_fields() {
        let raw = raw_worker_sizing_metadata(&ticket(&[("worker_model", " fast ")]), "codex");
        assert_eq!(raw.worker_model.as_deref(), Some("fast"));
        assert_eq!(raw.worker_effort, None);
        assert_eq!(raw.model_alias, None);
    }

    #[test]
    fn deterministic_failures_cover_provider_launch_errors() {
        assert!(is_deterministic_dispatch_failure(
            "exit=1; tail=HTTP 400 Bad Request: invalid value for --effort"
        ));
        assert!(!is_deterministic_dispatch_failure(
            "exit=1; tail=HTTP 400 Bad Request"
        ));
        assert!(!is_deterministic_dispatch_failure("worker crashed"));
        assert!(!is_deterministic_dispatch_failure("  "));
        assert!(is_deterministic_dispatch_failure(
            " Invalid  worker_effort 'x'"
        ));
    }

    #[test]
    fn research_dispatch_needs_an_explicit_mode_and_resolved_inputs() {
        let spike = tickets::parse(
            "---\nid: CT-1\ntitle: Spike: find out\nstatus: ready\npriority: low\n\
             depends_on: []\nrun_id: null\ncanceled: false\n---\nBody\n",
        )
        .unwrap();
        let contents = "---\nid: CT-1\ntitle: Spike: find out\n---\nBody\n";
        assert!(
            validate_research_dispatch(&spike, contents)
                .unwrap_err()
                .message
                .starts_with("Research execution mode must be explicit")
        );
        let explicit = "---\nid: CT-1\nexecution_mode: spike\n---\nBody\n";
        assert!(validate_research_dispatch(&spike, explicit).is_ok());

        let mut gated = sized();
        gated.body = "## Required inputs\n- [x] done\n  - [ ] consent\n## Notes\n".to_string();
        assert_eq!(
            validate_research_dispatch(&gated, "---\nid: CT-1\n---\n")
                .unwrap_err()
                .message,
            "Resolve the ticket's Required inputs before dispatch; no worker was started."
        );
        gated.body = "## Required inputs\n- [x] done\n## Notes\n- [ ] later\n".to_string();
        assert!(validate_research_dispatch(&gated, "---\nid: CT-1\n---\n").is_ok());
    }

    #[test]
    fn dirty_checkouts_are_reported_bounded() {
        assert_eq!(dirty_source_blocker("", false, 8), None);
        let status = " M src/a.rs\0?? new file.txt\0R  b.rs\0old b.rs\0 M .orchestrator/CT-1.md\0";
        let blocker = dirty_source_blocker(status, true, 8).unwrap();
        assert_eq!(blocker.dirty_paths, ["src/a.rs", "new file.txt", "b.rs"]);
        assert_eq!(
            blocker.reason,
            "source checkout has uncommitted changes (tracked: src/a.rs; untracked: new \
             file.txt; tracked: b.rs)"
        );
        let all = dirty_source_blocker(status, false, 2).unwrap();
        assert_eq!(all.dirty_paths, ["src/a.rs", "new file.txt"]);
        assert!(all.reason.ends_with("; +2 more)"), "{}", all.reason);
        let only_board = dirty_source_blocker(" M .orchestrator/CT-1.md\0", true, 8);
        assert_eq!(only_board, None);
        let long = format!(" M {}\u{e9}\0", "a".repeat(200));
        let bounded = dirty_source_blocker(&long, false, 8).unwrap();
        assert_eq!(bounded.dirty_paths[0].len(), 160);
        assert!(bounded.dirty_paths[0].ends_with("..."));
    }

    #[test]
    fn workspace_slugs_name_repo_digest_and_ticket() {
        let slug = workspace_slug(Path::new("/tmp/My Repo"), "CT-1").unwrap();
        assert!(slug.starts_with("my-repo-"), "{slug}");
        assert!(slug.ends_with("-ct-1"), "{slug}");
        assert_eq!(slug.len(), "my-repo-".len() + 8 + "-ct-1".len());
    }
}
