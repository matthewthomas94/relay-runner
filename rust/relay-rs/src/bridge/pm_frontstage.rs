//! Port of `services/pm_frontstage.py` for the Rust bridge (RR-492): the
//! public PM status events, the curated orchestration traces and the PM
//! update mode the bridge starts for ticket work, with the Relay command
//! metadata they all carry.
//!
//! Only what `voice_bridge.py` imports is here. The prototype planner
//! (`PMFrontstagePrototype`, `BackstageOutcome`, `DelegationRequest`, the
//! default acknowledgement builder and backstage planner) and the module's
//! command-line harness are not used by the bridge and stay in Python.
//!
//! Where the Python raises `ValueError`, these return `Err` with its message.
//! `PMUpdateMode` keeps the Python shape: it holds boxed callbacks for the
//! status reader, the current-command reader and the emitter, and `poll`
//! makes one decision; the bridge's own thread loops over it and sleeps
//! between polls, as `_start_pm_update_mode` does.

use std::fs;
use std::path::{Component, Path};
use std::sync::LazyLock;

use relay_intents::pattern::{self, Regex};

use crate::json::{Dict, Value, py_is_space, py_strip};
use crate::support::{env_or, now};

/// `STATUS_PHASES`.
pub const STATUS_PHASES: [&str; 4] = ["acknowledged", "planning", "outcome", "stale"];
/// `STATUS_SOURCES`.
pub const STATUS_SOURCES: [&str; 4] = ["pm", "orchestrator", "worker", "review-worker"];
/// `TRACE_KINDS`.
pub const TRACE_KINDS: &[&str] = &[
    "reasoning-summary",
    "clarification-request",
    "reading-context",
    "ticket-updating",
    "ticket-created",
    "dispatch-preparing",
    "dispatch-started",
    "dispatch-claimed",
    "run-running",
    "run-reviewing",
    "run-health-check",
    "run-health-warning",
    "run-review-needed",
    "run-merging",
    "run-merged",
    "run-reconciled",
    "run-integration-blocked",
    "run-verification-blocked",
    "run-verification-resumed",
    "run-succeeded",
    "run-failed",
    "run-canceled",
    "running-tests",
    "building",
    "installing",
    "preparing-response",
    "board-change",
];
/// `LIFECYCLE_DETAIL_TRACE_KINDS`: the worker lifecycle traces that carry
/// their full detail and need no command.
pub const LIFECYCLE_DETAIL_TRACE_KINDS: [&str; 10] = [
    "run-health-warning",
    "run-review-needed",
    "run-merged",
    "run-reconciled",
    "run-integration-blocked",
    "run-verification-blocked",
    "run-verification-resumed",
    "run-succeeded",
    "run-failed",
    "run-canceled",
];
pub const TRACE_MESSAGE_MAX_LEN: usize = 96;
pub const UPDATE_MODE_MESSAGE_MAX_LEN: usize = 120;

/// `_COMMAND_LIKE_TRACE_RE`.
static COMMAND_LIKE_TRACE_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        concat!(
            r"(`|\$\(|&&|\|\||\s;\s|",
            r"\b(?:bash|cat|curl|git|grep|npm|pnpm|python|python3|sh|swift|xcodebuild|yarn|zsh)\s+)",
        ),
        true,
    )
});
/// `_PRIVATE_ACTIVITY_RE`.
static PRIVATE_ACTIVITY_RE: LazyLock<Regex> = LazyLock::new(|| {
    pattern::compile(
        concat!(
            r"(transcript|source_text|tool\s+log|hidden\s+reasoning|chain[- ]of[- ]thought|",
            r"scratchpad|prompt|secret|credential|password|token|api[_ -]?key)",
        ),
        true,
    )
});

/// `_public_message`: whitespace runs collapsed to one space and stripped; an
/// empty result is refused.
fn public_message(value: &str) -> Result<String, String> {
    let message = value
        .split(py_is_space)
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if message.is_empty() {
        return Err("status events require a public user-facing message".to_string());
    }
    Ok(message)
}

/// `_clip_public_message`: at most `limit` characters, ending `...` when cut.
fn clip_public_message(message: &str, limit: usize) -> String {
    if message.chars().count() <= limit {
        return message.to_string();
    }
    let kept: String = message.chars().take(limit.saturating_sub(3)).collect();
    format!("{}...", kept.trim_end_matches(py_is_space))
}

/// `_clip_update_message`.
fn clip_update_message(message: &str) -> String {
    clip_public_message(message, UPDATE_MODE_MESSAGE_MAX_LEN)
}

fn command_like_or_private(message: &str) -> bool {
    pattern::search(&COMMAND_LIKE_TRACE_RE, message)
        || pattern::search(&PRIVATE_ACTIVITY_RE, message)
}

/// `_public_trace_detail`.
fn public_trace_detail(value: &str) -> Result<String, String> {
    let message = public_message(value)?;
    if command_like_or_private(&message) {
        return Err("trace messages must not contain raw commands or private details".to_string());
    }
    Ok(message)
}

/// `_public_update_activity`: a command-like or private activity is dropped.
fn public_update_activity(value: Option<&str>) -> Result<Option<String>, String> {
    let Some(value) = value else {
        return Ok(None);
    };
    let message = public_message(value)?;
    if command_like_or_private(&message) {
        return Ok(None);
    }
    Ok(Some(clip_update_message(&message)))
}

/// Python's `repr(text)`, for the error messages that quote their input.
fn str_repr(text: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push(quote);
    for character in text.chars() {
        match character {
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            '\r' => quoted.push_str("\\r"),
            '\t' => quoted.push_str("\\t"),
            _ if character == quote => {
                quoted.push('\\');
                quoted.push(character);
            }
            _ if character < ' ' || character == '\u{7f}' => {
                quoted.push_str(&format!("\\x{:02x}", u32::from(character)));
            }
            _ => quoted.push(character),
        }
    }
    quoted.push(quote);
    quoted
}

/// Python's `repr(value)` for a JSON value.
fn value_repr(value: &Value) -> String {
    match value {
        Value::Str(text) => str_repr(text),
        other => other.py_str(),
    }
}

/// Python's `int(value)`, with the message `int()` raises.
fn py_int(value: &Value) -> Result<i64, String> {
    value.py_int().ok_or_else(|| {
        format!(
            "invalid literal for int() with base 10: {}",
            value_repr(value)
        )
    })
}

/// `_coerce_seq`.
fn coerce_seq(value: Option<&Value>) -> Result<i64, String> {
    match value {
        None | Some(Value::Null) => {
            Err("relay command metadata requires relay_command_seq".to_string())
        }
        Some(value) if value.is_str("") => {
            Err("relay command metadata requires relay_command_seq".to_string())
        }
        Some(value) => value
            .py_int()
            .ok_or_else(|| format!("invalid relay_command_seq: {}", value_repr(value))),
    }
}

/// `str(d.get(key) or "").strip() or None`.
fn optional_text(data: &Dict, key: &str) -> Option<String> {
    Some(data.text(key)).filter(|text| !text.is_empty())
}

