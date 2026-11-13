//! `relay-rs hook`: the provider lifecycle hook transport. The Rust form of
//! `services/relay_completion_hook.py`; docs/specs/hook-contract.md is the
//! contract both are accepted against.
//!
//! The hook observes provider lifecycle JSON on stdin and publishes only Relay
//! voice-correlated final replies back to the bridge. It also records bounded
//! automatic-compaction diagnostics and the session binding. It never logs
//! prompt text, final response text, transcript paths, summaries or raw
//! payloads.

mod binding;
mod broker;
mod compaction;
mod continuation;
mod turns;

use crate::json::{self, Dict, Value, py_int_from_str, py_strip};
use crate::support::{self, Failure, env_optional, env_or, env_text, is_foreground_owner};

use broker::ProviderTurnBroker;

const DIAGNOSTIC_PREFIX: &str = "[relay_completion_hook]";

/// The hook's files and limits, read from the environment once.
pub struct Settings {
    state_path: String,
    claim_path: String,
    turns_path: String,
    projection_path: String,
    manual_submissions_path: String,
    inbox_path: String,
    broker_mode: String,
    fifo_path: String,
    session_key: String,
    turn_ttl_seconds: f64,
    turn_limit: i64,
    evidence_ttl_seconds: f64,
    session_events_path: String,
    compaction_events_path: String,
    threshold_tokens: i64,
}

impl Settings {
    fn from_environment() -> Self {
        let number =
            |name: &str, default: f64| py_strip(&env_or(name, "")).parse().unwrap_or(default);
        let session_events_path = env_or("RELAY_SESSION_EVENTS", "");
        Self {
            state_path: env_or("VOICE_COMMAND_STATE_FILE", "/tmp/voice_command_state.json"),
            claim_path: env_or("VOICE_COMMAND_CLAIM_FILE", "/tmp/voice_cmd_claimed.json"),
            turns_path: env_or(
                "VOICE_PROVIDER_TURNS_FILE",
                "/tmp/voice_provider_turns.json",
            ),
            projection_path: env_or(
                "VOICE_PROVIDER_TURN_PROJECTION_FILE",
                "/tmp/voice_provider_turns_v2.json",
            ),
            manual_submissions_path: env_or(
                "RELAY_TERMINAL_MANUAL_SUBMISSION_FILE",
                "/tmp/relay_terminal_manual_submission.json",
            ),
            inbox_path: env_or("VOICE_INTENT_INBOX", "/tmp/relay_intent_inbox.sqlite3"),
            broker_mode: py_strip(&env_or("RELAY_PROVIDER_TURN_BROKER_MODE", "dual_write"))
                .to_string(),
            fifo_path: env_or("VOICE_FIFO", "/tmp/voice_in.fifo"),
            session_key: env_text("RELAY_SESSION_KEY"),
            turn_ttl_seconds: number("VOICE_PROVIDER_TURN_TTL_SECONDS", 3600.0),
            turn_limit: py_int_from_str(&env_or("VOICE_PROVIDER_TURN_LIMIT", "")).unwrap_or(32),
            evidence_ttl_seconds: number("RELAY_MANUAL_SUBMISSION_EVIDENCE_TTL_SECONDS", 10.0),
            compaction_events_path: env_or("RELAY_CONTEXT_COMPACTION_EVENTS", &session_events_path),
            session_events_path,
            threshold_tokens: py_int_from_str(&env_or("RELAY_AUTO_COMPACT_THRESHOLD_TOKENS", ""))
                .map_or(150_000, |tokens| tokens.max(1)),
        }
    }
}

/// One lifecycle event and what the environment says about its session.
pub struct Event<'a> {
    settings: &'a Settings,
    payload: &'a Dict,
    now: f64,
    /// The foreground ownership envelope, when the session has one.
    ownership: Option<Dict>,
    /// `RELAY_PROVIDER_SESSION_ID`, trimmed and non-empty.
    environment_provider_session_id: Option<String>,
}

