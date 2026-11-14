//! Orchestrator sessions, the voice command ledger, messenger outcomes and the continuity lane.

use std::path::Path;

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;
use relay_services::continuity::lifecycle::ContinuityLifecycleAdapter;

impl Daemon {
    pub fn list_orchestrator_sessions_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: list_orchestrator_sessions_route",
        ))
    }

    pub fn pending_messenger_outcomes_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: pending_messenger_outcomes_route",
        ))
    }

    pub fn mark_messenger_outcome_delivered_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: mark_messenger_outcome_delivered_route",
        ))
    }

    pub fn record_messenger_outcome_attempt_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: record_messenger_outcome_attempt_route",
        ))
    }

    pub fn ensure_orchestrator_session_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: ensure_orchestrator_session_route",
        ))
    }

    pub fn heartbeat_orchestrator_session_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: heartbeat_orchestrator_session_route",
        ))
    }

    pub fn observe_continuity_event_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: observe_continuity_event_route",
        ))
    }

    pub fn stop_orchestrator_session_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: stop_orchestrator_session_route",
        ))
    }

    pub fn record_orchestrator_command_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: record_orchestrator_command_route",
        ))
    }

    pub fn get_continuity_report_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: get_continuity_report_route",
        ))
    }

    pub fn review_continuity_proposal_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: review_continuity_proposal_route",
        ))
    }
}

/// `ContinuityLifecycleAdapter(emit=self._emit_continuity_incident)`.
pub fn continuity_adapter(_data_root: &Path) -> ContinuityLifecycleAdapter {
    ContinuityLifecycleAdapter::new(None)
}

impl Daemon {
    /// `process_orchestrator_commands(limit)`: the command loop's work.
    pub fn process_orchestrator_commands(&self, _limit: i64) -> Outcome<()> {
        Ok(())
    }

    /// `sample_continuity()`: the continuity sampler's work.
    pub fn sample_continuity(&self) -> Outcome<()> {
        Ok(())
    }
}