/// `RelayCommandMetadata`: the identity of the Relay command a status event
/// or trace belongs to.
#[derive(Clone, Debug, PartialEq)]
pub struct RelayCommandMetadata {
    pub relay_command_seq: i64,
    pub relay_command_id: String,
    pub provider: Option<String>,
    pub source_text: Option<String>,
    /// Relay Remote origin (RR-423); absent for microphone commands.
    pub input_source: Option<String>,
    pub device_id: Option<String>,
}

impl RelayCommandMetadata {
    /// `RelayCommandMetadata.from_dict(payload, source_text=...)`.
    pub fn from_dict(payload: Option<&Dict>, source_text: Option<&str>) -> Result<Self, String> {
        let empty = Dict::new();
        let data = payload.unwrap_or(&empty);
        let command_id = data.text("relay_command_id");
        if command_id.is_empty() {
            return Err("relay command metadata requires relay_command_id".to_string());
        }
        let source_text = match source_text {
            Some(text) => Some(text.to_string()),
            None => data.present("source_text").map(Value::py_str),
        };
        Ok(Self {
            relay_command_seq: coerce_seq(data.get("relay_command_seq"))?,
            relay_command_id: command_id,
            provider: optional_text(data, "provider"),
            source_text,
            input_source: optional_text(data, "input_source"),
            device_id: optional_text(data, "device_id"),
        })
    }

    /// `matches(current)`: whether `current` names this command.
    pub fn matches(&self, current: Option<&Dict>) -> bool {
        let Some(current) = current else {
            return false;
        };
        let Ok(current_seq) = coerce_seq(current.get("relay_command_seq")) else {
            return false;
        };
        current_seq == self.relay_command_seq
            && current.string("relay_command_id") == self.relay_command_id
    }

    /// `to_public_dict`: never the source text.
    pub fn to_public_dict(&self) -> Dict {
        let mut data = Dict::new();
        data.insert("relay_command_seq", self.relay_command_seq);
        data.insert("relay_command_id", self.relay_command_id.as_str());
        if let Some(provider) = &self.provider {
            data.insert("provider", provider.as_str());
        }
        if let Some(input_source) = &self.input_source {
            data.insert("input_source", input_source.as_str());
            data.insert("device_id", self.device_id.clone());
        }
        data
    }
}

/// `str(value).upper()` when `value` is truthy, as both event types keep a
/// ticket id.
fn upper_ticket_id(ticket_id: Option<&str>) -> Option<String> {
    ticket_id.map(|ticket| {
        if ticket.is_empty() {
            String::new()
        } else {
            ticket.to_uppercase()
        }
    })
}

/// `PMStatusEvent`: a public status event for the notch.
#[derive(Clone, Debug, PartialEq)]
pub struct PMStatusEvent {
    pub phase: String,
    pub message: String,
    pub source: String,
    pub command: RelayCommandMetadata,
    pub run_id: Option<i64>,
    pub ticket_id: Option<String>,
}

impl PMStatusEvent {
    /// `PMStatusEvent(...)` with its `__post_init__` validation.
    pub fn new(
        phase: &str,
        message: &str,
        source: &str,
        command: RelayCommandMetadata,
        run_id: Option<i64>,
        ticket_id: Option<&str>,
    ) -> Result<Self, String> {
        let normalized_phase = py_strip(phase).to_lowercase();
        let normalized_source = py_strip(source).to_lowercase();
        if !STATUS_PHASES.contains(&normalized_phase.as_str()) {
            return Err(format!("invalid status phase: {}", str_repr(phase)));
        }
        if !STATUS_SOURCES.contains(&normalized_source.as_str()) {
            return Err(format!("invalid status source: {}", str_repr(source)));
        }
        Ok(Self {
            phase: normalized_phase,
            message: public_message(message)?,
            source: normalized_source,
            command,
            run_id,
            ticket_id: upper_ticket_id(ticket_id),
        })
    }

    /// `to_dict`.
    pub fn to_dict(&self) -> Dict {
        let mut data = Dict::new();
        data.insert("phase", self.phase.as_str());
        data.insert("message", self.message.as_str());
        data.insert("source", self.source.as_str());
        data.insert("command", self.command.to_public_dict());
        if let Some(run_id) = self.run_id {
            data.insert("run_id", run_id);
        }
        if let Some(ticket_id) = self
            .ticket_id
            .as_deref()
            .filter(|ticket| !ticket.is_empty())
        {
            data.insert("ticket_id", ticket_id);
        }
        data
    }
}

/// `default_orchestration_trace_message`: the curated words for a trace that
/// brings none. A `reasoning-summary` has none, since they would only be
/// filler.
pub fn default_orchestration_trace_message(
    kind: &str,
    ticket_id: Option<&str>,
    run_id: Option<i64>,
) -> Result<String, String> {
    let ticket = upper_ticket_id(ticket_id.map(py_strip))
        .filter(|ticket| !ticket.is_empty())
        .unwrap_or_else(|| "Ticket".to_string());
    let run = run_id.map(|run| format!(" run {run}")).unwrap_or_default();
    let message = match kind {
        "clarification-request" => "I need a little more detail".to_string(),
        "reading-context" => "Reading project context".to_string(),
        "ticket-updating" => format!("Updating {ticket}"),
        "ticket-created" => format!("Created ticket {ticket}"),
        "dispatch-preparing" => format!("Preparing {ticket} dispatch"),
        "dispatch-started" => format!("Dispatching {ticket}"),
        "dispatch-claimed" => format!("{ticket}{run} claimed"),
        "run-running" => format!("{ticket}{run} running"),
        "run-reviewing" => format!("Reviewing {ticket}{run}"),
        "run-health-check" => format!("{ticket}{run} health check passed"),
        "run-health-warning" => format!("{ticket}{run} may need attention"),
        "run-review-needed" => format!("{ticket}{run} awaiting review"),
        "run-merging" => format!("Merging {ticket}{run}"),
        "run-merged" => format!("{ticket}{run} merged"),
        "run-reconciled" => format!("{ticket}{run} history reconciled"),
        "run-integration-blocked" => format!("{ticket}{run} waiting for a clean source checkout"),
        "run-verification-blocked" => format!("{ticket}{run} waiting on external verification"),
        "run-verification-resumed" => format!("{ticket}{run} verification resumed"),
        "run-succeeded" => format!("{ticket}{run} succeeded"),
        "run-failed" => format!("{ticket}{run} failed"),
        "run-canceled" => format!("{ticket}{run} canceled"),
        "running-tests" => "Running tests".to_string(),
        "building" => "Building project".to_string(),
        "installing" => "Installing dependencies".to_string(),
        "preparing-response" => "Preparing response".to_string(),
        "board-change" if ticket_id.is_some_and(|raw| !raw.is_empty()) => {
            format!("Board updated for {ticket}")
        }
        "board-change" => "Board updated".to_string(),
        _ => {
            return Err(format!(
                "{kind} traces require a public user-facing message"
            ));
        }
    };
    Ok(message)
}

/// `orchestration_trace_status_phase`: terminal run kinds are outcomes.
pub fn orchestration_trace_status_phase(kind: &str) -> &'static str {
    match kind {
        "run-succeeded"
        | "run-failed"
        | "run-canceled"
        | "run-merged"
        | "run-reconciled"
        | "run-integration-blocked"
        | "run-verification-blocked" => "outcome",
        _ => "planning",
    }
}

