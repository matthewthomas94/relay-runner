//! Lifecycle and orchestration traces: `_emit_lifecycle`,
//! `_notify_orchestration_trace`, `_orchestration_trace_payload` and
//! `_notify_state`, with the `services/pm_frontstage.py` event types they
//! build.
//!
//! The event types are the part of `relay-rs/src/bridge/pm_frontstage.rs`
//! (RR-492) the daemon uses: the bridge is a binary crate, so the daemon
//! keeps its own copy of the validation rules. The daemon only builds
//! command metadata from a sequence number, an id and a provider, so the
//! Relay Remote origin fields are left out.

use std::os::unix::net::UnixDatagram;
use std::sync::LazyLock;

use relay_intents::json::{self, Dict, Value, py_is_space, py_strip, str_repr};
use relay_intents::pattern::{self, Regex};

use crate::daemon::Daemon;
use crate::relay_command::relay_command_current;

/// The fields of one lifecycle event.
#[derive(Clone, Debug, Default)]
pub struct LifecycleEvent<'a> {
    pub kind: &'a str,
    pub ticket_id: Option<&'a str>,
    pub run_id: Option<i64>,
    /// Default `orchestrator`.
    pub source: Option<&'a str>,
    pub message: Option<&'a str>,
    pub repo_path: Option<&'a str>,
    pub provider_key: Option<&'a str>,
    /// Default true: record a messenger outcome for the repository.
    pub queue_messenger: Option<bool>,
}

impl Daemon {
    /// `_emit_lifecycle(kind, ...)`: the trace payload sent to the voice
    /// state socket and recorded for the messenger, or `None` when the event
    /// does not build.
    pub fn emit_lifecycle(&self, event: &LifecycleEvent<'_>) -> Option<Dict> {
        let payload = orchestration_trace_payload(
            event.kind,
            event.ticket_id,
            event.run_id,
            event.source.unwrap_or("orchestrator"),
            event.message,
            None,
        )?;
        self.notify_state("working", payload.clone());
        if event.queue_messenger.unwrap_or(true)
            && let Some(repo_path) = event.repo_path.filter(|repo| !repo.is_empty())
            && let Err(error) =
                self.messenger_outcomes
                    .record(repo_path, &payload, event.provider_key)
        {
            eprintln!("[orchestrator] could not queue the messenger outcome: {error}");
        }
        Some(payload)
    }

    /// `_notify_orchestration_trace(kind, ...)`.
    pub fn notify_orchestration_trace(
        &self,
        kind: &str,
        ticket_id: Option<&str>,
        run_id: Option<i64>,
        relay_command_seq: Option<&Value>,
        relay_command_id: Option<&str>,
    ) {
        let seq = relay_command_seq.filter(|value| !matches!(value, Value::Null));
        let id = relay_command_id.filter(|id| !id.is_empty());
        if (seq.is_some() || id.is_some())
            && !relay_command_current(&self.paths, seq, id.unwrap_or_default(), None)
        {
            return;
        }
        let command = (seq.is_some() || id.is_some()).then(|| {
            let mut metadata = Dict::new();
            metadata.insert("relay_command_seq", seq.cloned());
            metadata.insert("relay_command_id", id);
            metadata
        });
        if let Some(payload) = orchestration_trace_payload(
            kind,
            ticket_id,
            run_id,
            "orchestrator",
            None,
            command.as_ref(),
        ) {
            self.notify_state("working", payload);
        }
    }

    /// `_notify_state(state, **fields)`: a datagram to the voice state socket.
    pub fn notify_state(&self, state: &str, fields: Dict) -> bool {
        let mut message = Dict::new();
        message.insert("source", "orchestrator");
        message.insert("state", state);
        message.update(&fields);
        let Ok(socket) = UnixDatagram::unbound() else {
            return false;
        };
        socket
            .send_to(
                json::dumps(&Value::Dict(message)).as_bytes(),
                &self.paths.voice_state_sock,
            )
            .is_ok()
    }
}

