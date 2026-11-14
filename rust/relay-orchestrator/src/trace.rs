//! Lifecycle and orchestration traces: `_emit_lifecycle`,
//! `_notify_orchestration_trace`, `_orchestration_trace_payload` and
//! `_notify_state`.

use relay_intents::json::{Dict, Value};

use crate::daemon::Daemon;

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
    pub fn emit_lifecycle(&self, _event: &LifecycleEvent<'_>) -> Option<Dict> {
        None
    }

    /// `_notify_orchestration_trace(kind, ...)`.
    pub fn notify_orchestration_trace(
        &self,
        _kind: &str,
        _ticket_id: Option<&str>,
        _run_id: Option<i64>,
        _relay_command_seq: Option<&Value>,
        _relay_command_id: Option<&str>,
    ) {
    }

    /// `_notify_state(state, **fields)`: a datagram to the voice state socket.
    pub fn notify_state(&self, _state: &str, _fields: Dict) -> bool {
        false
    }
}
