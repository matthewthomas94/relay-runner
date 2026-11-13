//! Public PM-frontstage status and orchestration traces for the notch and
//! the messenger, and the acknowledgement state (`voice_bridge.py`
//! `_pm_status_event_payload` to `_handle_orchestration_trace_control`, and
//! `_queue_voice_acknowledgement`).

use std::sync::Arc;

use super::commands::discard_pending_command;
use super::context::Bridge;
use super::orchestrator::{
    self, DaemonError, LocalDaemon, NotifyState, OrchestratorSession, PmUpdatePoll,
    PmUpdateSources, PmUpdateStep,
};
use super::pm_frontstage::{
    CurrentCommandReader, OrchestrationTraceEvent, PMStatusEvent, PMUpdateMode,
    RelayCommandMetadata, StatusEmitter, UpdateStatusReader, build_pm_update_snapshot,
};
use super::replies;
use super::settings::settings;
use super::speech::{acknowledgement_auto_dismiss_seconds, build_voice_acknowledgement};
use super::store::{self, read_json_file};
use super::turns;
use crate::json::{self, Dict, Value};

/// `_pm_status_event_payload`: a public PM status event from Relay metadata.
pub fn pm_status_event_payload(
    phase: &str,
    message: &str,
    source: &str,
    relay_command: &Dict,
    source_text: Option<&str>,
    ticket_id: Option<&str>,
    run_id: Option<i64>,
) -> Option<Dict> {
    let built = RelayCommandMetadata::from_dict(Some(relay_command), source_text)
        .and_then(|command| PMStatusEvent::new(phase, message, source, command, run_id, ticket_id));
    match built {
        Ok(event) => Some(event.to_dict()),
        Err(error) => {
            eprintln!("[voice_bridge] Could not build PM status event: {error}");
            None
        }
    }
}

/// `_coerce_optional_int`.
pub fn coerce_optional_int(value: Option<&Value>) -> Option<i64> {
    match value {
        None | Some(Value::Null) => None,
        Some(Value::Str(text)) if text.is_empty() => None,
        Some(value) => value.py_int(),
    }
}