/// `_orchestration_trace_payload(...)`: `text`, `trace_event` and, when the
/// trace names its command, `status_event`. `command` is the metadata dict
/// `RelayCommandMetadata.from_dict` reads; one it refuses is dropped.
pub(crate) fn orchestration_trace_payload(
    kind: &str,
    ticket_id: Option<&str>,
    run_id: Option<i64>,
    source: &str,
    message: Option<&str>,
    command: Option<&Dict>,
) -> Option<Dict> {
    let command = command.and_then(|data| RelayCommandMetadata::from_dict(data).ok());
    let event =
        match OrchestrationTraceEvent::new(kind, source, message, command, run_id, ticket_id) {
            Ok(event) => event,
            Err(error) => {
                eprintln!("[orchestrator] could not build orchestration trace: {error}");
                return None;
            }
        };
    let mut payload = Dict::new();
    payload.insert("text", event.message.as_str());
    payload.insert("trace_event", event.to_dict());
    if let Some(status_event) = event.to_status_event_dict() {
        payload.insert("status_event", status_event);
    }
    Some(payload)
}

// -- services/pm_frontstage.py ------------------------------------------------

/// `STATUS_PHASES`.
const STATUS_PHASES: [&str; 4] = ["acknowledged", "planning", "outcome", "stale"];
/// `STATUS_SOURCES`.
const STATUS_SOURCES: [&str; 4] = ["pm", "orchestrator", "worker", "review-worker"];
/// `TRACE_KINDS`.
const TRACE_KINDS: &[&str] = &[
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
const TRACE_MESSAGE_MAX_LEN: usize = 96;

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

/// `_public_message`: whitespace runs collapsed to one space; an empty
/// result is refused.
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

/// `_public_trace_detail`.
fn public_trace_detail(value: &str) -> Result<String, String> {
    let message = public_message(value)?;
    if pattern::search(&COMMAND_LIKE_TRACE_RE, &message)
        || pattern::search(&PRIVATE_ACTIVITY_RE, &message)
    {
        return Err("trace messages must not contain raw commands or private details".to_string());
    }
    Ok(message)
}

/// Python's `repr(value)` for the messages that quote their input.
fn value_repr(value: &Value) -> String {
    match value {
        Value::Str(text) => str_repr(text),
        other => other.py_str(),
    }
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

/// `RelayCommandMetadata`, as the daemon builds it.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct RelayCommandMetadata {
    pub relay_command_seq: i64,
    pub relay_command_id: String,
    pub provider: Option<String>,
}

impl RelayCommandMetadata {
    /// `RelayCommandMetadata.from_dict(payload)`.
    pub fn from_dict(data: &Dict) -> Result<Self, String> {
        let command_id = data.text("relay_command_id");
        if command_id.is_empty() {
            return Err("relay command metadata requires relay_command_id".to_string());
        }
        Ok(Self {
            relay_command_seq: coerce_seq(data.get("relay_command_seq"))?,
            relay_command_id: command_id,
            provider: Some(data.text("provider")).filter(|text| !text.is_empty()),
        })
    }

    /// `to_public_dict`.
    pub fn to_public_dict(&self) -> Dict {
        let mut data = Dict::new();
        data.insert("relay_command_seq", self.relay_command_seq);
        data.insert("relay_command_id", self.relay_command_id.as_str());
        if let Some(provider) = &self.provider {
            data.insert("provider", provider.as_str());
        }
        data
    }
}

/// `str(value).upper()`, as both event types keep a ticket id.
fn upper_ticket_id(ticket_id: Option<&str>) -> Option<String> {
    ticket_id.map(str::to_uppercase)
}

/// `PMStatusEvent`: a public status event for the notch.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct PMStatusEvent {
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
        if let Some(ticket_id) = self.ticket_id.as_deref().filter(|id| !id.is_empty()) {
            data.insert("ticket_id", ticket_id);
        }
        data
    }
}