/// `OrchestrationTraceEvent`: a short public trace for the notch, with its
/// whole validated wording kept as `lifecycle_detail` for the messenger.
#[derive(Clone, Debug, PartialEq)]
pub struct OrchestrationTraceEvent {
    pub kind: String,
    pub source: String,
    /// At most `TRACE_MESSAGE_MAX_LEN` characters.
    pub message: String,
    pub command: Option<RelayCommandMetadata>,
    pub run_id: Option<i64>,
    pub ticket_id: Option<String>,
    pub lifecycle_detail: String,
}

impl OrchestrationTraceEvent {
    /// `OrchestrationTraceEvent(...)` with its `__post_init__` validation
    /// (the Python defaults are `source="orchestrator"` and `None` for the
    /// rest). A message read from JSON should be passed as
    /// `data.present("message").map(|_| data.string("message"))`, which is
    /// what `_public_message`'s `str(value or "")` makes of it.
    pub fn new(
        kind: &str,
        source: &str,
        message: Option<&str>,
        command: Option<RelayCommandMetadata>,
        run_id: Option<i64>,
        ticket_id: Option<&str>,
    ) -> Result<Self, String> {
        let normalized_kind = py_strip(kind).to_lowercase();
        let normalized_source = py_strip(source).to_lowercase();
        if !TRACE_KINDS.contains(&normalized_kind.as_str()) {
            return Err(format!(
                "invalid orchestration trace kind: {}",
                str_repr(kind)
            ));
        }
        if !STATUS_SOURCES.contains(&normalized_source.as_str()) {
            return Err(format!("invalid trace source: {}", str_repr(source)));
        }
        let message = match message {
            Some(message) => message.to_string(),
            None => default_orchestration_trace_message(&normalized_kind, ticket_id, run_id)?,
        };
        let public_detail = public_trace_detail(&message)?;
        Ok(Self {
            kind: normalized_kind,
            source: normalized_source,
            message: clip_public_message(&public_detail, TRACE_MESSAGE_MAX_LEN),
            command,
            run_id,
            ticket_id: upper_ticket_id(ticket_id),
            lifecycle_detail: public_detail,
        })
    }

    /// `to_dict`.
    pub fn to_dict(&self) -> Dict {
        let mut data = Dict::new();
        data.insert("kind", self.kind.as_str());
        data.insert("message", self.message.as_str());
        data.insert("source", self.source.as_str());
        data.insert("lifecycle_detail", self.lifecycle_detail.as_str());
        if let Some(command) = &self.command {
            data.insert("command", command.to_public_dict());
        }
        if let Some(run_id) = self.run_id {
            data.insert("run_id", run_id);
        }
        if let Some(ticket_id) = self
            .ticket_id
            .as_deref()
            .filter(|ticket| !ticket.is_empty())
        {
            data.insert("ticket_id", ticket_id);
        }
        data
    }

    /// `to_status_event_dict`: the matching status event, when the trace
    /// names its command.
    pub fn to_status_event_dict(&self) -> Option<Dict> {
        let command = self.command.clone()?;
        // Every field is already validated and normalized, so this is the
        // `PMStatusEvent(...)` the Python builds, which cannot raise here.
        let event = PMStatusEvent {
            phase: orchestration_trace_status_phase(&self.kind).to_string(),
            message: self.message.clone(),
            source: self.source.clone(),
            command,
            run_id: self.run_id,
            ticket_id: self.ticket_id.clone(),
        };
        Some(event.to_dict())
    }
}

/// `PMUpdateRun`: one active worker run in an update snapshot.
#[derive(Clone, Debug, PartialEq)]
pub struct PMUpdateRun {
    pub ticket_id: Option<String>,
    pub run_id: Option<i64>,
    pub state: String,
    /// Public and at most `UPDATE_MODE_MESSAGE_MAX_LEN` characters; a
    /// command-like or private activity is dropped.
    pub activity: Option<String>,
}

impl PMUpdateRun {
    /// `PMUpdateRun(...)` with its `__post_init__` validation.
    pub fn new(
        ticket_id: Option<&str>,
        run_id: Option<i64>,
        state: &str,
        activity: Option<&str>,
    ) -> Result<Self, String> {
        Ok(Self {
            ticket_id: upper_ticket_id(ticket_id),
            run_id,
            state: public_message(state)?,
            activity: public_update_activity(activity)?,
        })
    }
}

/// `PMUpdateSnapshot`: what update mode reads from the daemon on each poll.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PMUpdateSnapshot {
    pub session_state: Option<String>,
    pub active_runs: Vec<PMUpdateRun>,
    pub blocked_tickets: i64,
    pub awaiting_merge: i64,
    pub stale_runs: i64,
    pub open_tickets: i64,
}

impl PMUpdateSnapshot {
    /// `signature(state)`: the Python tuple holds the state and every field
    /// of the snapshot, so the pair compares the same.
    pub fn signature(&self, state: &str) -> (String, PMUpdateSnapshot) {
        (state.to_string(), self.clone())
    }
}

/// `PMUpdatePollResult`.
#[derive(Clone, Debug, PartialEq)]
pub struct PMUpdatePollResult {
    pub continue_running: bool,
    pub state: String,
    pub emitted_event: Option<PMStatusEvent>,
    pub stale: bool,
}

/// `_provider_key`: `claude` or `codex`, from any provider spelling.
fn provider_key(value: &str) -> Option<&'static str> {
    let text = py_strip(value).to_lowercase();
    if text.is_empty() {
        return None;
    }
    Some(if text.contains("claude") {
        "claude"
    } else {
        "codex"
    })
}

/// `str(Path(raw).expanduser().resolve())`: `~` expanded, made absolute,
/// links followed, and parts that do not exist kept as written.
fn resolve_path(raw: &str) -> String {
    let expanded = match raw.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => {
            format!("{}{rest}", env_or("HOME", ""))
        }
        _ => raw.to_string(),
    };
    let path = Path::new(&expanded);
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    };
    let mut missing = Vec::new();
    let mut existing = absolute.as_path();
    let mut resolved = loop {
        if let Ok(resolved) = fs::canonicalize(existing) {
            break resolved;
        }
        match (existing.parent(), existing.components().next_back()) {
            (Some(parent), Some(last)) => {
                missing.push(last);
                existing = parent;
            }
            _ => break Path::new("/").to_path_buf(),
        }
    };
    for component in missing.into_iter().rev() {
        match component {
            Component::ParentDir => {
                resolved.pop();
            }
            Component::Normal(name) => resolved.push(name),
            _ => {}
        }
    }
    resolved.to_string_lossy().into_owned()
}

/// `_normalize_path_text`, for text already read as `str(value or "")`.
fn normalize_path_text(value: &str) -> String {
    let raw = py_strip(value);
    if raw.is_empty() {
        return String::new();
    }
    resolve_path(raw)
}

/// The dict rows of `payload[key]` when that is a list.
fn dict_rows(value: Option<&Value>) -> Vec<&Dict> {
    value
        .and_then(Value::as_list)
        .map(|rows| rows.iter().filter_map(Value::as_dict).collect())
        .unwrap_or_default()
}