/// `_orchestration_trace_payload`: `{"text", "trace_event"[, "status_event"]}`.
pub fn orchestration_trace_payload(
    kind: &str,
    relay_command: Option<&Dict>,
    source_text: Option<&str>,
    source: &str,
    message: Option<&str>,
    ticket_id: Option<&str>,
    run_id: Option<i64>,
) -> Option<Dict> {
    let command = match relay_command.filter(|command| !command.is_empty()) {
        Some(command) => match RelayCommandMetadata::from_dict(Some(command), source_text) {
            Ok(command) => Some(command),
            Err(error) => {
                eprintln!("[voice_bridge] Could not build orchestration trace: {error}");
                return None;
            }
        },
        None => None,
    };
    let event =
        match OrchestrationTraceEvent::new(kind, source, message, command, run_id, ticket_id) {
            Ok(event) => event,
            Err(error) => {
                eprintln!("[voice_bridge] Could not build orchestration trace: {error}");
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

/// `emit_orchestration_trace`: a short public trace to the notch while its
/// command is current.
#[allow(clippy::too_many_arguments)]
pub fn emit_orchestration_trace(
    bridge: &Bridge,
    kind: &str,
    relay_command: Option<&Dict>,
    source: &str,
    message: Option<&str>,
    ticket_id: Option<&str>,
    run_id: Option<i64>,
    state_path: &str,
) -> bool {
    if let Some(command) = relay_command.filter(|command| !command.is_empty()) {
        let seq = command.get("relay_command_seq");
        let id = command.get("relay_command_id");
        let has_seq = seq.is_some_and(|value| !matches!(value, Value::Null));
        if (has_seq || id.is_some_and(Value::truthy))
            && !turns::relay_command_current(seq, id, state_path)
        {
            eprintln!(
                "[voice_bridge] Dropping orchestration trace because its Relay command was superseded."
            );
            return false;
        }
    }
    let Some(payload) = orchestration_trace_payload(
        kind,
        relay_command,
        None,
        source,
        message,
        ticket_id,
        run_id,
    ) else {
        return false;
    };
    store::notify_state("working", payload.clone());
    if let Some(messenger) = bridge.messenger()
        && let Some(Value::Dict(trace_event)) = payload.get("trace_event")
    {
        messenger.submit_trace(trace_event.clone());
    }
    true
}

/// `_handle_orchestration_trace_control`: a `__TRACE__:` line.
pub fn handle_orchestration_trace_control(bridge: &Bridge, raw: &str, state_path: &str) -> bool {
    let text = json::py_strip(raw);
    if text.is_empty() {
        return true;
    }
    let data = match json::parse(text) {
        Some(Value::Dict(data)) => data,
        Some(_) => return true,
        None => {
            let mut data = Dict::new();
            data.insert("kind", "board-change");
            data.insert("message", text);
            data
        }
    };
    let mut relay_command = match data.get("relay_command").and_then(Value::as_dict) {
        Some(command) => command.clone(),
        None => read_json_file(&settings().claim_file),
    };
    if relay_command.is_empty() {
        relay_command = Dict::new();
    }
    let command = (!relay_command.is_empty()).then_some(&relay_command);
    replies::note_pm_trace(command);
    let kind = match data.truthy("kind") {
        Some(value) => value.py_str(),
        None => "board-change".to_string(),
    };
    let source = match data.truthy("source") {
        Some(value) => value.py_str(),
        None => "orchestrator".to_string(),
    };
    let message = data.present("message").map(|_| data.string("message"));
    let ticket_id = data.present("ticket_id").map(Value::py_str);
    emit_orchestration_trace(
        bridge,
        &kind,
        command,
        &source,
        message.as_deref(),
        ticket_id.as_deref(),
        coerce_optional_int(data.get("run_id")),
        state_path,
    )
}

/// `_queue_voice_acknowledgement`: the acknowledgement state for the newest
/// command, published while it is still current.
pub fn queue_voice_acknowledgement(
    relay_command: &Dict,
    source_text: Option<&str>,
    discard_pending: bool,
) -> bool {
    let acknowledgement = build_voice_acknowledgement(source_text, Some(relay_command));
    let text = json::py_strip(&acknowledgement);
    if text.is_empty() {
        return false;
    }
    let settings = settings();
    if discard_pending {
        discard_pending_command(&settings.cmd_file, &settings.cmd_meta_file);
    }
    let auto_dismiss = acknowledgement_auto_dismiss_seconds(text);
    let status_event = pm_status_event_payload(
        "acknowledged",
        text,
        "pm",
        relay_command,
        source_text,
        None,
        None,
    );
    if !turns::relay_command_current(
        relay_command.get("relay_command_seq"),
        relay_command.get("relay_command_id"),
        &settings.command_state_file,
    ) {
        eprintln!(
            "[voice_bridge] Dropping acknowledgement because its Relay command was superseded."
        );
        return true;
    }
    let mut payload = Dict::new();
    payload.insert("text", text);
    payload.insert("auto_dismiss_seconds", auto_dismiss);
    if let Some(status_event) = status_event {
        payload.insert("status_event", status_event);
    }
    store::notify_state("acknowledgement", payload);
    true
}

/// `_start_pm_update_mode` with its `PMUpdateMode` built over the daemon's
/// status for a ticket action's command.
pub fn start_pm_update_mode(
    bridge: &Bridge,
    metadata: &Dict,
    action_kind: &str,
    session: Option<Arc<OrchestratorSession>>,
    source_text: &str,
) {
    let relay_command = metadata.clone();
    let source_text = source_text.to_string();
    let notify: NotifyState =
        Arc::new(|state: &str, fields: Dict| store::notify_state(state, fields));
    orchestrator::start_pm_update_mode(
        action_kind,
        session.as_ref(),
        bridge.messenger_arc(),
        notify,
        Arc::new(LocalDaemon),
        move |sources: Arc<PmUpdateSources>| {
            let command =
                RelayCommandMetadata::from_dict(Some(&relay_command), Some(&source_text)).ok()?;
            let reader = Arc::clone(&sources);
            let status_reader: UpdateStatusReader<DaemonError> = Box::new(move || {
                let payloads = reader.fetch_status()?;
                build_pm_update_snapshot(
                    &reader.repo_path,
                    Some(&payloads.sessions),
                    Some(&payloads.runs),
                    Some(&payloads.program),
                    reader.provider.as_deref(),
                    reader.session_id,
                )
                // Python lets a malformed snapshot end the thread; here the
                // loop reports it like a failed fetch.
                .map_err(|_| DaemonError::Protocol("malformed PM update snapshot"))
            });
            let current = Arc::clone(&sources);
            let current_reader: CurrentCommandReader =
                Box::new(move || Some(current.current_command()));
            let emitter = Arc::clone(&sources);
            let emit: StatusEmitter =
                Box::new(move |event: &PMStatusEvent| emitter.emit(&event.to_dict()));
            let mut mode = PMUpdateMode::new(
                command,
                status_reader,
                Some(current_reader),
                Some(emit),
                settings().pm_update_cadence_seconds,
                settings().pm_update_startup_grace_seconds,
            );
            let poll: PmUpdatePoll = Box::new(move || {
                mode.poll(None).map(|result| PmUpdateStep {
                    continue_running: result.continue_running,
                    state: result.state,
                    stale: result.stale,
                })
            });
            Some(poll)
        },
    );
}