/// `default_orchestration_trace_message`.
fn default_orchestration_trace_message(
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
fn orchestration_trace_status_phase(kind: &str) -> &'static str {
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
struct OrchestrationTraceEvent {
    kind: String,
    source: String,
    message: String,
    command: Option<RelayCommandMetadata>,
    run_id: Option<i64>,
    ticket_id: Option<String>,
    lifecycle_detail: String,
}

impl OrchestrationTraceEvent {
    fn new(
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

    fn to_dict(&self) -> Dict {
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
        if let Some(ticket_id) = self.ticket_id.as_deref().filter(|id| !id.is_empty()) {
            data.insert("ticket_id", ticket_id);
        }
        data
    }

    fn to_status_event_dict(&self) -> Option<Dict> {
        let command = self.command.clone()?;
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_trace_payload_carries_the_default_wording() {
        let payload = orchestration_trace_payload(
            "ticket-created",
            Some("ct-7"),
            None,
            "orchestrator",
            None,
            None,
        )
        .unwrap();
        assert_eq!(payload.string("text"), "Created ticket CT-7");
        let event = payload.get("trace_event").and_then(Value::as_dict).unwrap();
        assert_eq!(event.string("ticket_id"), "CT-7");
        assert_eq!(event.string("lifecycle_detail"), "Created ticket CT-7");
        assert!(payload.get("status_event").is_none());
    }

    #[test]
    fn a_trace_with_its_command_has_a_status_event() {
        let mut command = Dict::new();
        command.insert("relay_command_seq", "3");
        command.insert("relay_command_id", "cmd-3");
        let payload = orchestration_trace_payload(
            "run-failed",
            Some("CT-1"),
            Some(9),
            "worker",
            None,
            Some(&command),
        )
        .unwrap();
        let status = payload
            .get("status_event")
            .and_then(Value::as_dict)
            .unwrap();
        assert_eq!(status.string("phase"), "outcome");
        assert_eq!(status.string("message"), "CT-1 run 9 failed");
        let metadata = status.get("command").and_then(Value::as_dict).unwrap();
        assert_eq!(
            metadata.get("relay_command_seq").and_then(Value::py_int),
            Some(3)
        );
    }

    #[test]
    fn private_or_unknown_traces_do_not_build() {
        assert!(
            orchestration_trace_payload("teleported", None, None, "orchestrator", None, None)
                .is_none()
        );
        assert!(
            orchestration_trace_payload(
                "building",
                None,
                None,
                "orchestrator",
                Some("running git status"),
                None
            )
            .is_none()
        );
        let long = "word ".repeat(40);
        let payload =
            orchestration_trace_payload("building", None, None, "worker", Some(&long), None)
                .unwrap();
        assert_eq!(
            payload.string("text").chars().count(),
            TRACE_MESSAGE_MAX_LEN
        );
        assert!(payload.string("text").ends_with("..."));
    }

    #[test]
    fn status_events_validate_like_python() {
        let mut data = Dict::new();
        data.insert("relay_command_seq", 1);
        data.insert("relay_command_id", "a");
        data.insert("provider", "claude");
        let command = RelayCommandMetadata::from_dict(&data).unwrap();
        let event = PMStatusEvent::new(
            "Outcome",
            "  Done \n now ",
            "orchestrator",
            command.clone(),
            None,
            Some("ct-2"),
        )
        .unwrap();
        let dict = event.to_dict();
        assert_eq!(dict.string("message"), "Done now");
        assert_eq!(dict.string("ticket_id"), "CT-2");
        assert_eq!(
            PMStatusEvent::new("later", "x", "pm", command, None, None).unwrap_err(),
            "invalid status phase: 'later'"
        );
        let mut missing = Dict::new();
        missing.insert("relay_command_id", "a");
        assert_eq!(
            RelayCommandMetadata::from_dict(&missing).unwrap_err(),
            "relay command metadata requires relay_command_seq"
        );
    }
}