/// `_select_orchestrator_session`: the session with `session_id`, else the
/// first for the repository and provider.
fn select_orchestrator_session<'a>(
    sessions_payload: Option<&'a Dict>,
    repo: &str,
    provider: Option<&'static str>,
    session_id: Option<i64>,
) -> Result<Option<&'a Dict>, String> {
    let sessions = sessions_payload
        .map(|payload| {
            dict_rows(match payload.get("orchestrator_sessions") {
                Some(sessions) => Some(sessions),
                None => payload.get("sessions"),
            })
        })
        .unwrap_or_default();
    if let Some(session_id) = session_id {
        for row in &sessions {
            let id = match row.truthy("id") {
                Some(id) => py_int(id)?,
                None => 0,
            };
            if id == session_id {
                return Ok(Some(row));
            }
        }
    }
    Ok(sessions.into_iter().find(|row| {
        normalize_path_text(&row.string("repo_path")) == repo
            && (provider.is_none() || provider_key(&row.string("provider_key")) == provider)
    }))
}

/// `_summary_item_for_repo`: the program summary item for the repository.
fn summary_item_for_repo<'a>(program_payload: Option<&'a Dict>, repo: &str) -> Option<&'a Dict> {
    dict_rows(program_payload?.get("items"))
        .into_iter()
        .find(|item| {
            item.get("project")
                .and_then(Value::as_dict)
                .is_some_and(|project| normalize_path_text(&project.string("path")) == repo)
        })
}

/// `int(summary.get(key) or 0)`.
fn summary_count(summary: Option<&Dict>, key: &str) -> Result<i64, String> {
    match summary.and_then(|summary| summary.truthy(key)) {
        Some(value) => py_int(value),
        None => Ok(0),
    }
}

/// `build_pm_update_snapshot`: the repository's session state, its first
/// three claimed or running runs and its program counts, from the daemon's
/// `/v1/orchestrator-sessions`, `/v1/runs` and `/v1/program/status`
/// payloads. An `Err` is where the Python raises reading a malformed number.
pub fn build_pm_update_snapshot(
    repo_path: &str,
    sessions_payload: Option<&Dict>,
    runs_payload: Option<&Dict>,
    program_payload: Option<&Dict>,
    provider: Option<&str>,
    session_id: Option<i64>,
) -> Result<PMUpdateSnapshot, String> {
    let repo = normalize_path_text(repo_path);
    let provider = provider.and_then(provider_key);
    let session = select_orchestrator_session(sessions_payload, &repo, provider, session_id)?;

    let mut active_runs = Vec::new();
    for row in dict_rows(runs_payload.and_then(|payload| payload.get("runs"))) {
        if normalize_path_text(&row.string("repo_path")) != repo {
            continue;
        }
        if provider.is_some() && provider_key(&row.string("provider_key")) != provider {
            continue;
        }
        let state = row.text("state");
        if state != "Claimed" && state != "Running" {
            continue;
        }
        let ticket_id = optional_text(row, "ticket_id");
        let run_id = row.present("id").map(py_int).transpose()?;
        let activity = optional_text(row, "activity");
        active_runs.push(PMUpdateRun::new(
            ticket_id.as_deref(),
            run_id,
            &state,
            activity.as_deref(),
        )?);
    }
    active_runs.truncate(3);

    let summary = summary_item_for_repo(program_payload, &repo);
    Ok(PMUpdateSnapshot {
        session_state: session
            .map(|session| session.text("state").to_lowercase())
            .filter(|state| !state.is_empty()),
        active_runs,
        blocked_tickets: summary_count(summary, "blocked")?,
        awaiting_merge: summary_count(summary, "awaiting_merge")?,
        stale_runs: summary_count(summary, "stale_runs")?,
        open_tickets: summary_count(summary, "open_tickets")?,
    })
}

/// `_active_run_message`: the first two runs, with a count when there are
/// more than one.
fn active_run_message(active_runs: &[PMUpdateRun]) -> String {
    let parts: Vec<String> = active_runs
        .iter()
        .take(2)
        .map(|run| {
            let mut subject = run
                .ticket_id
                .clone()
                .filter(|ticket| !ticket.is_empty())
                .unwrap_or_else(|| "Worker".to_string());
            if let Some(run_id) = run.run_id {
                subject.push_str(&format!(" run {run_id}"));
            }
            let detail = match &run.activity {
                Some(activity) if !activity.is_empty() => activity.as_str(),
                _ if run.state == "Claimed" => "Starting work",
                _ => "Working",
            };
            format!("{subject}: {detail}")
        })
        .collect();
    if active_runs.len() == 1 {
        return clip_update_message(&parts[0]);
    }
    let remaining = active_runs.len() - parts.len();
    let mut prefix = format!("{} workers active", active_runs.len());
    if remaining > 0 {
        prefix.push_str(&format!(" (+{remaining} more)"));
    }
    clip_update_message(&format!("{prefix}. {}", parts.join("; ")))
}

/// `_count_phrase` with the regular plural.
fn count_phrase(count: i64, singular: &str) -> String {
    if count == 1 {
        format!("{count} {singular}")
    } else {
        format!("{count} {singular}s")
    }
}

/// `summarize_pm_update_snapshot`: the update-mode state, the status phase
/// and the public message for a snapshot.
pub fn summarize_pm_update_snapshot(
    snapshot: &PMUpdateSnapshot,
    startup_grace_active: bool,
    saw_progress: bool,
) -> (&'static str, &'static str, String) {
    let terminal = match snapshot.session_state.as_deref() {
        Some("failed") => Some((
            "failed",
            "The orchestrator session needs attention before work can continue.",
        )),
        Some("stopped") => Some((
            "stopped",
            "The orchestrator session stopped before finishing the status loop.",
        )),
        Some("stale") => Some((
            "stale",
            "The orchestrator session went stale, so update mode stopped.",
        )),
        _ => None,
    };
    if let Some((state, message)) = terminal {
        return (state, "outcome", clip_update_message(message));
    }

    if !snapshot.active_runs.is_empty() {
        return (
            "awaiting_workers",
            "planning",
            active_run_message(&snapshot.active_runs),
        );
    }

    if snapshot.blocked_tickets != 0 || snapshot.stale_runs != 0 {
        let mut parts = Vec::new();
        if snapshot.blocked_tickets != 0 {
            parts.push(count_phrase(snapshot.blocked_tickets, "blocked ticket"));
        }
        if snapshot.stale_runs != 0 {
            parts.push(count_phrase(snapshot.stale_runs, "stale run"));
        }
        let message = format!("Needs attention: {}.", parts.join(", "));
        return ("blocked", "planning", clip_update_message(&message));
    }

    if snapshot.awaiting_merge != 0 {
        let message = format!(
            "Waiting on review or merge for {}.",
            count_phrase(snapshot.awaiting_merge, "ticket")
        );
        return ("reviewing", "outcome", clip_update_message(&message));
    }

    if startup_grace_active && !saw_progress {
        return (
            "planning",
            "planning",
            "Planning the work and checking current status.".to_string(),
        );
    }

    (
        "idle",
        "outcome",
        "No active worker runs right now.".to_string(),
    )
}

