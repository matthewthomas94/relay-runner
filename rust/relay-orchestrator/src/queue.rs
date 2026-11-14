//! Queue drains and the ready sweeps.

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;
use relay_intents::json::Dict;

impl Daemon {
    pub fn list_queue_drains_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: list_queue_drains_route"))
    }

    pub fn sweep_ready_tickets_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: sweep_ready_tickets_route",
        ))
    }

    pub fn sweep_program_ready_tickets_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: sweep_program_ready_tickets_route",
        ))
    }

    pub fn reconcile_queue_drains_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: reconcile_queue_drains_route",
        ))
    }

    pub fn cancel_queue_drain_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: cancel_queue_drain_route"))
    }
}

pub const QUEUE_DRAIN_MONITOR_INTERVAL_SECONDS: f64 = 5.0;

impl Daemon {
    /// `reconcile_queue_drains(repo_paths=..., trigger=...)`.
    pub fn reconcile_queue_drains(
        &self,
        _repo_paths: Option<Vec<String>>,
        _trigger: Option<&str>,
    ) -> Outcome<Dict> {
        Ok(Dict::new())
    }
}
