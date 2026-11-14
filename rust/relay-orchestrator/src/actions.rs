//! `POST /v1/orchestrator-actions`.

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;

impl Daemon {
    pub fn apply_orchestrator_actions_route(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: apply_orchestrator_actions_route",
        ))
    }
}