/// `UpdateStatusReader`: the snapshot `_fetch_pm_update_snapshot` builds. An
/// `Err` is where that raises; the bridge's error type tells a failed fetch
/// (the Python loop reports it and marks the session `blocked`) from a
/// malformed payload (the Python thread ends on the exception).
pub type UpdateStatusReader<E> = Box<dyn FnMut() -> Result<PMUpdateSnapshot, E> + Send>;
/// `CurrentCommandReader`: the newest command, as the state file holds it.
pub type CurrentCommandReader = Box<dyn FnMut() -> Option<Dict> + Send>;
/// `StatusEmitter`.
pub type StatusEmitter = Box<dyn FnMut(&PMStatusEvent) + Send>;

/// `PMUpdateMode`: after ticket work is queued, polls the daemon and emits a
/// public status event when the picture changes, or on the cadence while
/// work is under way, until the work settles or a newer command takes over.
pub struct PMUpdateMode<E> {
    pub command: RelayCommandMetadata,
    status_reader: UpdateStatusReader<E>,
    current_command_reader: Option<CurrentCommandReader>,
    emit_callback: Option<StatusEmitter>,
    pub cadence_seconds: f64,
    pub startup_grace_seconds: f64,
    pub started_at: f64,
    pub last_emitted_at: f64,
    last_signature: Option<(String, PMUpdateSnapshot)>,
    pub state: String,
    pub saw_progress: bool,
}

impl<E> PMUpdateMode<E> {
    /// `PMUpdateMode(...)`; the bridge passes `PM_UPDATE_CADENCE_SECONDS` and
    /// `PM_UPDATE_STARTUP_GRACE_SECONDS` (Python defaults 8.0 and 6.0).
    pub fn new(
        command: RelayCommandMetadata,
        status_reader: UpdateStatusReader<E>,
        current_command_reader: Option<CurrentCommandReader>,
        emit: Option<StatusEmitter>,
        cadence_seconds: f64,
        startup_grace_seconds: f64,
    ) -> Self {
        Self {
            command,
            status_reader,
            current_command_reader,
            emit_callback: emit,
            cadence_seconds: cadence_seconds.max(1.0),
            startup_grace_seconds: startup_grace_seconds.max(0.0),
            started_at: now(),
            last_emitted_at: 0.0,
            last_signature: None,
            state: "planning".to_string(),
            saw_progress: false,
        }
    }

    /// `poll(now=...)`: one decision at `moment` (`time.time()` when `None`).
    /// A superseded command stops before the status reader is called.
    pub fn poll(&mut self, moment: Option<f64>) -> Result<PMUpdatePollResult, E> {
        let moment = moment.unwrap_or_else(now);
        if !self.command_is_current() {
            self.state = "stale".to_string();
            return Ok(PMUpdatePollResult {
                continue_running: false,
                state: "stale".to_string(),
                emitted_event: None,
                stale: true,
            });
        }

        let snapshot = (self.status_reader)()?;
        let startup_grace_active = (moment - self.started_at) < self.startup_grace_seconds;
        let (state, phase, message) =
            summarize_pm_update_snapshot(&snapshot, startup_grace_active, self.saw_progress);
        if matches!(state, "awaiting_workers" | "blocked" | "reviewing") {
            self.saw_progress = true;
        }

        self.state = state.to_string();
        let signature = snapshot.signature(state);
        if self.last_signature.is_none() && state == "planning" && !self.saw_progress {
            self.last_signature = Some(signature);
            return Ok(PMUpdatePollResult {
                continue_running: true,
                state: state.to_string(),
                emitted_event: None,
                stale: false,
            });
        }
        let changed = self.last_signature.as_ref() != Some(&signature);
        let terminal = matches!(state, "failed" | "stopped" | "stale")
            || (state == "idle" && (self.saw_progress || !startup_grace_active));
        let mut event = None;
        let cadence_due = self.last_emitted_at != 0.0
            && (moment - self.last_emitted_at) >= self.cadence_seconds
            && state != "idle";
        if changed || cadence_due {
            let source = if snapshot.active_runs.is_empty() {
                "orchestrator"
            } else {
                "worker"
            };
            let emitted =
                PMStatusEvent::new(phase, &message, source, self.command.clone(), None, None)
                    .expect("update-mode messages are never empty");
            self.last_emitted_at = moment;
            if let Some(emit) = self.emit_callback.as_mut() {
                emit(&emitted);
            }
            event = Some(emitted);
        }
        self.last_signature = Some(signature);
        Ok(PMUpdatePollResult {
            continue_running: !terminal,
            state: state.to_string(),
            emitted_event: event,
            stale: false,
        })
    }