impl Event<'_> {
    fn name(&self) -> String {
        let payload = self.payload;
        let name = payload
            .truthy("hook_event_name")
            .or_else(|| payload.truthy("hookEventName"));
        py_strip(&name.map(Value::py_str).unwrap_or_default()).to_string()
    }

    /// The provider: the launch's, else the claim's, else the event's.
    fn provider(&self, claim: Option<&Dict>) -> Option<String> {
        let launch = env_optional("RELAY_RUNNER_PROVIDER").unwrap_or_default();
        [
            launch,
            claim
                .map(|claim| claim.string("provider"))
                .unwrap_or_default(),
            self.payload.string("provider"),
        ]
        .into_iter()
        .map(|value| py_strip(&value).to_lowercase())
        .find(|value| !value.is_empty())
    }

    fn session_id(&self) -> String {
        ["session_id", "sessionId"]
            .into_iter()
            .map(|key| self.payload.text(key))
            .find(|value| !value.is_empty())
            .unwrap_or_else(|| "unknown".to_string())
    }

    /// The native turn. Claude Code hooks carry no `turn_id`, and
    /// `session_id` is constant across a session's turns; `prompt_id` is
    /// unique per turn and shared by that turn's UserPromptSubmit and
    /// Stop/StopFailure payloads, so it pairs them exactly.
    fn turn_id(&self) -> Option<String> {
        let named = ["turn_id", "turnId"]
            .into_iter()
            .map(|key| self.payload.text(key))
            .find(|value| !value.is_empty());
        if named.is_some() {
            return named;
        }
        if self.provider(None).as_deref() == Some("claude") {
            return Some(self.payload.text("prompt_id")).filter(|value| !value.is_empty());
        }
        None
    }

    fn provider_session_id(&self) -> Option<String> {
        ["provider_session_id", "providerSessionId"]
            .into_iter()
            .map(|key| self.payload.text(key))
            .find(|value| !value.is_empty())
            .or_else(|| self.environment_provider_session_id.clone())
    }

    /// Whether `record` belongs to this session's foreground owner.
    fn owns(&self, record: &Dict) -> bool {
        self.ownership
            .as_ref()
            .is_some_and(|ownership| turns::same_foreground_owner(record, ownership))
    }

    fn diagnostic(&self, kind: &str, fields: Dict) {
        eprintln!(
            "{DIAGNOSTIC_PREFIX} {kind} {}",
            json::dumps_compact_sorted(&Value::Dict(fields))
        );
    }
}

fn note(message: &str) {
    eprintln!("{DIAGNOSTIC_PREFIX} {message}");
}

fn open_turn_broker(settings: &Settings) -> Result<Option<ProviderTurnBroker>, Failure> {
    if settings.broker_mode == "legacy" {
        return Ok(None);
    }
    ProviderTurnBroker::open(&settings.inbox_path, &settings.projection_path).map(Some)
}

fn handle_hook_payload(settings: &Settings, payload: &Dict) -> Result<(), Failure> {
    let ownership = Some(support::ownership_from_environment()).filter(is_foreground_owner);
    let event = Event {
        settings,
        payload,
        now: support::now(),
        ownership,
        environment_provider_session_id: Some(env_text("RELAY_PROVIDER_SESSION_ID"))
            .filter(|value| !value.is_empty()),
    };
    let name = event.name();
    if name == "SessionStart" {
        // Claude fires SessionStart only after its first-run screens (folder
        // trust, onboarding, bypass disclaimer); the embedded terminal holds
        // voice delivery until this stage is recorded.
        let mut record = Dict::new();
        record.insert("outcome", "ready");
        record.insert("stage", "provider_session_start");
        record.insert("timestamp", support::utc_timestamp(event.now));
        compaction::append_session_event(&record, &settings.session_events_path);
        return Ok(());
    }
    let turn_event = matches!(name.as_str(), "UserPromptSubmit" | "Stop" | "StopFailure");
    if turn_event && event.ownership.is_none() {
        note("ignored lifecycle event without foreground ownership");
        return Ok(());
    }
    let broker = open_turn_broker(settings)?;
    compaction::record_diagnostic(&event, &name);
    match name.as_str() {
        "UserPromptSubmit" => turns::bind_prompt_submit(&event, broker.as_ref()),
        // stop_hook_active marks a continuation after another Stop hook
        // blocked. This hook never blocks, so there is no loop to break: a
        // turn still active here completes with this, its real final. A turn
        // an earlier Stop already completed is a duplicate.
        "Stop" | "StopFailure" => turns::complete_turn(&event, &name, broker.as_ref()),
        _ => Ok(()),
    }
}

/// One lifecycle event on stdin. Always exits 0: a hook must never fail the
/// provider's turn.
fn run_lifecycle_event() -> u8 {
    let payload = match json::parse_bytes(&support::read_stdin()) {
        Some(Value::Dict(payload)) => payload,
        Some(_) => return 0,
        None => {
            note("ignored malformed hook JSON");
            return 0;
        }
    };
    if binding::record_session_binding(&payload, false, None).is_err() {
        note("session binding unavailable");
    }
    let settings = Settings::from_environment();
    if let Err(Failure(kind)) = handle_hook_payload(&settings, &payload) {
        note(&format!("hook transport failed: {kind}"));
    }
    0
}

/// `relay-rs hook [mode]`. Any argument list but the three modes is a
/// lifecycle event, as it is for the Python script.
pub fn run(arguments: &[String]) -> u8 {
    let mode: Vec<&str> = arguments.iter().map(String::as_str).collect();
    match mode.as_slice() {
        ["--record-codex-startup"] => match binding::record_codex_startup_binding() {
            Ok(true) => 0,
            Ok(false) | Err(_) => 1,
        },
        ["--context-continuation"] => {
            let settings = Settings::from_environment();
            println!(
                "{}",
                continuation::answer(&support::read_stdin(), &settings.inbox_path)
            );
            0
        }
        ["--record-process"] => match binding::record_session_binding(&Dict::new(), true, None) {
            Ok(true) => 0,
            Ok(false) | Err(_) => 1,
        },
        _ => run_lifecycle_event(),
    }
}