    /// `_command_is_current`: always, without a reader.
    fn command_is_current(&mut self) -> bool {
        match self.current_command_reader.as_mut() {
            None => true,
            Some(read) => self.command.matches(read().as_ref()),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::json::{dumps, parse};

    fn relay_command(seq: i64, command_id: &str) -> Dict {
        let mut command = Dict::new();
        command.insert("relay_command_seq", seq);
        command.insert("relay_command_id", command_id);
        command.insert("provider", "codex");
        command
    }

    fn metadata(seq: i64, command_id: &str, source_text: Option<&str>) -> RelayCommandMetadata {
        RelayCommandMetadata::from_dict(Some(&relay_command(seq, command_id)), source_text).unwrap()
    }

    fn trace(kind: &str, message: Option<&str>) -> Result<OrchestrationTraceEvent, String> {
        OrchestrationTraceEvent::new(kind, "orchestrator", message, None, None, None)
    }

    fn object(text: &str) -> Dict {
        match parse(text) {
            Some(Value::Dict(dict)) => dict,
            _ => panic!("not an object: {text}"),
        }
    }

    #[test]
    fn status_event_contract_is_public_and_structured() {
        let command = metadata(7, "cmd-7", Some("dispatch RR-7 with hidden details"));
        let event = PMStatusEvent::new(
            "outcome",
            "The PM can dispatch the worker.",
            "orchestrator",
            command,
            Some(42),
            Some("rr-7"),
        )
        .unwrap();

        let payload = event.to_dict();
        assert!(payload.get("phase").unwrap().is_str("outcome"));
        assert!(
            payload
                .get("message")
                .unwrap()
                .is_str("The PM can dispatch the worker.")
        );
        assert!(payload.get("source").unwrap().is_str("orchestrator"));
        assert!(payload.get("ticket_id").unwrap().is_str("RR-7"));
        assert_eq!(payload.get("run_id").unwrap().py_int(), Some(42));
        let command = payload.get("command").unwrap().as_dict().unwrap();
        assert_eq!(command.get("relay_command_seq").unwrap().py_int(), Some(7));
        assert!(command.get("relay_command_id").unwrap().is_str("cmd-7"));
        assert!(command.get("provider").unwrap().is_str("codex"));
        assert!(command.get("source_text").is_none());
        assert!(payload.get("reasoning").is_none());
    }

    #[test]
    fn orchestration_trace_contract_is_curated_and_public() {
        let command = metadata(8, "cmd-8", Some("create RR-8 with private transcript text"));
        let event = OrchestrationTraceEvent::new(
            "dispatch-claimed",
            "orchestrator",
            None,
            Some(command),
            Some(51),
            Some("rr-8"),
        )
        .unwrap();

        let payload = event.to_dict();
        assert!(payload.get("kind").unwrap().is_str("dispatch-claimed"));
        assert!(
            payload
                .get("message")
                .unwrap()
                .is_str("RR-8 run 51 claimed")
        );
        assert!(payload.get("ticket_id").unwrap().is_str("RR-8"));
        assert_eq!(payload.get("run_id").unwrap().py_int(), Some(51));
        let command = payload.get("command").unwrap().as_dict().unwrap();
        assert!(command.get("relay_command_id").unwrap().is_str("cmd-8"));
        assert!(command.get("source_text").is_none());
        assert!(event.message.chars().count() <= 96);

        let status_event = event.to_status_event_dict().unwrap();
        assert!(status_event.get("phase").unwrap().is_str("planning"));
        assert!(
            status_event
                .get("message")
                .unwrap()
                .is_str("RR-8 run 51 claimed")
        );
    }

    #[test]
    fn lifecycle_trace_preserves_validated_detail_beyond_compact_message() {
        let detail = concat!(
            "RR-279 verification resumed: Mounted test on the currently running installed ",
            "Relay Runner v0.4.35 after Screen Recording and Accessibility were granted."
        );
        let event = OrchestrationTraceEvent::new(
            "run-verification-resumed",
            "orchestrator",
            Some(detail),
            None,
            Some(15),
            Some("RR-279"),
        )
        .unwrap();

        let payload = event.to_dict();
        assert!(payload.get("lifecycle_detail").unwrap().is_str(detail));
        assert!(event.message.chars().count() <= 96);
        assert!(event.message.ends_with("..."));
        assert!(event.to_status_event_dict().is_none());

        let long = "A".repeat(120);
        let progress = trace("reasoning-summary", Some(&long)).unwrap();
        assert!(progress.message.chars().count() <= 96);
        assert!(progress.message.ends_with("..."));
        assert_eq!(progress.lifecycle_detail, long);
    }

    #[test]
    fn lifecycle_detail_uses_the_same_public_content_validation() {
        for private_detail in [
            "RR-279 failed after inspecting a secret token from the transcript",
            "RR-279 failed because stored credentials were unavailable",
        ] {
            let error = trace("run-failed", Some(private_detail)).unwrap_err();
            assert!(
                error.contains("raw commands or private details"),
                "{private_detail}"
            );
        }
    }

    #[test]
    fn reasoning_summary_requires_its_own_message() {
        let error = trace("reasoning-summary", None).unwrap_err();
        assert!(error.contains("require a public user-facing message"));
        let event = trace(
            "reasoning-summary",
            Some("Checking how replies reach the notch"),
        )
        .unwrap();
        assert_eq!(event.message, "Checking how replies reach the notch");
    }

    #[test]
    fn foreground_trace_kinds_cover_provider_neutral_main_agent_activity() {
        let command = metadata(9, "cmd-9", None);
        let cases = [
            ("clarification-request", "I need a little more detail"),
            ("reading-context", "Reading project context"),
            ("ticket-updating", "Updating RR-9"),
            ("dispatch-preparing", "Preparing RR-9 dispatch"),
            ("run-reviewing", "Reviewing RR-9 run 12"),
            ("run-health-check", "RR-9 run 12 health check passed"),
            ("run-health-warning", "RR-9 run 12 may need attention"),
            ("run-merging", "Merging RR-9 run 12"),
            ("running-tests", "Running tests"),
            ("building", "Building project"),
            ("installing", "Installing dependencies"),
            ("preparing-response", "Preparing response"),
        ];
        for (kind, expected) in cases {
            let event = OrchestrationTraceEvent::new(
                kind,
                "orchestrator",
                None,
                Some(command.clone()),
                Some(12),
                Some("rr-9"),
            )
            .unwrap();
            assert_eq!(event.message, expected, "{kind}");
            let status = event.to_status_event_dict().unwrap();
            assert!(status.get("phase").unwrap().is_str("planning"), "{kind}");
        }
    }

    #[test]
    fn review_worker_trace_source_is_public_status_safe() {
        let event = OrchestrationTraceEvent::new(
            "run-reviewing",
            "review-worker",
            None,
            None,
            Some(12),
            Some("RR-9"),
        )
        .unwrap();
        assert_eq!(event.source, "review-worker");
        assert_eq!(event.message, "Reviewing RR-9 run 12");
    }

    #[test]
    fn canceled_run_trace_is_public_outcome() {
        let command = metadata(12, "cmd-12", None);
        let event = OrchestrationTraceEvent::new(
            "run-canceled",
            "worker",
            None,
            Some(command),
            Some(12),
            Some("RR-9"),
        )
        .unwrap();
        assert_eq!(event.message, "RR-9 run 12 canceled");
        let status = event.to_status_event_dict().unwrap();
        assert!(status.get("phase").unwrap().is_str("outcome"));
    }

    #[test]
    fn orchestration_trace_rejects_commands_and_private_details() {
        let command = metadata(10, "cmd-10", None);
        for message in [
            "git status --short",
            "Reviewed secret token from transcript",
        ] {
            let result = OrchestrationTraceEvent::new(
                "reading-context",
                "orchestrator",
                Some(message),
                Some(command.clone()),
                None,
                None,
            );
            assert!(result.is_err(), "{message}");
        }
    }

    #[test]
    fn orchestration_trace_rejects_raw_command_like_messages() {
        let error = trace("board-change", Some("git status && cat secret.txt")).unwrap_err();
        assert!(error.contains("raw commands"));
    }

    #[test]
    fn reasoning_summary_allows_public_assessment_but_rejects_hidden_chain_of_thought() {
        let event = trace(
            "reasoning-summary",
            Some("My current reasoning is to inspect the bridge boundary first"),
        )
        .unwrap();
        assert!(event.message.contains("reasoning"));
        assert!(
            trace(
                "reasoning-summary",
                Some("Here is my hidden chain-of-thought")
            )
            .is_err()
        );
    }

    /// The exact JSON the Python produces for the same inputs.
    #[test]
    fn payloads_match_the_python_json() {
        let mut raw = object(
            r#"{"relay_command_seq": "7", "relay_command_id": " cmd-7 ", "provider": "claude", "input_source": "remote", "device_id": ""}"#,
        );
        let command = RelayCommandMetadata::from_dict(Some(&raw), Some("x")).unwrap();
        let event = OrchestrationTraceEvent::new(
            " Dispatch-Claimed ",
            "Worker",
            None,
            Some(command.clone()),
            Some(51),
            Some("rr-8"),
        )
        .unwrap();
        assert_eq!(
            dumps(&Value::Dict(event.to_dict())),
            r#"{"kind": "dispatch-claimed", "message": "RR-8 run 51 claimed", "source": "worker", "lifecycle_detail": "RR-8 run 51 claimed", "command": {"relay_command_seq": 7, "relay_command_id": "cmd-7", "provider": "claude", "input_source": "remote", "device_id": null}, "run_id": 51, "ticket_id": "RR-8"}"#
        );
        assert_eq!(
            dumps(&Value::Dict(event.to_status_event_dict().unwrap())),
            r#"{"phase": "planning", "message": "RR-8 run 51 claimed", "source": "worker", "command": {"relay_command_seq": 7, "relay_command_id": "cmd-7", "provider": "claude", "input_source": "remote", "device_id": null}, "run_id": 51, "ticket_id": "RR-8"}"#
        );

        let long = concat!(
            "  I found\n three\n verification-blocked tickets. I am separating their real-world ",
            "evidence requirements from the checks that can run in this worktree now."
        );
        assert_eq!(
            dumps(&Value::Dict(
                trace("reasoning-summary", Some(long)).unwrap().to_dict()
            )),
            r#"{"kind": "reasoning-summary", "message": "I found three verification-blocked tickets. I am separating their real-world evidence require...", "source": "orchestrator", "lifecycle_detail": "I found three verification-blocked tickets. I am separating their real-world evidence requirements from the checks that can run in this worktree now."}"#
        );
        let board = OrchestrationTraceEvent::new(
            "board-change",
            "orchestrator",
            None,
            None,
            None,
            Some("  "),
        )
        .unwrap();
        assert_eq!(
            dumps(&Value::Dict(board.to_dict())),
            r#"{"kind": "board-change", "message": "Board updated for Ticket", "source": "orchestrator", "lifecycle_detail": "Board updated for Ticket", "ticket_id": "  "}"#
        );

        let plain = RelayCommandMetadata::from_dict(
            Some(&object(
                r#"{"relay_command_seq": 2.0, "relay_command_id": "c"}"#,
            )),
            None,
        )
        .unwrap();
        let status = PMStatusEvent::new(
            " OUTCOME ",
            " a \t b ",
            "Review-Worker",
            plain,
            Some(0),
            Some(""),
        )
        .unwrap();
        assert_eq!(
            dumps(&Value::Dict(status.to_dict())),
            r#"{"phase": "outcome", "message": "a b", "source": "review-worker", "command": {"relay_command_seq": 2, "relay_command_id": "c"}, "run_id": 0}"#
        );

        assert!(command.matches(Some(&object(
            r#"{"relay_command_seq": 7, "relay_command_id": "cmd-7"}"#
        ))));
        assert!(!command.matches(Some(&object(
            r#"{"relay_command_seq": "7", "relay_command_id": " cmd-7 "}"#
        ))));
        assert!(!command.matches(Some(&object(
            r#"{"relay_command_seq": true, "relay_command_id": "cmd-7"}"#
        ))));
        assert!(!command.matches(None));
        raw.remove("relay_command_seq");
        assert!(!command.matches(Some(&raw)));
    }

    #[test]
    fn errors_carry_the_python_messages() {
        let command = metadata(1, "c", None);
        let from =
            |text: &str| RelayCommandMetadata::from_dict(Some(&object(text)), None).unwrap_err();
        assert_eq!(
            PMStatusEvent::new("bogus", "m", "pm", command.clone(), None, None).unwrap_err(),
            "invalid status phase: 'bogus'"
        );
        assert_eq!(
            PMStatusEvent::new("outcome", "m", "it's", command, None, None).unwrap_err(),
            r#"invalid status source: "it's""#
        );
        assert_eq!(
            from(r#"{"relay_command_id": "x", "relay_command_seq": "abc"}"#),
            "invalid relay_command_seq: 'abc'"
        );
        assert_eq!(
            from(r#"{"relay_command_id": "x", "relay_command_seq": [1]}"#),
            "invalid relay_command_seq: [1]"
        );
        assert_eq!(
            from(r#"{"relay_command_id": "x", "relay_command_seq": ""}"#),
            "relay command metadata requires relay_command_seq"
        );
        assert_eq!(
            from(r#"{"relay_command_seq": 1}"#),
            "relay command metadata requires relay_command_id"
        );
        assert_eq!(
            RelayCommandMetadata::from_dict(None, None).unwrap_err(),
            "relay command metadata requires relay_command_id"
        );
        assert_eq!(
            trace("nope", None).unwrap_err(),
            "invalid orchestration trace kind: 'nope'"
        );
        assert_eq!(
            OrchestrationTraceEvent::new("board-change", "x", None, None, None, None).unwrap_err(),
            "invalid trace source: 'x'"
        );
        assert_eq!(
            trace("reasoning-summary", None).unwrap_err(),
            "reasoning-summary traces require a public user-facing message"
        );
        assert_eq!(
            trace("board-change", Some(" \n ")).unwrap_err(),
            "status events require a public user-facing message"
        );
        assert_eq!(
            trace("board-change", Some("run `ls`")).unwrap_err(),
            "trace messages must not contain raw commands or private details"
        );
    }

    #[test]
    fn build_pm_update_snapshot_uses_durable_repo_scoped_sources() {
        let sessions = object(
            r#"{"orchestrator_sessions": [
                {"id": 7, "repo_path": "/tmp/repo", "provider_key": "codex", "state": "awaiting_workers"},
                {"id": 8, "repo_path": "/tmp/other", "provider_key": "codex", "state": "idle"}
            ]}"#,
        );
        let runs = object(
            r#"{"runs": [
                {"id": 21, "repo_path": "/tmp/repo", "ticket_id": "rr-9", "state": "Running", "activity": "Running tests", "provider_key": "codex"},
                {"id": 22, "repo_path": "/tmp/repo", "ticket_id": "rr-10", "state": "Failed", "activity": "cat secret.txt", "provider_key": "codex"},
                {"id": 23, "repo_path": "/tmp/other", "ticket_id": "rr-11", "state": "Running", "activity": "Other repo", "provider_key": "codex"}
            ]}"#,
        );
        let program = object(
            r#"{"items": [{"project": {"path": "/tmp/repo"}, "open_tickets": 4, "blocked": 1, "awaiting_merge": 2, "stale_runs": 1}]}"#,
        );
        let snapshot = build_pm_update_snapshot(
            "/tmp/repo",
            Some(&sessions),
            Some(&runs),
            Some(&program),
            Some("codex"),
            Some(7),
        )
        .unwrap();

        assert_eq!(snapshot.session_state.as_deref(), Some("awaiting_workers"));
        assert_eq!(
            snapshot.active_runs,
            vec![
                PMUpdateRun::new(Some("RR-9"), Some(21), "Running", Some("Running tests")).unwrap()
            ]
        );
        assert_eq!(snapshot.blocked_tickets, 1);
        assert_eq!(snapshot.awaiting_merge, 2);
        assert_eq!(snapshot.stale_runs, 1);
        assert_eq!(snapshot.open_tickets, 4);

        // Without a session id the first session for the repository and
        // provider is chosen; another provider's runs are not counted.
        let claude = build_pm_update_snapshot(
            "/tmp/repo",
            Some(&sessions),
            Some(&runs),
            None,
            Some("claude-code"),
            None,
        )
        .unwrap();
        assert_eq!(claude, PMUpdateSnapshot::default());
        // A malformed number is an error, where the Python raises.
        let bad =
            object(r#"{"runs": [{"id": "x", "repo_path": "/tmp/repo", "state": "Running"}]}"#);
        assert!(build_pm_update_snapshot("/tmp/repo", None, Some(&bad), None, None, None).is_err());
    }

    #[test]
    fn summaries_match_the_python_wording() {
        let runs = vec![
            PMUpdateRun::new(Some("rr-1"), Some(1), "Claimed", None).unwrap(),
            PMUpdateRun::new(None, None, "Running", Some("Building the app")).unwrap(),
            PMUpdateRun::new(Some("rr-3"), Some(3), "Running", Some("x")).unwrap(),
        ];
        let summarize =
            |snapshot: PMUpdateSnapshot| summarize_pm_update_snapshot(&snapshot, false, false);
        assert_eq!(
            summarize(PMUpdateSnapshot {
                active_runs: runs.clone(),
                ..Default::default()
            }),
            (
                "awaiting_workers",
                "planning",
                "3 workers active (+1 more). RR-1 run 1: Starting work; Worker: Building the app"
                    .to_string()
            )
        );
        assert_eq!(
            summarize(PMUpdateSnapshot {
                active_runs: runs[..2].to_vec(),
                ..Default::default()
            })
            .2,
            "2 workers active. RR-1 run 1: Starting work; Worker: Building the app"
        );
        assert_eq!(
            summarize(PMUpdateSnapshot {
                blocked_tickets: 1,
                stale_runs: 2,
                ..Default::default()
            }),
            (
                "blocked",
                "planning",
                "Needs attention: 1 blocked ticket, 2 stale runs.".to_string()
            )
        );
        assert_eq!(
            summarize(PMUpdateSnapshot {
                awaiting_merge: 1,
                ..Default::default()
            }),
            (
                "reviewing",
                "outcome",
                "Waiting on review or merge for 1 ticket.".to_string()
            )
        );
        assert_eq!(
            summarize(PMUpdateSnapshot {
                session_state: Some("stale".to_string()),
                ..Default::default()
            }),
            (
                "stale",
                "outcome",
                "The orchestrator session went stale, so update mode stopped.".to_string()
            )
        );
        assert_eq!(summarize(PMUpdateSnapshot::default()).0, "idle");
        assert_eq!(
            summarize_pm_update_snapshot(&PMUpdateSnapshot::default(), true, false).0,
            "planning"
        );
    }

    #[test]
    fn pm_update_mode_emits_on_meaningful_change_and_cadence() {
        let command = metadata(10, "cmd-10", None);
        let notifications = Arc::new(Mutex::new(Vec::new()));
        let running = PMUpdateSnapshot {
            session_state: Some("awaiting_workers".to_string()),
            active_runs: vec![
                PMUpdateRun::new(Some("RR-9"), Some(51), "Running", Some("Running tests")).unwrap(),
            ],
            ..Default::default()
        };
        let mut snapshots = vec![
            PMUpdateSnapshot {
                session_state: Some("planning".to_string()),
                ..Default::default()
            },
            running.clone(),
            running,
        ]
        .into_iter();
        let log = Arc::clone(&notifications);
        let mut mode = PMUpdateMode::new(
            command,
            Box::new(move || Ok::<_, String>(snapshots.next().unwrap())),
            Some(Box::new(|| Some(relay_command(10, "cmd-10")))),
            Some(Box::new(move |event: &PMStatusEvent| {
                log.lock().unwrap().push(event.clone())
            })),
            5.0,
            2.0,
        );
        mode.started_at = 100.0;

        let first = mode.poll(Some(100.0)).unwrap();
        let second = mode.poll(Some(103.0)).unwrap();
        let third = mode.poll(Some(109.0)).unwrap();

        assert!(first.continue_running);
        assert!(first.emitted_event.is_none());
        assert_eq!(second.state, "awaiting_workers");
        assert_eq!(
            second.emitted_event.unwrap().message,
            "RR-9 run 51: Running tests"
        );
        assert_eq!(third.state, "awaiting_workers");
        let third_event = third.emitted_event.unwrap();
        assert_eq!(third_event.message, "RR-9 run 51: Running tests");
        assert_eq!(third_event.source, "worker");
        assert_eq!(notifications.lock().unwrap().len(), 2);
    }

    #[test]
    fn pm_update_mode_stops_when_newer_command_takes_over() {
        let command = metadata(11, "cmd-11", None);
        let mut mode = PMUpdateMode::new(
            command,
            Box::new(|| -> Result<PMUpdateSnapshot, String> {
                panic!("a stale poll reads no status")
            }),
            Some(Box::new(|| Some(relay_command(12, "newer")))),
            None,
            8.0,
            6.0,
        );
        mode.started_at = 100.0;

        let result = mode.poll(Some(100.0)).unwrap();

        assert!(!result.continue_running);
        assert!(result.stale);
        assert_eq!(result.state, "stale");
        assert_eq!(mode.state, "stale");
    }

    #[test]
    fn pm_update_mode_keeps_status_messages_public_and_bounded() {
        let command = metadata(13, "cmd-13", None);
        let message_log = Arc::new(Mutex::new(Vec::new()));
        let log = Arc::clone(&message_log);
        let mut mode = PMUpdateMode::new(
            command,
            Box::new(|| {
                Ok::<_, String>(PMUpdateSnapshot {
                    session_state: Some("awaiting_workers".to_string()),
                    active_runs: vec![
                        PMUpdateRun::new(
                            Some("RR-13"),
                            Some(99),
                            "Running",
                            Some(
                                "Reading source files while raw transcript text stays private and very long for clipping verification",
                            ),
                        )
                        .unwrap(),
                    ],
                    ..Default::default()
                })
            }),
            Some(Box::new(|| Some(relay_command(13, "cmd-13")))),
            Some(Box::new(move |event: &PMStatusEvent| {
                log.lock().unwrap().push(event.message.clone())
            })),
            30.0,
            0.0,
        );
        mode.started_at = 200.0;

        let result = mode.poll(Some(200.0)).unwrap();

        assert!(result.continue_running);
        assert!(message_log.lock().unwrap()[0].chars().count() <= 120);
        let event = result.emitted_event.unwrap();
        assert!(!event.message.to_lowercase().contains("transcript"));
        assert!(
            event
                .to_dict()
                .get("command")
                .unwrap()
                .as_dict()
                .unwrap()
                .get("source_text")
                .is_none()
        );
    }

    #[test]
    fn pm_update_mode_stops_once_work_settles() {
        let command = metadata(14, "cmd-14", None);
        let mut snapshots = vec![
            PMUpdateSnapshot {
                active_runs: vec![
                    PMUpdateRun::new(Some("RR-1"), Some(1), "Claimed", None).unwrap(),
                ],
                ..Default::default()
            },
            PMUpdateSnapshot::default(),
        ]
        .into_iter();
        let mut mode = PMUpdateMode::new(
            command,
            Box::new(move || Ok::<_, String>(snapshots.next().unwrap())),
            None,
            None,
            8.0,
            6.0,
        );
        mode.started_at = 100.0;

        let working = mode.poll(Some(100.0)).unwrap();
        assert!(working.continue_running);
        assert_eq!(
            working.emitted_event.unwrap().message,
            "RR-1 run 1: Starting work"
        );
        let settled = mode.poll(Some(101.0)).unwrap();
        assert!(!settled.continue_running);
        assert_eq!(settled.state, "idle");
        let event = settled.emitted_event.unwrap();
        assert_eq!(
            (event.phase.as_str(), event.source.as_str()),
            ("outcome", "orchestrator")
        );
        assert_eq!(event.message, "No active worker runs right now.");
    }
}
